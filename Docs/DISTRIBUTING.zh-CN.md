# 把这个服务交给别人（中文）

> [English](DISTRIBUTING.md) · 面向"要把这套东西装到别人机器上"的人。
> 接收方只需要看 [README.md](../README.md)（中文版为准，英文镜像 `README.en.md`）。

"不写代码的人也能装上、用上"是项目的硬要求，所以下面这些不是可选项。

## 交付什么

```bash
make release          # dist/imagehive-<版本>-macos-arm64.tar.gz（含 .sha256）
make release-verify   # 把这份归档装进一个私有 HOME 并逐项检查
```

归档是**自包含**的：`install.sh` 会 `source cli/lib/*.sh`，所以只装 `prebuilt/`
的归档什么都装不上（旧版本就是这个毛病）。

```
imagehive-<版本>-macos-arm64/
├── install.sh  uninstall.sh        安装/卸载（会 source cli/）
├── prebuilt/                       imagehived、imagehive-mcp + MLX *.bundle
├── cli/  Docs/                     管理命令与文档（含中文文档）
├── README.md  README.en.md         两份面向使用者的 README
├── AGENTS.md  LOCAL-SERVICE.md  UPSTREAM-README.md
├── CHANGELOG.md  LICENSE  NOTICE
├── BUILD-INFO.txt                  版本、git revision、构建主机
└── SHA256SUMS                      上面每个文件的校验和
dist/<名字>.tar.gz.sha256           归档自身的校验和
```

版本号取自 `cli/lib/common.sh` 的 `IH_VERSION`，上游 git tag 只记在
`BUILD-INFO.txt` 里，避免把本仓库的构建误认成上游发布。

**权重绝不打包**：`NOTICE` 要求从发布方下载，而且 11–33 GiB 的 Apache-2.0
权重不该躺在发行包里。

## 对方要做的事

```bash
base=https://github.com/hrygo/ImageHive/releases/latest/download
curl -fsSLO "$base/imagehive-macos-arm64.tar.gz"
curl -fsSLO "$base/imagehive-macos-arm64.tar.gz.sha256"
shasum -a 256 -c imagehive-macos-arm64.tar.gz.sha256
tar -xzf imagehive-macos-arm64.tar.gz && cd imagehive-*
bash install.sh
```

然后重启 agent，直接让它画一张图。不用装 Xcode、不用编译、不用 `sudo`。

每次发行会把同一份归档挂两遍：带版本号的名字（`imagehive-<版本>-macos-arm64.tar.gz`，
便于锁定版本）和上面这个稳定名字（便于把那条命令长期写进文档不再改）。两者各有
对应的 `.sha256`。

改名（0.6）之后**必须发一次新 Release**：资产名从 `sensenova-u1-macos-arm64.tar.gz`
变成 `imagehive-macos-arm64.tar.gz`，而 `releases/latest/download/<资产名>` 只解析最新
那个 Release——旧 Release 不提供新名字，文档里那条一行命令在改名当天就会 404。

### 为什么是 `bash install.sh`，不是 `./install.sh`

凡是从网络下来的文件都带 `com.apple.quarantine`（隔离属性），Gatekeeper 会拒绝
**执行**它们。macOS 26 上实测：

* 带隔离的 **Mach-O 可执行文件**会挂住——进程停在 `syspolicyd` 等一个确认框，
  而终端里的安装过程永远看不到那个框（实测 30 秒不返回，只能手动 kill）；
* 带隔离的 **shell 脚本**交给 `bash` 读取则完全正常（`bash install.sh` 在刚下载
  的副本上直接可跑）；
* BSD `install` 与 `cp` 会把隔离标记**复制到目标文件**（实测 `xattr -l` 可见），
  所以二进制会带着标记落进 `~/.local/share/imagehive/bin/`，之后每次 MCP
  客户端启动都会挂。

