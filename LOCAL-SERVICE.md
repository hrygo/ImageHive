# 本机增量：imagehive 常驻生图服务（SenseNova-U1.5 模型）

这个分支在上游 `xocialize/sensenova-u1-swift` 之上只做一件事：把生图/改图/看图能力
变成一台常驻服务与一个 MCP 前端，让 opencode、Codex、QwenPaw 按需调用，并且**永远
只有一份权重常驻**。上游的模型实现、测试与文档一概未改。

- 上游基线：`96a0c9b`（`upstream/main`），我们的提交全部在 `main` 分支上。
- 相关设计、验收记录与机器接线见 `本机优化配置` 仓库
  `docs/superpowers/specs/2026-09-18-sensenova-u15-local-image-service-design.md`。
- 除服务本体外，本分支还带上了分发用的外壳：`install.sh` / `uninstall.sh`、
  管理命令 `cli/imagehive`、面向使用者的 `README.md` 与 `Docs/`。

## 目录

| 路径 | 角色 |
|---|---|
| `Sources/imagehived/` | 守护进程：唯一持有权重，串行生成，空闲 TTL 卸载，socket 绑定即单实例互斥 |
| `Sources/imagehive-mcp/` | stdio MCP 前端：无状态、不加载权重，把工具调用转成 socket 请求；连不上时按需拉起守护进程 |
| `install.sh` / `uninstall.sh` | 安装与卸载：preflight、制品下载、构建、安装、LaunchAgent、客户端接线、冒烟 |
| `cli/imagehive` | 管理命令：`status`/`doctor`/`models`/`clients`/`generate`/`config` 等 |
| `Docs/LAYOUT.md` | 安装位置与依据（app data / 可执行文件 / 权重 / 出图各自的家） |
| `AGENTS.md` | 改这个仓库的 agent 指导：硬约束、验证清单、文档归属 |
| `Package.swift` | 相对上游的两处改动：新增上述两个 executable target |
| `scripts/deploy.sh` | 兼容入口：等价于 `install.sh --model none --clients none`（构建 + 安装到 `~/.local/share/imagehive/bin` + 重启） |

## 构建与运行

```bash
# 推荐：一条命令装好（preflight → 制品 → 构建 → 安装 → 接线 → 冒烟）
./install.sh

swift build -c release --product imagehived
swift build -c release --product imagehive-mcp

# 只重建并重装本机已装的产物（不下载模型、不接线）
./scripts/deploy.sh

# 守护进程（前台运行；正常由 launchd 或 MCP 前端拉起）。两个可执行文件装在
# ~/.local/share/imagehive/bin，应用数据/权重在 ~/Library/Application Support/ImageHive。
"$HOME/.local/share/imagehive/bin/imagehived"

# 前端：stdio 上跑 MCP，日志走 stderr
"$HOME/.local/share/imagehive/bin/imagehive-mcp"
```

环境变量（都有默认值，见两个 `main.swift` 顶部）：

| 变量 | 默认 | 作用 |
|---|---|---|
| `IMAGEHIVE_HOME` | `~/Library/Application Support/ImageHive` | 应用数据：`config.json`、`service.conf`、socket |
| `IMAGEHIVE_MODELS` | `$IMAGEHIVE_HOME/models` | 权重与制品目录（`config.json` 里的相对路径以此为准） |
| `IMAGEHIVE_OUT` | `~/Pictures/ImageHive` | 出图目录 |
| `IMAGEHIVE_SOCKET` | `$IMAGEHIVE_HOME/imagehived.sock` | 守护进程监听路径，同时是单实例互斥锁 |
| `IMAGEHIVE_DAEMON_BIN` | `~/.local/share/imagehive/bin/imagehived` | 前端自拉守护进程时用的可执行文件 |
| `IMAGEHIVE_TTL_SECONDS` | `600` | 空闲多久卸载权重 |
| `IMAGEHIVE_MIN_WARM_SECONDS` | `60` | 出图后最短保温时间 |

socket 协议是换行分隔 JSON：`{"cmd":"generate"|"edit"|"vqa"|"status"|"unload", ...}`，
失败一律回 `{"ok":false,"error":"..."}`。

## 与上游同步

```bash
git fetch upstream
git rebase upstream/main main
```

我们只新增文件，唯一会与上游冲突的是 `Package.swift`（两个 target 追加在文件末尾），
冲突时保留上游内容再加回这两个 target 即可。

## 仓库外的机器接线

这些刻意不放在这里，避免源码仓库绑定某台机器的路径：

