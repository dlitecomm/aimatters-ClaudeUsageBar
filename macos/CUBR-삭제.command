#!/bin/bash
# ClaudeUsageBar(CUBR) 맥 삭제 — 더블클릭하면 됩니다
cd "$(dirname "$0")"

echo "▶ ClaudeUsageBar 를 삭제합니다."

# 실행 중이면 종료
pkill -x ClaudeUsageBar 2>/dev/null || true
sleep 1

# 로그인 항목 제거
osascript -e 'tell application "System Events" to delete login item "ClaudeUsageBar"' 2>/dev/null || true

# 앱 제거
rm -rf "/Applications/ClaudeUsageBar.app"

echo ""
echo "✅ 삭제 완료. (Claude Code 로그인/키체인 토큰은 앱 것이 아니므로 그대로 유지됩니다)"
echo "   소스 폴더(~/ClaudeUsageBar)까지 지우려면 휴지통으로 옮기시면 됩니다."
