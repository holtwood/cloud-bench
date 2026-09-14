# 踩坑记录

> 只记「不写下来下次一定会再踩一遍」的坑。每条按 **现象 → 真因 → 解法** 写。
>
> 这些坑多数是 2026-09 六台主机实测过程中真实踩到并逐个定位的，
> 复现成本很高（有的单次就浪费几十分钟甚至一次数据丢失），故集中沉淀。
>
> ⚠️ 第一节提到的 `cloud-benchmark.sh` **尚未随本仓库发布**（仍在作者私有仓库）。
> 这些坑对任何自建云主机评测脚本的人都适用，故先行公开。

---

## 一、评测脚本侧

### 1. apt 卡死 45 分钟：`sudo` 把 `DEBIAN_FRONTEND` 吞了

**现象**：`deps` 阶段在某家云上卡住几十分钟毫无输出，SSH 看着像断连。

**真因**：两层叠加——

1. `sudo` 默认 `env_reset`，`DEBIAN_FRONTEND=noninteractive` 传不进去；
2. 进到交互模式后，whiptail 是**直接读 `/dev/tty`** 的，`< /dev/null` 这种重定向对它无效。

所以「把 stdin 重定向到 /dev/null」这个常见解法在这里完全不起作用。

**解法**：

```bash
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y ...
# 再兜一层（防个别包仍要问）：
debconf-set-selections <<< 'debconf debconf/frontend select Noninteractive'
```

外加 apt 超时兜底 + **直连优先、代理回落**（有的机器配了 8894 端口的本地代理，apt 走代理反而更慢）。

### 2. `pkill -f` 把自己杀了

**现象**：一条清理残留进程的命令执行后，SSH 会话直接掉线，后续步骤全没跑。

**真因**：`pkill -9 -f "iperf3.config"` 匹配的是**完整命令行**，而正在执行这条命令的
SSH 会话自身的命令行里就包含 `iperf3.config` 这个字符串 → 自杀。

**解法**：进程名精确匹配用 `pkill -x`；必须用 `-f` 时把模式写成 `[i]perf3` 这种
正则技巧（自身命令行里是 `[i]perf3`，不匹配 `iperf3`）。

### 3. PTS 把日志写到几十 GB，差点写满磁盘

**现象**：PTS 后台跑着，日志文件涨到 **29~37GB**，磁盘告急。

**真因**：PTS 的交互菜单在 stdin 是 EOF 时会**无限重印菜单**。`</dev/null` 和
`yes ''`（空行回车）都会触发。空行在菜单里的语义是"接受默认值"，而默认值会再次进菜单。

**解法**：唯一正确的是 `yes '1'`（持续喂合法的菜单选项）；同时加**日志看门狗**——
超过阈值就杀掉 PTS 进程并截断日志。

### 4. PTS `batch-setup` 的答案序列错一位，代价是 7 天

**现象**：batch 模式跑起来后，PTS 自报预计耗时 **7 天**，跑的是 fio 的 1573 个变体组合。

**真因**：`batch-setup` 有 7 个问题，第 7 问是「Run all test options?」。
答 `y` 就会**展开所有变体**（fio 有 1573 个组合）。

**坑中坑**：一路回车是**不等于**全选 `n` 的——第 3~6 问的默认值仍然是 `Y`。
正确的答案序列是 `y n n n n n n`（只有第一问答 y）。

### 5. PTS 从源码装不上：73 字节的"存根"

**现象**：源码安装后 `phoronix-test-suite` 命令存在但跑不起来。

**真因**：包里的 `phoronix-test-suite` 只是 **73 字节的引导存根**，真正的安装逻辑在
`install-sh` 脚本里；而自建 wrapper 或符号链接会指向自己，形成自我递归。

**解法**：老老实实跑 `install-sh`，不要绕。

### 6. 内核编译失败被误判成"内存不足"，真因是缺两个包

**现象**：PTS `build-linux-kernel` 编译失败，第一反应是内存不够。

**真因**：日志里是 `flex: not found` 和 `gelf.h: No such file`——

- flex 缺失 → 词法分析阶段就挂
- `libelf-dev` 缺失 → `gelf.h` 找不到

**解法**：编译内核的依赖链要补全：
`build-essential flex bison libelf-dev libssl-dev bc`。
**教训**：内存不足和依赖缺失在 PTS 里都表现为"编译失败"，必须看日志尾部而不是猜。

### 7. 重跑 PTS 覆盖了 `pts.log`，5 项成绩没了

**现象**：为补跑内核编译重跑 PTS，结果该机 `pts.log` 里只剩内核编译，之前的
7-Zip/openssl/redis/ramspeed 成绩全部消失。

**真因**：`pts.log` 是**每次重跑覆盖写**的，不是追加。

**解法**：`collect` 阶段自动备份 `~/.phoronix-test-suite/test-results/` 下的
**`composite.xml`**（PTS 的权威结果记录，按时间戳分目录）。出事时从它恢复。
**这是唯一可靠的数据源**，日志只是给人和脚本看的。

### 8. YABS 的 Geekbench 卡 18 分钟，最终分数还是 null

**现象**：YABS 跑到 Geekbench 环节卡很久，最后拿到的分数是 `null`。

**真因**：Geekbench 需从海外 CDN 下载，国内机器下载慢或不稳定，且其 API 常返回空。

**解法**：加 `-g` 跳过。YABS 在本方法论里的定位是**交叉验证 fio**，不需要 Geekbench。

### 9. 天翼云屏蔽 AVX，`stress-ng` 直接 SIGILL

**现象**：超售检测阶段 `stress-ng` 崩溃（SIGILL，非法指令）。

