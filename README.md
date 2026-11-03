<p align="center">
  <img src="assets/cam-app-icon-trimmed.png" width="112" alt="Codex Account Manager 图标">
</p>

<h1 align="center">Codex Account Manager</h1>

<p align="center">在 macOS 上管理和切换 Codex 账号与 API Key。</p>

<p align="center">
  <img alt="Version" src="https://img.shields.io/badge/version-v0.5.0-3375d2">
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2013%2B-11151d">
  <img alt="SwiftUI" src="https://img.shields.io/badge/UI-SwiftUI-3375d2">
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-3375d2"></a>
</p>

Codex Account Manager（CAM）是一个本地 macOS 应用，用于管理 ChatGPT 账号和 OpenAI API Key，并查看 Codex 返回的账号额度。应用提供菜单栏入口和独立主面板。

> 当前版本要求 Codex 使用文件凭据存储，并仅管理官方账号和官方 API Key。

## 核心能力

### 账号与 API Key

- 通过浏览器或设备代码登录 ChatGPT 账号；新账号登录在独立的临时 Codex 目录中完成。
- 添加 OpenAI API Key，在已保存的账号与 API Key 之间切换。
- 当前登录直接显示为“使用中”；切换前自动备份当前文件凭据。
- 优先显示账号提供的名称，没有名称时显示邮箱，也可以设置本地别名。
- 对已保存的账号重新登录时，核对账号与工作区身份。

### 会员与额度

- 将 Codex 返回的会员类型归类显示为 `Free`、`Plus`、`Pro`、`Team` 或 `Unknown`；实际订阅名称以 ChatGPT 设置为准。
- 显示服务端返回的额度周期、剩余比例、重置时间和积分等信息。
- 手动刷新当前登录的额度；其他账号显示上次获取的结果。
- API Key 的计费与 ChatGPT 额度分开，本应用不显示 API Key 余额。

### 使用体验

- 菜单栏和主面板均可切换配置；主窗口打开时显示程序坞图标。
- 支持浅色、深色与跟随系统外观，以及开机自启和静默启动。
- 提供账号搜索、面板快捷键和本地诊断日志。
- 可配置 Codex 目录、应用数据目录和会话历史分组。
- 在“关于”页面手动检查 GitHub 上的最新正式版本，并打开发布页面下载。

## 工作方式

```text
Codex Account Manager
  ├─ 登录新账号：临时 Codex 目录 → 官方登录 → CAM 本地凭据
  ├─ 备份当前登录：Codex Home/auth.json → CAM 本地凭据
  └─ 切换登录：所选凭据 → Codex Home/auth.json
```

Codex 使用期间可能刷新令牌，CAM 会在切换前重新保存当前文件凭据。账号登录和 API Key 登录在同一时刻使用其中一种；添加配置后不会自动切换。

若切换失败，CAM 只在能够确认当前文件仍是本次写入的内容且原凭据存在时尝试恢复。切换前请结束其他 Codex CLI 会话，切换期间不要重新启动 Codex。

## 安装

### 环境要求

- macOS 13 或更高版本。
- 已安装 Codex CLI。
- 从源码构建需要 Xcode；运行应用不需要 Python。

### 从源码构建

```bash
git clone https://github.com/StarRain/Codex-Account-Manager.git
cd Codex-Account-Manager
sh scripts/build.sh
open "dist/Codex Account Manager.app"
```

也可以在 Xcode 中打开 `CodexAccountManager.xcodeproj`，选择 `CodexAccountManager` 方案构建运行。

脚本生成的应用使用本地临时签名，未经过 Apple 开发者签名或公证。如果旧版 CAM 正在运行，请先从菜单栏退出，再打开新版。

## 使用

