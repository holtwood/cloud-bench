#!/usr/bin/env bash
# =============================================================================
# 多云轻量主机性能横评 —— 统一评测脚本（可复用）
# =============================================================================
# 目标：对多家云商的轻量型云主机跑同一套固定流程，产出可横向对比的数据。
#
# 用法：
#   0) 追加新主机：编辑 results/hosts.tsv 加一行，然后按 1) 跑即可
#   1) 远端跑测试（tmux 后台执行，SSH 断连不中断）
#      ./scripts/cloud-benchmark.sh run --name mycloud-2c2g-01
#         默认档位 quick（约 16 分钟）：磁盘 p99 / 超售 %steal / 物理核识别
#         —— 轻量云最关心的三项全在这里，且是 YABS/bench.sh 测不出来的
#      ./scripts/cloud-benchmark.sh run --name mycloud-2c2g-01 --profile standard
#         约 40 分钟：加 YABS 交叉验证 + PTS（7-Zip / redis）
#      ./scripts/cloud-benchmark.sh run --name mycloud-2c2g-01 --profile full
#         约 2.5 小时：全量，含 PTS 内核编译（轻量云一般用不到）
#      ./scripts/cloud-benchmark.sh run --name mycloud-2c2g-01 --stages env,deps,fio
#         只跑指定阶段（逗号分隔，逐项覆盖档位预设）
#      ./scripts/cloud-benchmark.sh run --name mycloud-2c2g-01 --at 23:30   # 远端定时开跑
#         （--at 的等待在**远端**计算，本机关机/断网都不影响；跑生产机时用它卡低峰窗口）
#   2) 查看进度（tail 远端日志 / 阶段完成情况）
#      ./scripts/cloud-benchmark.sh status --name tencent-2c2g-03
#   3) 回收结果到 results/<name>/
#      ./scripts/cloud-benchmark.sh collect --name tencent-2c2g-03
#   4) 跨主机 iperf3 互测（双向 -P 8，需要两台的 ssh 别名都可直连）
#      ./scripts/cloud-benchmark.sh iperf --a tencent-2c2g-03 --b volc-4c8g-01
#   5) 汇总所有已回收结果 → results/summary/compare.{csv,md}
#      ./scripts/cloud-benchmark.sh summarize
#   6) 单机「人话报告」——面向入门：把数字翻译成「会不会卡 / 是不是虚标 / 能跑什么」
#      ./scripts/cloud-benchmark.sh report --name mycloud-2c2g-01
#   7) 提交结果到站点（先 --dry-run 看一眼要传什么，确认后再提交）
#      ./scripts/cloud-benchmark.sh submit --name mycloud-2c2g-01 --api https://bench.example.com --dry-run
#      export BENCH_API_KEY=xxx     # 密钥用环境变量传，别写进命令行（会留在 shell 历史）
#      ./scripts/cloud-benchmark.sh submit --name mycloud-2c2g-01 --api https://bench.example.com
#
# 设计原则：
#   - 被测主机上不安装任何 AI agent / 常驻进程，只装评测工具（fio/sysbench/...），
#     保持被测环境干净（agent 进程会占用 CPU/内存，直接污染跑分）
#   - 所有长任务在远端 tmux 中执行，SSH 断连不中断
#   - 每阶段独立日志 + 失败不阻塞后续阶段（记录到 failed-stages.txt）
#   - 关键指标统一写入 metrics.tsv（metric<TAB>value<TAB>unit），summarize 只读它
#   - 幂等：同一阶段重复跑会覆盖该阶段产物，不产生重复 metric（先删旧的同名 metric）
#
# 阶段说明（--stages 可任选，逗号分隔；all = 全部）：
#   env      前置检查 + 系统信息（lscpu/free/lsblk/os-release/虚拟化）→ system-info.txt
#   deps     安装评测工具（fio sysbench iperf3 stress-ng sysstat + PTS 的 php 扩展）
#   yabs     YABS 快速跑分（CPU + fio + iperf3 一次出结果，保留 JSON）
#   pts      Phoronix Test Suite（**standard/full 档才跑**；内核编译一项就要 87 分钟，
#            轻量云场景用不到，故 quick 档默认跳过）
#   fio      磁盘精测：4K 随机读/写（direct=1,bs=4k,iodepth=32,numjobs=4,60s）+ 顺序读写
#   sysbench CPU 单线程/全核各 60s + 内存带宽
#   stress   超售检测：stress-ng --cpu $(nproc) 满载 + mpstat 1 记录 %steal
#            （时长随档位：quick 5m / standard 10m / full 20m，--stress-mins 可覆盖）
#   net      公网 Speedtest（跨机 iperf3 用 iperf 子命令单独跑）
#
# 注意：
#   - 被测主机在跑业务时，deps/yabs/fio/sysbench/stress 都会抢占资源，必须低峰期执行；
#     业务高峰只适合跑 env/net 这类轻量阶段。
#   - 火山云磁盘余量小（<15G）时，fio 自动把测试文件降到 1G×4，测完立即删除。
# =============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# 全局配置
# ---------------------------------------------------------------------------
SCRIPT_VERSION="1.0.0"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 产物目录：默认本仓库的 results/，可用 CB_RESULTS_DIR 覆盖。
# 这样「工具在公开仓库、实测数据在私有工作区」也能跑——评测数据是使用者自己的，
# 没必要（也不应该）塞进工具仓库。
RESULTS_DIR="${CB_RESULTS_DIR:-$REPO_ROOT/results}"
HOSTS_FILE="$RESULTS_DIR/hosts.tsv"
# 远端工作目录：用 ~ 让远端 shell 展开，root 与普通用户（ubuntu）都适用。
# 注意：这两个变量传给远端时**不能加引号**，否则 ~ 不会展开。
REMOTE_BASE='~/cloud-benchmark'
REMOTE_OUT="$REMOTE_BASE/out"
TMUX_SESSION="cloudbench"

# ⚠️ 必须给本脚本单独指定 ControlPath。用户 ~/.ssh/config 里配了
#    `ControlMaster auto` + `ControlPath ~/.ssh/cm-%C` + `ControlPersist 10m`，
#    新连接会复用**已存在（可能已僵死）的主连接**——被测机满负载跑 PTS 时表现为
#    「SSH 全部卡住、命令不返回」，实测加 -o ControlPath=none 后立即秒回，
#    排查时一度误判为 CPU 饱和导致 sshd 饿死。
#    这里用独立 socket 路径：既不被其他会话的僵死连接拖累，又保留脚本内的连接复用。
SSH_OPTS=(-o ConnectTimeout=15 -o ServerAliveInterval=60 -o ServerAliveCountMax=3 \
          -o StrictHostKeyChecking=accept-new \
          -o ControlMaster=auto -o ControlPath="$HOME/.ssh/cb-%r@%h:%p" -o ControlPersist=5m)

# 各阶段超时（秒）—— 轻量主机 + 1M 带宽下实测：YABS 单轮可达 2 小时
TIMEOUT_YABS=14400      # 4h
TIMEOUT_PTS=32400       # 9h（build-linux-kernel 在 1核2G 上极慢）
TIMEOUT_FIO=1800        # 30m
TIMEOUT_SYSBENCH=900    # 15m
TIMEOUT_STRESS=1800     # 30m（压测本身 20m）
TIMEOUT_NET=900         # 15m

ALL_STAGES="env deps yabs pts fio sysbench stress net"

# ---------------------------------------------------------------------------
# 评测档位（profile）—— 为「轻量云 + 初级用户」场景预设
# ---------------------------------------------------------------------------
# 设计依据：实测耗时（腾讯云4C4G 空机，无业务干扰）
#   pts   1:49:20  ← 占 74%，其中 build-linux-kernel 一项 87 分钟（占全脚本 59%）
#   stress   20:03 · yabs 7:40 · fio 5:05 · deps 3:08 · sysbench 2:10 · env+net <1min
#   → 全量约 2 小时 28 分
#
# 为什么默认砍 PTS：轻量云用户不会编译内核，也不关心 openssl/ramspeed 跑分；
# 而**全部差异化指标都在这三项之外**——
#   磁盘 p99 长尾 → fio  ·  超售 %steal → stress  ·  物理核/超线程 → env
# 砍掉通用跑分后，quick 档 16 分钟就能拿到 YABS/bench.sh 测不出的数据。
#
# profile 只提供默认值；显式 --stages / --pts-tests / --stress-mins 可逐项覆盖。
PROFILE_QUICK="env deps fio sysbench stress net"
PROFILE_STANDARD="env deps yabs fio sysbench stress net pts"
PTS_QUICK=""                          # quick 不跑 PTS
PTS_STANDARD="compress-7zip redis"    # 只留最直观、最快的两项
PTS_FULL="compress-7zip openssl build-linux-kernel ramspeed redis"
STRESS_QUICK=5                        # 5 分钟足够暴露持续超售
STRESS_STANDARD=10
STRESS_FULL=20                        # 与历史数据口径一致

