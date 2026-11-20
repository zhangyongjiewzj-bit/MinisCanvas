# MinisCanvas

[中文](#中文) | [English](#english)

---

## 中文

MinisCanvas 是一个 macOS 原生的智能体（Agent）客户端：在本机用对话驱动模型读写文件、运行命令、浏览网页，并在有风险的动作前让你审批。交互思路参考 Claude Code（例如逐次工具审批、会话内排队、项目指令文件），但它是独立实现的另一个项目，与 Anthropic、OpenAI 等公司没有从属或背书关系。

> 状态：早期版本（0.1.x），可能有缺陷。请先阅读文末免责声明。

### 主要功能

- **多家模型供应商**：内置的供应商类型包括 OpenAI、Anthropic、Google Gemini、OpenRouter、DeepSeek、Responses API（/v1/responses）、本地模型（Ollama/ComfyUI）；也有阿里云百炼、Gimage2、可灵、即梦等偏媒体生成的类型。
- **文件与命令工具**：模型可以通过工具读文件（含 PDF 文本、按页读取）、写文件、精确替换编辑文件、删除文件、在 macOS zsh 中执行命令。
- **后台命令**：命令可放到当前会话的后台运行，之后读取输出或停止。
- **逐次审批与持久规则**：可为 shell、写文件、编辑、网页抓取等能力保存持久审批规则，并在设置里查看和撤销。
- **文件改动前备份与恢复**：写入前保留原文件作为检查点，可恢复。
- **网页抓取与内置浏览器**：抓取网页并提取为纯文本；浏览器的写操作类动作有独立开关并逐项审批。
- **MCP**：配置 MCP 服务器、发现工具并逐项授权。
- **Hooks**：支持 PreToolUse、PostToolUse、UserPromptSubmit、SessionStart、Stop 五类事件。
- **技能（Skills）与记忆**：技能存放在本地目录，导入后需你审核批准才启用；长期记忆可管理并注入对话上下文。
- **项目指令文件**：识别项目目录下的 AGENTS.md、CLAUDE.md、.claude/CLAUDE.md，需经你信任后使用。
- **子任务与任务中心**：把工作交给并发的子任务，并在任务中心查看。
- **定时任务**：基于 cron 表达式的计划任务，设置页中可授权与撤销。
- **上下文压缩**：对话接近上限时压缩历史并保留你的原话。
- **Git 工作流**：通过 git/gh 的编排；子任务可使用独立 git worktree。
- **会话管理**：新建、重命名、分组、置顶、归档、搜索、草稿保留、输入历史搜索。
- **命令面板与快捷键**：命令面板、斜杠命令、可改绑的快捷键。
- **语音**：语音输入（系统语音识别）与文字转语音工具。
- **备份与导出**：`.minissync` 快照（会话、长期记忆、技能、设置；不含钥匙串密钥，可选密码保护）；脱敏诊断包导出。

**画布（Canvas）**：源码中保留画布相关代码，但画布功能目前冻结，本项目不对其作任何功能承诺。

### 系统要求

- macOS 14.0 或更新版本。
- Apple 芯片和 Intel 均可：发布包为通用（Universal）二进制，不需要 Rosetta。

### 快速开始

**路径一：下载安装**

1. 从 Releases 页面（`https://github.com/zhangyongjiewzj-bit/MinisCanvas`）下载 `MinisCanvas-<版本>-macos-universal.zip` 和同名 `.sha256` 文件。
2. 校验 sha256，解压，把 `MinisCanvas.app` 拖入“应用程序”。
3. 第一次打开会被 macOS 拦截（安装包仅 ad-hoc 签名，未经 Apple 公证），按系统版本放行。
4. 在设置中添加模型供应商和 API Key，开始对话。

详见 [INSTALL.md](./INSTALL.md)。

**路径二：从源码构建**

1. 安装 Xcode（已验证 Xcode 26 / Swift 6.3.3）。
2. 获取源码：`git clone https://github.com/zhangyongjiewzj-bit/MinisCanvas`。
3. 开发构建：`swift build --package-path src/MinisCanvasApp`；或打发布包：`scripts/build_release.sh`。
4. 产物在 `dist/`，校验方式见构建说明。

详见 [BUILDING.md](./BUILDING.md)。使用说明见 [docs/USER_GUIDE.md](./docs/USER_GUIDE.md)。

### 项目结构

- `src/MinisCanvasApp`：主应用（界面、设置、对话），打包出 `MinisCanvas.app`。
- `src/MinisCore`：智能体核心库（模型接入、工具、审批、记忆、技能、会话存储）。
- `src/CanvasCore`：画布核心库；主应用依赖它，所以仍需保留。
- `src/CanvasApp`：旧的独立画布入口，画布冻结，不保证可用。
- `src/MinisApp`：旧的独立聊天入口，不保证可用。

### 隐私与安全

- 应用本地运行，会话、设置、日志、技能保存在你的电脑上（用户资源库的 Application Support 下）。
- API Key 等凭据保存在 macOS 钥匙串，设置文件里只留名称等元数据。
- 你的消息、附件、历史上下文，以及模型调用工具后得到的结果（如读到的文件内容、命令输出、抓取的网页文本）会发送给你所配置的模型供应商，请不要让模型读取你不愿发给该供应商的文件。
- 默认的“每次询问”档下，授权目录内的读文件、搜索、压缩上下文、提问和读取技能不弹审批卡；敏感文件、写文件、编辑、删除、执行命令、网页抓取、对外发送照常审批。“绕过权限”模式几乎不再逐次询问，但仍有硬安全边界（不改系统文件、不卸载已安装软件、保护应用自身目录与钥匙串等）。
- 备份快照 `.minissync` 含私人会话与记忆；未选择密码保护时以明文保存，请妥善保管。
- 产品内含一些内部验收用代码和环境变量（如 `MINISCANVAS_FIELD_PROFILE`），默认不启用。

### 已知限制

- 发布包未公证，首次打开需手动放行；放行步骤在不同 macOS 版本上的具体表现未逐版实测。
- Intel 机器上的实际运行尚未经过实机验证。
- 界面目前只有中文。
- 画布功能冻结。
- 命令的危险识别是尽力而为，不是完整沙箱。
- 公开测试入口只覆盖 MinisCore 与 CanvasCore；主应用部分测试需要原生宿主和“辅助功能”授权，普通 `swift test` 不保证全绿。

### 许可证与致谢

GPL-3.0-only，全文见 [LICENSE](./LICENSE)；版权与第三方组件声明（含 OpenMinis 衍生说明、SwiftSoup、SwiftTerm、Keyline Icons、Gitleaks 规则数据）见 [NOTICE](./NOTICE)。版权归 zang。

参与贡献见 [CONTRIBUTING.md](./CONTRIBUTING.md)，安全问题见 [SECURITY.md](./SECURITY.md)。

### 免责声明

本软件按“现状”提供，不附带任何明示或默示担保，详见 GPL-3.0 第 15、16 条。智能体工具能读写文件、执行命令并访问网络，使用前请理解审批提示，并对重要数据自行备份。**开启“绕过权限”模式后，模型可在不逐次询问你的情况下执行任意命令、访问几乎任意路径；只在你完全信任当前任务与模型时使用，并事先备份。** 本项目与 Anthropic、OpenAI 等公司没有从属或背书关系，文中提到的产品名仅用于说明兼容性或交互参考。

---

## English

MinisCanvas is a native macOS agent client. You chat with a model that can read and write files, run shell commands and browse the web on your machine, with approval prompts before risky actions. Its interaction model draws on Claude Code (per-call tool approval, queued messages, project instruction files), but it is an independent project with no affiliation with or endorsement by Anthropic, OpenAI or any other vendor.

> Status: early release (0.1.x); expect bugs. Read the disclaimer below.

### Features

- Multiple provider types: OpenAI, Anthropic, Google Gemini, OpenRouter, DeepSeek, the Responses API, local models (Ollama/ComfyUI), plus media-oriented ones (Alibaba Bailian, Gimage2, Kling, Jimeng).
- File and command tools (read incl. PDF pages, write, edit, delete, zsh commands) with background commands.
- Per-call approvals and persistent rules; file checkpoints before edits, with restore.
- Web fetch and a built-in browser (write actions are separately switchable and approved per item).
- MCP servers with per-tool authorization; Hooks (PreToolUse, PostToolUse, UserPromptSubmit, SessionStart, Stop).
- Skills (reviewed and approved by you before use), long-term memory, project instruction files (AGENTS.md, CLAUDE.md, .claude/CLAUDE.md; trust required).
- Child tasks with a task center, cron-based scheduled tasks, context compaction, git workflow helpers.
- Session management, command palette, rebindable shortcuts, speech input and text-to-speech.
- `.minissync` backups (no Keychain secrets; optional password) and a redacted diagnostics export.

Canvas code remains in the repository, but the canvas feature is frozen and no functionality is promised.

### Requirements

- macOS 14.0 or later.
- Apple silicon and Intel: the release is a universal binary; Rosetta is not needed.

### Quick start

**Download:** get `MinisCanvas-<version>-macos-universal.zip` and its `.sha256` from the Releases page (`https://github.com/zhangyongjiewzj-bit/MinisCanvas`), verify the checksum, unzip, drag the app to Applications, then approve the first launch (the app is ad-hoc signed and not notarized). See [INSTALL.md](./INSTALL.md).

**Build from source:** install Xcode (verified with Xcode 26 / Swift 6.3.3), clone the repository, then run `swift build --package-path src/MinisCanvasApp` for development or `scripts/build_release.sh` for a release package. See [BUILDING.md](./BUILDING.md). User guide (Chinese): [docs/USER_GUIDE.md](./docs/USER_GUIDE.md).

### Structure

- `src/MinisCanvasApp`: the main app (UI, settings, chat).
- `src/MinisCore`: agent core library (providers, tools, approvals, memory, skills, sessions).
- `src/CanvasCore`: canvas core library; still required by the main app.
- `src/CanvasApp`, `src/MinisApp`: legacy entry points; not guaranteed to work.

### Privacy and security

- Runs locally; sessions, settings, logs and skills live under your Application Support folder. API keys are stored in the macOS Keychain.
- Your messages, attachments, history and tool results (file contents, command output, fetched pages) are sent to the model provider you configure.
- With the default "ask every time" mode, reads, searches, context compaction, questions and skill reads inside authorized folders do not prompt; sensitive files, writes, edits, deletes, command execution, web fetch and outbound sends are still approved. Bypass mode has hard safety boundaries.
- The product contains some internal verification code and environment variables (for example `MINISCANVAS_FIELD_PROFILE`), disabled by default.

### Known limitations

Not notarized (manual approval on first launch; steps not verified on every macOS version); Intel hardware not verified; Chinese-only UI; canvas frozen; command risk detection is best-effort, not a sandbox; the public test script covers MinisCore and CanvasCore only, while some app tests need a native host and Accessibility permission.

### License

GPL-3.0-only. See [LICENSE](./LICENSE) and [NOTICE](./NOTICE). Copyright zang. See also [CONTRIBUTING.md](./CONTRIBUTING.md) and [SECURITY.md](./SECURITY.md).

### Disclaimer

Provided "as is", without warranty of any kind (GPL-3.0 sections 15 and 16). The agent can read and write files, run commands and use the network; back up important data. With bypass mode on, the model can run arbitrary commands and access almost any path without asking each time; use it only when you fully trust the task and the model. No affiliation with or endorsement by Anthropic, OpenAI or other vendors.
