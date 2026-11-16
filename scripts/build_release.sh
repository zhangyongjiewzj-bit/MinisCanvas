#!/bin/bash
# ============================================================
# build_release.sh — 给外部用户/开源构建者用的独立打包脚本。
# Standalone release build script for external users / open-source builders.
#
# 主线 / Pipeline:
#   swift build (release, 按架构) -> [lipo 合并] -> 组装 MinisCanvas.app
#   -> ad-hoc 签名 -> 校验 -> ditto 打 zip -> 写 .sha256
#
# 用法 / Usage:
#   scripts/build_release.sh [--arch arm64|x86_64|universal]
#                            [--output <dir>] [--version <x.y.z>]
#   默认 / defaults: --arch universal, --output <repo>/dist, --version 0.1.0
#
# 产物 / Outputs (in <output>):
#   MinisCanvas.app
#   MinisCanvas-<version>-macos-<arch>.zip
#   MinisCanvas-<version>-macos-<arch>.zip.sha256
#
# 与 scripts/package_app.sh 的关系 / Relation to package_app.sh:
#   package_app.sh 承载内部准入流程（收据、来源哈希、专用钥匙串、
#   规范哈希），本脚本不依赖、不调用、不修改它，只复制其最小组装逻辑：
#     - 环境变量清理        <- package_app.sh:38-63
#     - 资源 bundle 复制与 KeylineIcons 路径规整
#                           <- package_app.sh:70-135, :988-1060
#     - Info.plist 字段     <- package_app.sh:1159-1207
#     - 功能清单 JSON(精简) <- package_app.sh:731-780
#     - ad-hoc 签名与校验   <- package_app.sh:1320-1324
#   不使用 entitlements（package_app.sh 方案A：ad-hoc 身份不注入
#   受限 entitlements，否则 AMFI 拒载），因此这里也不传 --entitlements。
#
# 架构说明 / Architecture notes:
#   本机 `swift build --help` 未列出 --arch，只有 --triple，故不用
#   `--arch arm64 --arch x86_64` 一次构建（该选项在不同 SwiftPM 版本里
#   会切换到 Xcode/swiftbuild 后端，产物路径不同）。改为每个架构单独
#   `swift build --triple <arch>-apple-macosx14.0`（native 后端、独立
#   scratch），再用 `lipo -create` 合并，`lipo -info` 校验。
#   `swift build --help` on the reference machine lists --triple but not
#   --arch, so each slice is built separately with --triple and merged by lipo.
#
# 兼容性 / Compatibility: macOS 自带 bash 3.2。
# ============================================================
set -euo pipefail
# bash 3.2 在 UTF-8 locale 下，中文后紧跟 $var 会误读变量名；统一 C locale，
# 并在消息里一律使用 ${var}。 / Use C locale and ${var} braces everywhere.
export LC_ALL=C

SCRIPT_NAME="build_release.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PKG="${ROOT}/src/MinisCanvasApp"
TARGET_NAME="MinisCanvasApp"      # SwiftPM executable target
PRODUCT_NAME="MinisCanvas"        # .app 名与可执行文件名 / app + executable name
BUNDLE_ID="com.miniscanvas.MinisCanvas"
MIN_MACOS="14.0"                  # 与 Package.swift .macOS(.v14) 一致 / matches Package.swift

ARCH="universal"
OUTPUT=""
VERSION="0.1.0"

err() { # err "中文" "English"
  echo "[${SCRIPT_NAME}] 错误 / ERROR: $1" >&2
  echo "[${SCRIPT_NAME}]        $2" >&2
  exit 1
}
info() { echo "[${SCRIPT_NAME}] $*"; }

usage() {
  cat <<'EOF'
用法 / Usage:
  scripts/build_release.sh [--arch arm64|x86_64|universal] [--output <dir>] [--version <x.y.z>]

  --arch     目标架构，默认 universal（arm64 + x86_64） / target arch, default universal
  --output   输出目录，默认 <仓库>/dist / output dir, default <repo>/dist
  --version  版本号 x.y.z，默认 0.1.0 / version, default 0.1.0
  -h|--help  显示帮助 / show help

产物 / outputs: MinisCanvas.app, MinisCanvas-<version>-macos-<arch>.zip, .zip.sha256
EOF
}

# ---------- 参数 / argument parsing ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --arch)
      [ $# -ge 2 ] || err "--arch 缺少参数" "--arch requires a value"
      ARCH="$2"; shift 2 ;;
    --output)
      [ $# -ge 2 ] || err "--output 缺少参数" "--output requires a value"
      OUTPUT="$2"; shift 2 ;;
    --version)
      [ $# -ge 2 ] || err "--version 缺少参数" "--version requires a value"
      VERSION="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; err "未知参数: ${1}" "Unknown argument: ${1}" ;;
  esac
done

case "${ARCH}" in
  arm64|x86_64|universal) ;;
  *) err "--arch 只能是 arm64、x86_64 或 universal，收到: ${ARCH}" \
         "--arch must be arm64, x86_64 or universal, got: ${ARCH}" ;;