# ---------------------------------------------------------------------------
# 日志与输出
# ---------------------------------------------------------------------------
c_info()  { printf '\033[36m[INFO]\033[0m %s\n' "$*"; }
c_ok()    { printf '\033[32m[ OK ]\033[0m %s\n' "$*"; }
c_warn()  { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
c_err()   { printf '\033[31m[ERR ]\033[0m %s\n' "$*" >&2; }
c_head()  { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }

die() { c_err "$*"; exit 1; }

usage() {
  echo "cloud-benchmark.sh  v$SCRIPT_VERSION"
  echo
  sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

# ---------------------------------------------------------------------------
# 主机清单解析
# ---------------------------------------------------------------------------
# hosts.tsv 列：name ssh_alias vendor spec vcpu ram_gb bandwidth price_cny price_note role
host_field() {
  local name="$1" col="$2"
  [ -f "$HOSTS_FILE" ] || die "主机清单不存在：$HOSTS_FILE"
  awk -F'\t' -v n="$name" -v c="$col" '
    /^[[:space:]]*#/ || NF < 2 { next }
    $1 == n { print $c; found=1; exit }
    END { if (!found) exit 1 }
  ' "$HOSTS_FILE"
}

host_target() {
  local name="$1" alias
  alias="$(host_field "$name" 2)" || die "主机清单里没有 '$name'（见 $HOSTS_FILE）"
  echo "$alias"
}

# ---------------------------------------------------------------------------
# 远端执行封装
# ---------------------------------------------------------------------------
rsh() {  # rsh <target> <command...>
  local target="$1"; shift
  ssh "${SSH_OPTS[@]}" "$target" "$@"
}

# 远端下载封装：若本机 127.0.0.1:8894 有 mihomo 在监听，则 curl 自动走代理。
# ⚠️ 实测踩坑（2026-09-13，腾讯云 04）：无代理机器直连海外源极慢/失败——
#    speedtest CLI（install.speedtest.net，Cloudflare 前置）与 yabs.sh（GitHub）
#    国内直连不可靠；而有 mihomo 的机器（01/02/03）下载飞快。
#    PTS 下载已由 pts_ensure_batch_config 的 --pts-proxy 覆盖，这里管 CLI 下载。
cb_curl() {  # cb_curl <url> -o <file>
  local args=("$@")
  if ss -tln 2>/dev/null | grep -q ':8894 '; then
    curl -sL -x http://127.0.0.1:8894 "${args[@]}"
  else
    curl -sL "${args[@]}"
  fi
}

# ---------------------------------------------------------------------------
# 远端执行器（exec 模式）—— 下面所有 stage_* 都在被测主机上运行
# ---------------------------------------------------------------------------
need_sudo() {
  if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo -n"; fi
}

# 某阶段重跑成功后，清掉它在 failed-stages.txt 里的历史失败记录（幂等）
# ⚠️ 这里必须分两行声明 local：bash 的 `local a="$1" b="$a"` 中，同一行内的 $a
#    取到的是**外部同名变量**（实测 `local out="AAA" g="$out-BBB"` → g 为 "-BBB"，
#    即 $out 求值为空）。写成一行会让 f 变成 "-failed-stages.txt" 这种错误路径。
clear_failed() {
  local out="$1" stage="$2"
  local f="$out/failed-stages.txt"
  [ -f "$f" ] || return 0
  awk -v s="$stage" '$0 != s' "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
  [ -s "$f" ] || rm -f "$f"
}

# 向 metrics.tsv 追加一条指标（同 metric 名先删旧行，保证幂等）
metric() {
  local out="$1" key="$2" val="$3" unit="${4:-}"
  [ -n "$val" ] && [ "$val" != "null" ] || return 0
  local f="$out/metrics.tsv"
  touch "$f"
  awk -F'\t' -v k="$key" '$1 != k' "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
  printf '%s\t%s\t%s\n' "$key" "$val" "$unit" >> "$f"
}

stage_env() {
  local out="$1"
  local f="$out/system-info.txt"
  need_sudo
  {
    echo "########## 采集时间 ##########"
    date -Is
    echo "hostname: $(hostname)"
    echo
    echo "########## 前置检查 ##########"
    echo "--- 磁盘剩余 ---"
    df -h / /boot 2>/dev/null
    echo "--- 当前负载 ---"
    uptime
    echo "--- CPU 占用 TOP5 ---"
    ps -eo pcpu,pmem,comm --sort=-pcpu | head -6
    echo "--- 内存占用 TOP5 ---"
    ps -eo pcpu,pmem,comm --sort=-pmem | head -6
    echo "--- 在跑的业务进程（非系统）---"
    ps -eo comm --no-headers | sort | uniq -c | sort -rn | head -15
    echo "--- 容器（如有）---"
    $SUDO docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null || echo "（无 docker 或无权限）"
    echo
    echo "########## CPU ##########"
    lscpu
    echo "--- 在线 CPU / 物理核 / 线程 ---"
    echo "nproc=$(nproc)"
    lscpu -p=Core,Socket 2>/dev/null | grep -v '^#' | sort -u | wc -l | sed 's/^/物理核数(去重 Core,Socket)=/'
    # CPU 指令集单行摘要：lscpu 的 Flags 是 80 列折行的（单词会被截断成 "pg"+"e"），
    # 直接 grep 会漏判。评测里这是硬指标（天翼云屏蔽 AVX 直接导致 stress-ng SIGILL）。
    echo "--- CPU 指令集（单行不折行）---"
    grep -m1 '^flags' /proc/cpuinfo | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//'
    echo
    echo "--- 关键指令集判定 ---"
    for feat in avx avx2 avx512f fma aes sse4_2 rdrand; do
      printf '%-10s ' "$feat"
      grep -m1 '^flags' /proc/cpuinfo | grep -qw "$feat" && echo '有' || echo '无'
    done
    echo
    echo "########## 内存 ##########"
    free -h
    echo "--- swap ---"
    swapon --show 2>/dev/null || echo "无 swap"
    echo
    echo "########## 磁盘 ##########"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL
    echo "--- 调度器 ---"
    for d in /sys/block/vd*/queue/scheduler /sys/block/sd*/queue/scheduler /sys/block/nvme*/queue/scheduler; do
      [ -r "$d" ] && echo "$d: $(cat "$d")"
    done
    echo
    echo "########## 操作系统 ##########"
    cat /etc/os-release
    echo "kernel: $(uname -r)"
    echo "虚拟化类型: $(systemd-detect-virt 2>/dev/null || echo unknown)"
    echo "云厂商 DMI: $(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo n/a) / $(cat /sys/class/dmi/id/product_name 2>/dev/null || echo n/a)"
    echo
    echo "########## 频率与调度 ##########"
    echo "cpufreq governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
    echo "当前 MHz(各核): $(grep -h 'cpu MHz' /proc/cpuinfo 2>/dev/null | awk -F': ' '{printf "%s ", $2}')"
  } > "$f" 2>&1
  c_ok "system-info.txt 已生成"
}

stage_deps() {
  local out="$1"
  need_sudo
  local log="$out/deps.log"
  {
    echo "=== 安装评测工具 $(date -Is) ==="
    # ⚠️ 四个实测踩坑（2026-09-11，两台生产机上分别踩到，全部已复现确认）：
    #   1) DEBIAN_FRONTEND 必须**显式经 sudo 传递**（用 `env` 前缀）：
    #      sudo 默认 env_reset 会把 `export DEBIAN_FRONTEND` 清掉，导致 debconf 在
    #      tmux 的 pty 下拉起 whiptail 交互框，卡在
    #      "Start Iperf3 as a daemon automatically?" 永不返回（实测卡 157s+ 到 45min）。
    #   2) 只重定向 stdin 到 /dev/null **无效**：whiptail 直接打开 /dev/tty，不看 stdin。
    #   3) 用 debconf-set-selections 预设答案兜底（即使前面都失效也不会卡）。
    #   4) apt 加超时 + 优先直连绕过业务代理：生产机常配全局 mihomo 代理
    #      （Acquire::http::Proxy "http://127.0.0.1:8894"）和国外源
    #      （deb.nodesource.com / cli.github.com / security.ubuntu.com），
    #      代理一挂 apt 就整体卡死（腾讯云实测 209s 零下载）。国内镜像直连更快，
    #      且不依赖业务进程存活；直连装不齐时再回退系统代理配置重试。
    local APT_ENV=(env DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true)
    local APT_OPTS=(-o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 -o Acquire::Retries=1)
    local NOPROXY=(-o Acquire::http::Proxy=false -o Acquire::https::Proxy=false)

    # 快速路径：工具齐全就不再动 apt（幂等，重复跑很快）
    # ⚠️ 检查清单必须含 make/gcc/cc：PTS 测试安装时都要编译，
    #    漏了它们会导致「工具全齐、PTS 却全失败」（实测踩坑 2026-09-13：
    #    腾讯云 01 的 build-essential 没装上，deps 快速路径却判「齐全」跳过，
    #    PTS 4 个测试全部 make/cc not found）。
    local missing=""
    for c in fio sysbench iperf3 stress-ng mpstat php jq make gcc; do
      command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    if [ -z "$missing" ]; then
      echo "评测工具已齐全，跳过 apt 安装"
    else
      echo "缺失工具:$missing"
      local PKGS=(fio sysbench iperf3 stress-ng sysstat php-cli php-xml php-gd php-bz2 curl jq bc)
      # ⚠️ build-essential 必须装（实测踩坑 2026-09-13）：PTS 的测试安装时都要编译
      #    （7-Zip / openssl / ramspeed / redis / build-linux-kernel），cloud image
      #    （腾讯云 01）通常不带 gcc/make——实测全部 `make: command not found` /
      #    `cc: command not found`，PTS 4 个测试安装全部失败、一个成绩都没有。
      #    天翼云的 Ubuntu Server 镜像自带 gcc/make 所以此前没暴露这个问题。
      # ⚠️ flex/bison 也必须装（实测踩坑 2026-09-13，真正根因）：build-linux-kernel
      #    编译时执行 `flex: not found` 直接失败（3 次 run 全部 quit），PTS 日志只留
      #    `failed to properly run` 无具体错误，一度误判为内存不足——手动跑才看到
      #    `E: /bin/sh: 1: flex: not found`。Linux 内核构建需要 flex+bison，
      #    cloud image 不带，而天翼云 Ubuntu Server 自带故此前未暴露。
      # ⚠️ libelf-dev/libssl-dev/bc 也必须装（同轮踩坑续）：补完 flex/bison 后
      #    编译报 `fatal error: gelf.h: No such file`（objtool 需要 libelf-dev），
      #    后续可能还需 openssl 头与 bc。一次装齐内核构建完整依赖链。
      PKGS+=(build-essential flex bison libelf-dev libssl-dev bc)
      # 兜底：预设 iperf3 的 debconf 答案（即使前端仍被拉起也不会阻塞）
      printf 'iperf3 iperf3/daemon boolean false\n' | \
        $SUDO "${APT_ENV[@]}" debconf-set-selections 2>/dev/null || true

      # 第一轮：直连（绕过业务代理）
      $SUDO "${APT_ENV[@]}" apt-get update -qq "${APT_OPTS[@]}" "${NOPROXY[@]}" < /dev/null 2>&1 | tail -3
      $SUDO "${APT_ENV[@]}" apt-get install -y -qq "${APT_OPTS[@]}" "${NOPROXY[@]}" "${PKGS[@]}" < /dev/null 2>&1 | tail -20

      # 第二轮：直连装不齐时，回退系统代理配置重试
      local still=""
      for c in fio sysbench iperf3 stress-ng; do
        command -v "$c" >/dev/null 2>&1 || still="$still $c"
      done
      if [ -n "$still" ]; then
        echo "直连后仍缺:$still —— 回退系统 apt 代理配置重试"
        $SUDO "${APT_ENV[@]}" apt-get update -qq "${APT_OPTS[@]}" < /dev/null 2>&1 | tail -3
        $SUDO "${APT_ENV[@]}" apt-get install -y -qq "${APT_OPTS[@]}" "${PKGS[@]}" < /dev/null 2>&1 | tail -20
      fi
    fi
    echo
    echo "=== 版本确认 ==="
    # 存在性用 command -v 判断；版本号尽力而为（mpstat 等不支持 --version，不能据此判缺失）
    for c in fio sysbench iperf3 stress-ng mpstat php jq; do
      if command -v "$c" >/dev/null 2>&1; then
        printf '%-14s OK   %s\n' "$c" "$("$c" --version 2>&1 | head -1)"
      else
        printf '%-14s 缺失!\n' "$c"
      fi
    done
    echo
    echo "--- PTS ---"
    if command -v phoronix-test-suite >/dev/null 2>&1; then
      phoronix-test-suite --version 2>&1 | head -3
    else
      echo "PTS 未安装，尝试安装到 /tmp（与历史测试口径一致）"
      cd /tmp && git clone --depth 1 https://github.com/phoronix-test-suite/phoronix-test-suite.git 2>&1 | tail -2
      if [ -f /tmp/phoronix-test-suite/phoronix-test-suite ]; then
        # ⚠️ 源码方式必须用官方 **install-sh** 安装（实测踩坑 2026-09-13，折腾多轮）：
        #    源码目录里的 phoronix-test-suite 只是个**存根**（73 字节），直接运行会报
        #    「you must first change directories to phoronix-test-suite or install the
        #      program using the install-sh script」并立刻退出（141/SIGPIPE），
        #    表现为「阶段完成但零成绩」。两个看似可行的错误做法：
        #      · 建符号链接 → PTS 按自身路径推断安装位置，链接后找不到自己；
        #      · 自建 wrapper  `cd /tmp/phoronix-test-suite && exec ./phoronix-test-suite "$@"`
        #        → **自我递归**（cd 到自己目录再 exec 自己），同样跑不起来。
        #    唯一可靠做法：跑 install-sh（装出 /usr/bin/phoronix-test-suite，
        #    存根会从 73 字节变为正常启动脚本）。
        cd /tmp/phoronix-test-suite && $SUDO ./install-sh >/dev/null 2>&1
        # 清掉可能残留的同名文件：/usr/local/bin 的 PATH 优先级高于 /usr/bin
        $SUDO rm -f /usr/local/bin/phoronix-test-suite
      fi
      phoronix-test-suite --version 2>&1 | head -3
    fi
  } > "$log" 2>&1
  if grep -q '缺失!' "$log"; then
    c_warn "部分工具安装失败，见 $log"
    echo "deps" >> "$out/failed-stages.txt"
  else
    clear_failed "$out" deps
    c_ok "评测工具就绪"
  fi
}

stage_yabs() {
  local out="$1"
  local log="$out/yabs.log"
  {
    echo "=== YABS $(date -Is) ==="
    cd "$out" || exit 1
    [ -f yabs.sh ] || cb_curl https://yabs.sh -o yabs.sh
    # -j 输出 JSON；-w 写 JSON 文件；保留完整日志
    # ⚠️ 加 **-g 跳过 Geekbench**（实测踩坑 2026-09-13）：
    #    YABS 会从**海外 CDN**（cdn.geekbench.com → Linode）下载 100MB+ 的
    #    Geekbench 6 包，国内极慢（实测两台腾讯云各卡在 curl 下载 18 分钟以上，
    #    整个 YABS 被拖住）。而 YABS v2026-07-24 与 Geekbench 6 存在兼容问题，
    #    它解析出的 single/multi 分数**恒为 null**（用户 2026-09-10 的手动测试
    #    同样如此，只有结果 URL）——即这个下载**换不来任何可用数据**，
    #    纯属浪费时间与带宽。故直接跳过；若将来 YABS 修好了解析，
    #    再去掉此参数并承担下载耗时。
    # 注：源方案写的是 `curl -sL yabs.sh | bash`，这里先下载再执行以便传参和留痕，等价
    timeout "$TIMEOUT_YABS" bash yabs.sh -j -w yabs-result.json -g
    echo "=== YABS 退出码: $? $(date -Is) ==="
  } > "$log" 2>&1

  # 从 JSON 提取关键指标
  # YABS 的 -w 指定文件名；不同版本也可能落成 yabs_result.json，做一次兼容
  local jj=""
  for cand in "$out/yabs-result.json" "$out/yabs_result.json" "$out/result.json"; do
    [ -s "$cand" ] && { jj="$cand"; break; }
  done
  if [ -n "$jj" ]; then
    # YABS v2026-07-24 的真实 JSON 结构（首轮按 .read.iops 解析全部落空，实测校正）：
    #   fio[]   : {bs, iops_r, iops_w, iops_rw, speed_r, speed_w, speed_rw, speed_units}
    #   cpu     : 只有元数据（model/cores/freq/aes/virt），**没有跑分**
    #   geekbench[]: {version, single, multi, url}（single/multi 常为 null，见下）
    metric "$out" "yabs_4k_read_iops"  "$(jq -r '.fio[] | select(.bs=="4k") | .iops_r // empty' "$jj" 2>/dev/null)" "IOPS"
    metric "$out" "yabs_4k_write_iops" "$(jq -r '.fio[] | select(.bs=="4k") | .iops_w // empty' "$jj" 2>/dev/null)" "IOPS"
    metric "$out" "yabs_4k_total_iops" "$(jq -r '.fio[] | select(.bs=="4k") | .iops_rw // empty' "$jj" 2>/dev/null)" "IOPS"
    metric "$out" "yabs_64k_total_iops" "$(jq -r '.fio[] | select(.bs=="64k") | .iops_rw // empty' "$jj" 2>/dev/null)" "IOPS"
    # ⚠️ YABS v2026-07-24 与 Geekbench 6 存在兼容问题：分数恒为 null，只有结果 URL
    #    （用户 2026-09-10 的手动测试同样如此），需从网页查看分数，非本次操作所致。
    metric "$out" "yabs_geekbench_url" "$(jq -r '.geekbench[0].url // empty' "$jj" 2>/dev/null)" ""
    metric "$out" "yabs_geekbench_single" "$(jq -r '.geekbench[0].single // empty' "$jj" 2>/dev/null)" "分"
    metric "$out" "yabs_geekbench_multi"  "$(jq -r '.geekbench[0].multi // empty' "$jj" 2>/dev/null)" "分"
    metric "$out" "yabs_elapsed_sec" "$(jq -r '.runtime.elapsed // empty' "$jj" 2>/dev/null)" "s"
    clear_failed "$out" yabs
    c_ok "YABS 完成（JSON: $(basename "$jj")）"
  else
    c_warn "YABS 未产出 JSON，见 $log"
    echo "yabs" >> "$out/failed-stages.txt"
  fi
}

# 确保 PTS 的 batch 模式已配置。
# ⚠️ 实测踩坑（2026-09-11 三台全中）：PTS 首次使用必须先配置 batch 模式，
#    否则 `batch-benchmark` 只把 6 个测试**下载安装完就退出**——日志末尾仅有一句
#    `[NOTICE] The batch mode must first be configured`，**退出码仍是 0**（伪装成功）。
#    表现为：日志里全是 Downloading/Installing，没有任何 Test/Average 结果。
#
# 用官方 `batch-setup` 配置（对两种安装方式都有效，自动写对路径）：
#   deb 包安装（天翼云）→ /var/lib/phoronix-test-suite/core.pt2so
#   源码安装（腾讯云/火山云）→ ~/.phoronix-test-suite/user-config.xml
# 不要用 sed 改 user-config.xml：deb 安装下该文件根本不存在（天翼云实测）。
#
# batch-setup 依次问 7 个问题，输入序列「y n n n n n y」对应：
#   y  Save test results when in batch mode         (Y/n) → 保存结果
#   n  Open the web browser automatically          (y/N) → 不自动开浏览器
#   n  Auto upload results to OpenBenchmarking.org (Y/n) → 不上传
#   n  Prompt for test identifier                  (Y/n) → 不提示
#   n  Prompt for test description                 (Y/n) → 不提示
#   n  Prompt for saved results file-name          (Y/n) → 不提示
#   n  Run all test options                        (Y/n) → **只跑默认选项**
# ⚠️ 两处都踩过坑：
#   ① 全部回车取默认值是错的——第 3~6 问默认 Y，会继续交互；
#   ② 第 7 问「Run all test options」绝不能答 y！答 y 会跑**每个测试的全部变体组合**，
#      fio 一个测试就有 1573 个组合，PTS 自报 `Estimated Time To Completion: 7 Days`
#      （天翼云实测），完全不可用。评测只要默认口径，必须答 n。
pts_ensure_batch_config() {
  echo "=== 配置 PTS batch 模式（batch-setup；输入序列 y n n n n n n）==="
  printf 'y\nn\nn\nn\nn\nn\nn\n' | phoronix-test-suite batch-setup 2>&1 | tail -3
  # 校验：未配置时 batch 前缀命令会打印 NOTICE
  if phoronix-test-suite batch-list-available-tests 2>&1 | grep -q "batch mode must first be configured"; then
    echo "[WARN] batch 模式仍未配置，PTS 可能只下载不运行"
    return 1
  fi

  # ⚠️ PTS 代理自动配置（实测踩坑 2026-09-13）：PTS 下载测试包走
  #    user-config.xml 的 Networking 段代理。无代理的机器直连国外源极慢
  #    （腾讯云 04 实测下载 linux-7.0.tar.xz 要 46 分钟），配了代理后 1 分钟。
  #    调度端可设 CB_PTS_PROXY="127.0.0.1:8894"（cmd_run --pts-proxy），
  #    脚本自动写入 PTS 配置；不设则保持现状（机器自带代理配置则不受影响）。
  local ucfg="$HOME/.phoronix-test-suite/user-config.xml"
  if [ -n "${CB_PTS_PROXY:-}" ] && [ -f "$ucfg" ]; then
    local paddr="${CB_PTS_PROXY%%:*}" pport="${CB_PTS_PROXY##*:}"
    sed -i \
      -e "s|<ProxyAddress>[^<]*</ProxyAddress>|<ProxyAddress>$paddr</ProxyAddress>|" \
      -e "s|<ProxyPort>[^<]*</ProxyPort>|<ProxyPort>$pport</ProxyPort>|" \
      "$ucfg"
    echo "PTS 代理已配置: $CB_PTS_PROXY"
  fi
  echo "PTS batch 模式已配置并校验通过"
}

stage_pts() {
  local out="$1"
  local log="$out/pts.log"
  need_sudo
  {
    echo "=== Phoronix Test Suite 6 项 $(date -Is) ==="
    cd "$out" || exit 1
    command -v phoronix-test-suite >/dev/null 2>&1 || { echo "PTS 未安装"; exit 1; }
    pts_ensure_batch_config
    export PTS_CONCURRENT_TEST_RUNS=1
    export PTS_SILENT_MODE=1          # 无人值守：不打印进度动画、不问交互问题
    export PTS_BATCH_MODE=1
    # 禁用彩色输出：PTS 检测到 pty（有 tmux 的机器）会输出 ANSI 颜色码，
    # 形如 `Average: \x1b[1;34m16484 MIPS\x1b[0m`，会让下游的
    # `Average:\s*[0-9.]+` 解析全部失配（实测：火山云有 tmux 因而带色、
    # 天翼云用 nohup 无色，同样脚本结果却不同）。TERM=dumb 可关闭彩色。
    export TERM=dumb

    # ⚠️ 日志看门狗（严重事故防护，实测踩坑 2026-09-12）：
    #    PTS 某些失败路径会疯狂刷日志——pts/fio 的默认引擎 IO_uring 在云 VM 上直接
    #    失败，PTS 一边重试一边输出错误，实测把 pts.log 写到 **29~37GB**、以约
    #    11MB/s 持续增长，三台磁盘全部被写到 100% 占满（含两台跑着生产业务的机器）。
    #    这里每 30s 检查一次，超过 500MB 就**截断日志 + 杀掉 PTS**：
    #    ⚠️ 只截断不够（2026-09-13 复查）——PTS 进程持有旧文件描述符，
    #    截断后它继续写**已删除的 inode**，磁盘空间被「幽灵文件」持续占用，
    #    直到 PTS 退出才释放。日志涨到 500MB 说明 PTS 已死循环，直接杀更干净。
    local logfile="$out/pts.log"
    (
      while sleep 30; do
        [ -f "$logfile" ] || continue
        # 注意：这里是 ( ) 子 shell，不能用 local（local 只在函数上下文有效）
        sz=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
        if [ "$sz" -gt 524288000 ]; then
          printf '\n[WATCHDOG] pts.log 达 %s 字节（异常），终止 PTS\n' "$sz" >> "$logfile"
          # 用 [p] 技巧避免匹配到自身命令行
          pkill -9 -f '[p]ts-core' 2>/dev/null
          pkill -9 -x phoronix-test-suite 2>/dev/null
          # 截断兜底：若还有残留进程在写，至少别撑爆磁盘
          tail -c 10485760 "$logfile" > "$logfile.tmp" 2>/dev/null && mv "$logfile.tmp" "$logfile"
        fi
      done
    ) >/dev/null 2>&1 &
    local watchdog=$!

    # batch-benchmark = 非交互批处理模式，自动采用默认选项（等价源方案的 default-benchmark）
    # HOME 下需要可写，PTS 结果落在 ~/.phoronix-test-suite
    # stdin 同样重定向，避免任何意外的交互提示挂住（同 deps 阶段的踩坑）
    #
    # ⚠️ **刻意不跑 pts/fio**：它是 PTS 里唯一有 1573 个变体组合的测试，且默认引擎
    #    IO_uring 在云 VM（1核2G）上必然失败——跑几十分钟一条成绩都产不出，只留下
    #    海量错误日志（就是上面那场事故的主因）。磁盘 IO 数据由本项目自建的 fio 精测
    #    覆盖（4K 随机读/写 + p99 + 顺序读/写），口径更统一、粒度更细。
    # ⚠️ 喂给 PTS 的 stdin 必须是**有效选项编号**（实测踩坑，2026-09-12 三台磁盘被写满）
    #    pts/openssl 的选项是**多选菜单**（RSA4096 / SHA256 / AES-128-GCM / ChaCha20 …，
    #    提示语 `** Multiple items can be selected, delimit by a comma. **`），
    #    它**没有默认值、必须输入有效编号**。三种喂法实测结果：
    #      </dev/null  → 读到 EOF，PTS 无限循环重印菜单（pts.log 涨到 29~37GB 写满三台盘）
    #      yes ''      → 空行是无效输入，同样无限重印（pts.log 600MB+，仍无成绩）
    #      yes '1'     → ✅ 每次都选中第 1 项，正常推进
    #    故这里用 `yes '1'`：对所有提问一律取第 1 个选项（即最基础的那一项）。
    #    另有日志看门狗兜底（见上），即便再遇异常路径也不会写满磁盘。
    #
    # 测试列表可由调度端覆盖（CB_PTS_TESTS，见 cmd_run 的 --pts-tests）：
    # 磁盘紧张的机器（如只剩 8G 的火山云）可只跑不占空间的 compress-7zip /
    # ramspeed / redis，跳过 build-linux-kernel（内核源码+编译产物，瞬时峰值约 27G）
    # 与 openssl（源码编译）——这会形成口径差异，需在汇总与文章中标注。
    local pts_tests="${CB_PTS_TESTS:-compress-7zip openssl build-linux-kernel ramspeed redis}"
    echo "PTS 测试列表: $pts_tests"
    yes '1' | timeout "$TIMEOUT_PTS" phoronix-test-suite batch-benchmark $pts_tests
    local pts_rc=$?
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    echo "=== PTS 退出码: $pts_rc ==="
  } > "$log" 2>&1

  # 7-Zip 是 PTS 里最稳定可比的单项，提取出来做横向对比
  # ⚠️ 必须像 summarize.py 那样「剥离 ANSI + 放宽窗口」：
  #   ① PTS 输出在样本与 Average 之间有**空行**，`grep -A4` 取不到（实测漏掉）；
  #   ② 有 pty 时输出带 ANSI 颜色码（`Average: \x1b[1;34m...`），`Average: [0-9]` 失配。
  local txt_clean
  txt_clean=$(sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$log" 2>/dev/null)
  local z d
  z=$(printf '%s\n' "$txt_clean" | awk '/Compression Rating:/{f=1} f&&/Average:/{print $2; exit}')
  d=$(printf '%s\n' "$txt_clean" | awk '/Decompression Rating:/{f=1} f&&/Average:/{print $2; exit}')
  [ -n "$z" ] && metric "$out" "pts_7zip_compress_mips" "$z" "MIPS"
  [ -n "$d" ] && metric "$out" "pts_7zip_decompress_mips" "$d" "MIPS"

  # ⚠️ 必须校验是否真出成绩：batch 模式未配置时 PTS 会「下载安装完就退出」，
  #    **退出码依然是 0**，只看退出码会误判成功（首轮三台全中）。
  #    有效的 PTS 结果日志里必有 `Average: <数字>` 行（剥离 ANSI 后再判断）。
  if printf '%s\n' "$txt_clean" | grep -qE 'Average:[[:space:]]*[0-9.]+'; then
    clear_failed "$out" pts
    c_ok "PTS 完成（日志: pts.log，已检出成绩）"
  else
    c_warn "PTS 未产出任何测试成绩（日志: pts.log）——请检查 batch 模式配置"
    grep -q 'batch mode must first be configured' "$log" && \
      c_warn "  确认原因：日志含 'The batch mode must first be configured'"
    echo "pts" >> "$out/failed-stages.txt"
  fi
}

# fio 4K 精测：direct=1, bs=4k, iodepth=32, numjobs=4, runtime=60s，记录 IOPS 与 p99
stage_fio() {
  local out="$1"
  need_sudo
  local log="$out/fio.log"
  local dir="$out/fio"
  mkdir -p "$dir"

  # 依据磁盘余量决定测试文件大小（每 job 一个文件，共 numjobs 份）
  local avail_gb size="1G" jobs=4
  avail_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  if [ "${avail_gb:-0}" -lt 20 ]; then
    size="1G"; c_warn "磁盘余量 ${avail_gb}G < 20G，fio 测试文件降为 1G×${jobs}"
  elif [ "${avail_gb:-0}" -lt 40 ]; then
    size="2G"
  else
    size="4G"
  fi

  {
    echo "=== fio 磁盘精测 $(date -Is)（size=$size numjobs=$jobs）==="
    echo "--- 4K 随机读 ---"
    timeout "$TIMEOUT_FIO" fio --name=4k-randread --directory="$dir" --filename_format='fiotest.$jobnum' \
        --size="$size" --ioengine=libaio --direct=1 --bs=4k --iodepth=32 --numjobs="$jobs" \
        --rw=randread --runtime=60 --time_based --group_reporting \
        --percentile_list=50:99:99.9 --output-format=json --output="$out/fio-4k-randread.json"
    echo "退出码=$?"
    jq -r '.jobs[0] | "  IOPS=\(.read.iops) BW=\(.read.bw/1024)MiB/s p99=\(.read.clat_ns.percentile["99.000000"]/1000)us"' \
        "$out/fio-4k-randread.json" 2>/dev/null

    echo "--- 4K 随机写 ---"
    timeout "$TIMEOUT_FIO" fio --name=4k-randwrite --directory="$dir" --filename_format='fiotest.$jobnum' \
        --size="$size" --ioengine=libaio --direct=1 --bs=4k --iodepth=32 --numjobs="$jobs" \
        --rw=randwrite --runtime=60 --time_based --group_reporting \
        --percentile_list=50:99:99.9 --output-format=json --output="$out/fio-4k-randwrite.json"
    echo "退出码=$?"
    jq -r '.jobs[0] | "  IOPS=\(.write.iops) BW=\(.write.bw/1024)MiB/s p99=\(.write.clat_ns.percentile["99.000000"]/1000)us"' \
        "$out/fio-4k-randwrite.json" 2>/dev/null

    echo "--- 顺序读 1M ---"
    timeout "$TIMEOUT_FIO" fio --name=seq-read --directory="$dir" --filename_format='fiotest.$jobnum' \
        --size="$size" --ioengine=libaio --direct=1 --bs=1m --iodepth=16 --numjobs="$jobs" \
        --rw=read --runtime=60 --time_based --group_reporting \
        --output-format=json --output="$out/fio-seq-read.json"
    echo "退出码=$?"
    jq -r '.jobs[0] | "  BW=\(.read.bw/1024)MiB/s IOPS=\(.read.iops)"' "$out/fio-seq-read.json" 2>/dev/null

    echo "--- 顺序写 1M ---"
    timeout "$TIMEOUT_FIO" fio --name=seq-write --directory="$dir" --filename_format='fiotest.$jobnum' \
        --size="$size" --ioengine=libaio --direct=1 --bs=1m --iodepth=16 --numjobs="$jobs" \
        --rw=write --runtime=60 --time_based --group_reporting \
        --output-format=json --output="$out/fio-seq-write.json"
    echo "退出码=$?"
    jq -r '.jobs[0] | "  BW=\(.write.bw/1024)MiB/s IOPS=\(.write.iops)"' "$out/fio-seq-write.json" 2>/dev/null

    echo "=== 清理测试文件 $(date -Is) ==="
    rm -rf "$dir"
    echo "已删除 $dir"
  } > "$log" 2>&1

  local rr="$out/fio-4k-randread.json" rw="$out/fio-4k-randwrite.json"
  if [ -s "$rr" ]; then
    metric "$out" "fio_4k_randread_iops"  "$(jq -r '.jobs[0].read.iops // empty' "$rr" 2>/dev/null)" "IOPS"
    metric "$out" "fio_4k_randread_p99_us" "$(jq -r '.jobs[0].read.clat_ns.percentile["99.000000"] / 1000 // empty' "$rr" 2>/dev/null)" "us"
    metric "$out" "fio_4k_randread_bw"    "$(jq -r '.jobs[0].read.bw / 1024 // empty' "$rr" 2>/dev/null)" "MiB/s"
  fi
  if [ -s "$rw" ]; then
    metric "$out" "fio_4k_randwrite_iops"  "$(jq -r '.jobs[0].write.iops // empty' "$rw" 2>/dev/null)" "IOPS"
    metric "$out" "fio_4k_randwrite_p99_us" "$(jq -r '.jobs[0].write.clat_ns.percentile["99.000000"] / 1000 // empty' "$rw" 2>/dev/null)" "us"
    metric "$out" "fio_4k_randwrite_bw"    "$(jq -r '.jobs[0].write.bw / 1024 // empty' "$rw" 2>/dev/null)" "MiB/s"
  fi
  [ -s "$out/fio-seq-read.json" ] && \
    metric "$out" "fio_seq_read_mib_s"  "$(jq -r '.jobs[0].read.bw / 1024 // empty' "$out/fio-seq-read.json" 2>/dev/null)" "MiB/s"
  [ -s "$out/fio-seq-write.json" ] && \
    metric "$out" "fio_seq_write_mib_s" "$(jq -r '.jobs[0].write.bw / 1024 // empty' "$out/fio-seq-write.json" 2>/dev/null)" "MiB/s"

  # ⚠️ 失败检测：4 个 JSON 一个都没产出时不能静默报「完成」——
  #    记录进 failed-stages.txt 并在汇总中体现（2026-09-13 复查补充）。
  if [ ! -s "$out/fio-4k-randread.json" ] && [ ! -s "$out/fio-4k-randwrite.json" ]; then
    c_warn "fio 未产出任何 JSON（可能引擎不支持或磁盘异常），见 $log"
    echo "fio" >> "$out/failed-stages.txt"
  else
    clear_failed "$out" fio
    c_ok "fio 精测完成（测试文件已清理）"
  fi
}

stage_sysbench() {
  local out="$1"
  local log="$out/sysbench.log"
  need_sudo
  local nproc_val; nproc_val=$(nproc)
  {
    echo "=== sysbench $(date -Is) ==="
    echo "--- CPU 单线程 60s ---"
    timeout "$TIMEOUT_SYSBENCH" sysbench cpu --cpu-max-prime=20000 --threads=1 --time=60 run
    echo
    echo "--- CPU 全核(${nproc_val}) 60s ---"
    timeout "$TIMEOUT_SYSBENCH" sysbench cpu --cpu-max-prime=20000 --threads="$nproc_val" --time=60 run
    echo
    echo "--- 内存带宽（1M 块，单线程，60s）---"
    timeout "$TIMEOUT_SYSBENCH" sysbench memory --memory-block-size=1M --memory-total-size=100G --threads=1 --time=60 run
    echo
    echo "--- 内存带宽（1M 块，全核，60s）---"
    timeout "$TIMEOUT_SYSBENCH" sysbench memory --memory-block-size=1M --memory-total-size=100G --threads="$nproc_val" --time=60 run
  } > "$log" 2>&1

  # 解析：(events per second) 与 (MiB/sec)
  local vals
  vals=$(grep -oE 'events per second:\s+[0-9.]+' "$log" | awk '{print $NF}')
  local s1 s2
  s1=$(echo "$vals" | sed -n 1p); s2=$(echo "$vals" | sed -n 2p)
  [ -n "$s1" ] && metric "$out" "sysbench_cpu_single_eps" "$s1" "events/s"
  [ -n "$s2" ] && metric "$out" "sysbench_cpu_multi_eps"  "$s2" "events/s"
  local m1 m2
  m1=$(grep -oE '[0-9.]+ MiB/sec' "$log" | awk '{print $1}' | sed -n 1p)
  m2=$(grep -oE '[0-9.]+ MiB/sec' "$log" | awk '{print $1}' | sed -n 2p)
  [ -n "$m1" ] && metric "$out" "sysbench_mem_single_mib_s" "$m1" "MiB/s"
  [ -n "$m2" ] && metric "$out" "sysbench_mem_multi_mib_s"  "$m2" "MiB/s"

  # ⚠️ 失败检测：连 events per second 都解析不到说明 sysbench 根本没跑起来
  #    （2026-09-13 复查补充），不能静默报「完成」。
  if [ -z "$s1" ] && [ -z "$s2" ]; then
    c_warn "sysbench 未产出 events per second（可能执行失败），见 $log"
    echo "sysbench" >> "$out/failed-stages.txt"
  else
    clear_failed "$out" sysbench
    c_ok "sysbench 完成（单核 ${s1:-?} / 全核 ${s2:-?} events/s）"
  fi
}

# 超售检测：全核满载 20 分钟，同时采样 %steal（这是判断邻居抢占的核心指标）
stage_stress() {
  local out="$1"
  need_sudo
  local log="$out/stress-ng.log"
  local mplog="$out/mpstat.log"
  # 压测时长由档位决定（quick 5m / standard 10m / full 20m）。
  # 5 分钟足以暴露「持续被邻居抢占」——超售很少是瞬时的，但也很少需要 20 分钟才显形。
  local mins="${CB_STRESS_MINS:-20}"
  {
    echo "=== stress-ng 全核 ${mins}m + mpstat 采样 $(date -Is) ==="
    echo "nproc=$(nproc)"
    # ⚠️ 实测踩坑（天翼云）：部分云厂商的 VM 会屏蔽 AVX/AVX2/FMA/AVX-512 指令集
    #    （该机 CPU flags 只有 sse4_2/aes，无任何 avx），而 stress-ng 默认
    #    cpu-method=all 会执行 AVX 指令 → SIGILL(ILL_ILLOPN) → 0.01s 即
    #    `failed: 2: cpu`、bogo ops 全零，连带 mpstat 只采到表头（%steal 数据全失）。
    #    回退到纯整数运算 int32（不依赖 SIMD），保证 %steal 仍可测量。
    local METHOD=""
    if ! timeout 60 stress-ng --cpu "$(nproc)" --timeout 3s --metrics-brief >/dev/null 2>&1; then
      METHOD="--cpu-method int32"
      echo "[WARN] 默认 cpu-method 不可用（疑似 VM 屏蔽 AVX），回退 --cpu-method int32"
      echo "  该机 /proc/cpuinfo 含 avx: $(grep -qw avx /proc/cpuinfo && echo 是 || echo 否)"
    fi
    echo "stress-ng 实际参数: --cpu $(nproc) $METHOD --timeout ${mins}m"
    mpstat 1 > "$mplog" 2>&1 &
    local mpid=$!
    timeout "$TIMEOUT_STRESS" stress-ng --cpu "$(nproc)" $METHOD --timeout "${mins}m" --metrics-brief
    echo "stress-ng 退出码=$?"
    kill "$mpid" 2>/dev/null
    wait "$mpid" 2>/dev/null
    echo "=== 结束 $(date -Is) ==="
  } > "$log" 2>&1

  # mpstat: 第 3 列是 %usr ... 最后一列是 %steal（不同版本列数可能不同，按表头定位）
  if [ -s "$mplog" ]; then
    local steal_idx idle_idx
    steal_idx=$(awk '/%steal/{for(i=1;i<=NF;i++) if($i=="%steal") print i; exit}' "$mplog")
    idle_idx=$(awk '/%idle/{for(i=1;i<=NF;i++) if($i=="%idle") print i; exit}' "$mplog")
    if [ -n "${steal_idx:-}" ]; then
      # 跳过表头与汇总行（"Average:"），取运行中的样本
      local avg_steal max_steal avg_idle
      avg_steal=$(awk -v c="$steal_idx" 'NR>3 && $1!="Average:" && $c ~ /^[0-9.]+$/ {s+=$c; n++} END {if(n) printf "%.2f", s/n}' "$mplog")
      max_steal=$(awk -v c="$steal_idx" 'NR>3 && $1!="Average:" && $c ~ /^[0-9.]+$/ {if($c>m) m=$c} END {printf "%.2f", m+0}' "$mplog")
      avg_idle=$(awk -v c="$idle_idx" 'NR>3 && $1!="Average:" && $c ~ /^[0-9.]+$/ {s+=$c; n++} END {if(n) printf "%.2f", s/n}' "$mplog")
      [ -n "$avg_steal" ] && metric "$out" "stress_avg_steal_pct" "$avg_steal" "%"
      [ -n "$max_steal" ] && metric "$out" "stress_max_steal_pct" "$max_steal" "%"
      [ -n "$avg_idle" ]  && metric "$out" "stress_avg_idle_pct"  "$avg_idle"  "%"
      c_ok "stress-ng 完成（平均 %steal=${avg_steal}% / 峰值 ${max_steal}%）"
    else
      c_warn "未能从 mpstat 解析 %steal，见 $mplog"
    fi
  fi
  # stress-ng bogo ops 作为满载下的算力参考
  # 注意 stress-ng metrics 行格式（前缀带 pid）：
  #   stress-ng: metrc: [1116252] cpu 30691 8.00 15.98 0.00 3836.36 1921.12
  #   $1=stress-ng:  $2=metrc:  $3=[pid]  $4=cpu  $5=bogo总ops  $6=real时间
  #   $7=usr时间  $8=sys时间  $9=bogo ops/s(real)  $10=bogo ops/s(usr+sys)
  # 取 $9（按 real time 的 ops/s）。
  local bogo
  bogo=$(grep -oE '^.*\bcpu\s+[0-9.]+\s+[0-9.]+\s+[0-9.]+\s+[0-9.]+\s+[0-9.]+\s+[0-9.]+' "$log" 2>/dev/null | awk '{print $9}' | head -1)
  [ -n "$bogo" ] && metric "$out" "stress_bogo_ops" "$bogo" "bogo ops/s"
}

stage_net() {
  local out="$1"
  local log="$out/speedtest.log"
  {
    echo "=== 公网 Speedtest $(date -Is) ==="
    cd "$out" || exit 1
    # Ookla 官方 CLI（轻量套餐带宽受限，结果会顶到套餐上限；记录标称带宽用于解释）
    if [ ! -x ./speedtest ]; then
      # 下载走 cb_curl（检测本机 mihomo 代理）；测速本身连国内节点、直连更快
      cb_curl "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz" -o st.tgz \
        && tar xzf st.tgz speedtest 2>/dev/null && rm -f st.tgz
    fi
    if [ -x ./speedtest ]; then
      # ⚠️ 不要接 `head -40`：speedtest 输出超 40 行时 head 会提前关管道，
      #    speedtest 收到 SIGPIPE 被杀、JSON 不完整（2026-09-13 复查发现的风险）。
      #    输出全部落盘，由下方按行提取 result 行解析（EULA 文本会被跳过）。
      timeout "$TIMEOUT_NET" ./speedtest --accept-license --accept-gdpr --format=json > speedtest.json 2>&1
      echo "speedtest 退出码=$?"
    else
      echo "Ookla CLI 下载失败，回退 speedtest-cli"
      timeout 120 cb_curl https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py -o st.py \
        && timeout "$TIMEOUT_NET" python3 st.py --simple 2>&1 | tee speedtest.txt
    fi
    echo "=== 结束 $(date -Is) ==="
  } > "$log" 2>&1

  # ⚠️ Ookla CLI 首次运行会先在 stdout 打印一整段 EULA 文本，JSON 结果在其后的
  #    某一行——直接对整个文件 jq 会解析失败（首轮三台 speedtest.json 全被误判为
  #    「未产出可用 JSON」，实际数据完好）。故按行提取 result 行再解析。
  local sfile="$out/speedtest.json"
  [ -s "$sfile" ] || sfile="$log"
  local jline
  jline=$(grep -o '{"type":"result".*}' "$sfile" 2>/dev/null | tail -1)
  if [ -n "$jline" ]; then
    printf '%s\n' "$jline" > "$out/speedtest-result.json"
    metric "$out" "speedtest_down_mbps"  "$(printf '%s' "$jline" | jq -r '.download.bandwidth / 125000 // empty' 2>/dev/null)" "Mbps"
    metric "$out" "speedtest_up_mbps"    "$(printf '%s' "$jline" | jq -r '.upload.bandwidth / 125000 // empty' 2>/dev/null)" "Mbps"
    metric "$out" "speedtest_latency_ms" "$(printf '%s' "$jline" | jq -r '.ping.latency // empty' 2>/dev/null)" "ms"
    metric "$out" "speedtest_jitter_ms"  "$(printf '%s' "$jline" | jq -r '.ping.jitter // empty' 2>/dev/null)" "ms"
    metric "$out" "speedtest_server"     "$(printf '%s' "$jline" | jq -r '.server.name // empty' 2>/dev/null)" ""
    clear_failed "$out" net
    c_ok "Speedtest 完成"
  else
    c_warn "Speedtest 未取到 result 行，见 $log"
    echo "net" >> "$out/failed-stages.txt"
  fi
}

# 远端入口：在 tmux 里按阶段顺序执行
remote_exec() {
  local out="$1" stages="$2"
  mkdir -p "$out"
  cd "$out" || exit 1
  echo "$$" > "$out/exec.pid"

  for s in $stages; do
    echo "[$(date -Is)] >>> 阶段开始: $s" >> "$out/progress.log"
    case "$s" in
      env)      stage_env "$out" ;;
      deps)     stage_deps "$out" ;;
      yabs)     stage_yabs "$out" ;;
      pts)      stage_pts "$out" ;;
      fio)      stage_fio "$out" ;;
      sysbench) stage_sysbench "$out" ;;
      stress)   stage_stress "$out" ;;
      net)      stage_net "$out" ;;
      *) c_warn "未知阶段: $s" ;;
    esac
    echo "[$(date -Is)] <<< 阶段结束: $s" >> "$out/progress.log"
  done
  echo "[$(date -Is)] === 全部阶段完成 ===" >> "$out/progress.log"
  touch "$out/DONE"
}

