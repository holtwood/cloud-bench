#!/usr/bin/env python3
"""把评测产物转换成结果 JSON —— 可直接提交到 Cloud Bench 站点。

用法::

    # 只生成 JSON（默认输出到 stdout）
    ./scripts/to-result.py --name mycloud-2c2g-01 -o result.json

    # 生成并提交到站点
    ./scripts/to-result.py --name mycloud-2c2g-01 --submit https://bench.example.com

环境变量::

    BENCH_API_KEY   提交密钥。**推荐用环境变量**——写成 --key 参数会留在 shell 历史里。

机器元信息（云商 / 规格 / 价格 / 地区）从 ``results/hosts.tsv`` 读，
即你已经为跑测试填好的那份清单，不需要再填一遍。

设计说明
--------
本脚本是「评测 → 数据」的最后一环：把 ``results/<name>/`` 下的原始产物
（fio JSON / sysbench / mpstat / YABS / Speedtest / PTS 日志）解析成统一 schema。

**为什么优先从原始产物解析，而不是读 metrics.tsv**：metrics.tsv 由采集脚本在远端
生成，历史上出现过两类缺失（旧版提取有 bug、重跑 PTS 覆盖日志），原始产物才是权威来源。
"""
import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

# 零值即缺失的指标：实测必然 > 0，0 只可能是「未跑 / 跑失败 / 解析失败」。
# 注意 steal_avg_pct 刻意不在列——满载 0% 抢占是合法且有意义的结果（说明没超售）。
ZERO_MEANS_MISSING = (
    "cpu_single_eps", "cpu_multi_eps",
    "sevenzip_compress_mips", "sevenzip_decompress_mips", "kernel_build_sec",
    "disk_4k_read_iops", "disk_4k_write_iops",
    "disk_4k_read_p99_ms", "disk_4k_write_p99_ms",
    "disk_seq_read_mibs", "disk_seq_write_mibs",
    "mem_bandwidth_mibs",
    "net_down_mbps", "net_up_mbps", "net_ping_ms",
    "redis_rps", "yabs_4k_total_iops",
)