esac
if ! printf '%s' "${VERSION}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  err "--version 必须形如 1.2.3，收到: ${VERSION}" \
      "--version must look like 1.2.3, got: ${VERSION}"
fi
[ -n "${OUTPUT}" ] || OUTPUT="${ROOT}/dist"
mkdir -p "${OUTPUT}" || err "无法创建输出目录: ${OUTPUT}" "Cannot create output dir: ${OUTPUT}"
OUTPUT="$(cd "${OUTPUT}" && pwd -P)"

# ---------- 环境检查 / preflight ----------
[ "$(uname -s)" = "Darwin" ] || err "只能在 macOS 上构建" "This script only runs on macOS"
for tool in swift lipo codesign ditto plutil shasum otool; do
  command -v "${tool}" >/dev/null 2>&1 || err \
    "找不到命令 ${tool}。请安装 Xcode 或 Command Line Tools（xcode-select --install）" \
    "Command not found: ${tool}. Install Xcode or the Command Line Tools (xcode-select --install)"
done
[ -f "${PKG}/Package.swift" ] || err "找不到 ${PKG}/Package.swift，请在完整仓库中运行" \
  "Missing ${PKG}/Package.swift; run from a full checkout"
xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1 || err \
  "找不到 macOS SDK。请安装 Xcode 或 CLT，并确认 xcode-select -p 指向它" \
  "macOS SDK not found. Install Xcode or CLT and check xcode-select -p"

# 构建期不得带入现场/测试环境变量 / drop field-profile env (package_app.sh:49-63)
for key in HERMES_FIELD_PROFILE_ACTIVE HERMES_FIELD_PROFILE_ROOT \
  MINISCANVAS_FIELD_PROFILE MINISCANVAS_FIELD_PROFILE_ROOT MINISCANVAS_PROFILE_IDENTITY \
  MINISCANVAS_FIELD_SOURCE_HEAD MINISCANVAS_FIELD_SOURCE_TREE \
  MINISCANVAS_FIELD_BINARY_SHA256 MINISCANVAS_FIELD_APP_TREE_SHA256 \
  MINISCANVAS_FIELD_RUNNER_PERMISSION; do
  unset "${key}" 2>/dev/null || true
done

if [ "${ARCH}" = "universal" ]; then
  ARCH_LIST="arm64 x86_64"
else
  ARCH_LIST="${ARCH}"
fi

APP_DIR="${OUTPUT}/${PRODUCT_NAME}.app"
ZIP_NAME="${PRODUCT_NAME}-${VERSION}-macos-${ARCH}.zip"
ZIP_PATH="${OUTPUT}/${ZIP_NAME}"
WORK_DIR="${OUTPUT}/.build-release"   # scratch，可安全删除 / safe to delete
mkdir -p "${WORK_DIR}"

