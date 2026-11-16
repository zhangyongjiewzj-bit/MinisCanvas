# 参与贡献

感谢你愿意改进 MinisCanvas。

## 提 issue

- 请先搜索是否已有相同问题。
- 说明 macOS 版本、芯片类型（Apple 芯片或 Intel）、应用版本，以及复现步骤、实际与期望结果。
- 请不要在 issue 里贴 API Key、密码、会话中的私人内容；诊断信息请使用应用内“导出脱敏诊断包”。
- 安全问题不要公开提 issue，见 [SECURITY.md](./SECURITY.md)。

## 提 PR

- 一个 PR 只做一件事，说明动机与验证方式。
- 构建与环境见 [BUILDING.md](./BUILDING.md)。
- 提交前运行 `scripts/test_core.sh`。主应用中需要原生宿主和“辅助功能”授权的测试不要求在 PR 中全部通过，请在说明里写明你实际运行了什么。
- 画布功能冻结，暂不接受画布新功能；`src/CanvasApp`、`src/MinisApp` 是旧入口，不保证可用。

## 代码风格

- 以 Swift 6 语言模式、完整并发检查（`-strict-concurrency=complete`）和 `-warnings-as-errors` 为准：新增代码不能引入任何编译警告。
- 沿用所在文件的命名、注释与结构风格，避免无关重构。
- 不要提交密钥、密码、个人信息或本机绝对路径。

## 许可

向本项目提交的贡献按 GPL-3.0-only 授权，与项目一致，见 [LICENSE](./LICENSE)。
