# 构建说明

## 环境要求

- macOS 14.0 或更高。
- Xcode 与 Swift 6 工具链。已验证的组合：Xcode 26 / Swift 6.3.3。
- 各包的 `Package.swift` 开启了 `-warnings-as-errors` 与 Swift 6 完整并发检查：任何编译警告都会导致构建失败，因此用其他 Swift 版本构建时，可能因新版本编译器产生的新警告而编不过。
- 首次构建需要联网拉取依赖：SwiftSoup 2.6.0、SwiftTerm 1.99.2（均为 MIT；SwiftTerm 的传递依赖也会被解析）。
- 通用包要求 SDK 能同时编译 arm64 与 x86_64（当前 Xcode 默认满足）。
- 仓库路径或输出路径含空格时脚本按带引号的数组处理，但未专门验证；遇到问题请换到不含空格的路径。

## 获取源码

```bash
git clone https://github.com/zhangyongjiewzj-bit/MinisCanvas
cd MinisCanvas
```

## 包结构

| 包 | 说明 |
|---|---|
| `src/MinisCanvasApp` | 主应用（可执行程序），依赖 CanvasCore、MinisCore、SwiftTerm |
| `src/MinisCore` | 智能体核心库，依赖 SwiftSoup |
| `src/CanvasCore` | 画布核心库，主应用依赖它，必须保留 |
| `src/CanvasApp`、`src/MinisApp` | 旧入口，画布功能冻结，不保证可用，也不被其他包依赖 |

## 开发时直接构建

```bash
swift build --package-path src/MinisCanvasApp          # 主应用（会一并构建 MinisCore、CanvasCore）
swift build --package-path src/MinisCore               # 只构建核心库
swift build --package-path src/CanvasCore
```

`scripts/build.sh` 会依次构建 `src/` 下全部 5 个包（包括旧入口），任一失败会继续其余包，最后汇总并以非零状态退出。旧入口不保证能编过。

## 运行测试

公开测试入口为：

```bash
scripts/test_core.sh
```

它对 MinisCore 与 CanvasCore 先编译测试，再运行 `swift test`。

MinisCore 的测试不会碰你的真实数据：它们只在声明过的一次性测试档里运行，没有这个测试档会直接拒绝运行（日志里会大量出现 `FormalTestIsolationPaths ... → nil` 或 `missingContract`）。脚本会在 `.build/test-profile/` 下建好私有测试根目录、临时 HOME 和 TMPDIR，并设置 `MINISCANVAS_TEST_*` 变量，测试逐个串行执行。所以请用这个脚本跑，不要直接对 MinisCore 运行 `swift test`。跑完留下的 `.build/test-profile/` 可以随时删除。

源码目录请放在自己的用户目录下（例如 `~/src/MinisCanvas`），不要放在 `/tmp`、`/var` 这类系统临时目录里：`/tmp` 实际是指向 `/private/tmp` 的符号链接，测试的隔离检查会拒绝路径里带符号链接的测试根目录，脚本遇到这种位置会直接提示并退出。

说明：

- MinisCanvasApp 的测试有一部分需要原生宿主、系统“辅助功能”授权和独占窗口，直接运行 `swift test --package-path src/MinisCanvasApp` 不保证全绿，这不代表代码有问题。
- MinisCore 的测试目标在 `Package.swift` 里引用了 `/Library/Developer/CommandLineTools/Library/Developer/Frameworks` 下的 Testing.framework 路径。该路径来自命令行工具；只装 Xcode、没有安装命令行工具时它可能不存在，此时请执行 `xcode-select --install` 安装命令行工具后再试。

## 打发布包

```bash
scripts/build_release.sh [--arch arm64|x86_64|universal] [--output <目录>] [--version <x.y.z>]
```

- `--arch`：默认 `universal`。脚本对每个架构分别 `swift build -c release`（用 `--triple`），再用 `lipo -create` 合并。
- `--output`：默认 `<仓库>/dist`。成功编译后，脚本会删除并覆盖该目录中三个固定名字的旧产物（`MinisCanvas.app`、对应 zip 与 `.sha256`）；编译失败不动旧产物。请勿把 `--output` 指向 `/Applications` 这类已有应用的目录。中间文件在 `<输出目录>/.build-release/`，可随时删除。
- `--version`：必须形如 `1.2.3`，默认 `0.1.0`，写入 Info.plist。

示例：

```bash
scripts/build_release.sh --version 0.1.0
```

产物（在输出目录中）：

- `MinisCanvas.app`：ad-hoc 签名，无 Developer ID，未公证，不含 entitlements。
- `MinisCanvas-<版本>-macos-<架构>.zip`：用 `ditto` 打包。
- `MinisCanvas-<版本>-macos-<架构>.zip.sha256`：SHA-256 校验和。

脚本不运行测试，也不启动应用；包内附带的 `PACKAGE_FEATURE_MANIFEST.json` 如实标注 `release_ready: false`。脚本开始时会清除构建环境中的内部验收用环境变量（如 `MINISCANVAS_FIELD_PROFILE`）。

## 校验产物

```bash
lipo -archs dist/MinisCanvas.app/Contents/MacOS/MinisCanvas     # universal 应含 x86_64 和 arm64
codesign --verify --deep --strict --verbose=2 dist/MinisCanvas.app
codesign -dv dist/MinisCanvas.app 2>&1 | grep -E "Signature|flags"   # 应显示 Signature=adhoc
(cd dist && shasum -a 256 -c MinisCanvas-0.1.0-macos-universal.zip.sha256)
```

自己从源码构建的应用没有隔离标记，通常不会被 macOS 拦截。把包发给别人，对方首次打开需要放行，见 [INSTALL.md](./INSTALL.md)。

## 常见问题

**编译报新的警告并失败**
`-warnings-as-errors` 使任何警告都成为错误。请优先使用已验证的 Xcode 26 / Swift 6.3.3；用其他版本遇到新警告，欢迎提 issue 或 PR 修复。

**测试报找不到 Testing.framework，或发现 0 个测试**
见上文“运行测试”：安装命令行工具（`xcode-select --install`），并确认 `xcode-select -p` 指向有效的开发者目录。

**拉取依赖失败**
首次构建需要访问 GitHub 拉取 SwiftSoup 与 SwiftTerm，请检查网络或代理。

**找不到命令 swift、lipo、codesign 等**
安装 Xcode 或命令行工具，并确认 `xcode-select -p` 指向它。

**打包脚本提示缺少某架构的 SDK**
更新 Xcode；或用 `--arch` 只构建本机架构。
