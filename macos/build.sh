#!/bin/bash
# ClaudeUsageBar 빌드 스크립트
set -e
cd "$(dirname "$0")"

APP="ClaudeUsageBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -o "$APP/Contents/MacOS/ClaudeUsageBar" main.swift

# 자체 서명 인증서가 있으면 그걸로 서명 (재빌드해도 키체인 "항상 허용" 유지),
# 없으면 애드혹 서명
IDENTITY="ClaudeUsageBar Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "서명: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "서명: 애드혹 (make-signing-cert.sh 실행을 권장)"
fi
echo "빌드 완료: $(pwd)/$APP"
