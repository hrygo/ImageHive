# AGENTS.md —— 改这个仓库

给 coding agent（Codex、Claude Code、opencode……）以及按同样方式工作的人看。面向使用者
的安装、用法、限制与排障写进 [README.md](README.md)（中文为权威版本）与 [Docs/](Docs/)；
本文件只讲怎么改代码而不把它改坏：改动范围、命令、硬约束、验证方式。

## 本仓库是什么

本仓库内含上游 [`xocialize/sensenova-u1-swift`](https://github.com/xocialize/sensenova-u1-swift)
的 Swift/MLX 移植源码（连同它的提交历史），并在其上新增一套常驻生图服务：

```text
MCP 客户端 ──► imagehive-mcp ──(unix socket)──► imagehived ──► 一份常驻权重
```

| 路径 | 角色 | 归属 |
|---|---|---|
| `Sources/SenseNovaU1/`、`Sources/MLXSenseNovaU1/`、`Sources/sensenova-cli/` | MLX 移植本体 | 上游——不要改 |
| `Tests/SenseNovaU1Tests/`、`Tests/MLXSenseNovaU1Tests/`、`Docs/publish/`、`Docs/receipts/` | 上游的测试与记录 | 上游——不要改 |
| `Sources/imagehived/` | 守护进程：唯一持有权重、串行生成、空闲 TTL 卸载、socket 绑定即单实例 | 本仓库 |
| `Sources/imagehive-mcp/` | stdio MCP 前端：无状态、不加载权重、连不上时按需拉起守护进程 | 本仓库 |
| `cli/`、`install.sh`、`uninstall.sh` | 管理命令（库在 `cli/lib/`）与安装/卸载脚本 | 本仓库 |
| `Makefile`、`scripts/`、`.github/` | 构建、发版与 CI 脚手架 | 本仓库 |
| `README.md`、`README.en.md`、`CHANGELOG.md`、`LOCAL-SERVICE.md`、`Docs/*`、`AGENTS.md`、`NOTICE` | 文档 | 本仓库 |
| `Package.swift` | 新增两个 executable target——本仓库唯一改动的上游文件 | 共用 |

改动请留在这个范围内。

## 命令

```bash
make help            # 列出全部目标
make build           # 两个产物，release
make test            # Tests/smoke.sh + Tests/cli.sh + Tests/rename.sh —— 需要磁盘上有制品
make test-quick      # 协议与改名迁移，不需要模型 —— CI 默认
make install         # 构建 + 安装 + 重启（保留已有模型）
make release-verify  # 打出 tar 包并装进沙箱 HOME 验证
./scripts/deploy.sh  # 只重建并重装二进制
```

`imagehive` 是管理命令（子命令见 `imagehive --help`）：`doctor` 真的坏了才返回非 0，可以当
检查用；`options` 在不加载权重的前提下打印守护进程的能力契约。改过任何 shell 文件后跑
`bash -n`；`install.sh --dry-run --model none --clients none` 打印每一步动作而不改状态。

## 硬约束

破坏了这几条，这个项目就没有意义：

1. **一台机器只有一份常驻权重。** 三个机制缺一不可：unix socket 绑定即进程互斥；守护进程
   的加载是 single-flight（`pendingLoad`），并发调用等的是同一个任务；守护进程最多持有
   一个档位（`cold | fast | quality`）。再加一个能加载权重的进程、socket 或缓存，这个
   项目就没有意义了。
   请求了没装的档位时，由**已装的那个来服务**（`resolveTier`），并按该制品自己的配方跑
   ——只装一个制品是受支持的安装方式，所以不要把"这个档位没装"变成硬失败，也永远不要让
   请求里的档位决定实际运行制品的步数。
2. **前端保持无状态。** `imagehive-mcp` 不得加载权重、不得写配置、不得在请求之间保留状态。
   它可以按需拉起守护进程。
3. **不提供 HTTP 端点。** 传输是 app home 里的 unix socket；socket 文件**就是**那把锁。
   不要"为了方便"加 TCP 监听。
4. **工具返回文件路径，不返回 base64 blobs**，除非调用方明确要 `inline_thumbnail: true`。
   大结果不许灌进 agent 的上下文。
5. **权重永不提交、永不 vendored、永不随本仓库分发。** 安装器从发布方下载（见
   [NOTICE](NOTICE)）。
6. **不以 root 运行，不写用户 home 之外的位置**（用户自己的 launchd 目录除外）。见
   [Docs/LAYOUT.md](Docs/LAYOUT.md)。
7. **请求在加载任何东西之前先校验，且 CLI 与守护进程规则一致。** 尺寸、步数、seed、文件
   路径都在 `imagehived` 里于 `ensureLoaded` **之前**校验——模型渲染不了的尺寸不是
   "失败请求"，而是不可捕获的 `[reshape]` fatal，会把共用服务一起带走（实测：0.5.0 的
   `1000x1000`）。
   `cli/imagehive` 在本地重复同一套检查，让笔误不必往返回一趟。两处都要加规则（消息里都要
   给出合法的替代值），并在 `Tests/cli.sh` 与 `Tests/smoke.sh` 里断言它。
8. **一个结果要在三处描述。** 调用方能从 MCP 回复或 `--json` 读到的任何字段，也要写进图片
   旁边的 sidecar；任何描述"这份服务接受什么"的内容，也要进 `model_options`。只加在其中
   一处，就是那类让"这张图是哪条提示词画的？"变得无法回答的漂移。
9. **请求严格读取，只有守护进程决定请求的含义。** 键**存在但类型不对**是错误；只有**缺失**
   才等于"用默认值"。宽松读取器（`intArg`、`doubleArg`）就是因此删掉的——它们把
   `"width": "512"` 变成 1024x1024、`"seed": "126"` 变成**随机** seed，做对比的人永远不会
   知道自己设置被丢了。判布尔要问 CoreFoundation 的 `jsonIsBoolean`：`raw is Bool` 对任何
   值为 0 或 1 的 JSON 数字都为**真**，否则 `"seed": 1`、`"steps": 1` 会被当成布尔拒掉。
10. **子进程必须被告知布局，不能靠它自己猜。** `ih_load_conf` 导出它解析出的路径，
    `install.sh` 导出 `IMAGEHIVE_VERSION`；前端或守护进程若在 CLI 走 `--home`/`--prefix`
    安装时回落内置默认值，就会在默认 socket 上起**第二个**服务——这是这个项目最不能发生的
    事（实测 2026-09-18：沙箱安装真的在真实 app home 里起了第二个守护进程）。
11. **旧名字可以继续可用，但绝不能再拉起一个服务。** 0.6 之前叫 `sensenova-u1`，那些路径、
    命令与环境变量仍然存在于已装的机器上（常量集中在 `cli/lib/common.sh` 的
    `IH_LEGACY_*`）。处理它们只有两种正确做法：转发到新二进制（`retire_legacy_names` 写
    的那种壳，老 MCP 条目指着它），或者收掉。**留着旧命令本体不行**：它的默认路径解析到
    0.6 之前的 home，那是又一个能加载权重的入口。任何新的安装/启动/卸载路径都要继续收旧
    名字（`ih_service_reap_legacy`、`ih_client_remove_legacy`），`uninstall.sh` 也一样；
    路径对照表在 [Docs/LAYOUT.md](Docs/LAYOUT.md) 的 "Upgrading from the old name"。

## 如何验证一处改动

改守护进程、前端或安装器，都要让下面这些保持绿色，并在 commit message 里说明跑过哪些：

1. `swift build -c release` 两个产物——不新增告警。
2. `make test-quick`——协议、单实例拒绝、冷启动状态、CLI 依赖的守护进程侧契约，外加
   `Tests/rename.sh` 的 0.6 改名迁移。这两步 CI 每次 push 都跑，写在这里的断言因此生效。
3. `make test`——`Tests/smoke.sh` 加 `Tests/cli.sh`：三个并发客户端、只加载一次
   （`loads_total == 1`）、只有一个 `imagehived` 进程——共享权重那条断言是这个项目
   存在的理由。
4. `install.sh --dry-run` 与 `uninstall.sh --dry-run`——不改状态、不报错。
5. `make release-verify`——分发相关的改动在 push 前跑；CI 的 release job 用同一个脚本把
   tar 包 `--skip-build` 装进私有 HOME。
6. `bash -n` 每个脚本、`python3 -m py_compile cli/lib/*.py`——CI 也跑（见
   `.github/workflows/ci.yml`）：语法错误就是坏发布。

## 已经让人重装过一次的坑

* **守护进程不由 launchd 拥有。** 谁先需要它，哪个 MCP 前端就把它拉起来（`spawnDaemon`），
  它活得比那个前端还久；launchd 的 job 只是让它在登录后有个位子。所以 `bootout` +
  `bootstrap` **不能**替换正在跑的守护进程——绑定失败、退出码 3，而旧进程继续服务，于是
  "重装看起来成功、其实什么都没变"（实测 2026-09-18）。任何启动/替换方式都必须先收掉占着
  socket 的进程（`ih_service_stop`、`ih_service_reap_stray`），任何升级路径都要校验守护进程
  报告的版本（`imagehive status` → `project_version=`）。
* **launchd 会限制重启频率。** 这里 `ThrottleInterval` 是 1 秒；用默认的 10 秒，每次显式
  重启都会白等那么久（实测 19 秒 vs 0 秒）。
* **搬动 app home 会把守护进程的 socket 文件一起搬走。** unix socket 是一个文件：`mv` 整个
  home 之后，仍在运行的旧守护进程就"占着新路径"。新守护进程的 bind 探测连得上，于是判定
  `another instance is live` 并退出 3——安装看起来成功，答复全来自旧进程（实测 2026-09-18）。
  迁移的**顺序**只能是先收进程、清掉它留下的 socket 文件、再搬目录。
* **改名不是字符串替换。** 旧命令树里的脚本若只是改个文件名，它的默认路径仍然指向 0.6 之前
  的 home：`sensenova-u1 status` 会在空目录里摸出一个新服务来。旧命令本体和它的 `lib/` 必须
  删掉，只留转发到新二进制的壳（见硬约束 11）。
* **标记块的两端都属于这个块。** `cli/lib/jsonc_edit.py` 的 `_strip_managed` 遇到收尾标记时
  要把那一行一起丢掉；旧实现只是停止了跳过、却把它留在文件里，于是每接一次线就多一行
  `// …:end`（实测 2026-09-18：本机 opencode 配置里躺着一条孤立的
  `// sensenova-u1:end`）。没有起始标记的落单结束行同样要清——没人会再来认领它。
* **迁移里唯一下不了台的一步是收进程。** `ih_service_reap_legacy` 会真的发信号，所以每个
  调用点都要自己判断 `--dry-run`（`migrate_brand_home` 里就是这么写的）；漏掉判断的版本
  在 `install.sh --dry-run` 时把正在跑的旧服务停掉了（实测 2026-09-18）。其余迁移步骤都由
  `run`/`write_file` 包着。
* **收进程要按布局限定，报告才全机。** `ih_legacy_daemon_pids` 只认这个 HOME 的旧前缀与旧
  socket 的持有者（`ih_legacy_daemon_pids_anywhere` 是全机的，只用于报告）。按进程名全机匹配
  会在沙箱 HOME 里跑安装器时**杀掉这台机器上真实的旧服务**（实测 2026-09-18，两次）；同理，
  沙箱安装还会在真实 launchd 域里 bootstrap 一个 job——所以
  [永远不要拿真实 HOME 测安装器](#永远不要拿真实-home-测安装器)那节的 `--label` 不是可选项。
* **LaunchAgent 由 `install.sh` 里的 unquoted heredoc 生成**，好让 `$(ih_*)` 展开。
  它的正文里（**包括注释**）永远不要出现反引号或 `$( )`——它们会被执行。
* **`service.conf` 逐行解析，绝不 source**（坏文件不能有机会执行任何东西）。值用单引号
  包裹，路径里的空格才能往返无损——不要改回 `printf %q`，它的转义会一次次叠加。
* **两个 Swift 程序都必须在 `FileManager.homeDirectoryForCurrentUser` 之前认 `$HOME`。**
  否则沙箱里的运行会悄悄摸回真实用户的 app home（这事已经发生过一次）。
* **两个测试脚本都写在临时 `HOME`/输出目录里。** 请保持：`Tests/smoke.sh` 曾经继承用户真实
  的 `~/Pictures/ImageHive`，把冒烟图悄悄倒了进去。

## 布局与配置

* **路径。** 见 [Docs/LAYOUT.md](Docs/LAYOUT.md)：应用数据与权重在
  `~/Library/Application Support/ImageHive`，可执行文件在 `~/.local`，出图在
  `~/Pictures/ImageHive`。每条路径都可覆盖（`--home`、`--models`、`--out`、`--prefix`、
  `--label`，或对应的 `IMAGEHIVE_*` 变量）。优先级是环境变量 > `service.conf` > 内置
  默认值；新增设置时保持这个顺序。
* **配置文件。** `config.json` 放运行期旋钮（`ttl_seconds`、`min_warm_seconds`、
  `fast_artifact`、`quality_artifact`）；`service.conf` 放安装布局，由 `install.sh` 写入。

## 永远不要拿真实 HOME 测安装器

把 `HOME` 指到一个临时目录，并给 job 一个自己的 label。这样能把整条路（二进制、配置、
LaunchAgent、包装脚本）走一遍，却不碰已安装的服务：

```bash
TD="$(mktemp -d)"; HOME="$TD" ./install.sh --model none --clients none \
  --label local.imagehive-test --yes
HOME="$TD" "$TD/.local/bin/imagehive" doctor
launchctl bootout gui/$(id -u)/local.imagehive-test
```

## 文档归属

改动落在哪类，就更新对应文档：

| 改动 | 要更新 |
|---|---|
| 路径、环境变量、安装位置 | `Docs/LAYOUT.md`，README 的路径表 |
| 改名、旧名字的处理、迁移顺序 | `Docs/LAYOUT.md` 的 "Upgrading from the old name"、`CHANGELOG.md`、两份 README 的升级一节、`Tests/rename.sh` |
| 新增 MCP 客户端、工具、参数或可接受取值 | `Docs/CLIENTS.md`、`model_options`、`CHANGELOG.md` |
| 模型预设、档位、制品形态 | `Docs/MODELS.md` |
| 值得命名的失败方式 | `Docs/TROUBLESHOOTING.md` |
| 行为或接口变化 | `CHANGELOG.md`（并 bump `cli/lib/common.sh` 里的 `IH_VERSION`）、两份 README |
| 打包、交付或发版步骤 | `Docs/DISTRIBUTING.md` 与 `Docs/DISTRIBUTING.zh-CN.md`；归档里究竟装了哪些文件，以 `Makefile` 的 `release` 目标为准（README 指向的文件必须随归档一起发，否则使用者按文档索引会撞上 404） |
| 设计理由、实测数据、与上游的偏离 | `LOCAL-SERVICE.md` |
| 面向使用者的事实：安装、用法、限制、求助 | `README.md` + `README.en.md` |
| agent 不得破坏的约束 | 本文件 |

与具体机器有关的设计与验收记录不放在本仓库（它们在作者机器的 `本机优化配置` 配置仓库里），
也不要让本仓库依赖它。

## 风格

* **Shell。** `set -euo pipefail`，`bash -n` 干净，步骤幂等，`--dry-run` 诚实，不用 `eval`，
  不 `source` 用户可编辑的文件。
* **Swift。** 不新增告警，类型小，除既有配置常量外不引入全局可变状态。`Package.swift` 是
  tools-version 6.2，因此上游 target 默认按 Swift 6 语言模式构建；本仓库新增的两个 target
  （`imagehived`、`imagehive-mcp`）显式钉了 `.swiftLanguageMode(.v5)`，不要顺手动这个钉子。
* **文档。** 写清楚"什么时候实测的什么结果"（`2026-09-18`、M5 Max、128 GB），不写泛泛而谈；
  中文为权威版本，`README.en.md` 与 `README.md` 保持一一对应。
* **提交。** `type(area): summary`，正文用中文说明*为什么*（现有历史就是模板）。

## 与上游保持同步

上游移植以 `upstream` 远程引入，本仓库是 `origin`；本仓库自己的提交线是当前分支
`local/main`，也就是 `origin/main`（公开默认分支）承载的内容。本地 `main` 分支仍停在本仓库
取用上游代码时的那个基线提交。

```bash
git fetch upstream
git rebase upstream/main local/main
```

本仓库只新增文件，所以唯一会冲突的是 `Package.swift`：保留上游内容，再把两个 executable
target 追加回去。
