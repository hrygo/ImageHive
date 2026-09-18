# 更新日志

本文件记录本仓库所有值得记下的变更，最新的在最前面。

格式参照 [Keep a Changelog 1.1.0](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循
[语义化版本 2.0.0](https://semver.org/lang/zh-CN/)。条目使用「新增」「变更」「修复」
「移除」「安全」，另有「文档与测试」用于纯文档与测试的改动。

**版本号**：本仓库自己编号（`cli/lib/common.sh` 里的 `IH_VERSION`），并接续上游的 tag 序列，
因此首个公开版是 `0.5.0`。发行包里的 `BUILD-INFO.txt` 记录所基于的上游提交；两套编号互不
相干——上游自己的 tag（`v0.1.0`…`v0.4.0`）不是本仓库的发行版。

**实际发布过什么**：`0.5.0`、`0.5.2`、`0.6.0` 打过 tag 并发过 GitHub Release。改名到 imagehive
时，`0.5.0` 与 `0.5.2` 那两个 Release 页面**连同资产一起删掉了**：资产名还带着旧名字，而
`releases/latest/download/<名字>` 只解析最新的那个 Release，留着只会把人引到 404 或引向一个
叫 `sensenova-u1` 的包。tag 保留，构建机上那份归档也保留
（`dist/sensenova-u1-0.5.0-macos-arm64.tar.gz`、`…-0.5.2-…`，sha256 与当时上传的资产一致，
实测 2026-09-18），要重新挂上去随时可以。`0.6.0` 是改名后的第一个发行版——发行名从
`sensenova-u1-macos-arm64.tar.gz` 变成 `imagehive-macos-arm64.tar.gz`。

`0.5.0` 以下的编号——`0.1.0`、`0.2.0`、`0.2.1`，以及私有的 `0.3.x`（本文件没有条目）——都是
私下构建、从未发布；`0.5.1` 没有单独打过 tag，它的改动随 `0.5.2` 的归档首次发布。没有链接的
标题，就是没有 tag 可比对的那几个版本。

**怎么发一个版本**：bump `IH_VERSION` → `make release-verify` → 打 tag `v<版本>` 并 push
（CI 会构建 tar 包并装进一个临时 `HOME` 验证）→ 把 `dist/*.tar.gz` 与其 `.sha256` 附到
GitHub Release 上。Release 页面承载资产与简短公告，本文件是长期记录。具体命令见
[Docs/DISTRIBUTING.zh-CN.md](Docs/DISTRIBUTING.zh-CN.md)。

## [Unreleased]

### 修复

* **被拒的请求不再碰 MLX。** `handle` 的收尾统计会读 `MLX.Memory.peakMemory`，而 MLX 在
  进程里的第一次调用会顺带建 Metal 设备——没有 Metal 设备的机器上那一次调用活不过去
  （实测 2026-09-18：CI runner，7 GiB，`system_profiler SPDisplaysDataType` 无输出）。
  于是一条**本该被拒绝**的请求（`"width": "512"`）会让守护进程带着 255 退出，调用方收到
  `(closed, no reply)`；同一条 `status` 请求、乃至空转 3 秒都毫无问题，所以这不是"机器
  不稳"，而是"拒绝的路径不该触发模型栈"。现在 `peakMemory`/`clearCache` 只在进程确实做过
  模型工作之后调用；`imagehive unload` 在冷启动时同样不再初始化 Metal。
* **守护进程的 stdout 并入日志。** 上面那条死因是 mlx-c 默认错误处理器
  `printf("MLX error: …"); exit(-1)` 打的，走 stdout；测试脚本与 `verify_release.sh` 只收
  stderr，于是"进程中途消失"只剩一个空日志。launchd job 与 MCP 前端本来就让两个流去同一个
  文件，这一改是让"只收 stderr"的调用方也不再丢线索。

### 文档与测试

* `Tests/cli.sh` 的 `fail()` 现在能说完话：两条 `printf '--- …'` 少了 `--`，bash 3.2 把
  以 `-` 开头的格式当选项、函数带着状态 2 退出，"守护进程还在不在"从来没打印过（CI 日志
  末行就是那条 `printf: --: invalid option`）。现在还会报 `wait` 状态（崩溃是 128+signal）
  与 socket 文件是否还在。
* 失败方式写进 [Docs/TROUBLESHOOTING.md](Docs/TROUBLESHOOTING.md)，实测与取舍写进
  [LOCAL-SERVICE.md](LOCAL-SERVICE.md)，约束写进 [AGENTS.md](AGENTS.md)。

## [0.6.0] - 2026-09-18

**项目更名为 imagehive。** 旧名 `sensenova-u1` 把上游的模型名当成了自己的名字，读起来像官方
出品，也把仓库绑在一次模型换代上；后缀 `-Service` 又是最泛的词。新名字只说这套东西本身：
一个常驻的本地图像服务，一份权重，多个 agent 共用。

### 变更

* **全面改名**：仓库、命令、二进制、MCP server 名、环境变量、app home、日志、launchd 标签、
socket 文件名、发行归档名。这是破坏性变更——写进 shell profile 或脚本的旧环境变量会被静默
忽略，而"静默回落到默认布局"正是能拉起第二个守护进程的那件事，所以对照表在这里给全：

  | 旧（≤ 0.5.2） | 新（0.6.0） |
  |---|---|
  | 仓库 `SenseNovaU1-Service` | `ImageHive` |
  | 命令 `sensenova-u1` | `imagehive` |
  | 守护进程 `sensenova-served` | `imagehived` |
  | MCP 前端 `sensenova-mcp` | `imagehive-mcp` |
  | 客户端里的 server 名 `sensenova` | `imagehive` |
  | `~/.local/share/sensenova-u1` | `~/.local/share/imagehive` |
  | `~/Library/Application Support/SenseNovaU1` | `~/Library/Application Support/ImageHive` |
  | `~/Pictures/SenseNovaU1` | `~/Pictures/ImageHive` |
  | `~/Library/Logs/SenseNovaU1/served.log` | `~/Library/Logs/ImageHive/imagehived.log` |
  | launchd 标签 `local.sensenova-u1` | `local.imagehive` |
  | socket 文件 `served.sock` | `imagehived.sock` |
  | 环境变量 `SENSENOVA_HOME` / `_SOCKET` / `_MODELS` / `_OUT` / `_PREFIX` / `_LABEL` / `_VERSION` / `_DAEMON_BIN` 等 | 同名的 `IMAGEHIVE_*` |
  | 归档 `sensenova-u1-macos-arm64.tar.gz` | `imagehive-macos-arm64.tar.gz` |

  改名没有碰别人的名字：上游移植（`Sources/SenseNovaU1/`、`Sources/MLXSenseNovaU1/`、
  `sensenova-cli`、两个上游测试 target）、上游仓库 `xocialize/sensenova-u1-swift`、上游测试用的
  `SENSENOVA_*` fixture 变量、以及模型制品 `SenseNova-U1.5-8B-MoT-*` 都保持原样。
* **`install.sh` 负责一次性迁移，顺序是关键**：先收掉 0.5.2 的守护进程，再搬目录。否则 home 一
  移动，旧守护进程的 socket 文件跟着移到新路径，新守护进程的 bind 探测会读到"已有实例在服务"
  然后 exit 3——装了个新版，答复却全部来自旧进程。搬 `~/Library/Application Support/SenseNovaU1`、
  `~/Pictures/SenseNovaU1` 与日志目录，卸载并删除旧 LaunchAgent 的 plist。只搬默认位置：
  `--home`/`--out` 装出来的东西不动，只打印出来由人决定。
* **旧 launchd job 按内容识别、按品牌词改名**：标签可以用 `--label` 自定义（作者机器上就是
  `com.hrygo.sensenova-u1`），只匹配默认标签会漏掉它。plist 正文里写着它启动哪个二进制，据此
  找到 job；标签里带品牌词就改名而不是替换——`com.hrygo.sensenova-u1` 变成
  `com.hrygo.imagehive`，用户自己的前缀留着；命令行上显式的 `--label` 优先。
* **旧名字继续能用，但不再能拉起第二个服务**：`~/.local/share/sensenova-u1/bin/` 里的两个二进制
  变成转发到新二进制的壳（老 MCP 条目指向这些路径），`sensenova-u1` 这个命令名变成转发到
  `imagehive` 的壳；而旧命令本体与它的 `lib/` 被删除——它们的默认路径是 0.6 之前的 home，
  留着就是又一个能启动守护进程的入口。
* **旧的 MCP 条目会被清掉**：安装器与 `imagehive clients remove` 都会移除客户端里名为
  `sensenova` 的条目。两个条目暴露同一组六个工具，客户端里每个工具会显示两次；opencode 的标记
  块（`// sensenova-u1:begin`）与 qwenpaw 的 `mcp.clients.sensenova_image` 键同样被识别并清理。
* **收旧守护进程按布局限定，报告才是全机**：只结束这个 HOME 的旧前缀与旧 socket 的持有者——
  从别的 `--home`/`--prefix` 起的那是另一个安装，安装器不该朝它发信号（实测 2026-09-18：按进程
  名全机匹配，会让在沙箱 HOME 里跑的安装器杀掉这台机器上真实的服务）。仍在跑旧二进制的进程则
  全机点名报告：它同样是一份多余的权重。
* **内部标识一并改名**：`sv_*` / `SV_*` 辅助前缀改为 `ih_*` / `IH_*`，`IMAGEHIVE_SERVED_BIN`
  改为 `IMAGEHIVE_DAEMON_BIN`，Swift 里的 `spawnServed` / `servedBinaryPath` 改为
  `spawnDaemon` / `daemonBinaryPath`。
* **GitHub 侧一起改**：仓库 `hrygo/SenseNovaU1-Service` → `hrygo/ImageHive`（旧地址 301
  重定向到新地址，实测 2026-09-18）；About 重写——原来写的是 "five MCP tools"，实际是六个；
  topics 补上 `mcp-server`、`model-context-protocol`、`image-generation`、`image-editing`、
  `vision-language-model`、`ai-agents`、`sensenova-u1`，让搜索能找到它。`0.5.x` 的两个
  Release 页面与资产删除，只保留 tag（理由与恢复方式见本文件开头"实际发布过什么"）。

### 新增

* `imagehive doctor` 报告 0.6 之前的遗留：旧 app home 还在磁盘上、旧守护进程还在跑、客户端里
  还留着旧条目。三件事都不会自己消失，而前两件各自意味着"有一份权重没人在用"。
* `uninstall.sh` 同样清理旧名字：旧守护进程、旧 launchd job、旧命令树与旧命令名；旧的 app home
  与图库保留并列出大小（那是 33 GB 的制品和用户的图片，不该由卸载脚本替人决定）。
* `Tests/smoke.sh` 与 `Tests/cli.sh` 在找不到新 app home 时回落到旧 app home 与 0.2 之前的
  目录布局，因此改名当天这台机器上仍能跑完整测试。
* 新增 `Tests/rename.sh`（并入 `make test-quick` 与 CI）：在一次性 HOME 里伪造一份 0.5.2 安装
  ——旧 app home、旧命令、两个旧 launchd job（含自定义标签）、一个真的在跑的旧守护进程，外加
  一个属于**别的**布局、不该被碰的旧守护进程——然后跑真的 `install.sh` 与 `uninstall.sh`，
  断言制品被搬而不是重下、旧 socket 文件没被带进新 home、旧名字只能转发、旧条目被清、
  `doctor` 的报告与实际遗留一致。

### 修复

* **发布包里的 `bash install.sh` 现在真的能装上了。** 归档刻意不含 `Package.swift`，而安装器
  默认要构建，于是 README 与 Release 说明里那条命令死在 `error: Package.swift not found`；
  `--skip-build` 只写在文档深处，`scripts/verify_release.sh` 又一直带着它跑，所以这条路径
  从没被验证过（实测 2026-09-18：严格按 README 装发布包时踩到）。现在由目录形态决定——没有
  `Package.swift` 但有 `prebuilt/imagehived` 就是发布包，直接装 `prebuilt/`，`--skip-build`
  仍然有效；验证脚本改为跑用户真正会敲的那条命令，并用一个跑不起来的 `swift` 断言整条路径
  不需要工具链，再逐字节比对装出来的二进制与 `prebuilt/`。
* **opencode 的标记块被删干净了，包括收尾那一行。** 旧实现在遇到 `…:end` 时停止跳过，却把那一行
  留在文件里，于是每接一次线就多留一行 `// …:end`（实测 2026-09-18：本机 opencode 配置里躺着
  一条孤立的 `// sensenova-u1:end`，而再跑一次安装会在它上面再加一条）。现在块的起止两行一起删，
  落单的 end 标记也一并清掉——那是坏版本留下的孤儿，谁都不会再来认领它；`clients remove` 改为
  按文件内容是否变化决定写回，所以只有孤儿标记时也会被清掉。
* **`--dry-run` 不再用过去式报账。** `removed the old launchd job …`、`images: A -> B`、
  `log: A -> B` 三行现在只在动作真的做完后打印；dry run 里紧挨着的 `would run: rm -f …` 就是
  全部真相，不再有一句读起来像"已经删了"的话陪着它。

### 文档与测试

* 更新日志改为 Keep a Changelog 格式，并写明每个版本里哪些东西是使用者真正能装到的。
* [README.md](README.md) 改为中文权威版，英文镜像为 [README.en.md](README.en.md)：加徽章、
  目录、"已知限制"，以及求助、贡献与维护入口；构建 / 测试 / 发版内容移到 `AGENTS.md`。
* [AGENTS.md](AGENTS.md) 改为中文，围绕命令、硬约束与"已经让人重装过一次的坑"重排，并补上
  上游同步流程与"哪份文档服务哪类读者"的规则。
* 不再以 fork 自述：本仓库内含上游移植的源码与提交历史，但 GitHub 上本仓库与上游不构成
  fork 关系（见 [NOTICE](NOTICE)）。
* [Docs/LAYOUT.md](Docs/LAYOUT.md) 增加"0.6 改名"一节：旧路径、对照表，以及迁移做了什么。
* 发行归档补齐 README 指向的文件：`AGENTS.md`、`LOCAL-SERVICE.md`、`UPSTREAM-README.md`
  现在随归档一起发。此前 README 的文档索引在发行包里指向三个不存在的文件，收紧后归档内
  83 条相对链接全部可达（实测 2026-09-18）。两份交付指南的归档清单也同步到与实际一致。
* [Docs/TROUBLESHOOTING.md](Docs/TROUBLESHOOTING.md) 里"重装了却没变化"那条不再写死作者机器
  的 `com.hrygo.imagehive` 标签，改为默认的 `local.imagehive` 并说明 `--label` 时替换成自己的。

## [0.5.2] - 2026-09-18

**服务不再猜客户端想要什么，跑不成的请求不花任何代价。** 这一轮源于对整套管理进程只提了
一个问题——"这个进程能被托付 34 GB 的别人的工作成果吗？"——然后用压力脚本、而不是顺利路径
来回答它。

### 变更

* **类型不对的参数会被拒绝；只有"缺省"才等于用默认值。** 改动前实测：`"width": "512"`
  按 1024x1024 出图、`"steps": "4"` 跑 50 步、`"seed": "126"` 产出**随机** seed——做对比的
  客户端没有任何办法知道自己设置被丢了。模型相关命令读取的每个参数现在都过一个严格读取器，
  报错时复述收到的值（`seed must be a number, got the string "126"`）。
* **跑不成的请求在加载权重之前就被拒绝。** `edit_image`/`describe_image` 的参考图在
  `ensureLoaded` 之前解码，笔误的代价从 34 GB 变成零。`describe_image` 过去用
  `compactMap { try? … }` 悄悄丢掉读不了的路径，然后对着"什么都没有"作答；现在它说
  `no such image: <path>`，而"空提问 + 没有图片"不再算一个请求。
* **socket 有了生命周期，而不只是一个文件。** SIGTERM/SIGINT 在退出前 unlink socket，
  停掉的守护进程不再留下"每个就绪检查都在找的那件东西"（实测：安装器报服务已起、紧接着它
  自己的冒烟测试失败）。一个裸换行会得到应答而不是沉默，客户端没发结尾换行就断开会被记
  日志，超过 16 MiB 的请求行会被拒绝而不是先缓冲。
* **前端快速失败，并指出该看哪个日志。** `imagehive-mcp` 在自身旁边找守护进程（`--prefix`
  安装以前会去 `~/.local/share` 找），立刻说 `not installed: no imagehived at <path>
  — run install.sh` 而不是轮询 30 秒；握手超时时指向守护进程日志；并且只重试只读请求
  ——出图请求中途失败时可能已经写出 PNG，所以它被如实上报，而不是重试一遍。
* **用不了的 `config.json` 会说话。** 截断的文件、类型不对的 `ttl_seconds`、000 权限的文件，
  过去都静默使用内置默认值。现在守护进程为每个不可用的键写一条告警，`status` 带上
  `config_warnings`，`doctor` 报 `config.json is not valid JSON`。
* **CLI 导出它解析出的布局。** `ih_load_conf` 现在导出
  `IMAGEHIVE_HOME/MODELS/OUT/SOCKET/PREFIX/LABEL`，这是"`--home` 安装会在默认 socket 上起
  第二个守护进程"的根因——这个项目最不能发生的事。`start`/`stop`/`restart` 报告的是"之后
  是否有人应答"，而不是 launchctl 被要求做什么；`doctor` 只读一次守护进程状态，而不是读
  三次（三次之间可能互相矛盾）。

### 修复

* **严格性撞上的那个坑。** Swift 的 `is Bool` 对任何值为 0 或 1 的 JSON 数字都为真，所以这层
  守卫的第一个版本把 `"seed": 1`、`"steps": 1` 当布尔拒掉了——`Tests/smoke.sh` 第一次运行
  （三个并发客户端，seed 1–3）就抓到了。现在布尔与数字靠 CoreFoundation 类型 id 区分，CLI 的
  可复现性用例改用 `--seed 1` 生成，让这个情形长期被覆盖。
* **重装现在真的会改变运行的东西。** 动手做才发现：应答的守护进程通常是"第一个需要它的
  MCP 前端"拉起的（`spawnDaemon`），而不是 launchd job，并且它活得比任何拉起它的前端都久。
  因此替换二进制后它仍占着 socket：被拉起的 job 绑定失败退出 3，安装报成功，而所有应答仍
  来自旧构建——实测是一次重装后 `options` 被回以 `unknown cmd 'options'`。
  * `stop`、`restart` 与 `install.sh` 现在会接管 socket：停掉 launchd job 之后，仍占着
    socket 的进程会被终止——但仅当它的命令行里有 `imagehived`，所以恰好持有 socket 的
    客户端不受影响。`restart` 现在是先 stop 再 start，而不是 `kickstart -k`（后者只能替换
    launchd 拥有的那个进程）。
  * `status` 报 `pid`、`project_version`、`protocol`，"现在应答的是哪一版"从外部有了答案。
    `doctor` 把它们与已安装的 CLI 比对，并说 `the daemon answering reports version X, this
    install is Y`（比 0.5.1 更老的守护进程根本不报版本，这是同一个信号）；安装器在装完后
    残留的守护进程不是它刚写入的那一版时给出告警。

### 文档与测试

* 测试：守护进程侧断言——类型不对、空行、缺失图片、未以换行结尾的请求、`stop` 移除
  socket——进入 `--quick` 模式，CI 因此覆盖它们；`Tests/socket_probe.py` 直接驱动协议。
  `Tests/cli.sh` 断言手工启动的守护进程（也就是正常安装的运行方式）会被 `stop` 结束、
  socket 被释放、`status` 会报出进程与版本。安装器自身的检查改为比对守护进程报告的版本与
  它绑定的 home，而不是把"连不上"当成"版本不匹配"。
* 文档：[Docs/TROUBLESHOOTING.md](Docs/TROUBLESHOOTING.md) 增加类型不对的参数、被忽略的
  `config.json`、活过守护进程的 socket，以及"我重装了，行为却没有变"。

## 0.5.1 - 2026-09-18

**一次出图现在可复现、自带说明、可脚本化——而且坏请求再也杀不死服务。** 这一轮源于按"真正
要比较两个模型的人"的方式去用它，而第一个发现不是缺便利，是崩溃。

### 新增

* **每张图都附带元数据。** `<image>.png.json` 记录提示词与其 SHA-256、负向提示词及其哈希、
  seed **以及它是被固定还是随机**、尺寸、步数、cfg、请求的档位与实际运行的档位、制品目录、
  耗时、峰值内存、`created_at` 与 project/protocol 版本。在此之前，一次运行留下的唯一记录
  只有文件名，比较只能靠嘴说，无法证明。`write_sidecar: false` / `IMAGEHIVE_SIDECAR=0` 关闭。
* **CLI 上的 `--seed` 与工具上的 `seed`**，以及批量用的 `--n`：`--seed 500 --n 4` 依次产出
  seed 500–503，一张一个文件。同一个 seed 加同一个制品可逐字节复现，这一点在依赖它之前先
  验证过（跨运行 SHA-256 一致）。
* **`imagehive generate` 上的 `--json`、`--out`、`--steps`、`--cfg`、`--negative`**，
  以及每个子命令的 `-h/--help`（`generate --help` 过去是 `error: unknown option: --help`）。
  `--json` 输出一个对象、批量时是数组，带机器可读的路径与耗时，而不是一句还要再解析的话；
  `--out` 把 PNG **和它的 sidecar** 一起搬走。
* **新的 `model_options` MCP 工具与 `imagehive options`**：这份契约——支持的尺寸与推荐值、
  各档位的步数与 cfg 范围及默认值、seed 规则、哪些参数适用于哪个工具、是否写 sidecar、
  是否存在取消、本机能服务哪些档位——在不加载权重的前提下返回。客户端不必再靠"发请求、读
  400"来发现规则。
* **`model_status` 在生成期间也能应答。** 一次生成会占住 actor 直到结束，`status` 过去排在
  它后面——实测阻塞 75.3 秒，使这个工具无法区分"忙"和"卡死"，也让 `unload` 的忙碌分支成了
  死代码。现在 `status`、`options` 与 `unload` 的忙碌分支由连接线程从 `StatusBoard` 快照
  直接回答；在飞的任务从 step 回调发布 `current`（`tool`、`step`、`total`、`percent`、
  `elapsed_seconds`），CLI 的进度行读的也是它。
* **CLI 等待期间在 stderr 显示进度**（只在 TTY 上，管道与捕获场景保持安静），轮询
  `status.current`——71 秒的生成不再看起来像卡死。
* `imagehived` 与 `imagehive-mcp` 的版本号取自 `IMAGEHIVE_VERSION`（由安装器写进
  `service.conf`），而不是自 0.2 起就一直错误的硬编码 `0.1.0`；同时暴露 `protocol: 1`，
  供客户端识别回复的形态。

### 变更

* **`negative` 现在在 `generate_image` 上生效，在 `edit_image` 上被拒绝而不是被静默丢弃。**
  守护进程从头到尾忽略了这个参数，而底下的模型一直支持它
  （`SenseNovaTokenizer.t2iIDs(prompt:negativePrompt:)`）；实测两条不同 negative 的请求产出
  了逐字节相同的文件。改图这条路径没有无条件分支，所以非空 negative 现在是错误，而不是空操作。
* 错误回复改用底层的 `localizedDescription`，不再把一个 `NSError` 直接倒出来。
* `LICENSE` 恢复为纯 MIT 文本，本仓库的版权行紧挨上游那行；本仓库新增部分的归属仍写在
  `NOTICE` 里。原先贴在 MIT 正文之后的那段附注会让 GitHub 把仓库标成 `NOASSERTION` 而不是
  MIT，对任何正在判断"能不能用"的人来说，那读起来像"许可不明"。作为 v0.5.0 发布的那份归档
  带的是同一套 MIT 条款的脚注版本，法律含义相同，因此不需要重新发布。

### 修复

* **不是 32 倍数的尺寸过去会中止守护进程**，而不是让请求失败。`Configuration.pixelsPerToken`
  是 `patchSize / downsampleRatio` = 16 / 0.5 = 32，于是 `1000x1000` 变成一个 reshape 无法
  满足的 latent 网格：`Fatal error: [reshape] Cannot reshape array of size 3000000 into shape
  (1,3,31,32,31,32)`，不可捕获，共享 socket 上每个客户端会话一起丢。现在 `width`、`height`
  （32 的倍数、32–4096）、`steps`（1–500）、`seed`（非负）都在加载权重**之前**校验——坏请求
  零代价，且回复会给出最接近的合法值。负 seed 与 `steps: 0` 是同一类 bug（`UInt64(-1)` 陷阱）。
* `scripts/verify_release.sh` 不再因为只读文件而中止。它用一次递归 `xattr -wr` 给解压副本打
  隔离属性，而 xattr 会拒绝调用方写不了的文件——由别的工具链构建的归档里，bundle 内部的
  macOS 资源可能是 444 权限，于是检查在前两步已经通过之后以 `[Errno 13] Permission denied`
  挂掉。现在逐个条目应用该标志、报告被拒条目数，真正要紧的断言（二进制被打上隔离属性、再由
  `install.sh` 解除）保持不变。用 444 资源的归档在本地复现：旧脚本如 CI 一样失败，新脚本通过。
  `install.sh` 原本就容忍同样的情况。
* 当机器低于制品的记忆内存下限、但这次安装根本不涉及制品时，`install.sh` 不再拒绝安装或打印
  dry run。`--model none` 只部署二进制、不带权重，而 dry run 的存在本就是为了让小内存机器
  的人看清一次安装会做什么；这两条过去会撞上跟真装 15 GB 一样的 `die`。门槛本身在该在的地方
  没有变：真要跑权重的安装，在低于 18 GB 的机器上仍然停下。

### 文档与测试

* 测试：新增 `Tests/cli.sh`（help、参数校验、`options`、`--json` + seed + sidecar + 逐字节
  复现、`--out`、`--n`、坏请求后服务仍活着）；`Tests/smoke.sh` 增加 `model_options`、
  坏尺寸存活、同 seed 逐字节一致、"生成期间 status 仍应答"三个用例。`Tests/smoke.sh` 也不再
  往用户真实的 `~/Pictures/ImageHive/` 写（它从没设过 `IMAGEHIVE_OUT`）——那些散落的基准图
  就是这么来的。`make test-quick` 以快速模式跑两个脚本；CI 会编译 CLI 的 Python 辅助文件。
* 文档：[Docs/MODELS.md](Docs/MODELS.md) 增加"图片尺寸"（规则、推荐集合、实测代价），
  [Docs/LAYOUT.md](Docs/LAYOUT.md) 说明图片旁边的 sidecar，
  [Docs/CLIENTS.md](Docs/CLIENTS.md) 增加"What the tools take"（参数表，加 agent 需要先知道的
  六件事），[Docs/TROUBLESHOOTING.md](Docs/TROUBLESHOOTING.md) 覆盖尺寸拒绝与"我杀掉了它，
  图片还是出现了"；两份 README 各用自己的语言记录了对比评测流程。

**有意不做**：在飞请求仍然无法取消（回复会如实说明，而不是假装能取消）；socket 协议保持
一行进一行出，因此进度不走协议；`--manifest` 没有实现——`--seed` + `--n` + `--json` 目前
覆盖了同样的需求。

## [0.5.0] - 2026-09-18

首个公开发行版。**把它交给别人，以及让不写代码的人用起来。** 发行归档当时装不上，下载下来的
副本可能在第一次启动时挂住；两者都已修复，并由 `make release-verify` 验证。

### 新增

* `make release` 现在生成完整、自包含的归档：`install.sh`、`uninstall.sh`、`cli/`、`Docs/`、
  `README`/`LICENSE`/`NOTICE`/`CHANGELOG`、`BUILD-INFO.txt`、`SHA256SUMS` 与 `prebuilt/`
  （两个二进制加 MLX bundles）。`install.sh` 会 source `cli/lib/*.sh`，所以早先只有
  `prebuilt/` 的 tar 包什么都装不了。
* **隔离属性被处理。** Gatekeeper 拒绝运行被隔离的 Mach-O：进程会挂在 `syspolicyd` 的系统
  确认框上，而终端里的安装根本看不到那个框；BSD 的 `install`/`cp` 还会把该标志传播给已安装
  的副本，于是每次 MCP 客户端启动都会挂住。`install.sh` 现在会清掉它所安装文件的
  `com.apple.quarantine` 并说明这一点；`bash install.sh` 在被隔离的副本上也能用，因为 shell
  读取的脚本不受这道门限制。这一切都不需要 Developer ID 或公证——实测数据在
  [Docs/DISTRIBUTING.md](Docs/DISTRIBUTING.md)。
* `python3` 现在是带可执行建议的检查项，而不是"先警告、二十分钟下载后再说失败"。
* 模型下载会打印心跳——文件数、字节数、百分比、已用时间——33 GiB 的拉取不再看起来像卡死；
  说明里也写明可以续传。（`IMAGEHIVE_PROGRESS=0` 可以静音。）
* 安装器结尾会在 `~/.local/bin` 不在 `PATH` 时指出这一点，给出要加的那一行，并提醒重启 agent。
* `scripts/verify_release.sh`（加 `make release-verify`）：按 `.sha256` 校验归档、给解压副本
  打隔离属性、用 `--skip-build` 装进一个私有 HOME（不需要 Xcode、不需要 Swift），并断言二进制、
  bundles 与命令都已就位**且隔离属性已解除**、沙箱服务能应答、`doctor` 如实报告沙箱"没有模型"
  的状态。`IMAGEHIVE_VERIFY_SKIP_SERVICE=1` 在无 GUI 的 CI 上跳过 launchd 那几步。
* CI：新增 `release` job，构建归档并从 tar 包安装，另加对每个脚本的 shell 语法检查（`bash -n`）。
* 文档：新增 [Docs/DISTRIBUTING.md](Docs/DISTRIBUTING.md)（交付什么、对方怎么做、离线安装、
  交付前清单）；README 增加"不需要 Xcode"的快速开始。
* **中文文档**：[Docs/DISTRIBUTING.zh-CN.md](Docs/DISTRIBUTING.zh-CN.md) 是中文交付指南
  （交付什么、对方怎么做、为什么写 `bash install.sh`、离线安装、交付前清单）。中文首页即
  [README.md](README.md)（中文版为准，英文镜像为 `README.en.md`），随归档一起发布。

### 变更

* 归档按 `cli/lib/common.sh` 里的项目版本命名（这里是 0.5.0），而不是按上游 git tag——后者
  会让一次本仓库的构建看起来像上游发行版；tag 记录在 `BUILD-INFO.txt` 里。
* `imagehive-mcp` 的守护进程日志和其他东西一样写在 `$HOME` 下，沙箱安装不再往真实用户的日志
  里追加内容。

## 0.2.1 - 2026-09-18

**只装一个档位完全够用。** `tier` 是偏好而不是硬要求——文档这么写，守护进程却没这么做，于是
只有单档的机器在打到另一档的请求上失败。

### 变更

* `imagehived` 把请求的档位与已安装的档位对齐，请求的那档没装时用已装的制品服务
  （`resolveTier`，两个方向都成立）。配方跟着内存里的制品走——`fast` 保持 8 步 / cfg 1.0，
  `quality` 保持 50 步 / cfg 4.0——所以回落绝不会用参考配方去驱动蒸馏权重，反之亦然。
* 回复同时给出两个档位（`"tier": "quality", "tier_requested": "fast"`），人读的那行是
  `tier quality, asked for fast, not installed`，`model_status` 报 `available_tiers`。
* `imagehive doctor` 把缺档位当提示而不是失败；`models` 与 `config show` 标出每档是否已装；
  不带 `--tier` 的 `generate` 选这台机器有的那一档。
* `install.sh` 在只装了一个制品时会说明，可选的 `--smoke-generate` 也不再假定 fast 档存在。

### 文档与测试

* `Tests/smoke.sh` 的出图断言改在主机实际拥有的制品上跑，并在单档机器上通过请求"没装的那一档"
  来证明回落成立。
* [Docs/MODELS.md](Docs/MODELS.md) —— "One artifact is enough"；
  [Docs/TROUBLESHOOTING.md](Docs/TROUBLESHOOTING.md) —— 新增的消息。

## 0.2.0 - 2026-09-18

**安装位置遵从平台惯例**（依据与来源见 [Docs/LAYOUT.md](Docs/LAYOUT.md)）。

### 新增

* 新设置 `IMAGEHIVE_MODELS`（`--models`）与 `IMAGEHIVE_OUT`（`--out`），以及给不常见旧布局用的
  `--legacy-home`；环境变量仍优先于 `service.conf`。
* 新文档：给改这个仓库的 agent 看的 [AGENTS.md](AGENTS.md)，以及记录布局决定的
  [Docs/LAYOUT.md](Docs/LAYOUT.md)。

### 变更

* 应用数据——`config.json`、`service.conf`、`imagehived.sock`——与权重迁到
  `~/Library/Application Support/ImageHive/`（权重在 `models/`），出图迁到
  `~/Pictures/ImageHive/`。
* 可执行文件从数据目录迁到 `~/.local/share/imagehive/`，命令在
  `~/.local/bin/imagehive`（XDG）。
* `install.sh` 自动迁移 0.2 之前的安装：搬走制品、原始 checkpoint 与图片，重写 `config.json`，
  并在旧目录留下小包装脚本，让早先写好的客户端条目继续可用——它们仍然都指向同一个 socket，
  所以仍然只有一份权重。
* 两个可执行文件现在都在 passwd 条目之前认 `$HOME`，沙箱 `HOME` 不再摸回真实用户的 app home。

### 修复

* `clients add opencode` 改为重写条目，而不是追加第二条。重复的 `"imagehive"` 键不是小事：
  JSON 保留**最后**一条，所以一条指向旧路径的陈旧或手写条目会悄悄盖过刚写入的那条——安装器
  说"已接线"，而客户端启动的仍是上一个二进制。`add` 现在先删掉所有副本。

## 0.1.0 - 2026-09-18

本机生图服务的首个可分享版本；从未发布。

### 新增

* `imagehived` —— 常驻守护进程：持有模型，串行生成，空闲 TTL 后卸载，socket 绑定即
  单实例，single-flight 加载。
* `imagehive-mcp` —— 无状态 stdio MCP 前端，五个工具（`generate_image`、`edit_image`、
  `describe_image`、`model_status`、`unload_model`），兼容两代协议（旧的 `initialize` 与
  2026-07-28 的 `server/discover`）。
* `install.sh` / `uninstall.sh` —— preflight、制品下载（优先 ModelScope，回退 Hugging Face 与
  hf-mirror）、构建、安装、LaunchAgent、客户端接线、冒烟测试；可重复运行、可回退。
* `imagehive` —— 管理命令：`status`、`doctor`、`models`、`clients`、
  `start/stop/restart`、`logs`、`unload`、`generate`、`config`、`paths`。
* 客户端适配：Codex、Claude Code、opencode、QwenPaw、Claude Desktop、Cursor，以及通用片段。
* 配置迁到 `$IMAGEHIVE_HOME/config.json`（档位路径、TTL）与 `$IMAGEHIVE_HOME/service.conf`
  （安装布局）；环境变量仍然优先。

[未发布]: https://github.com/hrygo/ImageHive/compare/v0.5.2...HEAD
[0.5.2]: https://github.com/hrygo/ImageHive/compare/v0.5.0...v0.5.2
[0.5.0]: https://github.com/hrygo/ImageHive/releases/tag/v0.5.0
