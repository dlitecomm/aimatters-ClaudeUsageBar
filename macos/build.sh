#!/bin/bash
# ClaudeUsageBar 빌드 스크립트
set -e
cd "$(dirname "$0")"

APP="ClaudeUsageBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -o "$APP/Contents/MacOS/ClaudeUsageBar" main.swift
codesign --force --sign - "$APP"
echo "빌드 완료: $(pwd)/$APP"
