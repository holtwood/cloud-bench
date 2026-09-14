# HANDOFF —— 交接文档

> 最后更新：2026-09-14
> 写给：接手这个项目的人（包括几周后已经忘了细节的我自己）

---

## 一、30 秒速览

**这是什么**：云服务器性能评测工具。在服务器上跑一套固定流程，把结果提交到对比站点。

**现在什么状态**：工具可用（脚本 + 上报 + 报告），站点可用（本地跑通，未公网部署），
已有 6 台真实机器的数据集。

**如果你只做一件事**：读第四节「关键设计决策」——那里写明了**为什么是这样**，
避免你（或我）把好不容易试出来的设计又改回去。

---

## 二、仓库地图

这个项目由**三个仓库**组成，分工按一条线划：

> **能给别人拿去复现测试的 → 公开；涉及数据集或运维配置的 → 私有。**

| 仓库 | 可见性 | 放什么 |
|---|---|---|
| **cloud-bench**（本仓库） | 公开 | 评测工具本体：采集脚本 / 汇总 / 上报 / 文档 |
| **cloud-bench-server** | 私有 | 站点代码（Go + 前端）+ **数据集** + 部署配置 |
| **dev-home** | 私有 | 作者的实测工作区：原始产物归档 + 结论，`scripts/` 里只有转发器 |

**为什么数据不开源**：数据是运营方的资产（含自有实测与社区提交）。站点对访客公开的是
**渲染后的页面**，不是数据文件与运维细节。

**工具与数据怎么分离**：工具支持 `CB_RESULTS_DIR` 环境变量指定产物目录，
所以「脚本在本仓库、数据在别处」跑得通。这是刻意的——评测者的数据不该被迫塞进工具仓库。

---

## 三、怎么跑（操作手册）

### 3.1 使用者视角（公开流程）

```bash
git clone https://github.com/holtwood/cloud-bench.git
cd cloud-bench

# 1. 配好 ssh 免密登录，然后在 ~/.ssh/config 里给目标机器起个别名
# 2. 填清单（列定义见模板里的注释）
cp results/hosts.tsv.example results/hosts.tsv
vim results/hosts.tsv

# 3. 测（默认 quick 档约 16 分钟；远端 tmux 执行，SSH 断连不中断）
./scripts/cloud-benchmark.sh run --name mycloud-2c2g-01

# 4. 看进度 / 回收产物
./scripts/cloud-benchmark.sh status  --name mycloud-2c2g-01
./scripts/cloud-benchmark.sh collect --name mycloud-2c2g-01

# 5. 出「人话报告」
./scripts/cloud-benchmark.sh report  --name mycloud-2c2g-01

# 6. 提交到站点（先 dry-run 看要传什么）
export BENCH_API_KEY=xxx
./scripts/cloud-benchmark.sh submit --name mycloud-2c2g-01 --api https://站点 --dry-run
./scripts/cloud-benchmark.sh submit --name mycloud-2c2g-01 --api https://站点
```

### 3.2 作者视角（工具在公开仓库、数据在私有工作区）

私有工作区（dev-home）里的 `scripts/cloud-benchmark.sh` 是个**转发器**，
自动设好 `CB_RESULTS_DIR` 指向本地的 `results/`，用法与上面完全一致。

```bash
# 手工等价于转发器做的事：
CB_RESULTS_DIR=/path/to/私有工作区/results \
  /path/to/cloud-bench/scripts/cloud-benchmark.sh run --name X
```

### 3.3 站点

站点代码在私有仓库 `cloud-bench-server`：

```bash
go build -o cloud-bench .
BENCH_API_KEY=xxx ./cloud-bench -addr :8090
# 打开 http://localhost:8090
```

不设 `BENCH_API_KEY` 时服务进入**只读模式**（提交被拒，站点仍可浏览）。

---

## 四、关键设计决策（含理由，别轻易推翻）

### 4.1 为什么默认档只要 16 分钟

实测全量 **2 小时 28 分**，其中 PTS 占 **1:49:20（74%）**，
而 PTS 里的 `build-linux-kernel` 单项就 **87 分钟（占全量 59%）**。

轻量云用户不会在 2C2G 上编译内核。砍掉通用跑分后：

| 档位 | 阶段 | 耗时 |
|---|---|---|
| `quick`（默认） | env deps fio sysbench stress(5m) net | ~16 分钟 |
| `standard` | quick + yabs + pts(7zip, redis) | ~40 分钟 |
| `full` | 全部八阶段 | ~2.5 小时 |

**关键：quick 不损失任何差异化指标**——磁盘 p99（fio）、超售 %steal（stress）、
物理核识别（env）全在其中。砍掉的恰恰是 YABS 也有的通用跑分。

> ⚠️ 如果哪天想「把内核编译加回默认」，请先想清楚：这会让 90% 的用户跑 2.5 小时，
> 而他们根本不需要这个指标。

### 4.2 为什么选 Go + JSON 文件，而不是数据库

- 服务端只有 ~600 行、**零第三方依赖**、单二进制部署
- 数据集是「追加型只读」，规模预期几百台，JSON 完全够
- 文件人类可读、可进 git、可 PR 审核
- 换 FastAPI/Django 只会引入更重的运行时，而产品价值不会增加

### 4.3 为什么 `metrics_missing` 由服务端派生

