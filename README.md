# ClaudeUsageBar

맥 메뉴바 / 윈도우 트레이에서 Claude(Claude Code) 사용량을 실시간으로 보여주는 미니 앱.

- 상태바에 **5시간 창 사용률 %** 표시 (`✳ 42%`)
- 클릭하면 5시간·주간(전체/Opus 등) 사용률과 **리셋 시각** 표시
- 1분마다 자동 갱신, 토큰 만료 시 자동 재발급(refresh)
- 데이터는 Claude Code가 로그인 때 저장한 OAuth 토큰으로 공식 사용량 API(`api.anthropic.com/api/oauth/usage`)를 호출해 가져옴. 토큰은 앱 밖으로 나가지 않음.

## 선행 조건 (맥·윈도우 공통)

터미널에서 Claude Code CLI 로그인이 한 번 되어 있어야 한다:

```bash
claude auth login
```

> 데스크톱 앱만 쓰고 CLI 로그인을 안 했다면 토큰 저장소(키체인/credentials.json)가 비어 있어 앱이 "claude auth login 실행 필요" 오류를 표시한다.

## 맥 (macos/)

- **설치**: `CUBR-설치.command` 더블클릭 — 앱을 `/Applications`에 복사하고, 로그인 시 자동 시작을 등록하고, 바로 실행한다. (앱 번들이 없으면 자동 빌드 — Xcode CLT 필요)
- **삭제**: `CUBR-삭제.command` 더블클릭 — 앱 종료, 로그인 항목 해제, `/Applications`에서 제거.
- **재설치**: 그냥 `CUBR-설치.command`를 다시 더블클릭 (기존 설치를 덮어씀).

첫 실행 때 키체인 접근 창이 뜨면 **"항상 허용"** 클릭. 터미널 검증: `/Applications/ClaudeUsageBar.app/Contents/MacOS/ClaudeUsageBar --once`

토큰 위치: 키체인 서비스 `Claude Code-credentials` (폴백: `~/.claude/.credentials.json`)

## 윈도우 (windows/)

`windows` 폴더를 윈도우 PC로 복사한 뒤:

- **설치**: `CUBR-Install.bat` 더블클릭 — `%LOCALAPPDATA%\ClaudeUsageBar`에 복사, 시작 프로그램 등록, **윈도우 설정 > 앱 > 설치된 앱 목록에 언인스톨 항목 등록**, 즉시 실행.
- **삭제**: 윈도우 설정 > 앱 > 설치된 앱에서 "ClaudeUsageBar" 제거 — 또는 `CUBR-Uninstall.bat` 더블클릭.
- **재설치**: `CUBR-Install.bat` 다시 실행 (덮어씀).

트레이 아이콘에 % 숫자가 색상(초록/노랑/빨강)으로 그려지고, 마우스 오버 툴팁·우클릭 메뉴로 상세 확인. 아이콘이 안 보이면 트레이의 숨김 아이콘(`^`)을 펼쳐 볼 것.

토큰 위치: `%USERPROFILE%\.claude\.credentials.json`

> 윈도우 스크립트는 맥에서 작성되어 실기기 테스트 전이다. 문제가 생기면 트레이 아이콘 `!` 상태의 툴팁 메시지를 확인.

## 동작 원리

1. Claude Code가 저장한 OAuth 자격증명(accessToken/refreshToken)을 읽는다.
2. 만료됐으면 공개 클라이언트 ID로 refresh 후 **저장소에 되쓴다** (갱신 토큰이 회전되므로 되쓰지 않으면 CLI 로그인이 깨짐).
3. `GET https://api.anthropic.com/api/oauth/usage` (헤더 `anthropic-beta: oauth-2025-04-20`) 호출.
4. 응답의 `five_hour` / `seven_day*` 창별 `utilization`(%)과 `resets_at`을 표시.

※ 이 사용량 엔드포인트는 비공식(문서화되지 않은) API라 형식이 바뀔 수 있다. 앱은 `utilization` 필드를 가진 창을 동적으로 파싱하므로 웬만한 변경엔 버틴다.