# 源码标识（可选，用于关于页清单；无 git 则 unknown）
# Source identity (optional; used by the About page manifest)
SOURCE_COMMIT="unknown"
SOURCE_TREE="unknown"
if command -v git >/dev/null 2>&1 && git -C "${ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
  SOURCE_COMMIT="$(git -C "${ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
  SOURCE_TREE="$(git -C "${ROOT}" rev-parse 'HEAD^{tree}' 2>/dev/null || echo unknown)"
fi
BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------- 编译 / build ----------
SLICE_BINS=()        # bash 数组，路径可含空格 / bash array; paths may contain spaces
RESOURCE_SRC_DIR=""
for arch in ${ARCH_LIST}; do
  scratch="${WORK_DIR}/${arch}"
  triple="${arch}-apple-macosx${MIN_MACOS}"
  info "编译 / building ${arch} (${triple}) ..."
  if ! swift build --package-path "${PKG}" -c release --scratch-path "${scratch}" \
        --triple "${triple}" --disable-keychain; then
    err "编译 ${arch} 失败。常见原因：网络无法拉取依赖(SwiftSoup)、Xcode/CLT 或 Swift 版本过旧、缺少 ${arch} 的 SDK/工具链(Xcode 命令行工具通常自带两种架构；请更新 Xcode)。" \
        "Build for ${arch} failed. Typical causes: no network for dependencies (SwiftSoup), Xcode/CLT or Swift too old, or no ${arch} SDK/toolchain (current Xcode ships both; try updating Xcode)."
  fi
  bin_dir="$(swift build --package-path "${PKG}" -c release --scratch-path "${scratch}" \
        --triple "${triple}" --disable-keychain --show-bin-path)" || err \
    "无法取得 ${arch} 的产物目录" "Cannot resolve the ${arch} bin path"
  bin="${bin_dir}/${TARGET_NAME}"
  [ -x "${bin}" ] || err "编译后找不到可执行文件: ${bin}" "Executable not found after build: ${bin}"
  SLICE_BINS+=("${bin}")
  # 资源 bundle 与架构无关，取第一个切片的 / resources are arch-independent: use the first slice's
  if [ -z "${RESOURCE_SRC_DIR}" ]; then RESOURCE_SRC_DIR="${bin_dir}"; fi
done

# ---------- 合并 / lipo ----------
MERGED_BIN="${WORK_DIR}/${PRODUCT_NAME}.bin"
rm -f "${MERGED_BIN}"
if [ "${ARCH}" = "universal" ]; then
  info "lipo 合并 arm64 + x86_64 ..."
  lipo -create "${SLICE_BINS[@]}" -output "${MERGED_BIN}" || err \
    "lipo 合并失败" "lipo -create failed"
else
  cp "${SLICE_BINS[0]}" "${MERGED_BIN}"
fi
chmod 755 "${MERGED_BIN}"

# ---------- 组装 .app / assemble ----------
# 编译与合并都成功后才清理旧产物，编译失败不会丢掉上一次的好产物；
# 只删 ${OUTPUT} 内这三个固定名字。
# Remove old artifacts only after a successful build; only these three fixed names inside ${OUTPUT}.
rm -rf "${APP_DIR}" "${ZIP_PATH}" "${ZIP_PATH}.sha256"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${MERGED_BIN}" "${APP_DIR}/Contents/MacOS/${PRODUCT_NAME}"

# SwiftPM 资源 bundle（package_app.sh:988-1060）。KeylineIcons 在 Package.swift 里
# 以 .copy("Resources/ThirdParty/KeylineIcons") 声明，SwiftPM 会放成 ThirdParty/KeylineIcons，
# 运行时代码从 bundle 根的 KeylineIcons/Raster 读取，故需上移一层
# （对应 package_app.sh materialize_swiftpm_resource_bundle 的 normalize）。
bundle_count=0
for src_bundle in "${RESOURCE_SRC_DIR}"/*.bundle; do
  [ -d "${src_bundle}" ] || continue
  name="$(basename "${src_bundle}")"
  dest="${APP_DIR}/Contents/Resources/${name}"
  cp -R "${src_bundle}" "${dest}"
  if [ -d "${dest}/ThirdParty/KeylineIcons" ] && [ ! -e "${dest}/KeylineIcons" ]; then
    mv "${dest}/ThirdParty/KeylineIcons" "${dest}/KeylineIcons"
    rmdir "${dest}/ThirdParty" 2>/dev/null || true
  fi
  [ -n "$(find "${dest}" -type f -print -quit)" ] || err "资源 bundle 为空: ${name}" "Resource bundle is empty: ${name}"
  bundle_count=$((bundle_count + 1))
done
[ "${bundle_count}" -ge 1 ] || err "没有找到 SwiftPM 资源 bundle（*.bundle）" \
  "No SwiftPM resource bundle (*.bundle) found next to the binary"
REQUIRED_BUNDLE="${APP_DIR}/Contents/Resources/MinisCanvasApp_MinisCanvasApp.bundle"
[ -d "${REQUIRED_BUNDLE}/KeylineIcons" ] || err \
  "资源 bundle 缺少 KeylineIcons（图标会缺失）" "Resource bundle lacks KeylineIcons (icons would be missing)"
[ -f "${REQUIRED_BUNDLE}/Legal/LICENSE" ] && [ -f "${REQUIRED_BUNDLE}/Legal/NOTICE" ] || err \
  "资源 bundle 缺少 Legal/LICENSE 或 Legal/NOTICE" "Resource bundle lacks Legal/LICENSE or Legal/NOTICE"
# 许可证文件同时放到 Resources 根，方便用户查看 / also place license files at Resources root
cp "${REQUIRED_BUNDLE}/Legal/LICENSE" "${APP_DIR}/Contents/Resources/LICENSE"
cp "${REQUIRED_BUNDLE}/Legal/NOTICE" "${APP_DIR}/Contents/Resources/NOTICE"
# 应用图标（可选）/ app icon (optional)
if [ -f "${ROOT}/docs/assets/AppIcon.icns" ]; then
  cp "${ROOT}/docs/assets/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi

# Info.plist（字段来自 package_app.sh:1159-1207；去掉内部 keychain 连续性字段）
cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleExecutable</key>
	<string>${PRODUCT_NAME}</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${PRODUCT_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>MinisCanvasSourceSHA</key>
	<string>${SOURCE_COMMIT}</string>
	<key>MinisCanvasSourceTree</key>
	<string>${SOURCE_TREE}</string>
	<key>MinisCanvasLaunchProfile</key>
	<string>desktop-default</string>
	<key>MinisCanvasFieldHarness</key>
	<string>external-explicit-only</string>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>${BUNDLE_ID}</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>miniscanvas</string>
				<string>minis</string>
			</array>
		</dict>
	</array>
	<key>NSMicrophoneUsageDescription</key>
	<string>用于语音输入和朗读</string>
	<key>NSSpeechRecognitionUsageDescription</key>
	<string>用于语音输入和朗读</string>
	<key>LSMinimumSystemVersion</key>
	<string>${MIN_MACOS}</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST
plutil -lint "${APP_DIR}/Contents/Info.plist" >/dev/null || err \
  "生成的 Info.plist 不合法" "Generated Info.plist is invalid"

# 关于页读取的功能清单（精简自 package_app.sh:731-780）。缺失只会让关于页显示
# “功能清单不可用”，不影响运行；这里写入诚实的外部构建状态。
# About page manifest (trimmed). Missing it only shows "unavailable"; we write honest status.
cat > "${APP_DIR}/Contents/Resources/PACKAGE_FEATURE_MANIFEST.json" <<MANIFEST
{
  "schema_version": 1,
  "kind": "PACKAGE_FEATURE_MANIFEST",
  "channel": "community-build",
  "source_sha": "${SOURCE_COMMIT}",
  "tree_sha": "${SOURCE_TREE}",
  "build_time": "${BUILD_TIME}",
  "features": ["community build via scripts/build_release.sh"],
  "automated_tests": "not run by build_release.sh",
  "packaged": "ad-hoc signed, not notarized (${ARCH})",
  "known_field_issues": ["ad-hoc signed and not notarized: first launch needs manual approval in macOS"],
  "field_verified": false,
  "release_ready": false
}
MANIFEST

# 二进制不得含绝对 scratch 路径（package_app.sh:1042-1062 的精简版）
# Binary must not embed absolute scratch paths (trimmed from package_app.sh:1042-1062)
OTOOL_SCAN="$(otool -L "${APP_DIR}/Contents/MacOS/${PRODUCT_NAME}" 2>&1; otool -l "${APP_DIR}/Contents/MacOS/${PRODUCT_NAME}" 2>&1)" || err \
  "otool 扫描失败" "otool scan failed"
case "${OTOOL_SCAN}" in
  *"${WORK_DIR}"*) err "二进制含有指向构建目录的绝对依赖/rpath" "Binary has an absolute dependency/rpath into the build dir" ;;
esac

# ---------- 签名 / ad-hoc sign ----------
info "ad-hoc 签名 / ad-hoc signing ..."
codesign --force --deep --sign - "${APP_DIR}" || err "codesign 签名失败" "codesign failed"
codesign --verify --deep --strict "${APP_DIR}" || err "codesign 校验失败" "codesign --verify --deep --strict failed"

# ---------- 架构校验 / architecture check ----------
APP_BIN="${APP_DIR}/Contents/MacOS/${PRODUCT_NAME}"
LIPO_INFO="$(lipo -info "${APP_BIN}")" || err "lipo -info 失败" "lipo -info failed"
info "${LIPO_INFO}"
case "${ARCH}" in
  universal)
    case "${LIPO_INFO}" in *arm64*) ;; *) err "通用包缺少 arm64 切片" "Universal binary lacks arm64 slice" ;; esac
    case "${LIPO_INFO}" in *x86_64*) ;; *) err "通用包缺少 x86_64 切片" "Universal binary lacks x86_64 slice" ;; esac ;;
  *)
    case "${LIPO_INFO}" in *"${ARCH}"*) ;; *) err "产物不含 ${ARCH} 切片" "Binary lacks the ${ARCH} slice" ;; esac ;;
esac

# ---------- 打包 / zip + sha256 ----------
ditto -c -k --keepParent "${APP_DIR}" "${ZIP_PATH}" || err "ditto 打包失败" "ditto zip failed"
(cd "${OUTPUT}" && shasum -a 256 "${ZIP_NAME}" > "${ZIP_NAME}.sha256") || err \
  "写入 sha256 失败" "Writing sha256 failed"

info "完成 / done:"
info "  ${APP_DIR}"
info "  ${ZIP_PATH}"
info "  ${ZIP_PATH}.sha256"
info "提示 / note: 包为 ad-hoc 签名、未公证；首次打开见 INSTALL.md / first launch: see INSTALL.md"