**真因**：天翼云（以及个别厂商）在虚拟化层**屏蔽了 AVX 指令集**，而 `stress-ng`
的部分测试默认会使用 AVX 指令。

**解法**：`env` 阶段就把 AVX/AVX-512 支持情况记录下来（这本身也是重要指标——
它决定某些工作负载能不能跑），后续阶段避开依赖 AVX 的测试项。

### 10. `git push | tail -3; echo $?` 永远报成功

**现象**：脚本判断推送结果，永远显示成功。

**真因**：管道的退出码是**最后一个命令**（`tail`）的退出码。`tail` 当然成功。

**解法**：用 `${PIPESTATUS[0]}`，或干脆不用管道。

---

## 二、cloud-bench 服务侧

### 11. `api_key` 从 body 泄漏进数据集（最严重的一个）

**现象**：提交时把密钥放在 body 里，它会**原样落盘**到 `data/machines/<id>.json`，
并出现在 `GET /api/machines/<id>` 和 `GET /api/results` 的响应里。

**真因**：`Result` 结构体的 `APIKey` 字段标了 `json:"api_key"` → 参与 JSON 解码，
于是被 `store.Save` 一起序列化写入。

**为什么严重**：`BENCH_API_KEY` 是**全体提交者共用的单一密钥**，一旦进 git 就永久公开，
数据集可被任意刷写。

**解法**：标 `json:"-"`（彻底不参与编解码，密钥只从 `X-API-Key` 头读），
并在 `handleSubmit` 里额外显式清空一次做双保险。
**教训**：**任何敏感字段都不要让它进结构体的 JSON 编解码路径**；密钥属于传输层，不属于数据模型。

### 12. `.gitignore` 写了却没生效，8.7MB 二进制进了仓库

**现象**：`.gitignore` 里明明有 `cloud-bench`，但 `git ls-files` 显示二进制被跟踪，
仓库历史里有 4 个 8.7MB 的 blob。

**真因**：`.gitignore` **不支持行尾注释**。写的是

```
cloud-bench          # 编译产物
```

git 把整串（含空格和 `#`）当成一个 pattern，自然匹配不上任何文件名。

**解法**：注释独立成行；改完 `git check-ignore -v <file>` **验证一下**再相信它。
（另外：已被跟踪的文件不受 `.gitignore` 影响，需要 `git rm --cached` 先摘出索引。）

**后续坑**：`git rm --cached` 只是不再跟踪，**历史里的二进制 blob 依然在**——
删文件 ≠ 删历史。本仓库实际清理过程（`.git` 21MB → 632KB，完整 clone 13MB → 584KB）：

```bash
# 推荐 git-filter-repo（比 filter-branch 快且安全，会自动 repack + gc）
git filter-repo --path <文件> --invert-paths --force
# 注意：它会移除 origin remote（防止你误推），需手动加回
git remote add origin <url>
git push --force-with-lease=main:<期望的远端SHA> origin main
```

**⚠️ force push 的实际边界**（实测确认，别以为推完就干净了）：

| 视角 | 结果 |
|---|---|
| 本地 `.git` | 21MB → 632KB ✓ |
| 别人全新 clone | 13MB → 584KB ✓（不可达对象不会被打包） |
| **GitHub 服务端** | **旧提交仍可通过 SHA 直接访问**（实测 `GET /repos/.../commits/<旧SHA>` 返回 200） |

GitHub 会周期性回收不可达对象（数天到数周）；要立即彻底清除只能联系 GitHub Support。
所以 force push 前务必确认**旧历史里没有真正的秘密**——若是密钥/凭据泄漏，
force push 不等于补救，**必须先轮换密钥**。

### 13. 「7/7 完整」是阶段完整，不是指标完整

**现象**：六台都标 `stages_done: 7/7`，但实际有三台各缺一项指标（值为 0）。

**真因**：脚本的完整度是**阶段产物文件是否存在**（阶段确实都跑了），
而"阶段跑了"不等于"每个子项都拿到了结果"。

**为什么必须修**：网站访客看到 `7/7 完整` + 某个指标显示 `—`，会读成"这台机器这项性能为 0"，
或者以为数据完整无缺。

**解法**：新增 `metrics_missing` 字段，**由服务端按指标实际值派生**（提交者声明无效，
否则可以声称完整却交空数据）。判定用「零值即缺失」，但 `steal_avg_pct` 例外——
满载 0% 抢占是合法且有意义的结论。前端把未测项显示为灰色「—」并注明来由。

### 14. 六台的 fio 测试文件大小其实不一样

**现象**：核对产物时发现 `size` 分别是 1G / 2G / 4G。

**真因**：脚本按磁盘余量自适应降级（余量 <20G → 1G，<40G → 2G，否则 4G），
火山云余量只有 8G 因此落到 1G。**降级本身是正确的设计**（不占满用户磁盘），
但它是影响 IOPS 可比性的前提，不记录就是隐性失真。

**解法**：数据集新增 `fio_file_size_gb` 字段，从 fio 产物读实际值（不硬编码，
随脚本策略自动同步），并在方法论文档的可比性约束里显式说明。

### 15. 测试残留混进了公开数据集

**现象**：`data/machines/` 里出现 `safe-test-01.json`、`leak-probe-01.json` 之类的
安全测试探针文件，其中一个还提交进了 git。

**真因**：安全测试直接打的是**生产数据目录**。

**解法**：测试用独立数据目录；每次跑完清理探针。**教训**：
测试环境和数据集目录要分开，否则"造出来的垃圾数据"会跟着数据集一起被发布。
