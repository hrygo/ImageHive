# SenseNova-U1.5 本机生图服务

> [English](README.md) · 英文版为准，中文版随 0.5.2 同步。术语、命令、字段、模型
> 名保持原文，方便和日志、配置、英文文档对上。
>
> 版本号：接续上游 tag 序列（fork 时上游停在 `v0.4.0`），因此首个公开版是
> **0.5.0**，当前版本 **0.5.2**；发行包里的 `BUILD-INFO.txt` 记录所基于的上游提交。

在自己的 Mac 上跑文生图、按指令改图和看图问答，通过 MCP 交给 AI agent 使用。
不需要 API key、不按张计费、图片不出本机；模型经 MLX 在 Apple 芯片上运行，
同一台机器上所有 agent 共用**一份**常驻权重。

## 快速开始

两条路，第一条不需要 Xcode、不需要编译，推荐给不写代码的人。

**用发行包**

```bash
base=https://github.com/hrygo/SenseNovaU1-Service/releases/latest/download
curl -fsSLO "$base/sensenova-u1-macos-arm64.tar.gz"
curl -fsSLO "$base/sensenova-u1-macos-arm64.tar.gz.sha256"
shasum -a 256 -c sensenova-u1-macos-arm64.tar.gz.sha256   # 校验下载是否完整
tar -xzf sensenova-u1-macos-arm64.tar.gz && cd sensenova-u1-*
bash install.sh          # 用 bash，不要 ./install.sh —— 原因见下
```

**从源码**（要改代码时；需要 Xcode 27 与 Metal 工具链，见前置条件）

```bash
git clone https://github.com/hrygo/SenseNovaU1-Service.git
cd SenseNovaU1-Service
./install.sh
```

两种方式装的东西完全一样。安装器会：检查机器 → 下载可直接运行的模型（默认约
11 GiB，优先走 ModelScope 直连，国内无需代理）→ 安装后台服务 → 接线它找到的
MCP 客户端 → 跑一个冒烟测试。

装完**重启你的 agent**（Codex、Claude、opencode、QwenPaw……），然后直接说一句
"给我画一张夕阳下的海边灯塔"，剩下的它会自己调工具。

### 为什么必须写 `bash install.sh`

从浏览器、AirDrop、网盘下来的文件都带 `com.apple.quarantine`（隔离属性），
Gatekeeper 会拒绝**执行**它：隔离的二进制会让进程挂在系统确认框上——而终端里的
安装过程根本看不到那个框，表现就是"卡住不动"。shell 脚本交给 `bash` 读取不受
这个限制，所以用 `bash install.sh` 启动；安装器随后会清掉它自己所安装文件的隔离
标记。不需要开发者签名，也不需要公证。实测数据与原理：
[Docs/DISTRIBUTING.zh-CN.md](Docs/DISTRIBUTING.zh-CN.md)。

## 装在哪里

全部在用户目录下，不需要 `sudo`，也不写进 Homebrew 前缀。`sensenova-u1 paths`
会一次性打印全部路径。

| 内容 | 位置 |
|---|---|
| 命令 | `~/.local/bin/sensenova-u1` |
| 可执行文件、MLX bundle、CLI 内部脚本 | `~/.local/share/sensenova-u1/` |
| 权重（约 11–33 GB） | `~/Library/Application Support/SenseNovaU1/models/` |
| 配置、socket、服务定义 | `~/Library/Application Support/SenseNovaU1/` |
| 日志 | `~/Library/Logs/SenseNovaU1/served.log` |
| 出图 | `~/Pictures/SenseNovaU1/` |

## 前置条件

| | |
|---|---|
| 硬件 | Apple 芯片（M1 及以上）。MLX 不支持 Intel Mac |
| 内存 | 4bit 档最少 18 GB（峰值约 15 GB）；bf16 档建议 48 GB 以上 |
| 系统 | macOS 26 或更新 |
| 磁盘 | 单档约 16 GiB，两档约 48 GiB |
| python3 | **必需**。`xcode-select --install`（随命令行工具，约 1.5 GB）或 `brew install python`。缺了安装器会立刻停下并告诉你 |
| 工具链 | 只有"从源码安装"需要：Xcode 27（完整 App，不是只有命令行工具）+ `xcodebuild -downloadComponent MetalToolchain`。发行包完全不需要 |
| 时间 | 首次 10–40 分钟，主要是下载模型和首次编译 |

已经有模型的人：`./install.sh --model none --skip-build` 两步都跳过。下载有进度
显示、随时可中断、重跑只补缺的文件。

## 档位怎么选

制品是上游发布的、可直接运行的 MLX 转换版本，自带 tokenizer，无需转换步骤。

