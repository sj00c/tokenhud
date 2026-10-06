# TokenHUD

Claude Code와 Codex의 남은 사용량을 macOS 메뉴바에 띄우는 SwiftBar 플러그인.

- 상태: stable
- 요구사항: macOS, SwiftBar 2.x, bash 3.2, jq, Swift 툴체인(아이콘 빌드용)
- 라이선스: MIT
- 문서: 이 파일이 전부

## 개요

- 해결 문제: 긴 작업을 시작하기 전에 한도가 남았는지 확인하려면 `claude`나 `codex`를 직접 띄워 `/usage`를 쳐야 함.
- 동작 방식: 각 공급자의 OAuth 토큰으로 사용량 API를 직접 조회해 메뉴바에 한 줄로 합성함.
- 적용 대상: Claude Code Max/Pro와 Codex 구독을 동시에 쓰며 주간 한도에 자주 닿는 사용자.
- 비적용 대상: API 종량제 과금 사용자. 이 도구는 구독 한도만 다루며 비용을 계산하지 않음.
- 서버가 `used_percent`를 직접 주므로 로컬 토큰 집계나 가격표를 두지 않음.
- CodexBar 대비 차이: Swift 앱이 아닌 단일 bash 스크립트이며 공급자를 Claude와 Codex 둘로 한정함.

## 설치

```sh
git clone https://github.com/sj00c/tokenhud.git ~/tokenhud
cd ~/tokenhud
swiftc -O assets/hudimg.swift -o assets/hudimg
```

- 사전 조건: `brew install jq`, SwiftBar 설치, `claude`와 `codex` CLI로 각각 1회 이상 로그인.
- SwiftBar 플러그인 폴더를 `~/tokenhud/plugin`으로 지정해야 함.
- `assets/`를 플러그인 폴더 안에 두면 안 됨. SwiftBar가 플러그인 폴더의 모든 파일을 실행하려 들어 앱이 죽음.
- 검증: `./plugin/tokenhud.1m.sh | head -1`이 `image=` 또는 숫자 타이틀을 출력함.

## 빠른 시작

```sh
./plugin/tokenhud.1m.sh
```

- 기대 출력: SwiftBar 형식 텍스트. 첫 줄이 메뉴바 타이틀, `---` 아래가 드롭다운.
- 소요 시간: 캐시 적중 시 0.1초 미만, API 조회 시 1~3초.

## 사용법

### 메뉴바 읽기

```
41/91  100
```

- 왼쪽: Claude 5시간 사용률 / 주간 사용률.
- 오른쪽: Codex 주간 사용률.
- 값이 `–`이면 해당 공급자의 데이터를 못 가져온 상태.
- 재로그인이 필요하면 타이틀 앞에 경고 표시가 붙음.

### 드롭다운 읽기

```
  5시간 █████░░░░░░░  42%↓ 1h 24m
  주간  ██████████░░  91%↑ 1d 14h
  주간 — 이 속도면 12h 49m 뒤 소진 (리셋은 1d 14h 뒤)
```

- `↓`: 시간 경과율보다 적게 씀. 리셋까지 여유 있음.
- `↑`: 경과율보다 많이 씀. 그대로면 리셋 전에 한도가 바닥남.
- 화살표가 없으면 창이 이미 소진됐거나 표본이 부족해 예측을 생략한 상태.
- 경고 줄은 과속인 창에만 붙고 소진 예상 시각과 리셋 시각을 같이 보여줌.

### 소진 예측 계산

- 경과율은 `(창 길이 - 남은 시간) / 창 길이`로 구함.
- 사용률이 경과율보다 크면 과속으로 판정함.
- 소진까지 남은 시간은 `(100 - 사용률) x 경과 시간 / 사용률`로 선형 외삽함.
- 이력 파일을 쓰지 않으므로 매 실행이 독립적으로 계산함.
- 창의 5%가 지나기 전에는 표본이 부족해 예측을 생략함.

### 강제 갱신

```sh
touch ~/.cache/tokenhud/.bust
```

- 드롭다운의 `지금 강제 갱신` 항목과 같은 동작.
- 캐시 파일을 지우지 않고 표식만 남기므로 API가 실패해도 직전 값이 남음.

### 절전 복귀 시 자동 갱신

```sh
sed "s|__TOKENHUD_DIR__|$PWD|" launchd/com.sj.tokenhud.wake.plist > ~/Library/LaunchAgents/com.sj.tokenhud.wake.plist
launchctl load ~/Library/LaunchAgents/com.sj.tokenhud.wake.plist
```

- 입력: `assets/wake-refresh.sh`가 벽시계 점프로 깨어남을, `scutil`로 네트워크 복구를 감시함.
- 출력: 키보드/마우스 입력이 들어온 뒤 `.bust` 표식과 `swiftbar://refreshallplugins` 호출.
- 다크웨이크(화면 꺼진 채 잠깐 깨는 것)에서는 발동하지 않음. 사람이 돌아오면 그때 한 번 갱신함.
- 주의: 절전에서 깬 직후 값이 몇 분간 낡은 채로 남는 문제를 없애기 위한 선택 구성.

### 상시 실행 비용

- 정상 상태에서는 TTL마다 한 번만 Keychain을 읽고 API를 조회함. 그 사이 실행은 `~/.cache/tokenhud/state.sh` 스냅샷만 읽어 외부 프로세스 1개(`date`)로 끝남.
- 오류·토큰 회전·재로그인 판정이 필요한 상태에서는 스냅샷을 쓰지 않고 매번 전체 경로를 돔.
- 키보드/마우스 입력이 `TOKENHUD_IDLE`초 이상 없으면 API를 조회하지 않음. 입력이 돌아오면 다음 실행에서 바로 조회함.
- 동시에 여러 실행이 겹쳐도 전체 경로는 하나만 돌고, 나머지는 직전 값을 그림.

