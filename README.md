# Cloud Bench

**云服务器性能评测工具** —— 一套可复现的深度评测脚本。

> 本仓库**只放工具**：评测脚本 + 方法论 + 踩坑记录。
> 数据集与对比站点由运营方私有维护，不在本仓库（详见文末「仓库边界」）。

## 为什么不用现成的

YABS、bench.sh、融合怪很快很好用，但它们测的是"快不快"，不测"稳不稳"。
实测下来这几处盲区恰恰决定实际体感：

| 盲区 | 后果 | 本工具 |
|---|---|---|
| 只有平均 IOPS，无长尾延迟 | 平均 26000 IOPS 看着漂亮，p99 可能是 **952ms**——数据库/容器的卡顿就来自这里 | fio 记录 **p99 / p99.9** |
| 几乎不做超售检测 | 邻居跑满时你的机器被抢 CPU，跑分那几分钟看不出来 | stress-ng 满载 20 分钟 + mpstat 持续记 **%steal** |
| 只看标称核数 | "4 核"可能是 2 物理核 × 2 超线程 | 拆出 **物理核/线程** + 多核扩展比交叉验证 |
| 不检测指令集 | 屏蔽 AVX 的机器跑某些负载会直接 SIGILL | AVX / AVX-512 检测 |
| 无原始数据 | 只有截图，无法复核 | 原始产物全量保留，汇总可重算 |

**不是"更准"，而是多测了几个维度**——跑分同量级时，这些维度才决定体验。

## 快速开始

```bash
git clone https://github.com/holtwood/cloud-bench.git
cd cloud-bench

# 1. 先在 ~/.ssh/config 里配好目标机器的别名（并确保免密登录可用）
# 2. 复制清单模板，按自己的机器填写
cp results/hosts.tsv.example results/hosts.tsv
vim results/hosts.tsv

# 3. 开跑（远端 tmux 后台执行，SSH 断连不中断；全量约 1-2 小时）
./scripts/cloud-benchmark.sh run --name mycloud-2c2g-01

# 4. 看进度 / 回收产物 / 汇总成表
./scripts/cloud-benchmark.sh status    --name mycloud-2c2g-01
./scripts/cloud-benchmark.sh collect   --name mycloud-2c2g-01
./scripts/cloud-benchmark.sh summarize
```

常用参数：

```bash
--stages env,deps,fio     # 只跑指定阶段（8 个阶段可任选）
--at 23:30                # 在**远端**定时开跑（跑生产机时用来卡低峰窗口）
--pts-tests <列表>        # 覆盖 PTS 测试项
```

> ⚠️ 跑生产机前请先读方法论里的「可比性约束」——业务负载、测试时段都会显著影响成绩。

## 八个阶段

| 阶段 | 内容 | 关键产出 |
|---|---|---|
| `env` | 系统信息、物理核/超线程、指令集、虚拟化类型 | 后续所有对比的前提 |
| `deps` | 安装 fio / sysbench / iperf3 / stress-ng / PTS | —— |
| `yabs` | YABS 快速跑分 | 与精测**交叉验证** |
| `pts` | Phoronix 固定 5 项（7-Zip / openssl / 内核编译 / ramspeed / redis） | 应用层性能 |
| `fio` | 磁盘精测：4K 随机 + 顺序读写 + **p99 长尾** | 决定"卡不卡" |
| `sysbench` | CPU 单核/全核 + 内存带宽 | 决定"强不强" |
| `stress` | 满载 20 分钟 + %steal | 决定"稳不稳"（超售证据） |
| `net` | Speedtest + 跨机 iperf3 | 带宽真实值 |

每个阶段的完整命令与参数、以及**读数据时的 6 项可比性约束**，见
**[docs/methodology.md](docs/methodology.md)**。

## 踩坑记录

**[docs/pitfalls.md](docs/pitfalls.md)** —— 15 条实测踩到的坑，每条按「现象 → 真因 → 解法」写。
其中几条代价很高（apt 卡死 45 分钟、PTS 日志写满 32GB、重跑覆盖导致数据丢失），
自己写评测脚本的话建议先扫一眼。

## 你的数据留在你自己的机器上

脚本**不会**自动上传任何东西。`results/` 已在 `.gitignore` 中排除——你的实测结果、
机器 IP、主机名全部留在本地。

想加入公开对比数据的话，跑完后提交到 Cloud Bench 站点（**站点尚未上线**，届时会
在此补充提交方式）。在此之前，结果可以完全自用。

## 仓库边界

| 内容 | 位置 |
|---|---|
| 评测脚本、方法论、踩坑记录 | **本仓库（公开）** |
| 数据集、对比站点服务端、部署配置 | 私有仓库（运营方维护） |

分界只有一条：**能给别人拿去复现测试的 → 公开；涉及你自己的数据或运维配置的 → 私有。**

## 许可

待定。