| 预设 | 磁盘 | 峰值内存 | 1024² 出图 | 适合 |
|---|---|---|---|---|
| `fast-4bit`（安装默认） | 11 GiB | 约 15 GB | 约 3 秒 | 草稿、快速迭代、缩略图 |
| `fast-8bit` | 20 GiB | 约 22 GB | 约 4 秒 | 同上，更接近 bf16 观感 |
| `quality-bf16` | 33 GiB | 约 35 GB | 约 50 秒（50 步） | 成品、图上文字、改图、看图问答 |

```bash
./install.sh --model fast          # 安装默认：轻量档
./install.sh --model both          # 两档都装
sensenova-u1 models pull quality-bf16   # 以后再加一档
sensenova-u1 models                    # 看这台机器装了什么
```

**只装一个档位完全够用**：`tier` 是偏好而不是硬要求。请求里写了没装的那一档时，
守护进程会用已装的那一档来服务，并在回复里说清楚——
`tier quality, asked for fast, not installed`。生成配方（步数、cfg）跟着**实际
运行的制品**走，所以不会出现"拿 8 步蒸馏权重按 50 步跑"这种越界组合。改图和
看图问答固定走质量档，`generate_image` 是唯一分档的工具。

## 让 agent 用上

`install.sh` 会自动接线它认出的客户端。也可以手动：

```bash
sensenova-u1 clients list      # 哪些装了、哪些已接线
sensenova-u1 clients add codex # 或 claude / opencode / qwenpaw / claude-desktop / cursor
sensenova-u1 clients add auto  # 所有检测到的
sensenova-u1 clients snippet   # 给其它客户端粘贴的通用片段
```

写配置前会做时间戳备份，重复运行是幂等的（不会写重复条目）。**改完必须重启
客户端**，MCP 条目只在启动时加载。

agent 那边会看到六个工具：`generate_image`（文生图，可给 `seed` 固定随机、可给
`negative` 负向提示词、可覆盖 `steps`/`cfg`）、`edit_image`（按指令改图）、
`describe_image`（看图/读图上的字）、`model_options`（**问之前先知道**：支持的尺寸、
步数与 cfg 的取值范围和默认值、seed 是否可复现、negative 只对生成有效、元数据落在哪、
本机装了哪些档）、`model_status`（服务状态 + 正在跑的任务进度，**生成期间也立刻返回**）、
`unload_model`（立刻释放内存）。

## 日常命令

```bash
sensenova-u1 status     # 当前驻留档位、加载次数、排队、峰值内存
sensenova-u1 doctor     # 逐项体检，有问题时退出码非 0
sensenova-u1 models     # 装了什么、还缺什么
sensenova-u1 logs -f    # 跟随守护进程日志
sensenova-u1 unload     # 立刻释放内存
sensenova-u1 generate --prompt "一盏黄铜台灯，深色木桌，柔和侧光"
sensenova-u1 options    # 这份服务接受什么：尺寸、步数、cfg、seed
sensenova-u1 restart    # 重启守护进程（权重仍在磁盘上）
sensenova-u1 paths      # 打印所有路径
```

### 做对比评测：固定 seed + 元数据 + 结构化输出

`--seed` 固定噪声；每张图旁边都会落一个 sidecar 记录"这张图是怎么来的"。这两件事
加起来，"我用的应该是同一串提示词"才变成事后可核对的证据：

```bash
sensenova-u1 generate --prompt "一盏黄铜台灯" --seed 42 --width 1216 --height 832
# Wrote ~/Pictures/SenseNovaU1/20260918T083207Z-t2i-seed42.png [1216x832, tier quality,
#       50 steps, 51.3s, seed 42] + 20260918T083207Z-t2i-seed42.png.json
sensenova-u1 generate --prompt "一盏黄铜台灯" --seed 42 --n 4 --out ~/eval/run1 --json
```

同一个 seed、同一个制品、同一组参数写出的 PNG **逐字节相同**（实测：512×512、6 步
两次运行 SHA-256 一致）。sidecar（`<图片名>.png.json`）里有提示词原文与其 SHA-256、
负向提示词、seed 以及它是被固定还是随机、尺寸、步数、cfg、实际运行的制品、耗时与
峰值内存。`--json` 把同样的内容以机器可读的形式打出来（`--n > 1` 时是数组），
`--out` 把图片和它的 sidecar 一起搬走。`sensenova-u1 generate --help` 列全部参数。

批量跑之前需要知道的一件事：**已经派发的请求无法取消**。杀掉命令不会停止生成，图片
照样落盘（详见 [Docs/TROUBLESHOOTING.md](Docs/TROUBLESHOOTING.md)）。要做干净计数
的评测，请等每一条返回再发下一条。