1. 打开主面板，查看当前使用中的账号或 API Key。
2. 选择“登录新账号”或“添加 API Key”，按提示完成添加。API Key 保存时不会验证有效性。
3. 在主面板或菜单栏中选择已保存的配置，切换前 CAM 会备份当前登录。
4. 如果 Codex 桌面版正在运行，可以选择立即重启或等它退出后再切换。
5. 点击“刷新额度”可重新查询当前 ChatGPT 登录；凭据失效时可对已保存的账号选择“重新登录”。

浏览器已经登录其他账号时，可以关闭自动打开浏览器，复制登录链接到其他浏览器或无痕窗口。设备代码登录需要在 ChatGPT 安全设置或工作区权限中启用。

### 面板快捷键

| 快捷键 | 操作 |
| --- | --- |
| `⌘1` / `⌘2` / `⌘3` | 打开全部、官方账号或官方 API Key 页面 |
| `⌘,` / `⌘[` | 打开设置 / 返回账号页面 |
| `⌘F` | 聚焦账号搜索框 |
| `⌘N` | 登录新账号；在 API Key 页面添加 API Key |
| `⌘R` | 刷新当前状态 |
| `⌘A` / `⌘C` / `⌘V` / `⌘X` | 全选 / 复制 / 粘贴 / 剪切 |
| `Return` / `Esc` | 在配置弹窗中保存 / 取消 |

搜索、新建和刷新快捷键仅在 CAM 面板的相应页面中生效。

### 统一 Codex 会话历史

账号和 API Key 使用同一个 Codex Home。开启“统一 Codex 会话历史”后，CAM 会在符合条件时保留当前的官方共享服务商分组，不修改现有会话文件。

该设置不会迁移其他服务商分组中的旧会话，也不会合并不同账号的云端会话。

## 数据与安全

- 应用数据默认存放在 `~/.cam`：账号信息位于 `profiles.json`，凭据位于 `credentials/`，诊断日志位于 `diagnostics.log`。
- 凭据文件未加密；凭据目录权限为 `0700`，文件权限为 `0600`。请勿提交或分享这些文件。
- Codex 的文件凭据默认位于 `~/.codex/auth.json`。CAM 启动时读取自身环境中的 `CODEX_HOME`，也可在设置中手动指定目录。
- 从 Finder 启动的应用不一定能继承仅在终端中设置的环境变量；桌面版和 CLI 需要使用相同的 Codex Home 才能共享登录。
- 账号授权使用临时目录，完成或取消后会清理；异常退出时系统临时目录中可能残留文件。
- `keyring`、`auto`、`ephemeral` 凭据模式，以及无法安全识别的环境变量、组织限制或 OpenAI 地址，会阻止 CAM 切换。详情见 [OpenAI 登录与凭据存储说明](https://developers.openai.com/codex/auth)。
- 本应用依赖 Codex 当前的凭据文件格式，并非 OpenAI 提供的多账号切换接口；真实账号和桌面版的完整切换与重启流程仍需在目标环境验证。

## 开发与验证

运行测试：

```bash
xcodebuild -project CodexAccountManager.xcodeproj -scheme CodexAccountManager -destination 'platform=macOS' test
```

使用模拟数据预览，不读取或修改真实登录：

```bash
open -n "dist/Codex Account Manager.app" --args --demo
open -n "dist/Codex Account Manager.app" --args --demo --dark
```

测试使用临时 Codex Home、模拟凭据和本机模拟服务。测试夹具及图标生成脚本需要 Python 3；图标源文件位于 [`assets/cam-app-icon-trimmed.png`](assets/cam-app-icon-trimmed.png)。

## 相关项目

- [Codex](https://github.com/openai/codex)：OpenAI 的 Codex 工具。

## 参与贡献

欢迎通过 [Issue](https://github.com/StarRain/Codex-Account-Manager/issues) 反馈问题或提交 Pull Request。涉及账号切换、凭据存储或登录流程的变更，请附上验证方式。

## 开源协议

本项目基于 [MIT License](LICENSE) 开源。

## 说明

CAM 是社区项目，与 OpenAI 无官方隶属或背书关系。
