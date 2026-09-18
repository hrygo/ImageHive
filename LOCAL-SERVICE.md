# 本机增量：SenseNova-U1.5 常驻生图服务

这个分支在上游 `xocialize/sensenova-u1-swift` 之上只做一件事：把生图/改图/看图能力
变成一台常驻服务与一个 MCP 前端，让 opencode、Codex、QwenPaw 按需调用，并且**永远
只有一份权重常驻**。上游的模型实现、测试与文档一概未改。

- 上游基线：`96a0c9b`（`origin/main`），我们的提交全部在 `local/main` 分支上。
- 相关设计、验收记录与机器接线见 `本机优化配置` 仓库
  `docs/superpowers/specs/2026-09-18-sensenova-u15-local-image-service-design.md`。
- 除服务本体外，本分支还带上了分发用的外壳：`install.sh` / `uninstall.sh`、
  管理命令 `cli/sensenova-u1`、面向使用者的 `README.md` 与 `Docs/`。

## 目录

| 路径 | 角色 |
|---|---|
| `Sources/sensenova-served/` | 守护进程：唯一持有权重，串行生成，空闲 TTL 卸载，socket 绑定即单实例互斥 |
| `Sources/sensenova-mcp/` | stdio MCP 前端：无状态、不加载权重，把工具调用转成 socket 请求；连不上时按需拉起守护进程 |
| `install.sh` / `uninstall.sh` | 安装与卸载：preflight、制品下载、构建、安装、LaunchAgent、客户端接线、冒烟 |
| `cli/sensenova-u1` | 管理命令：`status`/`doctor`/`models`/`clients`/`generate`/`config` 等 |
| `Docs/LAYOUT.md` | 安装位置与依据（app data / 可执行文件 / 权重 / 出图各自的家） |
| `AGENTS.md` | 改这个仓库的 agent 指导：硬约束、验证清单、文档归属 |
| `Package.swift` | 相对上游的两处改动：新增上述两个 executable target |
| `scripts/deploy.sh` | 兼容入口：等价于 `install.sh --model none --clients none`（构建 + 安装到 `~/.local/share/sensenova-u1/bin` + 重启） |

## 构建与运行

```bash
# 推荐：一条命令装好（preflight → 制品 → 构建 → 安装 → 接线 → 冒烟）
./install.sh

swift build -c release --product sensenova-served
swift build -c release --product sensenova-mcp

# 只重建并重装本机已装的产物（不下载模型、不接线）
./scripts/deploy.sh

# 守护进程（前台运行；正常由 launchd 或 MCP 前端拉起）。两个可执行文件装在
# ~/.local/share/sensenova-u1/bin，应用数据/权重在 ~/Library/Application Support/SenseNovaU1。
"$HOME/.local/share/sensenova-u1/bin/sensenova-served"

# 前端：stdio 上跑 MCP，日志走 stderr
"$HOME/.local/share/sensenova-u1/bin/sensenova-mcp"
```

环境变量（都有默认值，见两个 `main.swift` 顶部）：

| 变量 | 默认 | 作用 |
|---|---|---|
| `SENSENOVA_HOME` | `~/Library/Application Support/SenseNovaU1` | 应用数据：`config.json`、`service.conf`、socket |
| `SENSENOVA_MODELS` | `$SENSENOVA_HOME/models` | 权重与制品目录（`config.json` 里的相对路径以此为准） |
| `SENSENOVA_OUT` | `~/Pictures/SenseNovaU1` | 出图目录 |
| `SENSENOVA_SOCKET` | `$SENSENOVA_HOME/served.sock` | 守护进程监听路径，同时是单实例互斥锁 |
| `SENSENOVA_SERVED_BIN` | `~/.local/share/sensenova-u1/bin/sensenova-served` | 前端自拉守护进程时用的可执行文件 |
| `SENSENOVA_TTL_SECONDS` | `600` | 空闲多久卸载权重 |
| `SENSENOVA_MIN_WARM_SECONDS` | `60` | 出图后最短保温时间 |

socket 协议是换行分隔 JSON：`{"cmd":"generate"|"edit"|"vqa"|"status"|"unload", ...}`，
失败一律回 `{"ok":false,"error":"..."}`。

## 与上游同步

```bash
git fetch origin
git rebase origin/main local/main
```

我们只新增文件，唯一会与上游冲突的是 `Package.swift`（两个 target 追加在文件末尾），
冲突时保留上游内容再加回这两个 target 即可。

## 仓库外的机器接线

这些刻意不放在这里，避免源码仓库绑定某台机器的路径：

- LaunchAgent：`本机优化配置/scripts/launchd/com.hrygo.sensenova-u1.plist`
- 三个客户端注册（Codex / opencode / QwenPaw）与 `SENSENOVA_*` 环境变量
- 回归探针：`本机优化配置/scripts/sensenova_service_probe.sh`（断言并发调用只加载一份权重）

## 已知取舍

- 没有接上游 `MLXSenseNovaU1` 的 MLXEngine 契约包：本服务只需要"一份权重 + 串行出图 +
  空闲卸载"，直接调 `SenseNovaU1` 核心少一层版本耦合；需要引擎的内存预算/压力驱逐时再接。
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
- **守护进程由前端 fork，不由 launchd 拥有**：常驻进程是"第一个需要它的 MCP 前端"
  直接拉起的（`spawnServed`），launchd 的 job 只是让它在登录后有个位子。后果是：换掉二进制
  之后旧进程仍占着 socket，job 绑定失败（`last exit code = 3`），而所有应答仍来自旧版本——
  实测重装后 `options` 回 `unknown cmd`，输出里没有任何线索。因此 `stop`/`restart`/安装器都会
  先接管 socket（`sv_service_reap_stray`），`status` 与 `doctor` 也会报出正在应答的进程与版本。
- 权重目录与构建目录分离：权重在 `~/Library/Application Support/SenseNovaU1/models`（本机 33GB，只留品质档），
  可执行文件在 `~/.local/share/sensenova-u1`，出图在 `~/Pictures/SenseNovaU1`；本仓库只放代码。
  选择依据与迁移方式见 `Docs/LAYOUT.md`。