守护进程**按需启动**：空闲一段时间后的第一次调用会加载权重（约 5 秒），之后所有
调用复用它；空闲 10 分钟（`ttl_seconds`，在
`~/Library/Application Support/SenseNovaU1/config.json`）自动卸载，不会一直占着
30 多 GB。多个客户端共享同一份权重，不会因为多开一个客户端就多占一份内存。

## 常见问题

**`./install.sh` 卡住不动。** 隔离属性，见上面的"为什么必须写 `bash install.sh`"。

**`python3 is required and was not found.`** 用 `xcode-select --install` 或
`brew install python` 装好再重跑安装器，它会从断点继续。

**装完了但提示 `sensenova-u1: command not found`。** `~/.local/bin` 不在 macOS
默认 PATH 里：用全路径 `~/.local/bin/sensenova-u1 doctor`，或把
`export PATH="$HOME/.local/bin:$PATH"` 写进 `~/.zprofile`。安装器结尾也会提示。

**下载看起来卡住了。** 开始下载后每几秒会打印一行
`3/12 files, 8.2 GiB of 33.0 GiB (24%), 4m10s elapsed`。真的断了就 Ctrl-C 重跑
`sensenova-u1 models pull <预设>`，已完成的文件按大小校验后跳过，未完成的续传。

**客户端里看不到图片工具。** 重启客户端；仍不行就
`sensenova-u1 clients list` 看是否接线，再 `sensenova-u1 clients add <名字>`。

**第一次出图比后面慢 5–10 秒。** 那是模型加载，不是卡住。想一直保持热：把
`ttl_seconds` 调大。

**回复里写 `asked for fast, not installed`。** 正常：这台机器只装了另一档，
服务用已装档位完成，并如实告诉你实际用的是哪一档。

**内存吃紧。** `sensenova-u1 unload` 立刻释放；想更自动就把 `ttl_seconds` 改小
（例如 120）。实际开销看 `sensenova-u1 status` 的 `last_peak_mb`。

**报错 `seed must be a number, got the string "126"`（`width` 同理）。** 参数是强类型的：
数字要传数字（`"width": 512`，不是 `"width": "512"`），布尔传 `true`/`false`；只有"不传"
才等于用默认值。0.5.2 之前这类参数会被静默替换成默认值——字符串 seed 会变成**随机**
seed，字符串 steps 会按档位默认值跑，做对比评测的人看不出来。

**改了 `config.json` 却不生效。** 解析不了的文件不再被静默接受：守护进程启动时会写
`... is not valid JSON — every setting in it is ignored`，`status` 里有 `config_warning=`，
`doctor` 也会报 `config.json is not valid JSON`；单个键类型不对会点名报出来，其余键照常生效。
另外环境变量优先于文件（`SENSENOVA_TTL_SECONDS` 会盖掉 `ttl_seconds`），
所以还要看启动守护进程的客户端条目和 launchd job 里的环境。

**想卸载。** `./uninstall.sh`（默认保留权重，重装很快）；要连权重一起删：
`./uninstall.sh --purge-models`。

英文完整排障手册：[Docs/TROUBLESHOOTING.md](Docs/TROUBLESHOOTING.md)。

## 文档索引

| 文档 | 内容 |
|---|---|
| [README.md](README.md) | 英文首页（权威版本） |
| [Docs/DISTRIBUTING.zh-CN.md](Docs/DISTRIBUTING.zh-CN.md) | 中文交付指南：怎么打包给别人、对方怎么做、离线安装 |
| [Docs/DISTRIBUTING.md](Docs/DISTRIBUTING.md) | 英文交付指南（含 Gatekeeper 实测数据） |
| [Docs/MODELS.md](Docs/MODELS.md) | 制品、档位、单档机器、自建制品 |
| [Docs/LAYOUT.md](Docs/LAYOUT.md) | 安装位置的选择依据 |
| [Docs/CLIENTS.md](Docs/CLIENTS.md) | 各客户端接线细节 |
| [Docs/TROUBLESHOOTING.md](Docs/TROUBLESHOOTING.md) | 排障手册 |
| [CHANGELOG.md](CHANGELOG.md) | 版本变更 |

## 许可与致谢

本仓库是 [sensenova-u1-swift](https://github.com/xocialize/sensenova-u1-swift)
（MIT）的 fork，新增了常驻服务、MCP 前端与安装器。模型权重是 SenseTime 的
`SenseNova-U1.5-8B-MoT`（Apache-2.0），**不随本仓库分发**，由安装器按需从
ModelScope 或 Hugging Face 下载。完整清单与署名要求见 [NOTICE](NOTICE) 与
[LICENSE](LICENSE)。
