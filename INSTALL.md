# MinisCanvas 安装、卸载与常见问题

## 系统要求

- macOS 14.0 或更新版本。
- 安装包为通用二进制，同时含 Apple 芯片（arm64）和 Intel（x86_64）两种架构，都不需要 Rosetta。Intel 机器上的实际运行尚未经过实机验证。

## 下载与校验

1. 从 Releases 页面（`https://github.com/zhangyongjiewzj-bit/MinisCanvas`）下载 `MinisCanvas-<版本>-macos-universal.zip` 和同名的 `.sha256` 文件，放在同一目录。
2. 校验（以 0.1.0 为例），应输出 OK：

   ```bash
   shasum -a 256 -c MinisCanvas-0.1.0-macos-universal.zip.sha256
   ```

   校验不通过请不要继续安装。
3. 双击 zip 解压，把 `MinisCanvas.app` 拖入“应用程序”。

## 首次打开（放行）

安装包使用 ad-hoc 签名，没有 Developer ID，也未经 Apple 公证，所以第一次打开会被 macOS 拦截。以下步骤依据系统通常行为编写，未在每个系统版本上逐一实测；如与你看到的界面不同，请以系统提示为准。

- **macOS 14**：在“应用程序”里右键（或按住 Control 点按）`MinisCanvas.app` → 打开 → 在弹窗里再点“打开”。
- **macOS 15 及更新（含 26）**：先双击打开一次（会被拦截），然后进入 系统设置 › 隐私与安全性，滚到“安全性”，点“仍要打开”，按提示确认（可能需要登录密码）。这些系统上右键打开通常不再能绕过拦截。
- **终端方式（任意版本）**：

  ```bash
  xattr -dr com.apple.quarantine /Applications/MinisCanvas.app
  ```

放行等于告诉系统“我信任这个应用”，请只放行来源可靠、校验和一致的安装包。该命令只移除这个应用的隔离标记，不会关闭系统的其他保护。自己从源码编译的应用没有隔离标记，通常不需要放行。

## 首次配置模型

应用本身不带模型，需要你自备模型服务商的账号和 API Key。概述：

1. 打开设置（⌘,）→ “环境变量”页 → “新增供应商”。
2. 填写显示名、凭据名、API Key、Base URL（可选）、协议类型，也可用页面上的预设。保存后应用会自动检查是否就绪。
3. 在设置 → 常规 → “默认模型”选好服务商和模型。

Key 请自己输入，不要贴进聊天框。详细步骤见 [使用手册](./docs/USER_GUIDE.md)。

## 数据存放位置

数据都在本机，应用数据位于用户资源库下的 `~/Library/Application Support/`：

| 位置 | 内容 |
|---|---|
| `~/Library/Application Support/MinisCanvas/` | 会话数据、日志、后台命令记录等 |
| `~/Library/Application Support/MinisCore/` | 设置、环境变量/供应商元数据、MCP 配置、技能等 |
| macOS 钥匙串，服务名 `com.miniscanvas.miniscore.envvars` | API Key 等凭据 |
| `~/.minis-worktrees/` | 子任务使用的独立 git worktree（仅用过该功能时出现） |

实际出现的目录取决于用过的功能；系统还可能保留偏好设置、缓存和窗口状态。

## 卸载

1. 退出 MinisCanvas。
2. 把 `/Applications/MinisCanvas.app` 拖到废纸篓。
3. 如需清除数据（会删除全部会话、记忆、技能、设置，不可恢复；建议先在应用内“设置 → 存储”导出备份），删除上表中的两个 Application Support 目录。
4. 如需清除凭据：打开“钥匙串访问”，搜索 `com.miniscanvas.miniscore.envvars` 并删除相应条目。
5. 如用过子任务的 worktree：检查 `~/.minis-worktrees/`，删除前确认其中没有未提交的工作。

## 常见问题

**提示“已损坏，无法打开”或“无法验证开发者”**
先核对 SHA-256。校验通过且来源可靠，再按上面的步骤放行。

**macOS 15 及更新上右键没有可用的“打开”**
改用 系统设置 › 隐私与安全性 › “仍要打开”，或使用 `xattr` 命令。

**需要 Rosetta 吗？**
不需要，Apple 芯片和 Intel 都有原生切片。

**应用要访问钥匙串、文件夹、麦克风，正常吗？**
API Key 存放在钥匙串；文件访问受你授权的目录和审批控制；麦克风和语音识别仅在使用语音输入时请求。

**为什么需要联网？**
应用不自带模型，对话内容会发送给你配置的模型供应商；网页抓取和浏览器会访问你要求的站点。

## 免责声明

未经 Apple 公证，按 GPL-3.0-only 提供，不附带担保。见 [LICENSE](./LICENSE) 与 [NOTICE](./NOTICE)。