- LaunchAgent 自 0.6 起由 `install.sh` 自己生成
  （`~/Library/LaunchAgents/<label>.plist`，本机是 `com.hrygo.imagehive.plist`）。
  `本机优化配置/scripts/launchd/` 里那份是 0.6 之前手写的，文件名仍是
  `com.hrygo.sensenova-u1.plist`，安装器不再读它。
- 客户端注册（Codex / Claude / opencode / QwenPaw）与写进它们条目的 `IMAGEHIVE_*`
  环境变量，同样由 `install.sh` 接线，细节见 `Docs/CLIENTS.md`。
- 回归探针：`本机优化配置/scripts/sensenova_service_probe.sh`（断言并发调用只加载一份权重）
  —— 它仍按 0.6 之前的路径去找 `SenseNovaU1/served.sock`，迁移后要先更新再跑。

## 已知取舍

- 没有接上游 `MLXSenseNovaU1` 的 MLXEngine 契约包：本服务只需要"一份权重 + 串行出图 +
  空闲卸载"，直接调 `ImageHive` 核心少一层版本耦合；需要引擎的内存预算/压力驱逐时再接。
- 没有实现 MCP tasks 扩展：当前是同步阻塞 + 服务端串行队列，客户端一直等到出图完成。
- **请求不可取消**：已派发的请求在守护进程里跑到落盘，客户端断开也不停（批量评测要按此
  计数，中断不会回收样本）。协议层如实声明这一点（`model_options` 的
  `cancellation.supported = false`），不做假装成功的取消。
- **状态与进度不进 actor**：`status`、`options`、忙碌时的 `unload` 由连接线程从
  `StatusBoard` 快照直接回答。原先它们排在长同步的 `t2iGenerate` 后面，实测一次
  1536x1024/50 步生成会把 `model_status` 阻塞 75.3s（"忙"与"卡死"因此无法区分）。
  进度由调用方轮询 `current`，不往 socket 上发消息——保持一行请求一行响应。
- **校验前移**：尺寸/步数/seed 在任何权重加载之前校验。模型渲染不了的尺寸不是失败请求，
  而是不可捕获的 `[reshape]` fatal（实测 1000x1000 会带走整个共用服务）。
- **MLX 的第一次调用有副作用，所以"被拒的请求"不能碰它**：本进程里第一次调用 MLX 会顺带
  建 Metal 设备，而没有 Metal 设备的机器上那一次调用活不过去——mlx-c 的默认错误处理器是
  `printf("MLX error: …"); exit(-1)`：理由打在 stdout、退出码 255，stderr（也就是日志）
  里一个字都没有。实测 2026-09-18（CI runner：7 GiB，`system_profiler SPDisplaysDataType`
  无输出）空转 3 秒、连打 5 条 `status` 都活着，一条**本该被拒绝**的 `generate`
  （`"width": "512"`）就带走了整个守护进程，调用方只看到 `(closed, no reply)`。因此
  `peakMemory`/`clearCache` 只在进程确实做过模型工作后调用（`mlxTouched`），守护进程的
  stdout 也并进 stderr——库的死因不该只留在会被 `/dev/null` 吃掉的那个流里。没有 Metal
  设备的机器本来就跑不了模型，要守住的是"被拒的请求不触发它"。
- **参数是强类型的，只有"缺省"才等于"用默认值"**：类型不对的键一律报错并复述收到的值。
  旧行为实测会静默替换：`"width":"512"` 按 1024x1024 出图、`"steps":"4"` 跑 50 步、
  `"seed":"126"` 变成**随机** seed——做对比评测的人永远不会知道设置被丢掉了。实现时必须
  注意 Swift 的 `raw is Bool` 对 JSON 数字 0/1 也为真（`"seed":1` 会被误判成布尔），
  判断布尔要看 CoreFoundation 类型（`jsonIsBoolean`）；这条陷阱是冒烟测试第一次跑就抓到的。
- **坏配置会说话**：`config.json` 存在但读不了/解析失败/某键类型不对时，守护进程启动日志、
  `status`（`config_warning=`）和 `doctor` 都会报出来。此前一律静默回落内置默认值——
  用户改了配置却看不到任何效果，也无处可查。
