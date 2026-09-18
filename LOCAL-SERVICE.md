# 本机增量：SenseNova-U1.5 常驻生图服务

这个分支在上游 `xocialize/sensenova-u1-swift` 之上只做一件事：把生图/改图/看图能力
变成一台常驻服务与一个 MCP 前端，让 opencode、Codex、QwenPaw 按需调用，并且**永远
只有一份权重常驻**。上游的模型实现、测试与文档一概未改。

- 上游基线：`96a0c9b`（`origin/main`），我们的提交全部在 `local/main` 分支上。
- 相关设计、验收记录与机器接线见 `本机优化配置` 仓库
  `docs/superpowers/specs/2026-09-18-sensenova-u15-local-image-service-design.md`。

## 目录

| 路径 | 角色 |
|---|---|
| `Sources/sensenova-served/` | 守护进程：唯一持有权重，串行生成，空闲 TTL 卸载，socket 绑定即单实例互斥 |
| `Sources/sensenova-mcp/` | stdio MCP 前端：无状态、不加载权重，把工具调用转成 socket 请求；连不上时按需拉起守护进程 |
| `Package.swift` | 相对上游的两处改动：新增上述两个 executable target |
| `scripts/deploy.sh` | 构建两个产物，并在已安装 LaunchAgent 时重启服务 |

## 构建与运行

```bash
swift build -c release --product sensenova-served
swift build -c release --product sensenova-mcp

# 守护进程（前台运行；正常由 launchd 或 MCP 前端拉起）
SENSENOVA_HOME="$HOME/Models/SenseNova-U1.5" .build/release/sensenova-served

# 前端：stdio 上跑 MCP，日志走 stderr
.build/release/sensenova-mcp
```

环境变量（都有默认值，见两个 `main.swift` 顶部）：

| 变量 | 默认 | 作用 |
|---|---|---|
| `SENSENOVA_HOME` | `~/Models/SenseNova-U1.5` | 权重、制品与出图目录 |
| `SENSENOVA_SOCKET` | `~/Library/Application Support/SenseNovaU1/served.sock` | 守护进程监听路径，同时是单实例互斥锁 |
| `SENSENOVA_SERVED_BIN` | `$SENSENOVA_HOME/runtime/.build/release/sensenova-served` | 前端自拉守护进程时用的可执行文件 |
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
- 权重目录与构建目录分离：权重在 `~/Models/SenseNova-U1.5`（35GB × 2 档），本仓库只放代码。
