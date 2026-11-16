#!/bin/bash
# ============================================================
# build.sh — 遍历编译 src/ 下所有 SPM 包（swift build --package-path）
# 用途: 纯 CLI 开发环境（无 Xcode）下全量编译，供总控质检。
# 用法: ./build.sh [packages_dir]   # 默认 <repo>/src
# 行为: 任一包编译失败 -> 继续编译其余包，最后输出错误摘要并退出 1；
#       无包（空目录）视为通过（退出 0）。
# 要求: bash + set -euo pipefail
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES_DIR="${1:-$ROOT/src}"

if [[ ! -d "$PACKAGES_DIR" ]]; then
  echo "[build.sh] 错误: 包目录不存在: $PACKAGES_DIR" >&2
  exit 1
fi

# 收集所有 Package.swift（跳过 .build/.git 内部）
PACKAGES=()
while IFS= read -r p; do
  PACKAGES+=("$p")
done < <(find "$PACKAGES_DIR" -maxdepth 3 -name Package.swift ! -path '*/.build/*' ! -path '*/.git/*' 2>/dev/null | sort)

if [[ ${#PACKAGES[@]} -eq 0 ]]; then
  echo "[build.sh] 未发现 SPM 包（$PACKAGES_DIR 下无 Package.swift），视为通过（空目录不失败）。"
  exit 0
fi

echo "[build.sh] 发现 ${#PACKAGES[@]} 个 SPM 包:"
for p in "${PACKAGES[@]}"; do
  echo "  - ${p#${PACKAGES_DIR}/}"
done

FAILED=()
for pkg in "${PACKAGES[@]}"; do
  pkgdir="$(dirname "$pkg")"
  name="$(basename "$pkgdir")"
  echo ""
  echo "=== [build.sh] 编译 $name ($pkgdir) ==="
  if swift build --package-path "$pkgdir"; then
    echo "=== [build.sh] OK: $name 编译成功 ==="
  else
    echo "=== [build.sh] FAIL: $name 编译失败 ===" >&2
    FAILED+=("$name")
  fi
done

echo ""
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "[build.sh] 错误摘要: ${#FAILED[@]}/${#PACKAGES[@]} 个包编译失败:" >&2
  for f in "${FAILED[@]}"; do
    echo "  [x] $f" >&2
  done
  exit 1
fi

echo "[build.sh] 全部 ${#PACKAGES[@]} 个包编译通过 OK"
exit 0
