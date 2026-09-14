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
# 产物目录：可用 CB_RESULTS_DIR 覆盖 —— 工具与数据可以分处两个仓库
RESULTS = os.environ.get("CB_RESULTS_DIR") or os.path.join(REPO_ROOT, "results")
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


# ---------------------------------------------------------------------------
# 单机「人话报告」—— 面向初级用户
# ---------------------------------------------------------------------------
# 初级用户不读 p99 数字，他们要的是「行还是不行」。所以每项都给出：
#   实测值 → 等级 → 一句人话；最后落到「这台机器能跑什么」。
#
# 阈值取自 2026-09 六台轻量云实测（腾讯云×4 / 火山云 / 天翼云）：
#   4K 读 IOPS   <5,000 偏弱 | 5,000~15,000 一般 | >15,000 良好   (实测 2,302~26,059)
#   p99 延迟     >100ms 偏弱 | 20~100ms 一般    | <20ms 良好      (实测 6.4~952.1)
#   满载 %steal  >5% 偏弱   | 1~5% 注意         | <1% 良好        (实测全 0.00)
#   单核         <400 偏弱  | 400~600 中等      | >600 良好       (实测 403~976)
P99_GOOD_MS, P99_OK_MS = 20, 100
IOPS_GOOD, IOPS_OK = 15000, 5000
SINGLE_GOOD, SINGLE_OK = 600, 400
STEAL_OK, STEAL_WARN = 1, 5


def _g_bigger(v, ok, good):
    """越大越好的指标 → (等级, 标记)"""
    if v is None:
        return "未测", ""
    if v >= good:
        return "良好", "✅"
    return ("一般", "") if v >= ok else ("偏弱", "⚠️")


def _g_smaller(v, ok, good):
    """越小越好的指标（延迟类）→ (等级, 标记)"""
    if v is None:
        return "未测", ""
    if v <= good:
        return "良好", "✅"
    return ("一般", "") if v <= ok else ("偏弱", "⚠️")


def _dispw(s):
    """字符串的终端显示宽度：CJK 与 emoji 占 2 列，其余占 1 列。

    f-string 的 :<14 按**字符数**填充，中文标签会因此错位，所以表格必须按显示宽度对齐。
    """
    w = 0
    for c in str(s):
        o = ord(c)
        if o in (0xFE0F, 0xFE0E, 0x200D):   # 变体选择符/零宽连接符，不占列
            continue
        w += 2 if (o > 0x2E80 or 0x2190 <= o <= 0x2BFF or 0x1F300 <= o <= 0x1FAFF) else 1
    return w


def _pad(s, width, right=False):
    """按显示宽度补齐到 width 列"""
    s = str(s)
    gap = " " * max(0, width - _dispw(s))
    return gap + s if right else s + gap


def _cpu_topology(name):
    """从 system-info.txt 读 (物理核, 线程数)——轻量云常拿超线程冒充核心"""
    txt = _read_text(os.path.join(RESULTS, name, "system-info.txt"))
    tpc = cps = socks = None

    def tail_int(line):
        try:
            return int(line.split(":")[-1].strip())
        except ValueError:
            return None

    for line in txt.splitlines():
        if "Thread(s) per core" in line:
            tpc = tail_int(line)
        elif "Core(s) per socket" in line:
            cps = tail_int(line)
        elif "Socket(s)" in line:
            socks = tail_int(line)
    if tpc and cps and socks:
        return cps * socks, cps * socks * tpc
    return None, None


def _mem_actual(name):
    """从 system-info.txt 的 free 输出读**实测**内存（GB）。

    轻量云常见「标称 2G、实测 1.6G」（内核与虚拟化占用），对初级用户是重要提醒——
    内存比标称少，直接影响「能跑几个容器」。实测：天翼云 2C2G 只给出 1.6Gi。
    """
    txt = _read_text(os.path.join(RESULTS, name, "system-info.txt"))
    m = re.search(r"^Mem:\s+([\d.]+)\s*([GM])i?", txt, re.M)
    if not m:
        return None
    v = float(m.group(1))
    return v if m.group(2) == "G" else v / 1024.0


def _what_can_it_run(ram, g_iops, g_p99, g_cpu, g_steal):
    """把指标等级翻译成「能跑什么」——初级用户真正想要的结论"""
    can, warn, cannot = [], [], []
    if ram >= 2:
        can.append("个人博客 / 静态站 / 图床")
    else:
        warn.append("小内存（<2G）：只够纯静态页，别装面板")
    if ram >= 2 and g_cpu[0] != "偏弱":
        can.append("5~10 个轻量容器（面板 / Nginx / 小服务）")
    elif ram >= 2:
        warn.append("小容器 3~5 个（CPU 偏弱，多开会卡）")
    if g_p99[0] == "良好" and g_iops[0] != "偏弱":
        can.append("轻量数据库（MySQL / PostgreSQL / Redis）")
    elif g_p99[0] == "偏弱":
        warn.append("数据库：能跑，但磁盘长尾会带来偶发卡顿（建站时 MySQL 最明显）")
    else:
        warn.append("数据库：磁盘一般，轻量使用尚可")
    if g_cpu[0] == "良好" and ram >= 4:
        can.append("中小项目编译")
    else:
        cannot.append("编译构建（Go / Rust / 大型 npm 项目）")
    cannot.append("视频转码 / AI 推理 / 高并发站点")
    if g_steal[0] == "偏弱":
        warn.append("⚠️ 检测到明显超售——性能可能随邻居负载波动")
    return can, warn, cannot