def _read_text(path):
    if not os.path.isfile(path):
        return ""
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def _load_json(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return json.load(fh)
    except Exception:
        return None


def _strip_ansi(txt):
    return re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", txt)


# ---------------------------------------------------------------------------
# 各产物的解析
# ---------------------------------------------------------------------------
def read_metrics(results_dir, name):
    """读 metrics.tsv（远端脚本写的键值表）作为兜底来源"""
    m = {}
    for line in _read_text(os.path.join(results_dir, name, "metrics.tsv")).splitlines():
        parts = line.split("\t")
        if len(parts) >= 2 and parts[1] not in ("", "null"):
            try:
                m[parts[0]] = float(parts[1])
            except ValueError:
                pass
    return m


def read_sysinfo(results_dir, name):
    """从 system-info.txt 提取 CPU 型号 / 物理核 / 线程 / 指令集 / 内核"""
    info = {"cpu_model": "", "physical_cores": 0, "threads": 0,
            "avx512": False, "kernel": ""}
    txt = _read_text(os.path.join(results_dir, name, "system-info.txt"))
    if not txt:
        return info
    for line in txt.splitlines():
        s = line.strip()
        if s.startswith("Model name:"):
            info["cpu_model"] = s.split(":", 1)[1].strip()
        elif s.startswith("CPU(s):"):
            try:
                info["threads"] = int(s.split(":")[1].strip())
            except ValueError:
                pass
        elif "Thread(s) per core" in line:
            info["_tpc"] = _tail_int(line)
        elif "Core(s) per socket" in line:
            info["_cps"] = _tail_int(line)
        elif "Socket(s)" in line:
            info["_socks"] = _tail_int(line)
        elif s.lower().startswith("kernel:"):
            info["kernel"] = s.split(":", 1)[1].strip()
    if all(info.get(k) for k in ("_tpc", "_cps", "_socks")):
        info["physical_cores"] = info["_cps"] * info["_socks"]
    # AVX-512 判定：lscpu 的 Flags 行可能折行，先归一化空白再找
    info["avx512"] = "avx512f" in re.sub(r"\s+", " ", txt)
    return info


def _tail_int(line):
    try:
        return int(line.split(":")[-1].strip())
    except ValueError:
        return None


def _pts_log(results_dir, name):
    return _strip_ansi(_read_text(os.path.join(results_dir, name, "pts.log")))


def _pts_metric(results_dir, name, label, unit, fallback_key=None):
    """按 label 窗口从 pts.log 取 Average 值；解析不到时回落 metrics.tsv。

    双重来源的原因：重跑 PTS 会覆盖 pts.log（只剩最后跑的那项），
    而旧版脚本写 metrics.tsv 时又有提取 bug。两边都试才能拿到全。
    """
    txt = _pts_log(results_dir, name)
    start = txt.find(label)
    if start >= 0:
        m = re.search(r"Average:\s*([0-9.,]+)\s*" + unit, txt[start:start + 3000])
        if m:
            return float(m.group(1).replace(",", ""))
    if fallback_key:
        return float(read_metrics(results_dir, name).get(fallback_key, 0))
    return 0.0


def _kernel_build(results_dir, name):
    """内核编译秒数（PTS 的 Average: N Seconds）"""
    for m in re.finditer(r"Average:\s*([0-9.]+)\s*Seconds", _pts_log(results_dir, name)):
        return float(m.group(1))
    return 0.0


def _yabs_4k(results_dir, name):
    """YABS JSON 里的 4K 总 IOPS（结构是 fio[].iops_rw，不是 .read.iops）"""
    for fname in ("yabs-result.json", "yabs_result.json", "result.json"):
        j = _load_json(os.path.join(results_dir, name, fname))
        if not j:
            continue
        for e in j.get("fio", []):
            if e.get("bs") == "4k":
                return float(e.get("iops_rw", 0))
    return 0.0


def _speedtest(results_dir, name):
    """Speedtest 的上下行与延迟（Ookla 首次运行会先打印 EULA，结果在其后）"""
    out = {"down": 0.0, "up": 0.0, "ping": 0.0}
    for fname in ("speedtest.json", "speedtest.log"):
        txt = _read_text(os.path.join(results_dir, name, fname))
        if not txt:
            continue
        for line in reversed(txt.splitlines()):
            if '"type":"result"' in line:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                out["down"] = r.get("download", {}).get("bandwidth", 0) / 125000
                out["up"] = r.get("upload", {}).get("bandwidth", 0) / 125000
                out["ping"] = r.get("ping", {}).get("latency", 0)
                return out
    return out


def _fio_file_size(results_dir, name):
    """fio 单文件大小（GB）——脚本按磁盘余量自适应，属影响可比性的口径元信息"""
    j = _load_json(os.path.join(results_dir, name, "fio-4k-randread.json"))
    if not j:
        return 0
    sz = j.get("jobs", [{}])[0].get("job options", {}).get("size", "")
    m = re.match(r"^(\d+)\s*([GM])$", str(sz).strip(), re.I)
    if not m:
        return 0
    n, unit = int(m.group(1)), m.group(2).upper()
    return n if unit == "G" else max(1, round(n / 1024))


def _tested_at(results_dir, name):
    """从 progress.log 取测试完成日期（而不是取提交当天——两者可能差很久）"""
    txt = _read_text(os.path.join(results_dir, name, "progress.log"))
    dates = re.findall(r"\[(\d{4}-\d{2}-\d{2})T", txt)
    return dates[-1] if dates else ""


def _stages(results_dir, name):
    """从 progress.log 里实际出现的阶段名推导（不硬编码）"""
    txt = _read_text(os.path.join(results_dir, name, "progress.log"))
    seen = []
    for m in re.finditer(r"阶段开始:\s*(\w+)", txt):
        if m.group(1) not in seen:
            seen.append(m.group(1))
    return seen


# ---------------------------------------------------------------------------
# 主机清单（hosts.tsv）—— 元信息不再硬编码
# ---------------------------------------------------------------------------
# 列定义（制表符分隔）：
#   1 name  2 ssh_alias  3 ssh_host_ip  4 user  5 port  6 vendor  7 spec
#   8 vcpu  9 ram_gb  10 bandwidth  11 price_cny  12 price_note  13 role
#  14 region（可选）  15 vendor_type（可选）
def read_hosts(hosts_file):
    hosts = {}
    for line in _read_text(hosts_file).splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        f = line.split("\t")
        if len(f) < 13:
            continue
        hosts[f[0].strip()] = {
            "name": f[0].strip(), "vendor": f[5].strip(), "spec": f[6].strip(),
            "vcpu": f[7].strip(), "ram_gb": f[8].strip(), "bandwidth": f[9].strip(),
            "price_cny": f[10].strip(), "price_note": f[11].strip(), "role": f[12].strip(),
            "region": f[13].strip() if len(f) > 13 else "",
            "vendor_type": f[14].strip() if len(f) > 14 else "",
        }
    return hosts


def build_result(results_dir, hosts, name, submitter=""):
    """组装一台机器的结果对象（与站点 models.go 的 schema 对应）"""
    h = hosts.get(name)
    if not h:
        raise SystemExit(f"[ERR] hosts.tsv 里没有 '{name}'——先加一行再跑测试")

    raw = read_metrics(results_dir, name)
    info = read_sysinfo(results_dir, name)
    st = _speedtest(results_dir, name)

    try:
        ram = int(h["ram_gb"])
    except ValueError:
        ram = 0

    metrics = {
        "cpu_single_eps": raw.get("sysbench_cpu_single_eps", 0),
        "cpu_multi_eps": raw.get("sysbench_cpu_multi_eps", 0),
        "sevenzip_compress_mips": _pts_metric(results_dir, name, "Compression Rating:", "MIPS", "pts_7zip_compress_mips"),
        "sevenzip_decompress_mips": _pts_metric(results_dir, name, "Decompression Rating:", "MIPS", "pts_7zip_decompress_mips"),
        "kernel_build_sec": _kernel_build(results_dir, name),
        "disk_4k_read_iops": raw.get("fio_4k_randread_iops", 0),
        "disk_4k_write_iops": raw.get("fio_4k_randwrite_iops", 0),
        "disk_4k_read_p99_ms": raw.get("fio_4k_randread_p99_us", 0) / 1000,
        "disk_4k_write_p99_ms": raw.get("fio_4k_randwrite_p99_us", 0) / 1000,
        "disk_seq_read_mibs": raw.get("fio_seq_read_mib_s", 0),
        "disk_seq_write_mibs": raw.get("fio_seq_write_mib_s", 0),
        "mem_bandwidth_mibs": raw.get("sysbench_mem_single_mib_s", 0),
        "net_down_mbps": st["down"],
        "net_up_mbps": st["up"],
        "net_ping_ms": st["ping"],
        "steal_avg_pct": raw.get("stress_avg_steal_pct", 0),
        "redis_rps": _pts_metric(results_dir, name, "SET - Parallel Connections: 50:", "Requests Per Second", "pts_redis_rps"),
        "yabs_4k_total_iops": raw.get("yabs_4k_total_iops", 0) or _yabs_4k(results_dir, name),
    }

    stages = _stages(results_dir, name)
    return {
        "machine": {
            "id": name,
            "vendor": h["vendor"],
            "vendor_type": h["vendor_type"],
            "spec": h["spec"],
            "cpu_model": info["cpu_model"],
            "physical_cores": info["physical_cores"] or int(h["vcpu"] or 0),
            "threads": info["threads"] or int(h["vcpu"] or 0),
            "avx512": info["avx512"],
            "ram_gb": ram,
            "bandwidth": h["bandwidth"],
            "price_cny": int(h["price_cny"] or 0),
            "price_note": h["price_note"],
            "region": h["region"],
            "role": h["role"],
            "kernel": info["kernel"],
            "tested_at": _tested_at(results_dir, name),
            "submitter": submitter,
            "fio_file_size_gb": _fio_file_size(results_dir, name),
        },
        "metrics": metrics,
        "stages_done": stages,
        "stages_missing": [],
        # 提示：服务端会按实际指标重算该字段（提交者声明无效），这里填的是本地视角
        "metrics_missing": [k for k in ZERO_MEANS_MISSING if not metrics.get(k)],
    }


def post_result(url, key, payload):
    """提交到站点。失败时给出可操作的提示，而不是只抛一个 HTTP 码。"""
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        url.rstrip("/") + "/api/submit", data=data, method="POST",
        headers={"Content-Type": "application/json", "X-API-Key": key},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def main():
    ap = argparse.ArgumentParser(description="把评测产物转成结果 JSON（可提交到站点）")
    ap.add_argument("--name", required=True, help="主机名（对应 hosts.tsv 与 results/<name>/）")
    ap.add_argument("--results", default="results", help="产物根目录（默认 ./results）")
    ap.add_argument("--hosts", default="", help="主机清单路径（默认 <results>/hosts.tsv）")
    ap.add_argument("-o", "--output", default="", help="输出文件（默认打印到 stdout）")
    ap.add_argument("--submit", default="", metavar="URL", help="生成后直接提交到该站点")
    ap.add_argument("--key", default="", help="提交密钥（建议改用 BENCH_API_KEY 环境变量）")
    ap.add_argument("--submitter", default="", help="提交者标识（默认取 git user.name）")
    args = ap.parse_args()

    results_dir = args.results
    hosts_file = args.hosts or os.path.join(results_dir, "hosts.tsv")
    submitter = args.submitter
    if not submitter:
        try:
            import subprocess
            submitter = subprocess.run(["git", "config", "user.name"], capture_output=True,
                                       text=True, timeout=5).stdout.strip()
        except Exception:
            submitter = ""

    result = build_result(results_dir, read_hosts(hosts_file), args.name, submitter)

    # 本地视角的缺口提示（让用户知道哪些项没测到，而不是上传一堆 0 值还不自知）
    missing = result["metrics_missing"]
    if missing:
        print(f"[!] {len(missing)} 项指标没有值（阶段未跑或子项失败）：{', '.join(missing)}",
              file=sys.stderr)

    text = json.dumps(result, ensure_ascii=False, indent=2)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
        print(f"[OK] 已写出 {args.output}")
    elif args.submit:
        # 提交模式下只给一行摘要——把整份 JSON 灌到终端没有意义，还盖住了提交结果
        m, mt = result["machine"], result["metrics"]
        print(f"[i] {m['id']}  {m['vendor']} {m['spec']}  "
              f"单核 {mt['cpu_single_eps']:.0f} eps  "
              f"4K读 {mt['disk_4k_read_iops']:.0f} IOPS  "
              f"p99 {mt['disk_4k_read_p99_ms']:.2f}ms")
    else:
        print(text)

    if args.submit:
        key = args.key or os.environ.get("BENCH_API_KEY", "")
        if not key:
            raise SystemExit("[ERR] 缺少提交密钥：设 BENCH_API_KEY 环境变量，或用 --key")
        code, body = post_result(args.submit, key, result)
        if code in (200, 201):
            print(f"[OK] 已提交到 {args.submit}：{body.strip()}")
        else:
            print(f"[ERR] 提交失败 HTTP {code}: {body.strip()[:300]}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
