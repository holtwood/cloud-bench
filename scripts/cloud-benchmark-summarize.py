#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""多云轻量主机性能横评 —— 汇总脚本

读取 results/hosts.tsv 主机清单 + 各主机目录下的**原始产物**（fio JSON / sysbench 日志 /
mpstat 日志 / YABS JSON / speedtest 输出 / PTS 日志），在本地重新解析为统一指标，
生成可排序的对比表：
    results/summary/compare.csv   机器可读（Excel / pandas 直接打开）
    results/summary/compare.md    Markdown 表格（直接贴进评测文章）
    results/summary/compare.json  结构化数据

为什么在本地重新解析（而不是直接用远端写的 metrics.tsv）：
  - 解析逻辑只维护一处，修正口径后可直接回填历史数据，**不必重跑数小时的采集**
  - 远端 metrics.tsv 仍会读取，仅作缺失项兜底（本地解析优先）
  - Python 处理 JSON / 文本比远端 shell+jq 更稳，格式变动时更好修

指标口径统一说明（写进文章时必须带上）：
  - 价格：hosts.tsv 的 price_cny 为「首年特惠价」，性价比按 首年价÷12 折算月价计算，
          不是续费价；续费价差异大时需在文章中另行标注。
  - 单核/多核：sysbench cpu --cpu-max-prime=20000，60s，取 events per second。
  - 4K IOPS：fio direct=1 bs=4k iodepth=32 numjobs=4 runtime=60s。
  - %steal：stress-ng 全核满载 20 分钟期间的 mpstat 平均值/峰值，反映邻居抢占（超售）。
  - YABS 4K：YABS 自带的 fio（混合读写 50/50，bs=4k），与上面的精测口径不同，仅作交叉印证。
  - 上行/下行：Ookla Speedtest；轻量套餐按「上行」标称带宽，下行通常显著更大。