提交者声明的完整度**一律被覆盖**——否则可以声称「7/7 完整」却交一堆 0 值。
判定用「零值即缺失」，但 `steal_avg_pct` 刻意排除（满载 0% 抢占是**有效结论**，
说明没超售；算成缺失反而抹掉关键信息）。

### 4.4 为什么 `api_key` 用 `json:"-"`

**踩过的真坑**（见 `docs/pitfalls.md` 第 11 条）：该字段原本是 `json:"api_key"`，
导致提交 body 里的密钥会被落盘进数据集文件、并经两个 GET 接口回传。
而 `BENCH_API_KEY` 是全体提交者共用的单一密钥——泄漏即等于数据集可被任意刷写。

### 4.5 为什么 `fio_file_size_gb` 要记录

fio 测试文件大小按磁盘余量自适应（1G/2G/4G），六台实测中就不一致
（火山云 1G、腾讯云04 4G、其余 2G）。这是**影响 IOPS 横向可比性的口径**，
与 `kernel` 字段同理，必须随数据记录。

### 4.6 为什么 `tested_at` 从产物时间戳取，而不是取提交当天

测试与提交可能相隔很久。取产物时间戳才是「这台机器什么时候测的」。

---

## 五、产品定位与调研结论（2026-09）

### 定位

**开源评测工具 + 私有托管服务**。别人用工具测自己的机器 → 提交到站点 →
增厚数据集。数据归运营方，站点不开源。

### 同类产品调研（结论）

- **英文生态**：YABSdb / VPSBenchmarks / ServerHunter / VPSMetrics —— 全是**闭源商业站**
- **中文生态**：内容型博客一大堆（zhujiceping 等），但**没有众包聚合层**
  - `NodeQuality`（2.1k stars，AGPL）解决了「单次报告 + 分享链接」，**但报告之间无法对比**
  - `DigVPS` 是唯一的结构化数据库，但**站长亲测**（覆盖慢、不开放提交）
- **开源的通用 benchmark 平台**（flightlesssomething / ReBenchDB 等）：领域都不对
  （游戏 FPS、CI 回归、LLM 评测），改造代价大于收益

### 结论：空位在「众包 + 横向对比」

而且要建立护城河，靠的是**别人不测的指标**：
磁盘 p99 长尾、超售 %steal —— 中文圈没有站点测这些。

### 最大的外部杠杆

YABS 内置提交协议（`yabs.sh -s <url>`），是英文圈的事实标准入口。
实现一个兼容端点就能接入现成社区，不必从零攒用户。

---

## 六、待办与未决

### 待办（按性价比排序）

- [ ] **兼容 YABS 提交协议**（`POST /api/submit/yabs`）——半天工作量，直接接入现成社区
- [ ] **站点公网部署**（部署步骤见私有仓库的 `docs/deploy.md`）
- [ ] **LICENSE 选择**（目前无 license，法律上等于「保留所有权利」）
- [ ] 个人 profile / 贡献榜（`tokscale` 靠这个做到 5k stars，社交驱动是增长关键）
- [ ] 定期上报（探针式）——VPS 圈普遍挂探针，可积累**时间序列**，这是所有竞品都没有的维度

### 未决问题

| 问题 | 说明 |
|---|---|
| 火山云 region | YABS 的 IP 库识别为「香港九龙」，作者清单里写「广州/北京」——以哪个为准 |
| `fio_file_size_gb` 的影响 | 已知口径不一致，但「小文件是否显著抬高 IOPS」未做实验验证 |
| quick 档实测耗时 | 16 分钟是**按历史日志推算**的，尚未在真机上完整跑过一遍验证 |

---

## 七、已知的坑

完整清单见 **[docs/pitfalls.md](docs/pitfalls.md)**（15 条，每条按「现象 → 真因 → 解法」写）。
最值得先看的三条：

1. **PTS 日志会写满磁盘**（实测 29-37GB）——后台跑 PTS 必须用 `yes '1'` 喂 stdin，
   `</dev/null` 和 `yes ''` 都会让菜单无限重印
2. **`sudo` 默认 `env_reset` 会吞掉 `DEBIAN_FRONTEND`**，导致 apt 卡死几十分钟；
   而 whiptail 直读 `/dev/tty`，重定向 stdin 无效
3. **重跑 PTS 会覆盖 `pts.log`** —— `composite.xml` 才是权威结果源，`collect` 阶段会自动备份

---

## 八、环境与依赖

**工具侧**：bash 4+、python3（仅用标准库）、ssh 免密；远端需要能装
fio / sysbench / iperf3 / stress-ng / sysstat（脚本用 apt 装，已处理非交互与超时）

**站点侧**：Go 1.22+（零第三方依赖，`go build` 即可）、可选 Caddy 做反代

**平台实测范围**：脚本在 Debian/Ubuntu 系上验证过（国内多家云商的轻量/CVM 实例）。
其他发行版未实测——`docs/pitfalls.md` 里的坑大多与环境相关，换环境请重读。

---

## 九、文档索引

| 文档 | 内容 |
|---|---|
| [README.md](README.md) | 项目定位、快速开始、档位说明 |
| [docs/methodology.md](docs/methodology.md) | 8 阶段参数与设计意图、**6 项可比性约束** |
| [docs/pitfalls.md](docs/pitfalls.md) | 15 条实测踩坑 |
| 本文件 | 交接：仓库地图、决策理由、待办、未决 |

> 写代码前建议先读 `docs/methodology.md` 的「可比性约束」一节——
> 那些约束是数据的可信度来源，不是可选项。