# ---------------------------------------------------------------------------
# 本地调度：run / status / collect / iperf / summarize
# ---------------------------------------------------------------------------
cmd_run() {
  local name="" profile="" stages="" at="" pts_tests="" pts_proxy="" stress_mins=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)        name="$2"; shift 2 ;;
      --profile)     profile="$2"; shift 2 ;;
      --stages)      stages="$(echo "$2" | tr ',' ' ')"; shift 2 ;;
      --at)          at="$2"; shift 2 ;;
      --pts-tests)   pts_tests="$2"; shift 2 ;;
      --pts-proxy)   pts_proxy="$2"; shift 2 ;;
      --stress-mins) stress_mins="$2"; shift 2 ;;
      *) die "未知参数: $1" ;;
    esac
  done
  [ -n "$name" ] || die "用法: $0 run --name <主机名> [--profile quick|standard|full] [--stages env,deps,...] [--at HH:MM] [--pts-tests \"...\"] [--stress-mins N]"

  # 档位展开为默认值；显式传入的参数优先
  # （: "${var:=default}" 仅在 var 为空时赋值，故命令行给的值得以保留）
  : "${profile:=quick}"
  case "$profile" in
    quick)    : "${stages:=$PROFILE_QUICK}";    : "${pts_tests:=$PTS_QUICK}";    : "${stress_mins:=$STRESS_QUICK}" ;;
    standard) : "${stages:=$PROFILE_STANDARD}"; : "${pts_tests:=$PTS_STANDARD}"; : "${stress_mins:=$STRESS_STANDARD}" ;;
    full)     : "${stages:=$ALL_STAGES}";       : "${pts_tests:=$PTS_FULL}";     : "${stress_mins:=$STRESS_FULL}" ;;
    *) die "未知档位: $profile（可选 quick / standard / full）" ;;
  esac
  local target; target="$(host_target "$name")"

  c_head "在 $name ($target) 上启动评测"
  case "$profile" in
    quick)    c_info "档位: quick（约 16 分钟）—— 覆盖轻量云最关心的：磁盘 p99 / 超售 %steal / 物理核识别" ;;
    standard) c_info "档位: standard（约 40 分钟）—— quick + YABS 交叉验证 + PTS（7-Zip/redis）" ;;
    full)     c_info "档位: full（约 2.5 小时）—— 全量，含 PTS 内核编译（轻量云一般用不到）" ;;
  esac
  c_info "阶段: $stages"
  c_info "压测时长: ${stress_mins} 分钟"
  [ -n "$at" ] && c_info "定时: 远端本地时间 $at 开跑（远端计算，本机可关机）"

  # 上传本脚本自身（路径不加引号，让远端的 ~ 正常展开）
  rsh "$target" "mkdir -p $REMOTE_BASE $REMOTE_OUT && cat > $REMOTE_BASE/cloud-benchmark.sh && chmod +x $REMOTE_BASE/cloud-benchmark.sh" \
    < "${BASH_SOURCE[0]}" || die "上传脚本失败"

  # 前端检查：磁盘余量。阈值 5G——PTS 的 build-linux-kernel 约需 3G
  # （内核源码 150M + 编译产物 ~2G），留 2G 余量即可。
  # 不要设太高：生产机磁盘本就吃紧（火山云业务占 29G/39G、仅余 8.5G），
  # 10G 阈值会把完全跑得动的机器直接拦下（实测踩到）。
  local avail
  avail=$(rsh "$target" "df -BG --output=avail / | tail -1 | tr -dc '0-9'") \
    || die "无法连接 $target（SSH 失败）"
  if [ -z "$avail" ]; then
    die "无法读取 $target 的磁盘余量（df 无输出）"
  fi
  if [ "$avail" -lt 5 ]; then
    die "远端磁盘剩余 ${avail}G < 5G，先清理再跑"
  fi
  [ "$avail" -lt 10 ] && c_warn "远端磁盘仅剩 ${avail}G，跑 PTS 时请留意"
  c_ok "远端磁盘剩余 ${avail}G"

  # 生成远端启动脚本（含可选定时等待），避免多层引号嵌套出错。
  # 定时用**远端**的 date 计算：本机与远端时区不一致也不会跑偏。
  local tmp_start; tmp_start="$(mktemp /tmp/cb-start-XXXXXX.sh)"
  {
    echo '#!/bin/bash'
    [ -n "$pts_tests" ] && echo "export CB_PTS_TESTS='$pts_tests'"
    [ -n "$pts_proxy" ] && echo "export CB_PTS_PROXY='$pts_proxy'"
    echo "export CB_STRESS_MINS='$stress_mins'"
    echo "cd $REMOTE_BASE || exit 1"
    echo "mkdir -p $REMOTE_OUT"
    if [ -n "$at" ]; then
      cat <<EOF
t=\$(date -d 'today $at' +%s)
n=\$(date +%s)
[ "\$t" -le "\$n" ] && t=\$(date -d 'tomorrow $at' +%s)
w=\$((t-n))
echo "[\$(date -Is)] [定时] 等待 \${w}s，至远端时间 $at 开跑" | tee -a $REMOTE_OUT/driver.log
sleep "\$w"
EOF
    fi
    echo "./cloud-benchmark.sh __exec --out $REMOTE_OUT --stages \"$stages\" 2>&1 | tee -a $REMOTE_OUT/driver.log"
  } > "$tmp_start"

  # 用 cat 重定向而非 rsync：轻量镜像常未装 rsync（天翼云实测 `rsync: command not found`）
  rsh "$target" "cat > $REMOTE_BASE/start.sh && chmod +x $REMOTE_BASE/start.sh" < "$tmp_start" \
    || die "上传启动脚本失败"
  rm -f "$tmp_start"

  # 后台启动：优先 tmux（便于 attach 观察），无 tmux 时回退 setsid+nohup
  # （轻量镜像常两者缺一：天翼云实测无 tmux、无 rsync）
  local launch
  launch="cd $REMOTE_BASE || exit 1