def render_report(name):
    """单机人话报告：./scripts/cloud-benchmark.sh report --name X"""
    m, _local, _remote = collect_metrics(name)
    hosts = {h["name"]: h for h in read_hosts()}
    h = hosts.get(name, {})
    if not m:
        print(f"[ERR] 没有 {name} 的产物，先跑 run + collect", file=sys.stderr)
        return 1

    p99 = m.get("fio_4k_randread_p99_ms")
    if p99 is None and m.get("fio_4k_randread_p99_us") is not None:
        p99 = m["fio_4k_randread_p99_us"] / 1000.0
    iops = m.get("fio_4k_randread_iops")
    single = m.get("sysbench_cpu_single_eps")
    multi = m.get("sysbench_cpu_multi_eps")
    steal = m.get("stress_avg_steal_pct")
    try:
        ram = int(h.get("ram_gb") or 0)   # hosts.tsv 读出来是字符串
    except (TypeError, ValueError):
        ram = 0
    cores, threads = _cpu_topology(name)

    g_iops = _g_bigger(iops, IOPS_OK, IOPS_GOOD)
    g_p99 = _g_smaller(p99, P99_OK_MS, P99_GOOD_MS)
    g_cpu = _g_bigger(single, SINGLE_OK, SINGLE_GOOD)
    g_steal = _g_smaller(steal, STEAL_WARN, STEAL_OK)
    can, warn, cannot = _what_can_it_run(ram, g_iops, g_p99, g_cpu, g_steal)

    W = 62
    out = []
    out.append("═" * W)
    head = f"  {h.get('vendor','?')} {h.get('spec','?')}"
    price, note = str(h.get("price_cny") or ""), h.get("price_note") or ""
    if price and price != "0" and not note.startswith("待补"):
        head += f" · ¥{price}" + (f"/{note}" if note else "")
    if h.get("region"):
        head += f" · {h['region']}"
    out.append(head)
    if h.get("role"):
        out.append(f"  用途：{h['role']}")
    out.append("═" * W)

    def line(label, value, unit, g):
        mark = g[1] or "  "
        out.append(f"  {_pad(label,16)}{_pad(value,13,right=True)} {_pad(unit,10)}{mark} {g[0]}")

    out.append("")
    out.append("【会不会卡？】← 轻量云最该看的一项")
    line("磁盘 4K 随机读", fmt(iops, 0), "IOPS", g_iops)
    line("磁盘长尾 p99", fmt(p99, 2), "ms", g_p99)
    if g_p99[0] == "偏弱":
        out.append("  → ⚠️ 长尾严重：约 1% 的请求要等几百毫秒，建站会偶发卡顿")
    elif g_p99[0] == "良好":
        out.append("  → 日常使用流畅，不太可能感到卡顿")
    else:
        out.append("  → 基本流畅，重负载下偶有延迟")

    out.append("")
    out.append("【有没有被超售？】")
    line("满载 %steal", fmt(steal, 2), "%", g_steal)
    out.append("  → 没被邻居抢资源" if g_steal[0] == "良好" else "  → 存在资源争抢")

    out.append("")
    out.append("【CPU 够用吗？】")
    line("单核性能", fmt(single, 0), "events/s", g_cpu)
    if cores and threads:
        virt = "✅ 未虚标" if cores == threads else "⚠️ 超线程"
        out.append(f"  {_pad('物理核',16)}{_pad(cores,13,right=True)} 核（{threads} 线程）  {virt}")
        if cores != threads:
            out.append(f"  → 标称 {threads} 核，实际只有 {cores} 个物理核")
    if multi:
        out.append(f"  {_pad('多核性能',16)}{_pad(fmt(multi,0),13,right=True)} events/s")

    out.append("")
    out.append("【内存与网络】")
    mem_act = _mem_actual(name)
    out.append(f"  {_pad('内存',16)}{_pad(ram,13,right=True)} GB（标称）")
    if mem_act and ram and mem_act < ram * 0.92:
        out.append(f"  → ⚠️ 实测可用仅 {mem_act:.1f}G，比标称少 {round((1 - mem_act / ram) * 100)}%"
                   "（内核/虚拟化占用）——按实测值规划能跑多少服务")
    elif mem_act:
        out.append(f"  → ✅ 实测可用 {mem_act:.1f}G，与标称相符")
    line("内存带宽", fmt(m.get("sysbench_mem_single_mib_s"), 0), "MiB/s", ("", ""))
    up, down = m.get("speedtest_up_mbps"), m.get("speedtest_down_mbps")
    if up or down:
        bw = h.get("bandwidth", "")
        out.append(f"  {_pad('上行 / 下行',16)}{_pad(fmt(up,2) + ' / ' + fmt(down,2),13,right=True)} Mbps")
        if bw:
            try:
                if float(down) >= float(bw.rstrip("M")) * 0.8:
                    out.append(f"  → ✅ 达标（套餐 {bw}）")
                else:
                    out.append(f"  → ⚠️ 未跑满套餐标称的 {bw}")
            except ValueError:
                pass

    out.append("")
    out.append("【这台能跑什么？】")
    for x in can:
        out.append(f"  ✅ {x}")
    for x in warn:
        out.append(f"  ⚠️ {x}")
    for x in cannot:
        out.append(f"  ❌ {x}")

    done, missing = read_stages_done(name)
    out.append("")
    out.append(f"【数据完整度】{len(done)}/7 阶段"
               + (f"；缺：{', '.join(missing)}" if missing else "，无缺失"))
    out.append("")

    print("\n".join(out))
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--report":
        sys.exit(render_report(sys.argv[2]))
    sys.exit(main())
