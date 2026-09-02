#!/bin/bash
# 자체 서명 코드사인 인증서 생성 + 로그인 키체인에 등록
# 이 인증서로 서명하면 앱을 재빌드해도 키체인 "항상 허용"이 유지된다.
set -e

NAME="ClaudeUsageBar Signing"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "이미 인증서가 있습니다: $NAME"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "keyUsage=digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -addext "basicConstraints=CA:FALSE" 2>/dev/null

# macOS security가 읽을 수 있도록 구형(SHA1-3DES) 암호화 + 임시 비밀번호 사용
# (비밀번호는 이 스크립트 안에서만 쓰는 일회용 — 인증서는 키체인에 들어가면 끝)
openssl pkcs12 -export -out "$TMP/cub.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    -passout pass:cubr-temp 2>/dev/null

# 로그인 키체인에 등록, codesign이 키를 쓸 수 있게 허용
security import "$TMP/cub.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "cubr-temp" -T /usr/bin/codesign

# 자체 서명 인증서를 코드사인 용도로 신뢰 등록 (비밀번호 확인 창이 뜰 수 있음)
security add-trusted-cert -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem"

echo "인증서 등록 완료: $NAME"
echo "(첫 서명 때 '항상 허용' 창이 뜰 수 있습니다)"