所以安装器新增了 `dequarantine()`：只清理它自己安装的文件（二进制、bundle、CLI
目录），不碰用户其它文件；README 则告诉用户用 `bash` 启动。这套组合不需要开发者
证书，也不需要公证。如果你有 Developer ID，可以在 `make release` 之前给
`prebuilt/` 里的两个二进制签名，但清隔离标记这一步仍然保留。

## 离线 / 内网机器

1. 先在任何一台机器上跑一次安装器拿到制品（`imagehive models`），或者手动下载
   已发布的 `mlx-community/*` 制品；
2. 把**归档**和**制品目录**（形如 `<owner>-SenseNova-U1.5-8B-MoT-*`）一起拷过去；
3. 在目标机器上把制品放进
   `~/Library/Application Support/ImageHive/models/`，然后
   `bash install.sh --model none` —— 它会保留磁盘上已有的东西。

## 怎么发一个版本

版本号来自 `cli/lib/common.sh` 的 `IH_VERSION`，先改它，然后：

```bash
make release-verify        # 生成 dist/，并把归档装进一个一次性 HOME 里验证
V=0.6.0
git tag -a "v$V" -m "…" && git push origin "v$V"
gh release create "v$V" --repo hrygo/ImageHive --title "…" --notes-file - \
  "dist/imagehive-$V-macos-arm64.tar.gz" \
  "dist/imagehive-$V-macos-arm64.tar.gz.sha256" \
  dist/imagehive-macos-arm64.tar.gz \
  dist/imagehive-macos-arm64.tar.gz.sha256
```

四个容易踩的点（都是实际踩过的）：

* **先打 tag 再出包**：`BUILD-INFO.txt` 记的是 `git describe`，先出包再打 tag 会让归档里
  写成 `revision v0.5.0-18-gc8679f9` 而不是 `v0.5.2` —— 用户正是拿这个号和
  `project_version` 对账。
* **稳定名的那份也要传**：README 让人 `curl` 的是
  `releases/latest/download/imagehive-macos-arm64.tar.gz`，只有某个 release 恰好带了
  这个文件名的资产，这条链接才成立。
* **必须带 `--repo hrygo/ImageHive`**：本地还配着 `upstream`（上游移植的来源仓库），
  `gh` 默认会认成上游仓库——轻则报"tag 没推到 xocialize/sensenova-u1-swift"，重则把
  release 发到错误的地方。
* **按用户的方式验一遍**：匿名下载稳定名那份，和 `.sha256` 资产比对，不要只看上传成功：

```bash
base=https://github.com/hrygo/ImageHive/releases/latest/download
curl -fsSLO "$base/imagehive-macos-arm64.tar.gz{,.sha256}"
shasum -a 256 -c imagehive-macos-arm64.tar.gz.sha256
```

## 交付前清单

- [ ] `make release-verify` 通过（它会校验 sha256、给解压出来的整棵树打上隔离属性、
      用 `--skip-build` 装进一次性 HOME，并在**没有 Xcode、没有 Swift** 的前提下断言
      二进制/bundle/命令就位且不带隔离属性、沙箱服务能应答、`doctor` 如实报告状态）；
- [ ] `shasum -a 256 -c <归档>.sha256` 在你要发出去的那份上通过；
- [ ] 归档名里的版本与 `cli/lib/common.sh` 一致，且 `CHANGELOG.md` 有对应条目；
- [ ] 归档里没有权重、没有 `dist/`、没有 `.build/`；
- [ ] 中文文档随归档一起发（`README.md`、`README.en.md`、`Docs/DISTRIBUTING.zh-CN.md`）。

## 还没做的

* 没有 Apple Developer ID 签名与公证（当前不需要：清隔离标记已解决实际问题）。
* 没有 Homebrew formula / cask。
* 安装器自身的输出目前是英文（文档是中文）。
* **没有国内直连的镜像**：`releases/latest/download` 走 GitHub，部分网络需要代理；
  这时把归档当文件发过去即可，安装方式完全一样。