chmod +x start.sh
if command -v tmux >/dev/null 2>&1; then
  tmux kill-session -t $TMUX_SESSION 2>/dev/null
  tmux new-session -d -s $TMUX_SESSION './start.sh'
  echo 'LAUNCH=tmux 会话=$TMUX_SESSION'
else
  setsid nohup ./start.sh >/dev/null 2>&1 </dev/null &
  echo \"LAUNCH=nohup pid=\$!\"
fi"
  rsh "$target" "$launch" || die "后台启动失败"

  c_ok "已在远端后台执行（tmux 或 setsid+nohup 回退，SSH 断连不中断）"
  c_info "查看进度: $0 status --name $name"
  c_info "回收结果: $0 collect --name $name"
}

cmd_status() {
  local name=""
  while [ $# -gt 0 ]; do case "$1" in --name) name="$2"; shift 2 ;; *) die "未知参数: $1" ;; esac; done
  [ -n "$name" ] || die "用法: $0 status --name <主机名>"
  local target; target="$(host_target "$name")"

  c_head "$name ($target) 进度"
  rsh "$target" "
    echo '--- 运行状态 ---'
    if command -v tmux >/dev/null 2>&1 && tmux ls 2>/dev/null | grep -q '$TMUX_SESSION'; then
      echo 'tmux 会话运行中: $TMUX_SESSION'
    elif [ -f $REMOTE_OUT/exec.pid ] && kill -0 \$(cat $REMOTE_OUT/exec.pid) 2>/dev/null; then
      echo \"后台进程运行中 (PID \$(cat $REMOTE_OUT/exec.pid))\"
    else
      echo '（无运行中的任务）'
    fi
    echo '--- 阶段进度 ---'
    tail -12 $REMOTE_OUT/progress.log 2>/dev/null || echo '（无 progress.log）'
    echo '--- 已产出文件 ---'
    ls -la $REMOTE_OUT 2>/dev/null | tail -20
    echo '--- 驱动器日志尾部 ---'
    tail -5 $REMOTE_OUT/driver.log 2>/dev/null
  "
}

cmd_collect() {
  local name=""
  while [ $# -gt 0 ]; do case "$1" in --name) name="$2"; shift 2 ;; *) die "未知参数: $1" ;; esac; done
  [ -n "$name" ] || die "用法: $0 collect --name <主机名>"
  local target; target="$(host_target "$name")"

  # 用远端主机名做二级校验，避免张冠李戴
  local rhost; rhost=$(rsh "$target" 'hostname')
  local dest="$RESULTS_DIR/$name"
  mkdir -p "$dest"
  c_head "回收 $name ($target, hostname=$rhost) → $dest"

  # 用 tar over ssh 拉取（不依赖远端 rsync，轻量镜像常没装），排除：
  #   ./fio              测试文件目录（fio 阶段已自清，双保险）
  #   *.tgz / yabs.sh   下载物
  #   20*_+08_00 等      YABS 的 geekbench 解压目录（2026-09-13 实测被一起拉回，
  #                      里面是 geekbench 二进制，无用）
  rsh "$target" "cd $REMOTE_OUT && tar czf - \
      --exclude='./fio' --exclude='*.tgz' --exclude='yabs.sh' \
      --exclude='20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*' ." \
    | tar xzf - -C "$dest" || die "结果拉取失败"

  # ⚠️ 同时备份 PTS 的 test-results（2026-09-13 数据丢失事故的教训）：
  #    PTS 结果在 ~/.phoronix-test-suite/test-results/<时间戳>/ 下，不在 out/ 里。
  #    重跑 PTS 会覆盖 out/pts.log，但 test-results 按时间戳独立保存、永不覆盖。
  #    把**最新一个目录**的 composite.xml + test-logs 拉回，作为成绩的权威备份，
  #    即便 pts.log 被覆盖也能恢复（腾讯云 01/02 的 5 项成绩就是这样救回来的）。
  local pts_res
  pts_res=$(rsh "$target" "ls -td ~/.phoronix-test-suite/test-results/*/ 2>/dev/null | head -1")
  if [ -n "$pts_res" ]; then
    local pts_name; pts_name=$(basename "$pts_res")
    mkdir -p "$dest/pts-$pts_name"
    rsh "$target" "cd '$pts_res' && tar czf - composite.xml test-logs 2>/dev/null" \
      | tar xzf - -C "$dest/pts-$pts_name" 2>/dev/null \
      && c_info "已备份 PTS 结果: $pts_name（composite.xml + test-logs）"
  fi

  {
    echo "name=$name"
    echo "ssh_target=$target"
    echo "remote_hostname=$rhost"
    echo "collected_at=$(date -Is)"
  } > "$dest/meta.env"

  c_ok "已回收：$(ls -1 "$dest" | tr '\n' ' ')"
}

# 在远端起一个一次性 iperf3 server（-1 表示服务一个 client 后退出）
iperf_start_server() {
  local target="$1"
  rsh "$target" "
    pkill -x iperf3 2>/dev/null
    sleep 1
    if command -v tmux >/dev/null 2>&1; then
      tmux kill-session -t iperf3srv 2>/dev/null
      tmux new-session -d -s iperf3srv 'iperf3 -s -1 -p 5201 > /tmp/iperf3-server.log 2>&1'
    else
      setsid nohup iperf3 -s -1 -p 5201 > /tmp/iperf3-server.log 2>&1 </dev/null &
    fi
    sleep 1
    echo server_ready" 2>&1 | tail -1
}

# 跨主机 iperf3 互测（双向 -P 8）：A 作 server，B 作 client，再反向
cmd_iperf() {
  local a="" b=""
  while [ $# -gt 0 ]; do
    case "$1" in --a) a="$2"; shift 2 ;; --b) b="$2"; shift 2 ;; *) die "未知参数: $1" ;; esac
  done
  [ -n "$a" ] && [ -n "$b" ] || die "用法: $0 iperf --a <主机A> --b <主机B>"

  local ta tb ipa ipb
  ta="$(host_target "$a")"; tb="$(host_target "$b")"
  # 用私网 IP 还是公网 IP：优先公网（轻量套餐限速作用于公网），这里取公网
  ipa=$(host_field "$a" 3); ipb=$(host_field "$b" 3)

  c_head "iperf3 互测: $a ($ipa) <-> $b ($ipb)"

  for dir in "A->B" "B->A"; do
    # ⚠️ 两个实测 bug：
    #   ① dst 必须用 **ssh 别名**（host_target 的结果），不能直接塞主机清单名——
    #      清单名（如 volc-4c8g-01）不是 ssh 能解析的目标，rsh 会直接失败；
    #   ② server 必须先在**目标端**起来再跑 client。原先在循环外先给 A 起 server，
    #      导致第 1 轮 A→B 时 B 上根本没有 server，只能连出超时。
    local src dst dstip label
    if [ "$dir" = "A->B" ]; then src="$ta"; dst="$tb"; dstip="$ipb"; label="${a}__to__${b}"
    else src="$tb"; dst="$ta"; dstip="$ipa"; label="${b}__to__${a}"; fi
    c_info "方向 $dir ($label)"
    iperf_start_server "$dst"
    rsh "$src" "iperf3 -c $dstip -p 5201 -P 8 -t 15 --json" > "$RESULTS_DIR/iperf3-${label}.json" 2>&1
    local mbps
    mbps=$(jq -r '.end.sum_sent.bits_per_second / 1000000 // empty' "$RESULTS_DIR/iperf3-${label}.json" 2>/dev/null)
    if [ -n "$mbps" ]; then c_ok "  $label: ${mbps} Mbps"; else c_warn "  $label: 未取到结果（1M 带宽机器可能极慢）"; fi
  done
  # 清理两端的 server 会话/进程
  for t in "$ta" "$tb"; do
    rsh "$t" "tmux kill-session -t iperf3srv 2>/dev/null; pkill -x iperf3 2>/dev/null; true"
  done
  c_ok "iperf3 互测完成，JSON 见 results/iperf3-*.json"
}