- **自己的输出走 `write(2)`，一行日志不该有杀死进程的权力**：日志（stderr）与 MCP 协议
  （stdout）原先都用 `FileHandle`，而它在写入失败时抛 Objective-C 异常——Swift 接不住，
  于是"客户端关掉了管道的读端"这件事以 `SIGABRT` 落在进程头上。实测 2026-09-19：一小时内
  两份 `imagehive-mcp` 崩溃报告（栈都是 `log(_:)` → `-[NSConcreteFileHandle writeData:]`
  → `_objc_terminate`），一份死在启动后 0.13 秒的 "ready" 行上，另一份死在退出那一行；
  守护进程同一条路径带走唯一持有权重的进程。现在 EINTR 重试、其余失败只丢一行；stdout
  写失败按"客户端已走"处理，干净退出 0；`signal(SIGPIPE, SIG_IGN)` 提前到任何写入之前。
  MCP 客户端的批量重启（系统升级后的常态）因此只损失日志行，不掉会话，也不留崩溃报告。
- **读进来的数字要么是精确的整数，要么被拒绝**：`Int(Double)` 在越界时是陷阱不是转换
  （Swift fatal error，`SIGTRAP`、日志空白），实测 2026-09-19 用全新沙箱守护进程逐个输入
  取证：`{"width": 1e30}`、`{"steps": 1e19}`、`{"seed": 1e19}`、
  `{"width": 9223372036854775808}` 四条各自把守护进程带走。现在超过 2^53 的 JSON 数字在
  加载之前被拒（2^53 是 JSON double 还能精确表示某个整数的上限，再大就不是"发送的值"了），
  错误消息给出上限与不带指数的写法。同理 `writePNG` 对非有限像素按极值落盘：模型给出
  NaN/inf 不再是"出完图之后 trap"，而是这张图难看。`cfg`/`img_cfg` 有公开范围
  `0...100`（`options` 的 `cfg.minimum/maximum`、工具 schema、CLI 本地检查三处一致）——
  `1e30` 这样的有限数字以前会变成 `Float.inf` 送进模型。
- **fd 0/1/2 由我们自己补齐**：启动时缺哪个就把 `/dev/null` 打开到哪个，因为"最低空闲
  fd"可能被下一个 socket 或文件拿走。实测 2026-09-19：stderr 被调用方关掉的前端把日志行
  写进了自己的 daemon socket，守护进程当成请求、回 `unknown cmd ''`，客户端把这条错误
  当成了下一次调用的答复；守护进程 `2>&-` 时监听 socket 同样会落在 fd 2 上。补齐之后最坏
  也只是丢一行日志。
- **连接有上限、拒绝要说话**：每条连接一个线程停在 `read`，此前没有天花板；现在最多 64
  条，超出时先回 `too many clients: …` 再关闭（沉默关闭会让调用方等满整个超时），listen
  backlog 提到 128（实测 16 时第 24 次快速连接就被内核挡掉）。EINTR 统一在
  `writeAll`/读循环里重试：中断不是"对端走了"。
- **用户数据只做整体替换**：客户端接线写的是用户编辑器的配置，且是那份设置的唯一副本。
  `open(path, "w")` 先截断再写，进程死在中间就只剩半截文件；现在写同目录临时文件、fsync、
  保留权限、`os.replace`（`cli/lib/atomic_write.py`），失败时原文件逐字节不变。安装器同理：
  二进制与 MLX bundle 先复制到同目录的临时名再 `mv`，中断的安装不会留下截断的可执行文件。
- **socket 有生命周期**：SIGTERM/SIGINT 先 `unlink` 再退出，残留文件不再骗过"能连上才算就绪"
  的判断（实测安装器报服务已起、随即自己冒烟失败）。REST 侧同理：连不上时前端立即失败并指出
  守护进程日志路径，不再空等 30 秒；只对只读请求重试——出图请求重试会静默多写一张图。
- **守护进程由前端 fork，不由 launchd 拥有**：常驻进程是"第一个需要它的 MCP 前端"
  直接拉起的（`spawnDaemon`），launchd 的 job 只是让它在登录后有个位子。后果是：换掉二进制
  之后旧进程仍占着 socket，job 绑定失败（`last exit code = 3`），而所有应答仍来自旧版本——
  实测重装后 `options` 回 `unknown cmd`，输出里没有任何线索。因此 `stop`/`restart`/安装器都会
  先接管 socket（`ih_service_reap_stray`），`status` 与 `doctor` 也会报出正在应答的进程与版本。
- 权重目录与构建目录分离：权重在 `~/Library/Application Support/ImageHive/models`（本机 33GB，只留品质档），
  可执行文件在 `~/.local/share/imagehive`，出图在 `~/Pictures/ImageHive`；本仓库只放代码。
  选择依据与迁移方式见 `Docs/LAYOUT.md`。