## 설정

| 키 | 기본값 | 설명 |
| --- | --- | --- |
| `TOKENHUD_TTL` | `180` | API 재조회 간격(초). 분당 폴링하면 Anthropic이 429를 반환함 |
| `TOKENHUD_AUTOREFRESH` | `1` | OAuth 토큰 자동 회전 사용 여부 |
| `TOKENHUD_AUTOLOGIN_PROMPT` | `1` | 토큰 사망 시 재로그인 터미널을 1회 여는 기능 |
| `TOKENHUD_CLAUDE_REFRESH_WINDOW` | `900` | 만료 몇 초 전부터 회전을 시도할지 |
| `TOKENHUD_CLAUDE_REFRESH_COOLDOWN` | `600` | 회전 재시도 최소 간격(초) |
| `TOKENHUD_CODEX_REFRESH_WINDOW` | `900` | Codex 쪽 회전 시도 시점 |
| `TOKENHUD_CODEX_REFRESH_COOLDOWN` | `600` | Codex 쪽 회전 재시도 간격 |
| `TOKENHUD_ICON` | `logo` | `logo` 외의 값이면 이미지 없이 텍스트 타이틀만 그림 |
| `TOKENHUD_ASSETS` | `../assets` | `hudimg`와 로고 PNG가 있는 경로 |
| `TOKENHUD_IDLE` | `600` | 입력이 이 초만큼 없으면 API 조회를 쉼. `0`이면 항상 조회 |

- 우선순위: 환경변수 > 기본값. 설정 파일은 없음.
- 캐시 위치: `~/.cache/tokenhud/`
- 자격증명 출처: Claude는 Keychain `Claude Code-credentials`, 실패 시 `~/.claude/.credentials.json`. Codex는 `~/.codex/auth.json`.

## 제약과 알려진 문제

- 파일에서 읽은 자격증명으로는 토큰 회전을 하지 않음. Keychain을 못 읽으면 쓰지도 못해 회전 중 토큰을 유실할 위험이 있음.
- 회전 요청 중 네트워크가 끊기면 서버만 토큰을 교체한 상태가 되어 재로그인이 필요해짐.
- 다크웨이크에서는 회전을 미룸. 창이 2~5초라 요청 도중 다시 잠들면 위와 같은 유실이 발생함.
- 깨어 있음 판정은 최근 5분 내 키보드/마우스 입력으로 함. 입력 없이 오래 화면만 켜 둔 상태에서는 회전이 입력이 생길 때까지 미뤄짐.
- `hudimg`는 arm64로만 검증됨. Intel Mac에서는 `swiftc` 재빌드가 필요함.
- 추가분 항목은 리셋 창이 없어 소진 예측을 하지 않음.
- 모델별 주간 한도는 서버가 주는 이름을 그대로 표시하므로 이름이 예고 없이 바뀔 수 있음.

## 문제 해결

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| 메뉴바에 아무것도 없음 | SwiftBar가 플러그인을 빈 출력으로 래치함 | SwiftBar 재시작 |
| 메뉴바에 `SwiftBar`만 보임 | 플러그인 출력이 UTF-8로 안 읽혀 SwiftBar가 빈 출력으로 봄 | 플러그인 상단의 `LC_CTYPE` 설정이 있는지 확인 |
| `Keychain 접근 거부` | 백그라운드 프로세스의 Keychain ACL 거부 | 화면 잠금 해제 후 새로고침, 또는 `claude auth login` |
| `Keychain 못 읽음 — 파일 값으로 표시 중` | Keychain이 비었거나 껍데기만 남음 | `claude auth login`으로 자격증명 재생성 |
| `자동 갱신 토큰 없음` | 회전 유실로 refresh 토큰이 사라짐 | `claude auth login` 외에 복구 수단 없음 |
| `요청 과다 — 4m 뒤 재시도` | 서버가 429와 Retry-After를 반환함 | 표시된 시간까지 대기. 강제 갱신은 backoff를 늘림 |
| SwiftBar가 통째로 죽음 | 플러그인 폴더에 실행 불가 파일이 있음 | `assets/`를 플러그인 폴더 밖으로 옮김 |
| 아이콘 없이 텍스트만 나옴 | `assets/hudimg`가 없거나 실행 권한이 없음 | `swiftc -O assets/hudimg.swift -o assets/hudimg` |

- 회전 이력은 `~/.cache/tokenhud/claude-refresh.log`와 `codex-refresh.log`에 남음.

## 기여

- 이슈: https://github.com/sj00c/tokenhud/issues
- 문법 검사: `bash -n plugin/tokenhud.1m.sh`
- 동작 확인: `./plugin/tokenhud.1m.sh | grep -v image=`
- 아이콘 빌드: `swiftc -O assets/hudimg.swift -o assets/hudimg`

## 참고

- 소진 예측은 [CodexBar](https://github.com/steipete/CodexBar)의 pace projection과 [ai-usagebar](https://github.com/akitaonrails/ai-usagebar)의 pace 플레이스홀더에서 가져온 개념.
- 자격증명 파일 폴백과 레이트리밋 카운트다운 표시도 같은 두 프로젝트에서 가져옴.

## 라이선스

- MIT
- 전문: [LICENSE](LICENSE)
