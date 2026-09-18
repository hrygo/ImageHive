# imagehive

**本机常驻的 AI 图像服务：一份权重，所有 agent 共用。** 跑在 Apple 芯片上，
模型是 [SenseNova-U1.5-8B-MoT](https://huggingface.co/sensenova/SenseNova-U1.5-8B-MoT)，经上游的
Swift/MLX 移植运行。

[![ci](https://github.com/hrygo/ImageHive/actions/workflows/ci.yml/badge.svg)](https://github.com/hrygo/ImageHive/actions/workflows/ci.yml)
[![latest release](https://img.shields.io/github/v/release/hrygo/ImageHive)](https://github.com/hrygo/ImageHive/releases/latest)
[![license: MIT](https://img.shields.io/github/license/hrygo/ImageHive)](LICENSE)
[![platform: macOS 26+ · Apple silicon](https://img.shields.io/badge/platform-macOS%2026%2B%20%C2%B7%20arm64-black)](#前置条件)

在自己的 Mac 上跑文生图、按指令改图和看图问答，通过 MCP 交给 AI agent 使用。
不需要 API key、不按张计费、图片不出本机；同一台机器上所有 agent 共用**一份**常驻权重。

> **中文版为准** · 英文镜像：[README.en.md](README.en.md)（结构与本文一一对应）·
> 交付指南：[Docs/DISTRIBUTING.zh-CN.md](Docs/DISTRIBUTING.zh-CN.md)
>
> **名字**：叫 `imagehive`，不叫 `sensenova-u1`。模型名属于 SenseTime，放在这里会读起来像
> 官方出品，也把仓库绑在一次模型换代上；名字只描述这套东西本身——一个常驻的本地图像服务。
> 0.5.2 及更早叫 `sensenova-u1`，升级会由安装器自动迁移，见[从旧版本升级](#从旧版本升级)。
>
> **版本号**：本仓库自己编号（`cli/lib/common.sh` 里的 `IH_VERSION`），并接续上游的
> tag 序列，因此首个公开版是 **0.5.0**，当前版本 **0.6.0**。发行包里的 `BUILD-INFO.txt`
> 记录所基于的上游提交；两套编号互不相干。

## 一句话说明

* **每台机器只有一份常驻权重。** unix socket 绑定即进程互斥，加载是 single-flight，
  内存里最多只有一个档位——十个客户端也只是十个小进程，不会多出第二份 11–33 GB。
* **六个 MCP 工具**：生成、改图、看图、先问"能接受什么"、看状态、释放内存，见
  [agent 会看到的工具](#agent-会看到的工具)。
* **出图可复现、自带说明。** `--seed` 固定噪声，每张图旁边落一个 sidecar，记录提示词
  与其 SHA-256、seed 以及它是否被固定、实际运行的制品、尺寸、步数、cfg、耗时与峰值
  内存。同一个 seed + 同一个制品 + 同一组参数，写出的 PNG 逐字节相同（实测）。
* **只装一个档位完全够用。** 请求了没装的那一档是"偏好"而不是错误：服务用已装制品
  完成，并按该制品自己的配方运行，回复里如实说明。
* **不用 root，不开端口。** 全部装在用户目录下，走 app home 里的 unix socket；
  权重由安装器从发布方下载，本仓库不分发。

## 目录

* [快速开始](#快速开始)
* [前置条件](#前置条件)
* [档位怎么选](#档位怎么选)
* [装在哪里](#装在哪里)
* [从旧版本升级](#从旧版本升级)
* [让 agent 用上](#让-agent-用上)
* [agent 会看到的工具](#agent-会看到的工具)
* [日常命令](#日常命令)
* [可复现的评测](#可复现的评测)
* [配置](#配置)
* [排障与求助](#排障与求助)
* [已知限制](#已知限制)
* [卸载](#卸载)
* [贡献](#贡献)
* [文档索引](#文档索引)
* [许可与致谢](#许可与致谢)

## 快速开始

两条路，第一条不需要 Xcode、不需要编译，推荐给不写代码的人。

**用发行包**

```bash
base=https://github.com/hrygo/ImageHive/releases/latest/download
curl -fsSLO "$base/imagehive-macos-arm64.tar.gz"
curl -fsSLO "$base/imagehive-macos-arm64.tar.gz.sha256"
shasum -a 256 -c imagehive-macos-arm64.tar.gz.sha256   # 校验下载是否完整
tar -xzf imagehive-macos-arm64.tar.gz && cd imagehive-*
bash install.sh          # 用 bash，不要 ./install.sh —— 原因见 Docs/DISTRIBUTING.zh-CN.md
```

**从源码**（要改代码时；需要 Xcode 27 与 Metal 工具链，见[前置条件](#前置条件)）

```bash
git clone https://github.com/hrygo/ImageHive.git
cd ImageHive
./install.sh
```

两种方式装的东西完全一样。安装器会：检查机器 → 下载可直接运行的模型（默认约
11 GiB，优先走 ModelScope 直连，国内无需代理）→ 安装后台服务 → 接线它找到的 MCP
客户端 → 跑一个冒烟测试。装完**重启你的 agent**（Codex、Claude、opencode、
QwenPaw……），然后直接说一句"给我画一张夕阳下的海边灯塔"。

> **为什么必须写 `bash install.sh`**：从浏览器、AirDrop、网盘下来的文件都带
> `com.apple.quarantine`，Gatekeeper 会拒绝**执行**隔离的二进制——进程会挂在系统
> 确认框上，而终端里的安装过程看不到那个框，表现就是"卡住不动"。交给 `bash` 读取的
> 脚本不受这个限制，安装器随后会清掉它自己所安装文件的隔离标记。不需要开发者签名，
> 也不需要公证；实测数据见 [Docs/DISTRIBUTING.zh-CN.md](Docs/DISTRIBUTING.zh-CN.md)。

## 前置条件

| | |
|---|---|
| 硬件 | Apple 芯片（M1 及以上）。MLX 不支持 Intel Mac |
| 内存 | 4bit 档最少 18 GB（峰值约 15 GB）；bf16 档建议 48 GB 以上 |
| 系统 | macOS 26 或更新 |
| 磁盘 | 单档约 16 GiB，两档约 48 GiB，另加一次性约 2 GB 构建目录 |
| python3 | **必需**。`xcode-select --install`（随命令行工具，约 1.5 GB）或 `brew install python`。缺了安装器会立刻停下并告诉你 |
| 工具链 | 只有"从源码安装"需要：Xcode 27（完整 App，不是只有命令行工具）+ `xcodebuild -downloadComponent MetalToolchain`。发行包完全不需要 |
| 时间 | 首次 10–40 分钟，主要是下载模型和首次编译 |

已经有模型的人：`./install.sh --model none --skip-build` 两步都跳过。下载有进度显示、
随时可中断、重跑只补缺的文件。

## 档位怎么选

制品是上游发布的、可直接运行的 MLX 转换版本，自带 tokenizer，无需转换步骤。

| 预设 | 磁盘 | 峰值内存 | 1024² 出图 | 适合 |
|---|---|---|---|---|
| `fast-4bit`（安装默认） | 11 GiB | 约 15 GB | 约 3 秒 | 草稿、快速迭代、缩略图 |
| `fast-8bit` | 20 GiB | 约 22 GB | 约 4 秒 | 同上，更接近 bf16 观感 |
| `quality-bf16` | 33 GiB | 约 35 GB | 约 50 秒（50 步） | 成品、图上文字、改图、看图问答 |

```bash
./install.sh --model fast               # 安装默认：轻量档
./install.sh --model both               # 两档都装
imagehive models pull quality-bf16   # 以后再加一档
imagehive models                     # 看这台机器装了什么
```

改图和看图问答固定走质量档，`generate_image` 是唯一分档的工具。

### 只装一个档位完全够用

`tier` 是偏好而不是硬要求。请求里写了没装的那一档时，守护进程会用已装的那一档来
服务，并在回复里说清楚——

```
Wrote ~/Pictures/ImageHive/20260918T065356Z-t2i-seed610959.png
      [512x512, tier quality, asked for fast, not installed, 50 steps, 14.9s, seed 610959]
```

生成配方（步数、cfg）跟着**实际运行的制品**走：8 步 / cfg 1.0 属于蒸馏权重，50 步 /
cfg 4.0 属于 bf16 权重，所以不会出现"拿 8 步蒸馏权重按 50 步跑"这种越界组合。
`model_status` 会报 `available_tiers`，`imagehive doctor` 把缺档位当提示而不是失败
——单档机器是受支持的用法。

## 装在哪里

全部在用户目录下，不需要 `sudo`，也不写进 Homebrew 前缀。`imagehive paths`
会一次性打印全部路径。

| 内容 | 位置 |
|---|---|
| 命令 | `~/.local/bin/imagehive` |
| 可执行文件、MLX bundle、CLI 内部脚本 | `~/.local/share/imagehive/` |
| 权重（约 11–33 GB） | `~/Library/Application Support/ImageHive/models/` |
| 配置、socket、服务定义 | `~/Library/Application Support/ImageHive/` |
| 日志 | `~/Library/Logs/ImageHive/imagehived.log` |
| 出图 | `~/Pictures/ImageHive/` |

`--home`、`--models`、`--out`、`--prefix`、`--label`（或对应的 `IMAGEHIVE_*` 变量）
都能改位置。选择依据与每条规则见 [Docs/LAYOUT.md](Docs/LAYOUT.md)。

## 从旧版本升级

0.5.2 及更早，这套东西叫 `sensenova-u1`，路径、命令、环境变量都带着那个名字。重跑
`./install.sh` 就行，它会按顺序处理四件事：

1. **先收掉旧的守护进程**，再搬目录。顺序不能反：旧进程握着第二份权重，而搬动 app home
   会把它的 socket 文件一起搬到新路径，新守护进程探测到"有人应答"就退出 3——看起来升级
   成功，答复却全部来自旧进程。
2. 搬 `~/Library/Application Support/SenseNovaU1`、`~/Pictures/SenseNovaU1` 与日志目录到
   新名字下（同卷 `mv`，11–66 GB 的制品不会重下一遍），并卸载旧 LaunchAgent、删掉它的 plist。
   旧 job 是按**内容**找的（plist 里写着它启动哪个二进制），因为标签可以用 `--label` 自定义；
   标签里带品牌词的话会被**改名而不是替换**——`com.hrygo.sensenova-u1` 变成
   `com.hrygo.imagehive`，自己的前缀留着。命令行上显式给的 `--label` 优先。
3. 让旧名字继续能用但**不能再拉起第二个服务**：旧二进制路径变成转发到新二进制的壳（老
   MCP 条目还指着它们），`sensenova-u1` 命令名变成转发到 `imagehive` 的壳；旧命令本体和它
   的 `lib/` 被删除，因为它们的默认路径是 0.6 之前的 home。
4. 清掉客户端里名为 `sensenova` 的旧 MCP 条目——两个条目暴露同一组工具，客户端里每个工具
   会出现两次。

用 `--home`/`--out` 自定义过位置的不动：旧默认位置下没东西可找，替你移动一个自己选的目录
比告诉你它在哪儿更糟。`imagehive doctor` 会持续报告遗留：旧 app home、还在跑的旧守护进程、
还留着旧条目的客户端。确认干净之后再删旧目录：

```bash
rm -rf "$HOME/Library/Application Support/SenseNovaU1" ~/Pictures/SenseNovaU1
```

环境变量也改名了：`SENSENOVA_HOME`/`_SOCKET`/`_MODELS`/`_OUT`/`_PREFIX`/`_LABEL` 对应
`IMAGEHIVE_*`。写在 shell profile 里的旧变量不会报错，只会被忽略——那正是"静默回落到默认
布局"的场景，也就可能多起一个守护进程，所以升级后请一并改掉。

## 让 agent 用上

`install.sh` 会自动接线它认出的客户端。也可以手动：

```bash
imagehive clients list          # 哪些装了、哪些已接线
imagehive clients add codex     # 或 claude / opencode / qwenpaw / claude-desktop / cursor
imagehive clients add auto      # 所有检测到的
imagehive clients snippet       # 给其它客户端粘贴的通用片段
```

自带 `mcp add` 命令的客户端（`codex`、`claude`）走它的命令配置，其余客户端是往配置
文件里写一段带标记的块，写前先做时间戳备份，`clients remove` 再摘掉。MCP 条目只在
客户端启动时加载，**改完必须重启客户端**。各客户端细节见
[Docs/CLIENTS.md](Docs/CLIENTS.md)。

## agent 会看到的工具

| 工具 | 作用 |
|---|---|
| `generate_image` | 文生图；`tier=fast` 用于迭代，`tier=quality` 用于成品或图上文字。可给 `seed`（可复现）、`negative` 负向提示词，也可覆盖 `steps`/`cfg` |
| `edit_image` | 按指令改图，可带一张或多张参考图，保持主体一致 |
| `describe_image` | 看图、读图上的字、按验收要求核对结果、比较候选图 |
| `model_options` | **问之前先知道**：支持的尺寸、步数与 cfg 的取值范围和默认值、seed 规则、`negative` 只对生成有效、元数据落在哪、本机装了哪些档——不加载权重即可返回 |
| `model_status` | 当前驻留的权重、开机以来加载次数、队列深度、峰值内存，以及正在跑的任务进度；**生成期间也立刻返回** |
| `unload_model` | 立刻释放 15–35 GB，不等空闲超时 |

写提示词前值得知道的一点：负向提示词在这套结构里**就是** CFG 的无条件分支，所以只有
`cfg > 1` 时才起作用。质量档配方跑 cfg 4.0，会生效；轻量档配方跑 cfg 1.0，根本没有
无条件分支。`edit_image` 收到非空 negative 会直接报错，而不是默默丢弃。

## 日常命令

```bash
imagehive status     # 当前驻留档位、加载次数、排队、峰值内存
imagehive doctor     # 逐项体检，有问题时退出码非 0
imagehive logs -f    # 跟随守护进程日志
imagehive unload     # 立刻释放内存
imagehive generate --prompt "一盏黄铜台灯，深色木桌，柔和侧光" --tier fast
imagehive options    # 这份服务接受什么：尺寸、步数、cfg、seed
imagehive restart    # 重启守护进程（权重仍在磁盘上）
imagehive paths      # 打印所有路径
```

守护进程**按需启动**：空闲一段时间后的第一次调用会加载权重（约 5 秒），之后所有调用
复用它；空闲 10 分钟（`ttl_seconds`，在
`~/Library/Application Support/ImageHive/config.json`）自动卸载，不会一直占着
30 多 GB。

## 可复现的评测

`--seed` 固定噪声；每张图旁边都会落一个 sidecar 记录"这张图是怎么来的"。这两件事
加起来，"我用的应该是同一串提示词"才变成事后可核对的证据：

```bash
imagehive generate --prompt "一盏黄铜台灯" --seed 42 --width 1216 --height 832
# Wrote ~/Pictures/ImageHive/20260918T083207Z-t2i-seed42.png [1216x832, tier quality,
#       50 steps, 51.3s, seed 42] + 20260918T083207Z-t2i-seed42.png.json
imagehive generate --prompt "一盏黄铜台灯" --seed 42 --n 4 --out ~/eval/run1 --json
```

同一个 seed、同一个制品、同一组参数写出的 PNG **逐字节相同**（实测：512×512、6 步两次
运行 SHA-256 一致），`--seed 500 --n 4` 会依次走 seed 500–503，一张一个文件。sidecar
（`<图片名>.png.json`）里有提示词原文与其 SHA-256、负向提示词、seed 以及它是被固定
还是随机、尺寸、步数、cfg、实际运行的制品、耗时与峰值内存；
`write_sidecar: false` / `IMAGEHIVE_SIDECAR=0` 可以关掉。`--json` 把同样的内容以机器
可读的形式打出来（`--n > 1` 时是数组），`--out` 把图片和它的 sidecar 一起搬走，
`imagehive generate --help` 列全部参数。

批量跑之前需要知道的一件事：**已经派发的请求无法取消**。杀掉命令不会停止生成，图片
照样落盘（详见 [Docs/TROUBLESHOOTING.md](Docs/TROUBLESHOOTING.md)）。要做干净计数的
评测，请等每一条返回再发下一条。

### 一份权重，多个 agent

```
Codex ─┐
Claude ─┼─► imagehive-mcp（stdio，无状态，不加载权重）
Cursor ─┘        │
                 └─► unix socket ─► imagehived（持有权重，串行生成）
                                          └─► 一份常驻模型
```

MCP 前端是一层薄薄的无状态桥；守护进程持有模型并串行生成。多接一个客户端只是多一个
小进程，绝不会多一份权重——socket 绑定就是互斥锁，并发的冷启动共享同一次加载。项目
自己的冒烟测试断言的正是这一点（三个并发客户端、只加载一次），见
[如何验证一处改动](AGENTS.md#如何验证一处改动)。

## 配置

两个文件，都可选，都是纯 JSON / shell：

* `~/Library/Application Support/ImageHive/config.json` —— `ttl_seconds`、
  `min_warm_seconds`、`fast_artifact`、`quality_artifact`（相对路径以权重根目录为基准，
  绝对路径原样使用）。
* `~/Library/Application Support/ImageHive/service.conf` —— 安装布局（home、models、
  prefix、launchd label、socket）。由 `install.sh` 写入；
  `imagehive config set IMAGEHIVE_LABEL=...` 可以改。

环境变量（`IMAGEHIVE_HOME`、`IMAGEHIVE_TTL_SECONDS`、`IMAGEHIVE_SOCKET`……）优先于
两者，客户端条目就是靠它指向你的安装位置。读不了或解析失败的 `config.json` 不会静默
回落：守护进程会记下哪个键不可用，`status` 里能看到（命令行是 `config_warning=` 行，
守护进程的 JSON 回复里是 `config_warnings`），`doctor` 会报
`config.json is not valid JSON`。

## 排障与求助

先跑 `imagehive doctor`——真的坏了它才返回非 0。常见情况：

* **`Failed to load the default metallib`** —— 二进制旁边的 MLX 资源包缺失，重跑
  `./install.sh`（它会把 `*.bundle` 拷到旁边）。
* **首次构建报与 Metal 相关的错** —— `xcodebuild -downloadComponent MetalToolchain`。
* **客户端里看不到图片工具** —— 重启客户端；MCP 条目只在启动时加载。
* **`./install.sh` 卡住不动** —— 隔离属性，见[快速开始](#快速开始)里的说明。
* **`python3 is required and was not found.`** —— 用 `xcode-select --install` 或
  `brew install python` 装好再重跑，安装器会从断点继续。
* **装完了但提示 `imagehive: command not found`** —— `~/.local/bin` 不在 macOS
  默认 PATH 里：用全路径 `~/.local/bin/imagehive doctor`，或把
  `export PATH="$HOME/.local/bin:$PATH"` 写进 `~/.zprofile`。
* **下载看起来卡住了** —— 每几秒会打印一行
  `3/12 files, 8.2 GiB of 33.0 GiB (24%), 4m10s elapsed`；真断了就 Ctrl-C 后重跑
  `imagehive models pull <预设>`，已完成的文件按大小校验后跳过。
* **第一次出图比后面慢 5–10 秒** —— 那是模型加载，不是卡住。想一直保持热就把
  `ttl_seconds` 调大。
* **回复里写 `asked for fast, not installed`** —— 正常：这台机器只装了另一档，服务用
  已装档位完成，并如实告诉你实际用的是哪一档。
* **内存吃紧** —— `imagehive unload` 立刻释放；想更自动就把 `ttl_seconds` 改小
  （例如 120）。实际开销看 `imagehive status` 的 `last_peak_mb`。
* **报错 `seed must be a number, got the string "126"`（`width` 同理）** —— 参数是强类型
  的：数字要传数字（`"width": 512`，不是 `"width": "512"`），只有"不传"才等于用默认值。
  0.5.2 之前这类参数会被静默替换成默认值——字符串 seed 会变成**随机** seed。
* **改了 `config.json` 却不生效** —— 环境变量优先于文件（`IMAGEHIVE_TTL_SECONDS` 会
  盖掉 `ttl_seconds`），先看守护进程的配置告警，再看启动它的客户端条目和 launchd job。

英文完整排障手册：[Docs/TROUBLESHOOTING.md](Docs/TROUBLESHOOTING.md)。还是没解决？
到 <https://github.com/hrygo/ImageHive/issues> 提 issue，附上
`imagehive doctor` 的输出和守护进程日志（`imagehive logs`）。

## 已知限制

与其让人事后发现，不如写在这里：

* **已派发的请求无法取消。** 它会在守护进程里跑完并落盘，客户端断开也一样；
  `model_options.cancellation.supported` 直接报 `false`，不做假装成功的取消。
* **不提供 HTTP 端点，这是设计。** 传输走 app home 里的 unix socket，socket 文件
  **就是**锁：没有端口要开放，也没有第二个可能加载第二份权重的入口。
* **同一时刻只有一个档位**（`cold | fast | quality`）。守护进程最多持有一个制品，
  因为同时持有两个正是这个项目要避免的内存开销。
* **请求是串行的**，也还没有 MCP tasks 扩展：一次工具调用会阻塞到图片写完。
* **只支持 Apple 芯片 + macOS 26 及以上。** MLX 不支持 Intel Mac。

## 卸载

```bash
./uninstall.sh                 # 服务、二进制、客户端条目；保留权重
./uninstall.sh --purge-models  # 连下载的模型一起删
```

## 贡献

有问题或想改动，欢迎到 <https://github.com/hrygo/ImageHive/issues> 提 issue
或 PR。

这份 README 是给**使用者**看的；**改**这个服务所需的一切——构建 / 测试 / 发版目标、
服务依赖的硬约束、怎么在不碰真实安装的前提下测安装器、哪种改动该更新哪份文档——都在
[AGENTS.md](AGENTS.md)，贡献者与 coding agent 共用。设计取舍见
[LOCAL-SERVICE.md](LOCAL-SERVICE.md)；打包交付与发版流程见
[Docs/DISTRIBUTING.zh-CN.md](Docs/DISTRIBUTING.zh-CN.md)。

本仓库由 [hrygo](https://github.com/hrygo) 维护；MLX 移植与已发布的制品由上游
Xocialize 维护。

## 文档索引

| 文档 | 内容 |
|---|---|
| [README.en.md](README.en.md) | 英文镜像（中文版为准） |
| [Docs/DISTRIBUTING.zh-CN.md](Docs/DISTRIBUTING.zh-CN.md) | 中文交付指南：怎么打包给别人、对方怎么做、离线安装、发版清单 |
| [Docs/DISTRIBUTING.md](Docs/DISTRIBUTING.md) | 英文交付指南（含 Gatekeeper 实测数据） |
| [Docs/LAYOUT.md](Docs/LAYOUT.md) | 安装位置的选择依据 |
| [Docs/MODELS.md](Docs/MODELS.md) | 制品、档位、图片尺寸、单档机器、自建制品 |
| [Docs/CLIENTS.md](Docs/CLIENTS.md) | 各客户端接线细节与工具参数 |
| [Docs/TROUBLESHOOTING.md](Docs/TROUBLESHOOTING.md) | 排障手册（含实测数据） |
| [AGENTS.md](AGENTS.md) | 改这个仓库的 agent 指导 |
| [LOCAL-SERVICE.md](LOCAL-SERVICE.md) | 设计理由与有意留下的取舍 |
| [UPSTREAM-README.md](UPSTREAM-README.md) | 上游 MLX 移植自己的 README：性能表、它的 CLI、量化立场 |
| [CHANGELOG.md](CHANGELOG.md) | 每个版本改了什么 |
| [NOTICE](NOTICE) | 上游移植、权重与 LoRA 的署名 |

## 许可与致谢

本仓库内含上游 [`sensenova-u1-swift`](https://github.com/xocialize/sensenova-u1-swift)
（MIT）的 Swift/MLX 移植源码，并在其上新增了常驻服务、MCP 前端与安装器；GitHub 上本
仓库与上游不构成 fork 关系。模型权重是 SenseTime 的 `SenseNova-U1.5-8B-MoT`
（Apache-2.0），**不随本仓库分发**，由安装器按需从 ModelScope 或 Hugging Face 下载。
完整清单与署名要求见 [NOTICE](NOTICE) 与 [LICENSE](LICENSE)。