cmd_summarize() {
  c_head "汇总 results/ 下所有主机"
  python3 "$REPO_ROOT/scripts/cloud-benchmark-summarize.py" || die "汇总脚本执行失败"
}

# 提交评测结果到站点（先本地生成 JSON，再 POST）
# 面向初级用户的关键设计：默认先 dry-run 给用户看一眼要上传什么，确认后再提交。
cmd_submit() {
  local name="" api="" key="" dry=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)    name="$2"; shift 2 ;;
      --api)     api="$2"; shift 2 ;;
      --key)     key="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) die "未知参数: $1" ;;
    esac
  done
  [ -n "$name" ] || die "用法: $0 submit --name <主机名> --api <站点URL> [--dry-run]"
  api="${api:-${BENCH_API_URL:-}}"

  # 本地生成（同时把「哪些指标没测到」提示出来，避免把一堆 0 值传上去还不自知）
  if [ -n "$dry" ]; then
    python3 "$REPO_ROOT/scripts/to-result.py" --name "$name" --results "$RESULTS_DIR" \
      || die "生成结果 JSON 失败"
    c_info "以上是即将提交的内容（--dry-run，未上传）"
    return 0
  fi

  [ -n "$api" ] || die "缺少站点地址：--api <URL> 或 export BENCH_API_URL=..."
  # 密钥优先取环境变量：写成 --key 参数会留在 shell 历史里
  local k="${key:-${BENCH_API_KEY:-}}"
  [ -n "$k" ] || die "缺少提交密钥：推荐 export BENCH_API_KEY=xxx；也可用 --key（注意会留在命令历史）"

  c_head "提交 $name 的评测结果 → $api"
  BENCH_API_KEY="$k" python3 "$REPO_ROOT/scripts/to-result.py" \
    --name "$name" --results "$RESULTS_DIR" --submit "$api" \
    || die "提交失败（见上方错误信息）"
  c_ok "已提交"
}

