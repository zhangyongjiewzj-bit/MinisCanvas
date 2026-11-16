#!/bin/bash
# Public test entry for MinisCanvas: runs the Swift tests of the two library packages
# (MinisCore, CanvasCore). MinisCanvasApp tests are not included: part of them need a
# native app host, Accessibility permission and an exclusive window (see BUILDING.md).
#
# MinisCore tests refuse to touch real user data. They only run inside a declared,
# disposable test profile: a private test root, a throw-away HOME and TMPDIR, and the
# MINISCANVAS_TEST_* variables below. This script creates all of that under
# <repo>/.build/test-profile/ and never uses your real home folder for test data.
# The checkout itself must not live under /tmp or /var (see the check below).
#
# Steps per package:
#   1. swift build --build-tests   (normal environment; fetches dependencies if needed)
#   2. swift test --skip-build     (isolated environment, tests run one at a time)
#
# Usage:  scripts/test_core.sh [extra swift test arguments, e.g. --filter SomeSuite]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="${ROOT}/.build/test-profile"
RUN="p$(date +%m%d%H%M%S)-$$"
STATUS=0

# The isolation check refuses any symbolic link in the test root path (for example
# /tmp -> /private/tmp). Keep the checkout on a plain path such as ~/src/MinisCanvas.
case "${ROOT}" in
  /tmp/*|/private/tmp/*|/var/*|/private/var/*)
    echo "!! this checkout is under /tmp or /var (${ROOT}); MinisCore tests refuse temporary-folder roots."
    echo "!! clone it into your home folder (e.g. ~/src/MinisCanvas) and run again."
    exit 2 ;;
esac

mkdir -p "${WORK}"
chmod 700 "${WORK}"

run_package() {
  local PKG="$1"; shift
  local PKG_PATH="${ROOT}/src/${PKG}"
  local BASE="${WORK}/${RUN}/${PKG}"
  local TEST_ROOT="${BASE}/formal-test-root"
  local TEST_HOME="${WORK}/${RUN}/home-${PKG}"
  local TEST_TMP="${WORK}/${RUN}/tmp-${PKG}"
  mkdir -p "${TEST_ROOT}" "${TEST_HOME}" "${TEST_TMP}"
  chmod 700 "${WORK}/${RUN}" "${BASE}" "${TEST_ROOT}" "${TEST_HOME}" "${TEST_TMP}"

  echo "==> swift build --build-tests --package-path src/${PKG}"
  if ! swift build --build-tests --package-path "${PKG_PATH}"; then
    echo "!! build failed in ${PKG}"
    return 1
  fi

  local DEV INO OWN
  read -r DEV INO OWN < <(/usr/bin/stat -f '%d %i %u' "${TEST_ROOT}")
  local HEX
  HEX=$(printf '%032x' "$(date +%s)")

  echo "==> swift test --skip-build --package-path src/${PKG} (isolated test profile)"
  env -i \
    HOME="${TEST_HOME}" CFFIXED_USER_HOME="${TEST_HOME}" TMPDIR="${TEST_TMP}" \
    PATH="${PATH}" LANG=en_US.UTF-8 LC_ALL=C \
    ${DEVELOPER_DIR:+DEVELOPER_DIR="${DEVELOPER_DIR}"} \
    GIT_ALLOW_PROTOCOL=file GIT_TERMINAL_PROMPT=0 \
    GIT_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false \
    MINISCANVAS_TEST_PROFILE=1 \
    MINISCANVAS_TEST_DIRECTORY="${TEST_ROOT}" \
    MINISCANVAS_TEST_SCRATCH_DIRECTORY="${BASE}" \
    MINISCANVAS_TEST_RUN_ID="${RUN}" \
    MINISCANVAS_TEST_PACKAGE="${PKG}" \
    MINISCANVAS_PROFILE_IDENTITY="formal-test:${RUN}:${PKG}:${HEX}" \
    MINISCANVAS_TEST_ROOT_DEVICE="${DEV}" \
    MINISCANVAS_TEST_ROOT_INODE="${INO}" \
    MINISCANVAS_TEST_ROOT_OWNER="${OWN}" \
    swift test --skip-build --no-parallel --package-path "${PKG_PATH}" "$@"
}

for PKG in MinisCore CanvasCore; do
  if ! run_package "${PKG}" "$@"; then
    echo "!! tests failed in ${PKG}"
    STATUS=1
  fi
done

if [ "${STATUS}" -eq 0 ]; then
  echo "==> all public tests passed"
fi
echo "test profile left at ${WORK}/${RUN} (safe to delete)"
exit "${STATUS}"
