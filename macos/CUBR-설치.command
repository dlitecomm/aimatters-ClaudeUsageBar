#!/bin/bash
# ClaudeUsageBar(CUBR) 맥 설치 — 더블클릭하면 됩니다
set -e
cd "$(dirname "$0")"

APP="/Applications/ClaudeUsageBar.app"

echo "▶ ClaudeUsageBar 설치를 시작합니다."

# 실행 중이면 종료
pkill -x ClaudeUsageBar 2>/dev/null || true
sleep 1

# 앱 번들이 없으면 빌드 (Xcode Command Line Tools 필요)
if [ ! -d "ClaudeUsageBar.app" ]; then
    echo "▶ 앱을 빌드합니다..."
    ./build.sh
fi

# /Applications 로 복사
rm -rf "$APP"
cp -R "ClaudeUsageBar.app" "$APP"
echo "▶ /Applications 에 복사했습니다."

# 로그인 시 자동 시작 등록 (중복 방지 후 추가)
osascript -e 'tell application "System Events" to delete login item "ClaudeUsageBar"' 2>/dev/null || true
if osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/ClaudeUsageBar.app", hidden:false, name:"ClaudeUsageBar"}' >/dev/null 2>&1; then
    echo "▶ 로그인 항목(자동 시작)에 등록했습니다."
else
    echo "⚠ 로그인 항목 자동 등록 실패 — 시스템 설정 → 일반 → 로그인 항목에서 수동으로 추가하세요."
fi

# 실행
open "$APP"

echo ""
echo "✅ 설치 완료! 메뉴바에서 ✳ 아이콘을 확인하세요."
echo "   (숫자가 안 뜨면 터미널에서 'claude auth login' 로그인이 필요합니다)"