# 单机「人话报告」——面向初级用户：把指标翻译成「会不会卡 / 是不是虚标 / 能跑什么」
cmd_report() {
  local name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      *) die "未知参数: $1" ;;
    esac
  done
  [ -n "$name" ] || die "用法: $0 report --name <主机名>"
  python3 "$REPO_ROOT/scripts/cloud-benchmark-summarize.py" --report "$name" \
    || die "报告生成失败（该主机有产物吗？先 run + collect）"
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
main() {
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    run)       cmd_run "$@" ;;
    report)    cmd_report "$@" ;;
    submit)    cmd_submit "$@" ;;
    status)    cmd_status "$@" ;;
    collect)   cmd_collect "$@" ;;
    iperf)     cmd_iperf "$@" ;;
    summarize) cmd_summarize "$@" ;;
    __exec)    # 远端内部入口
      local out="" stages="$ALL_STAGES"
      while [ $# -gt 0 ]; do
        case "$1" in --out) out="$2"; shift 2 ;; --stages) stages="$(echo "$2" | tr ',' ' ')"; shift 2 ;; *) shift ;; esac
      done
      remote_exec "$out" "$stages" ;;
    -h|--help|help|"") usage ;;
    *) die "未知命令: $cmd（用 --help 看用法）" ;;
  esac
}

main "$@"
