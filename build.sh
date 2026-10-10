#!/bin/bash
# Video Post-Production 一键构建（GUI App + CLI）
#
# ⚠️ 关键：-target 必须显式写死。swiftc 不带 -target 时，部署目标 = 编译那台机器的
#    系统版本（本机 macOS 27 → 产物 minos 27.0），plist 里写的 LSMinimumSystemVersion
#    只是门面，真正决定能否加载的是 Mach-O 的 minos。曾因此发布出「要求 macOS 27」的包。
#    脚本末尾会强制用 vtool 复核 minos，不符即失败退出。
set -euo pipefail

cd "$(dirname "$0")"

TARGET="arm64-apple-macosx13.0"   # 代码真实下限：13.0（12.0 会撞 .defaultSize/.windowResizability）
EXPECT_MINOS="13.0"
APP="build/Video Post-Production.app"
BIN="$APP/Contents/MacOS/VideoFrameTool"   # 注意：不是 App 显示名
CLI="build/videopost-cli"

RUN_TESTS=0
[[ "${1:-}" == "--test" ]] && RUN_TESTS=1

echo "==> 编译 GUI App（target ${TARGET}）"
swiftc -disable-sandbox -O -target "$TARGET" -parse-as-library Logic.swift App.swift -o "$BIN"
codesign --force -s - "$APP"

echo "==> 编译 CLI（target ${TARGET}）"
swiftc -disable-sandbox -O -target "$TARGET" main.swift Logic.swift -o "$CLI"

if [[ "$RUN_TESTS" -eq 1 ]]; then
  echo "==> 编译并运行单测"
  swiftc -disable-sandbox -O -target "$TARGET" tests/TimelineModelTests.swift Logic.swift -o /tmp/tltest
  /tmp/tltest
fi

echo "==> 复核部署目标（minos 必须为 ${EXPECT_MINOS}）"
rc=0
for f in "$BIN" "$CLI"; do
  minos="$(vtool -show-build "$f" | grep -o 'minos [0-9.]*' | awk '{print $2}')"
  if [[ "$minos" == "$EXPECT_MINOS" ]]; then
    echo "    OK   ${f}  minos=${minos}"
  else
    echo "    FAIL ${f}  minos=${minos}（期望 ${EXPECT_MINOS}）—— 检查是否漏了 -target"
    rc=1
  fi
done

if [[ "$rc" -ne 0 ]]; then
  echo "构建失败：部署目标不符，请勿发布" >&2
  exit 1
fi

echo "==> 完成：$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