"""

import csv
import json
import os
import re
import sys
from collections import OrderedDict

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = os.path.join(REPO_ROOT, "results")
HOSTS = os.path.join(RESULTS, "hosts.tsv")
OUT_DIR = os.path.join(RESULTS, "summary")

# 展示用列定义：(列名, 指标键, 小数位)
METRIC_COLS = [
    ("单核(events/s)",   "sysbench_cpu_single_eps", 1),
    ("多核(events/s)",   "sysbench_cpu_multi_eps", 1),
    ("4K读IOPS",         "fio_4k_randread_iops", 0),
    ("4K写IOPS",         "fio_4k_randwrite_iops", 0),
    ("4K读p99(ms)",      "fio_4k_randread_p99_ms", 2),
    ("4K写p99(ms)",      "fio_4k_randwrite_p99_ms", 2),
    ("顺序读(MiB/s)",    "fio_seq_read_mib_s", 1),
    ("顺序写(MiB/s)",    "fio_seq_write_mib_s", 1),
    ("内存带宽(MiB/s)",  "sysbench_mem_single_mib_s", 0),
    ("下行(Mbps)",       "speedtest_down_mbps", 2),
    ("上行(Mbps)",       "speedtest_up_mbps", 2),
    ("ping(ms)",         "speedtest_latency_ms", 1),
    ("满载%steal(均)",   "stress_avg_steal_pct", 2),
    ("满载%steal(峰)",   "stress_max_steal_pct", 2),
    ("YABS4K总IOPS",     "yabs_4k_total_iops", 0),
    ("7z压缩(MIPS)",     "pts_7zip_compress_mips", 0),
    ("redis SET(RPS)",   "pts_redis_rps", 0),
]


# ---------------------------------------------------------------------------
# 原始产物解析
# ---------------------------------------------------------------------------
def _load_json(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return json.load(fh)
    except Exception:
        return None


def _read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except Exception:
        return ""


def _fio_job_metrics(path, rw, prefix):
    """解析 fio JSON：IOPS / 带宽 / p99（延迟单位 us → ms）"""
    j = _load_json(path)
    if not j or not j.get("jobs"):
        return {}
    job = j["jobs"][0]
    sec = job.get(rw) or {}
    out = {}
    if sec.get("iops"):
        out[f"{prefix}_iops"] = sec["iops"]
    if sec.get("bw"):
        out[f"{prefix}_bw"] = sec["bw"] / 1024.0          # KiB/s → MiB/s
    pct = (sec.get("clat_ns") or {}).get("percentile") or {}
    if pct:
        # 键形如 "99.000000"
        for k, v in pct.items():
            try:
                if abs(float(k) - 99.0) < 1e-6:
                    out[f"{prefix}_p99_ms"] = v / 1e6        # ns → ms
                    break
            except ValueError:
                continue
    return out


def parse_fio(d):
    """fio 精测：4K 随机读/写（含 p99）+ 顺序读/写"""
    m = {}
    m.update(_fio_job_metrics(os.path.join(d, "fio-4k-randread.json"), "read", "fio_4k_randread"))
    m.update(_fio_job_metrics(os.path.join(d, "fio-4k-randwrite.json"), "write", "fio_4k_randwrite"))
    for rw, key in (("read", "fio_seq_read_mib_s"), ("write", "fio_seq_write_mib_s")):
        j = _load_json(os.path.join(d, f"fio-seq-{rw}.json"))
        if j and j.get("jobs"):
            bw = (j["jobs"][0].get(rw) or {}).get("bw")
            if bw:
                m[key] = bw / 1024.0
    return m


def parse_sysbench(d):
    """sysbench：CPU 单核/全核 events/s，内存带宽 MiB/s

    ⚠️ 必须**按测试段**解析（2026-09-13 对抗性复查）：
    sysbench memory 测试**也输出 `events per second`**（且紧跟在 CPU 测试之后）——
    若用全局 findall 取前两个 eps，一旦 CPU 某段失败，内存的 eps 会错位顶替
    成「CPU 成绩」，静默污染数据。故按脚本写入的 `--- 段标题 ---` 分隔符切片。
    """
    txt = _read_text(os.path.join(d, "sysbench.log"))
    if not txt:
        return {}
    m = {}
    # 段标题由 cloud-benchmark.sh 写入，切片定位各测试的输出区
    def seg(start_marker, end_marker=None):
        i = txt.find(start_marker)
        if i < 0:
            return ""
        j = txt.find(end_marker, i) if end_marker else len(txt)
        return txt[i:j]

    cpu1 = seg("--- CPU 单线程 60s ---", "--- CPU 全核")
    cpuN = seg("--- CPU 全核", "--- 内存带宽")
    mem1 = seg("--- 内存带宽（1M 块，单线程，60s）---", "--- 内存带宽（1M 块，全核")
    memN = seg("--- 内存带宽（1M 块，全核")
    for blob, key in ((cpu1, "sysbench_cpu_single_eps"),
                      (cpuN, "sysbench_cpu_multi_eps")):
        v = re.search(r"events per second:\s*([0-9.]+)", blob)
        if v:
            m[key] = float(v.group(1))
    for blob, key in ((mem1, "sysbench_mem_single_mib_s"),
                      (memN, "sysbench_mem_multi_mib_s")):
        v = re.search(r"([0-9.]+)\s*MiB/sec", blob)
        if v:
            m[key] = float(v.group(1))
    return m


def parse_stress(d):
    """超售检测：mpstat 的 %steal（均值/峰值）与 %idle 均值"""
    txt = _read_text(os.path.join(d, "mpstat.log"))
    if not txt:
        return {}
    steal_idx = idle_idx = None
    steals, idles = [], []
    for line in txt.splitlines():
        parts = line.split()
        if "%steal" in parts:
            steal_idx = parts.index("%steal")
            idle_idx = parts.index("%idle") if "%idle" in parts else None
            continue
        if steal_idx is None or line.startswith(("Linux", "Average:")):
            continue
        if len(parts) <= steal_idx:
            continue
        try:
            steals.append(float(parts[steal_idx]))
            if idle_idx is not None and len(parts) > idle_idx:
                idles.append(float(parts[idle_idx]))
        except (ValueError, IndexError):
            continue
    m = {}
    if steals:
        m["stress_avg_steal_pct"] = sum(steals) / len(steals)
        m["stress_max_steal_pct"] = max(steals)
        m["stress_samples"] = len(steals)
    if idles:
        m["stress_avg_idle_pct"] = sum(idles) / len(idles)
    return m


def parse_yabs(d):
    """YABS：4K 混合 fio（交叉印证）、Geekbench 结果链接、运行时长"""
    j = None
    for cand in ("yabs-result.json", "yabs_result.json", "result.json"):
        j = _load_json(os.path.join(d, cand))
        if j:
            break
    if not j:
        return {}
    m = {}
    for entry in (j.get("fio") or []):
        if entry.get("bs") == "4k":
            if entry.get("iops_r"):
                m["yabs_4k_read_iops"] = entry["iops_r"]
            if entry.get("iops_w"):
                m["yabs_4k_write_iops"] = entry["iops_w"]
            if entry.get("iops_rw"):
                m["yabs_4k_total_iops"] = entry["iops_rw"]
            break
    gb = (j.get("geekbench") or [{}])[0]
    if gb.get("url"):
        m["yabs_geekbench_url"] = gb["url"]
    # 注意：YABS v2026-07-24 与 Geekbench 6 存在兼容问题，single/multi 常为 null
    if gb.get("single"):
        m["yabs_geekbench_single"] = gb["single"]
    if gb.get("multi"):
        m["yabs_geekbench_multi"] = gb["multi"]
    if (j.get("runtime") or {}).get("elapsed"):
        m["yabs_elapsed_sec"] = j["runtime"]["elapsed"]
    return m


def parse_speedtest(d):
    """Ookla Speedtest：首次运行会先打印 EULA 文本，结果 JSON 在后面某一行"""
    txt = _read_text(os.path.join(d, "speedtest.json")) or _read_text(os.path.join(d, "speedtest.log"))
    if not txt:
        return {}
    m = {}
    line = None
    for cand in reversed(txt.splitlines()):
        if '"type":"result"' in cand:
            line = cand
            break
    if not line:
        return {}
    try:
        res = json.loads(line)
    except Exception:
        return {}
    dl = (res.get("download") or {}).get("bandwidth")
    ul = (res.get("upload") or {}).get("bandwidth")
    ping = res.get("ping") or {}
    if dl:
        m["speedtest_down_mbps"] = dl / 125000.0          # bytes/s → Mbps
    if ul:
        m["speedtest_up_mbps"] = ul / 125000.0
    if ping.get("latency") is not None:
        m["speedtest_latency_ms"] = ping["latency"]
    if ping.get("jitter") is not None:
        m["speedtest_jitter_ms"] = ping["jitter"]
    return m


def parse_pts(d):
    """Phoronix Test Suite：提取 7-Zip 压缩/解压平均分（最稳定可比的单项）"""
    txt = _read_text(os.path.join(d, "pts.log"))
    if not txt:
        return {}
    # ⚠️ 必须先剥离 ANSI 颜色码：PTS 在有 pty 时会输出彩色，
    #    形如 `Average: \x1b[1;34m16484 MIPS\x1b[0m`——转义序列夹在
    #    `Average:` 与数字之间，会让 `Average:\s*[0-9.]+` 直接匹配失败
    #    （实测踩坑：火山云有 tmux→有 pty→带色，成绩被漏掉；天翼云用 nohup 无色）。
    txt = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", txt)
    m = {}
    # PTS 的 7-Zip 输出形如（注意样本与 Average 之间**有空行**）：
    #     Test: Compression Rating:
    #         11669
    #         11669
    #         11668
    #
    #     Average: 11669 MIPS
    # ⚠️ 不要用「从 label 匹配到第一个空行」的写法——那会在样本后即中止，
    #    永远取不到 Average（实测踩坑：成绩明明在日志里，表格却全是「—」）。
    #    改为从 label 位置向后取一段窗口再找带 MIPS 单位的 Average。
    for label, key in (("Compression Rating", "pts_7zip_compress_mips"),
                       ("Decompression Rating", "pts_7zip_decompress_mips")):
        start = txt.find(label + ":")
        if start >= 0:
            seg = txt[start:start + 3000]
            avg = re.search(r"Average:\s*([0-9.]+)\s*MIPS", seg)
            if avg:
                m[key] = float(avg.group(1))
    # Redis SET 吞吐：`Test: SET - Parallel Connections: 50:` 后的
    # `Average: 969045.25 Requests Per Second`（注意带逗号千分位时先去掉逗号）
    for label, key in (("SET - Parallel Connections: 50:", "pts_redis_rps"),):
        start = txt.find(label)
        if start >= 0:
            seg = txt[start:start + 3000]
            avg = re.search(r"Average:\s*([0-9.,]+)\s*Requests Per Second", seg)
            if avg:
                m[key] = float(avg.group(1).replace(",", ""))
    # batch 模式未配置时 PTS 只下载不跑（留下这条 NOTICE）
    if "batch mode must first be configured" in txt:
        m["_pts_batch_unconfigured"] = True
    if re.search(r"^\s*Estimated Download Time", txt, re.M) and \
       not re.search(r"Average:\s*[0-9.]+", txt):
        m["_pts_only_downloaded"] = True
    return m


def parse_remote_metrics(d):
    """远端脚本写的 metrics.tsv（作为本地解析的兜底）"""
    m = {}
    path = os.path.join(d, "metrics.tsv")
    if not os.path.isfile(path):
        return m
    for line in _read_text(path).splitlines():
        parts = line.split("\t")
        if len(parts) >= 2 and parts[1] not in ("", "null"):
            try:
                m[parts[0]] = float(parts[1])
            except ValueError:
                m[parts[0]] = parts[1]
    return m


def collect_metrics(name):
    """本地解析优先，远端 metrics.tsv 补缺"""
    d = os.path.join(RESULTS, name)
    local = {}
    for fn in (parse_fio, parse_sysbench, parse_stress, parse_yabs, parse_speedtest, parse_pts):
        try:
            local.update({k: v for k, v in fn(d).items() if v is not None})
        except Exception as exc:                          # 单文件异常不影响整体
            print(f"  [warn] {name} {fn.__name__} 解析异常: {exc}", file=sys.stderr)
    remote = parse_remote_metrics(d)
    merged = dict(remote)
    merged.update(local)                                  # 本地优先
    return merged, local, remote


# ---------------------------------------------------------------------------
# 主机清单
# ---------------------------------------------------------------------------
def read_hosts():
    host_list = []
    if not os.path.isfile(HOSTS):
        print(f"[ERR] 主机清单不存在: {HOSTS}", file=sys.stderr)
        return host_list
    for line in _read_text(HOSTS).splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        p = line.split("\t")
        if len(p) < 12:
            continue
        host_list.append(OrderedDict([
            ("name", p[0].strip()), ("ssh_alias", p[1].strip()), ("ip", p[2].strip()),
            ("user", p[3].strip()), ("port", p[4].strip()), ("vendor", p[5].strip()),
            ("spec", p[6].strip()), ("vcpu", p[7].strip()), ("ram_gb", p[8].strip()),
            ("bandwidth", p[9].strip()), ("price_cny", p[10].strip()),
            ("price_note", p[11].strip()),
            ("role", p[12].strip() if len(p) > 12 else ""),
        ]))
    return host_list


def read_cpu_model(name):
    """优先 system-info.txt 的 Model name，回落到 YABS JSON"""
    txt = _read_text(os.path.join(RESULTS, name, "system-info.txt"))
    for line in txt.splitlines():
        if line.strip().startswith("Model name:"):
            return line.split(":", 1)[1].strip()
    j = _load_json(os.path.join(RESULTS, name, "yabs-result.json"))
    if j:
        return (j.get("cpu") or {}).get("model", "—")
    return "—"


def read_stages_done(name):
    d = os.path.join(RESULTS, name)
    checks = [
        ("env", "system-info.txt"), ("yabs", "yabs.log"), ("pts", "pts.log"),
        ("fio", "fio.log"), ("sysbench", "sysbench.log"),
        ("stress", "stress-ng.log"), ("net", "speedtest.log"),
    ]
    done, missing = [], []
    for stage, fname in checks:
        (done if os.path.isfile(os.path.join(d, fname)) else missing).append(stage)
    return done, missing


def fmt(val, ndigits):
    if val is None or val == "":
        return "—"
    try:
        return f"{float(val):,.{ndigits}f}"
    except (TypeError, ValueError):
        return str(val)


# ---------------------------------------------------------------------------
def main():
    host_list = read_hosts()
    if not host_list:
        print("[ERR] 没有可汇总的主机，检查 results/hosts.tsv", file=sys.stderr)
        return 1

    os.makedirs(OUT_DIR, exist_ok=True)
    rows, raw = [], []
    notes = []

    for h in host_list:
        m, local, remote = collect_metrics(h["name"])
        done, missing = read_stages_done(h["name"])
        cpu_model = read_cpu_model(h["name"])

        try:
            price_month = float(h["price_cny"]) / 12.0
        except ValueError:
            price_month = None

        if m.get("_pts_batch_unconfigured") or m.get("_pts_only_downloaded"):
            notes.append(f"{h['name']}：PTS 未产出成绩（batch 模式未配置或仅完成下载）")

        row = OrderedDict()
        row["云商"] = h["vendor"]
        row["规格"] = h["spec"]
        row["CPU型号"] = cpu_model
        row["vCPU"] = h["vcpu"]
        row["带宽"] = h["bandwidth"]
        row["首年价(元)"] = h["price_cny"]
        row["折合月价(元)"] = fmt(price_month, 2) if price_month else "—"

        for label, key, nd in METRIC_COLS:
            row[label] = fmt(m.get(key), nd)

        if price_month:
            row["CPU性价比(多核/月价)"] = fmt(float(m["sysbench_cpu_multi_eps"]) / price_month, 1) \
                if m.get("sysbench_cpu_multi_eps") else "—"
            row["IOPS性价比(读/月价)"] = fmt(float(m["fio_4k_randread_iops"]) / price_month, 0) \
                if m.get("fio_4k_randread_iops") else "—"
        else:
            row["CPU性价比(多核/月价)"] = "—"
            row["IOPS性价比(读/月价)"] = "—"

        row["数据完整度"] = f"{len(done)}/7" + (f"（缺 {','.join(missing)}）" if missing else "")
        row["备注"] = h["role"]
        rows.append(row)
        raw.append({"host": h, "metrics": m, "local_parsed": local,
                    "remote_metrics": remote, "stages_done": done,
                    "stages_missing": missing})

    columns = list(rows[0].keys())

    csv_path = os.path.join(OUT_DIR, "compare.csv")
    with open(csv_path, "w", newline="", encoding="utf-8-sig") as fh:
        w = csv.DictWriter(fh, fieldnames=columns)
        w.writeheader()
        w.writerows(rows)

    md_path = os.path.join(OUT_DIR, "compare.md")
    with open(md_path, "w", encoding="utf-8") as fh:
        fh.write("# 多云轻量主机性能横评 —— 对比表\n\n")
        fh.write("> 价格口径：**首年特惠价**，性价比按 首年价÷12 折算月价计算，非续费价。\n")
        fh.write("> 数据由 `scripts/cloud-benchmark-summarize.py` 从各主机原始产物（fio JSON / "
                 "sysbench / mpstat / YABS / Speedtest / PTS 日志）本地重新解析生成。\n\n")
        fh.write("| " + " | ".join(columns) + " |\n")
        fh.write("|" + "|".join(["---"] * len(columns)) + "|\n")
        for r in rows:
            fh.write("| " + " | ".join(str(r[c]) for c in columns) + " |\n")
        fh.write("\n## 关键结论\n\n")
        for metric in ("单核(events/s)", "多核(events/s)", "4K读IOPS", "满载%steal(均)", "上行(Mbps)"):
            valid = [(r["云商"], r[metric]) for r in rows if r[metric] != "—"]
            if len(valid) >= 2:
                def num(x):
                    return float(str(x[1]).replace(",", ""))
                try:
                    hi = max(valid, key=num)
                    lo = min(valid, key=num)
                    fh.write(f"- **{metric}**：最高 {hi[0]}（{hi[1]}），最低 {lo[0]}（{lo[1]}）\n")
                except ValueError:
                    pass
        if notes:
            fh.write("\n## 数据说明\n\n")
            for n in notes:
                fh.write(f"- {n}\n")
        fh.write("\n")
        # 附：YABS Geekbench 结果链接（分数需从网页查看）
        gb = [(r["云商"], raw[i]["metrics"].get("yabs_geekbench_url"))
              for i, r in enumerate(rows) if raw[i]["metrics"].get("yabs_geekbench_url")]
        if gb:
            fh.write("### Geekbench 6 结果链接\n\n")
            for vendor, url in gb:
                fh.write(f"- {vendor}: {url}\n")

    json_path = os.path.join(OUT_DIR, "compare.json")
    with open(json_path, "w", encoding="utf-8") as fh:
        json.dump({"columns": columns, "rows": rows, "raw": raw},
                  fh, ensure_ascii=False, indent=2, default=str)

    print(f"[ OK ] 已生成对比表（{len(rows)} 台主机）")
    for p in (csv_path, md_path, json_path):
        print(f"       {p}")
    for r in rows:
        print(f"  - {r['云商']:<6} {r['规格']:<6} 数据完整度={r['数据完整度']}")
    for n in notes:
        print(f"  [!] {n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
