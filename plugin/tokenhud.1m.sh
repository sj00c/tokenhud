#!/bin/bash
# <bitbar.title>Token HUD</bitbar.title>
# <bitbar.version>1.0</bitbar.version>
# <bitbar.desc>Claude Code 5시간/주간 + Codex 주간 사용량</bitbar.desc>
# <bitbar.dependencies>jq</bitbar.dependencies>
#
# Claude : Keychain OAuth 토큰 -> api.anthropic.com/api/oauth/usage
# Codex  : ~/.codex/auth.json  -> chatgpt.com/backend-api/wham/usage
# 둘 다 서버가 used_percent 를 직접 준다. 로컬 집계/가격표 없음.

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

# launchd 로 뜬 SwiftBar 는 LANG/LC_* 없이 플러그인을 실행한다(C 로케일).
# 그러면 bash 가 ${BAR_FULL:0:n} 을 바이트 단위로 잘라 █(3바이트)가 쪼개지고,
# SwiftBar 는 UTF-8 로 못 읽은 출력을 빈 값으로 보고 메뉴바 항목을 숨긴다(실측).
export LC_CTYPE="en_US.UTF-8"

CACHE_DIR="$HOME/.cache/tokenhud"
[ -d "$CACHE_DIR" ] || mkdir -p "$CACHE_DIR"

# 현재 시각을 한 번만 구한다.
#
# bash 3.2(/bin/bash) 에는 $EPOCHSECONDS 가 없어 date 를 써야 한다. 예전엔
# 필요할 때마다 `$(date +%s)` 를 불러 1회 실행에 13번이나 스폰했다(실측).
# 한 번의 실행 안에서 몇 백 밀리초 차이는 의미가 없고, 오히려 같은 기준시각을
# 써야 계산이 서로 어깤나지 않는다(예: 남은시간 계산 중 초가 넘어가는 경우).
# 표시용 로컬 시각도 같은 date 한 번에서 UTC 오프셋을 받아 산술로 만든다.
read -r NOW TZ_OFF <<<"$(date '+%s %z')"
TZ_SEC=$(( 10#${TZ_OFF:1:2} * 3600 + 10#${TZ_OFF:3:2} * 60 ))
[ "${TZ_OFF:0:1}" = "-" ] && TZ_SEC=$(( -TZ_SEC ))

# epoch -> 로컬 "HH:MM:SS". 서브셸 없이 전역 CLOCK 으로 돌려준다.
clock_set() {   # clock_set <epoch> -> $CLOCK
  local t=$(( ($1 + TZ_SEC) % 86400 ))
  [ "$t" -lt 0 ] && t=$(( t + 86400 ))
  printf -v CLOCK '%02d:%02d:%02d' $(( t / 3600 )) $(( t % 3600 / 60 )) $(( t % 60 ))
}

# 표시는 1분마다 하되 API 는 TTL 안에서 재사용한다.
# Anthropic 쪽은 분당 폴링하면 429 를 뱉는다(실측). 기본 180초.
TTL="${TOKENHUD_TTL:-180}"

FONT="font=Menlo size=12"
SMALL="font=Menlo size=11"

# 소진 예측에 쓰는 창 길이.
#
# 서버는 resets_at(끝나는 시각)만 주고 창이 몇 시간짜리인지는 안 준다.
# 둘 다 고정값이라 상수로 박아둔다(Claude 5시간/7일, Codex 7일).
WIN_5H=18000
WIN_7D=604800

# 드롭다운 색 — SwiftBar 는 "밝은테마색,어두운테마색" 을 받는다.
#
# macOS 메뉴는 반투명이라 뒤 창(예: 초록 터미널)이 그대로 비친다.
# 그래서 텍스트가 배경 쪽으로 끌려가며 대비가 깎인다.
# 픽셀을 직접 떠서 재보니 평범한 진한 색(#248A3D)도 실효 대비가 2.2~3.0 밖에
# 안 나왔다 -> 밝은테마 쪽은 한 단계 더 어둡게 잡아 3.5+ 를 확보한다.
# (어두운테마 쪽은 배경이 어두우므로 기존 시스템색 그대로 둔다)
C_OK="#14532D,#30D158"      # 정상
C_WARN="#8A3A00,#FF9F0A"    # 70%+
C_CRIT="#8E0009,#FF453A"    # 90%+ / 오류
C_DIM="#48484A,#8E8E93"     # 보조 텍스트
CURL=(curl -s --max-time 8)

# 토큰 회전(OAuth refresh)용 curl 은 조회용과 분리한다.
#
# 회전은 실패해도 되는 요청이 아니다. 서버는 요청을 받는 순간 옛 refresh 토큰을
# 죽이고 새 토큰을 응답에 담아 준다 -> 응답을 못 받으면 로그인이 통째로 날아간다.
# 조회용 8초 타임아웃을 그대로 쓰면 응답이 오는 중에 curl 이 손을 놓는다.
# (실측 8/23: 다크웨이크 5초 창에서 회전 요청 -> code=000 -> 다음 시도부터 영구
#  invalid_grant. 서버는 회전시켰는데 새 토큰을 못 받아 계정이 죽었다.)
# --connect-timeout 을 따로 주는 이유: 깨어난 직후 Wi-Fi 재연결 중이면 연결
# 자체가 늦다. 연결만 붙으면 응답은 끝까지 기다린다.
CURL_ROT=(curl -s --connect-timeout 10 --max-time 45)

# 캐시가 TTL 안이면 0(=API 안 때림)
#
# 강제 갱신은 캐시 파일을 지우지 않고 이 표식만 남긴다.
# 예전엔 rm 으로 지웠는데, 지운 직후 API 가 실패하면 캐시가 영구 소실돼
# 값을 아예 못 그렸다(실제로 claude.json 이 그렇게 날아갔다).
# 표식 방식이면 최악의 경우에도 직전 값이 남는다.
BUST="$CACHE_DIR/.bust"
bust_active() {
  [ -f "$BUST" ] || return 1
  # 표식은 1회용. 오래 남아 매분 API 를 때리지 않게 즉시 지운다.
  local m; m=$(stat -f %m "$BUST" 2>/dev/null || echo 0)
  rm -f "$BUST"
  [ $(( NOW - m )) -lt 120 ]
}
BUSTED=0
bust_active && BUSTED=1

# 서버가 429 로 Retry-After 를 주면 그 시각까지는 아예 안 때린다.
#
# 예전엔 429 를 그냥 에러로만 처리하고 다음 주기(TTL)에 또 때렸다. 그러면
# 레이트리밋 중에 계속 두드려 backoff 가 늘어나기만 했다. Retry-After 를
# 표식에 적어두고, 그 시각 전에는 in_backoff 가 참이라 조회를 건너뛴다.
# bust(강제 갱신)보다도 우선한다 — 깨어남 폭풍이 429 서버를 두드리면 안 된다.
in_backoff() {   # in_backoff <claude|codex>
  local f="$CACHE_DIR/.$1_backoff_until" until
  [ -f "$f" ] || return 1
  until=$(<"$f") ; until="${until:-0}"
  [ "${until%.*}" -gt "$NOW" ] 2>/dev/null
}

# backoff 가 언제 풀리는지 사람이 읽게. 드롭다운에만 쓰이는 느린 경로라
# 서브쉘 쓰는 human_left 를 그대로 빌려쓴다.
backoff_left() {   # backoff_left <claude|codex>
  local f="$CACHE_DIR/.$1_backoff_until" until
  [ -f "$f" ] || { echo "잠시 후 자동 복구"; return; }
  until=$(<"$f") ; until="${until:-0}" ; until="${until%.*}"
  [ "$until" -gt "$NOW" ] 2>/dev/null || { echo "잠시 후 자동 복구"; return; }
  echo "$(human_left $(( until - NOW ))) 뒤 재시도"
}
set_backoff() {   # set_backoff <claude|codex> <초>
  local secs="${2:-300}"
  # 상한 30분: 서버가 비정상적으로 큰 값을 줘도 화면이 30분 넘게 안 멈추게.
  [ "$secs" -gt 1800 ] 2>/dev/null && secs=1800
  printf '%s\n' "$(( NOW + secs ))" > "$CACHE_DIR/.$1_backoff_until" 2>/dev/null
}
clear_backoff() { rm -f "$CACHE_DIR/.$1_backoff_until" 2>/dev/null; }

# 마지막 키보드/마우스 입력 뒤 몇 초가 지났나. ioreg 1회(≈20ms), 한 실행에 한 번만 잔다.
#
# 화면 전원 상태(IODisplayWrangler CurrentPowerState)는 Apple Silicon/macOS 15 에서
# 더는 노출되지 않는다(실측 10/6) -> 사람이 있느냐는 HID 유휴 시간으로 판정한다.
# 다크웨이크는 입력이 없으므로 유휴 시간이 잠들기 전부터 계속 늘어 있다.
IDLE_SECS=""
idle_secs_set() {   # -> $IDLE_SECS (못 읽으면 아주 큰 값 = 자리에 없음으로 본다)
  [ -n "$IDLE_SECS" ] && return
  local out v
  out=$(ioreg -c IOHIDSystem -d 4 -r -k HIDIdleTime 2>/dev/null)
  v="${out#*\"HIDIdleTime\" = }"; v="${v%%[!0-9]*}"
  if [ -n "$v" ] && [ "$v" != "$out" ]; then IDLE_SECS=$(( v / 1000000000 )); else IDLE_SECS=999999; fi
}

# 사용자가 TOKENHUD_IDLE 초 이상 자리를 비웠나. 0 이면 판정하지 않는다(항상 조회).
IDLE_LIMIT="${TOKENHUD_IDLE:-600}"
user_idle() {
  [ "$IDLE_LIMIT" -gt 0 ] 2>/dev/null || return 1
  idle_secs_set
  [ "$IDLE_SECS" -ge "$IDLE_LIMIT" ]
}

# 공급자별 데이터 시각(캐시 mtime). 스냅샷 유효기간과 드롭다운 표시에 쓴다.
MT_claude=0; MT_codex=0
# 자리를 비워 조회를 건너뛴 공급자가 있으면 1.
IDLE_SKIP=0

fresh() {
  local f="$CACHE_DIR/$1.json" m
  # backoff 중에는 캐시가 낙았어도 '신선한 셈' 치고 조회를 막는다.
  #
  # 단, 사용자가 메뉴에서 직접 "지금 강제 갱신"을 누른 경우는 예외다.
  # 예전엔 backoff 가 bust 보다 무조건 우선이라, 누르면 표식만 소모되고
  # 조회는 안 도는 무반응 버튼이 됐다(재로그인 직후가 정확히 이 상황 —
  # 토큰은 멀줦한데 직전 429 로 걸린 backoff 가 남아 몇 분간 옆날 값을 보였다).
  # 사용자가 명시적으로 누른 1회성 요청은 backoff 를 끊고 통과시킨다.
  # 자동 주기(BUSTED=0)는 예전대로 backoff 를 존중한다.
  if in_backoff "$1"; then
    [ "$BUSTED" = 1 ] || return 0
    clear_backoff "$1"
  fi
  [ -f "$f" ] || return 1
  m=$(stat -f %m "$f" 2>/dev/null) || return 1
  printf -v "MT_$1" '%s' "$m"
  # 한 공급자의 주기가 끝났으면(ROUND_DUE) 다른 쪽도 주기의 절반을 넘겼을 때 같이
  # 받는다. 둔의 주기가 어긋나면 TTL 마다 전체 경로가 두 번 돈다. 공급자별 호출 빈도는
  # 그대로(TTL 당 1회)이고, 오류 상태(스냅샷 없음)에서는 맞추지 않는다.
  [ "$BUSTED" = 1 ] || [ $(( NOW - m )) -ge "$TTL" ] || \
    { [ "$ROUND_DUE" = 1 ] && [ $(( NOW - m )) -ge $(( TTL / 2 )) ]; } || return 0
  # 조회할 차례라도 사람이 없으면 아무도 안 보는 값을 위해 서버를 치지 않는다.
  # 밤새 켜둔 맥이 180초마다 두 곳을 두드리던 게(하루 960회) 여기서 0이 된다.
  # 강제 갱신(.bust)도 여기서 멈춘다 — 다크웨이크 때 워처가 남긴 표식은 입력이
  # 없다. 메뉴에서 직접 누른 갱신은 입력이 방금 있었으니 통과한다.
  if user_idle; then IDLE_SKIP=1; return 0; fi
  return 1
}

# 캐시가 아직 "말이 되는" 값인지 판정한다.
#
# 나이만 보면 API 가 잠깐 죽어도 곧장 흐려지는데, 그건 과하다.
# 사용률은 리셋 시각 전까지 단조 증가만 하므로,
# 리셋이 안 지났으면 캐시값은 여전히 유효한 하한이다.
# -> 리셋 전이면 '유효', 리셋이 지났으면 '못 믿음'.
cache_still_valid() {   # cache_still_valid <claude|codex>
  local f="$CACHE_DIR/$1.json" now
  [ -s "$f" ] || return 1
  now=$NOW
  local resets
  if [ "$1" = "claude" ]; then
    # ISO8601 -> epoch (가장 이른 리셋 = 5시간 창)
    resets=$(jq -r '[.five_hour.resets_at, .seven_day.resets_at]
                    | map(select(. != null)) | .[0] // empty' "$f" 2>/dev/null)
    [ -z "$resets" ] && return 1
    iso_epoch_set "$resets"; resets=$EPOCH
  else
    resets=$(jq -r '[.rate_limit.primary_window, .rate_limit.secondary_window]
                    | map(select(. != null) | .reset_at) | min // empty' "$f" 2>/dev/null)
    resets=${resets%.*}
  fi
  [ -n "$resets" ] || return 1
  [ "$now" -lt "$resets" ]
}

# ── 유틸 ──────────────────────────────────────────────────────────────
# 남은 시간 사람이 읽게: 3720 -> "1h 2m"
human_left() {
  local s=$1
  [ -z "$s" ] || [ "$s" = "null" ] && { echo "-"; return; }
  s=${s%.*}
  [ "$s" -le 0 ] 2>/dev/null && { echo "곳"; return; }
  local d=$((s/86400)) h=$((s%86400/3600)) m=$((s%3600/60))
  if   [ $d -gt 0 ]; then echo "${d}d ${h}h"
  elif [ $h -gt 0 ]; then echo "${h}h ${m}m"
  else                    echo "${m}m"; fi
}

# human_left 의 서브셸 없는 판. 행 렌더링은 매분 도는 경로라 여기어만 쓴다.
# (cache_age 처럼 가끔 불리는 곳은 읽기 쉬운 원본 human_left 를 그대로 쓴다)
human_left_set() {   # human_left_set <초> -> $LEFT
  local s=$1
  if [ -z "$s" ] || [ "$s" = "null" ]; then LEFT="-"; return; fi
  s=${s%.*}
  if [ "$s" -le 0 ] 2>/dev/null; then LEFT="곳"; return; fi
  local d=$((s/86400)) h=$((s%86400/3600)) m=$((s%3600/60))
  if   [ $d -gt 0 ]; then LEFT="${d}d ${h}h"
  elif [ $h -gt 0 ]; then LEFT="${h}h ${m}m"
  else                    LEFT="${m}m"; fi
}

# ISO8601 -> epoch (소수점/타임존 흡수)
#
# 예전엔 `date -j -u -f ...` 를 썼는데, 이게 호출마다 프로세스를 띄운다.
# 리셋 시각이 항목마다 있어서 한 번 그릴 때 3~4회씩 불렸다.
# 입력은 항상 고정 포맷(YYYY-MM-DDTHH:MM:SS[.fff][Z])이라 산술로 끝난다.
#
# days_from_civil (Howard Hinnant) — 그레고리력 윤년 규칙(4/100/400)을 그대로 따른다.
# BSD date 와 1,015건(윤년 2024/2000/2100 · 경계값 · 랜덤 1000건) 전수 일치 확인했다.
# 결과는 전역 EPOCH 으로 돌려준다. 명령치환으로 받으면 호출마다 서브셸이 뜬다.
iso_epoch_set() {   # iso_epoch_set <ISO8601> -> $EPOCH (못 읽으면 빈 값)
  EPOCH=""
  local iso="${1%%.*}"
  { [ -z "$iso" ] || [ "$1" = "null" ]; } && return
  iso="${iso%Z}"
  # 포맷이 예상과 다르면 조용히 빈 값(호출쪽이 이미 빈 값을 처리한다).
  [ ${#iso} -lt 19 ] && return
  local y=$((10#${iso:0:4})) mo=$((10#${iso:5:2})) d=$((10#${iso:8:2}))
  local H=$((10#${iso:11:2})) M=$((10#${iso:14:2})) S=$((10#${iso:17:2}))
  local yy=$y era yoe doy doe days
  [ $mo -le 2 ] && yy=$((y-1))
  if [ $yy -ge 0 ]; then era=$((yy/400)); else era=$(( (yy-399)/400 )); fi
  yoe=$(( yy - era*400 ))
  if [ $mo -gt 2 ]; then doy=$(( (153*(mo-3)+2)/5 + d-1 ))
  else                  doy=$(( (153*(mo+9)+2)/5 + d-1 )); fi
  doe=$(( yoe*365 + yoe/4 - yoe/100 + doy ))
  days=$(( era*146097 + doe - 719468 ))
  EPOCH=$(( days*86400 + H*3600 + M*60 + S ))
}

# JWT payload 의 exp. Codex access token 만료를 API 호출 전에 판정한다.
jwt_exp() {
  local p="${1#*.}"
  p="${p%%.*}"
  [ -n "$p" ] || return
  case $(( ${#p} % 4 )) in 2) p="${p}==";; 3) p="${p}=";; esac
  printf '%s' "$p" | tr '_-' '/+' | base64 -d 2>/dev/null | jq -r '.exp // empty' 2>/dev/null
}

# 갱신 실패 때 매분 같은 OAuth 요청을 쏘지 않게 하는 공용 쿨다운.
# 준비되면 표식을 먼저 남긴다. 실패해도 다음 재시도는 cooldown 뒤다.
refresh_ready() {   # refresh_ready <표식파일> [초]
  local f="$1" cooldown="${2:-600}" last=0
  [ -f "$f" ] && last=$(stat -f %m "$f" 2>/dev/null || echo 0)
  [ $(( NOW - last )) -ge "$cooldown" ] || return 1
  touch "$f"
}

# 지금 토큰을 회전시켜도 되는 상태인가.
#
# 다크웨이크(맥이 화면 끄고 몇 초만 깨어 백그라운드 일 하는 상태)에서는
# 회전을 걸면 안 된다. 창이 2~5초짜리라 요청 도중에 다시 잠들고,
# 그러면 "서버는 회전시켰는데 새 토큰은 못 받은" 상태로 로그인이 죽는다.
# (8/23 실측: 19:15:30 다크웨이크 5초 창 -> 19:15:31 회전 -> code=000 -> 계정 사망)
#
# 판정: 최근 5분 안에 키보드/마우스 입력이 있었으면 사용자가 실제로 깨운 것.
#
# 예전 판정(IODisplayWrangler CurrentPowerState=4)은 macOS 15 에서 항목 자체가
# 사라져 항상 거짓이었고, 뒷부분 assertion 판정만 남아 있었다. 그런데
# PreventUserIdleSystemSleep 은 브라우저 재생·다운로드 같은 앱도 걸어두는 것이라
# 다크웨이크에서도 참이 될 수 있다 — 막으려던 바로 그 사고의 구멍이다.
# 입력 유무는 다크웨이크에서 절대 참이 안 된다. 틀려도 회전이 미뤄질 뿐이다.
system_awake() {
  idle_secs_set
  [ "$IDLE_SECS" -lt 300 ]
}

# 회전은 잠들면 안 되는 구간이다. caffeinate 로 그 구간만 붙잡는다.
# -i(유휴 슬립 방지) -m(디스크 슬립 방지). 명령이 끝나면 assertion 도 같이 풀린다.
# caffeinate 가 없거나 실패하면 그냥 원래 명령을 실행한다(기능 손실 없음).
hold_awake() {   # hold_awake <명령...>
  if [ -x /usr/bin/caffeinate ]; then
    /usr/bin/caffeinate -i -m "$@"
  else
    "$@"
  fi
}

# OAuth 응답의 에러 이름을 뽑는다.
#
# 두 서버가 모양이 다르다:
#   Anthropic : {"error":"invalid_grant", "error_description":"..."}   <- 문자열
#   OpenAI    : {"error":{"type":"..."}} 또는 {"error":"..."}          <- 섞임
# 예전 필터 `.error.type // .error` 는 문자열에 .type 을 붙이는 순간 jq 가
# "Cannot index string" 로 죽는다. // 는 에러를 못 받으므로 폴백도 안 탄다
# -> 모든 실패가 err= 빈칸으로 기록돼 원인 파악이 몇 달간 불가능했다(실측 8/23).
err_name() {   # err_name <응답본문>
  printf '%s' "$1" | jq -r '
    if   (.error|type) == "object" then (.error.type // .error.code // "")
    elif (.error|type) == "string" then .error
    else (.error_code // .code // "") end' 2>/dev/null
}

# 응답의 사람이 읽을 설명. 로그에만 쓴다.
err_desc() {   # err_desc <응답본문>
  printf '%s' "$1" | jq -r '
    if (.error|type) == "object" then (.error.message // .error_description // "")
    else (.error_description // .message // "") end' 2>/dev/null
}

# refresh 토큰이 서버에서 죽었다고 확정된 상태를 기록한다.
#
# 죽은 토큰으로 10분마다 계속 두드려도 절대 살아나지 않는다. 재로그인 말고는 없다.
# 표식에 토큰 지문(해시)을 같이 적어두면, 재로그인해서 토큰이 바뀌는 순간
# 지문이 달라져 표식이 저절로 무효가 된다 -> 수동으로 지울 필요가 없다.
tok_fp() { printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -c1-16; }

mark_dead() {   # mark_dead <claude|codex> <refresh토큰>
  printf '%s\n' "$(tok_fp "$2")" > "$CACHE_DIR/.$1_refresh_dead" 2>/dev/null
}

is_dead() {   # is_dead <claude|codex> <refresh토큰>
  local f="$CACHE_DIR/.$1_refresh_dead" saved
  [ -f "$f" ] || return 1
  saved=$(<"$f")
  [ "$saved" = "$(tok_fp "$2")" ]
}

clear_dead() { rm -f "$CACHE_DIR/.$1_refresh_dead" 2>/dev/null; }

# Claude refresh 토큰이 죽으면 같은 토큰당 한 번만 로그인 창을 연다.
# 매분 실행되는 SwiftBar 플러그인이므로 표식 없이는 Terminal 창이 계속 늘어난다.
prompt_claude_login_if_needed() {
  local marker="$CACHE_DIR/.claude_login_prompted" refresh fp saved=""

  case "$c_refresh_err" in
    refresh-expired|refresh-missing|refresh-dead) ;;
    *) rm -f "$marker" 2>/dev/null; return ;;
  esac
  [ "${TOKENHUD_AUTOLOGIN_PROMPT:-1}" = 1 ] || return
  system_awake || return

  refresh=$(printf '%s' "$c_tok" | jq -r '.claudeAiOauth.refreshToken // empty' 2>/dev/null)
  if [ -n "$refresh" ]; then fp=$(tok_fp "$refresh"); else fp="missing"; fi
  [ -f "$marker" ] && saved=$(<"$marker")
  [ "$saved" = "$fp" ] && return

  printf '%s\n' "$fp" > "$marker" 2>/dev/null || return
  /usr/bin/osascript \
    -e 'tell application "Terminal" to activate' \
    -e 'tell application "Terminal" to do script "/opt/homebrew/bin/claude auth login"' \
    >/dev/null 2>&1 || rm -f "$marker" 2>/dev/null
}

# 갱신 시도/결과 기록. 조용한 실패가 이틀치 갱신 창을 통째로 날린 적이 있다(8/12~14).
rlog() {   # rlog <claude|codex> <메시지>
  local f="$CACHE_DIR/$1-refresh.log"
  echo "$(date '+%m-%d %H:%M:%S') $2" >> "$f"
  [ "$(wc -l < "$f" 2>/dev/null || echo 0)" -gt 200 ] && \
    { tail -120 "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"; }
}

# 12칸 게이지
#
# 예전엔 12회 루프를 돌며 문자를 붙였고, 호출마다 명령치환(서브셸)이 뗴다.
# 가능한 문자열은 13가지뿐이니 미리 깔아두고 잘라 쓴다.
# 결과는 전역 변수로 넘겨 서브셸 자체를 없앨다.
BAR_FULL="████████████"
BAR_EMPTY="░░░░░░░░░░░░"
bar_set() {   # bar_set <pct> -> $BAR
  local pct=${1%.*}
  [ -z "$pct" ] && pct=0
  [ "$pct" -gt 100 ] 2>/dev/null && pct=100
  [ "$pct" -lt 0 ] 2>/dev/null && pct=0
  local fill=$((pct*12/100))
  BAR="${BAR_FULL:0:fill}${BAR_EMPTY:0:$((12-fill))}"
}

# 임계값 색 (밝은/어두운 테마 쌍). 서브셸 없이 전역으로 돌려준다.
color_set() {   # color_set <pct> -> $COLOR
  local pct=${1%.*}
  [ -z "$pct" ] && pct=0
  if   [ "$pct" -ge 90 ] 2>/dev/null; then COLOR="color=$C_CRIT"
  elif [ "$pct" -ge 70 ] 2>/dev/null; then COLOR="color=$C_WARN"
  else COLOR="color=$C_OK"; fi
}

# 소진 예측(pace) — CodexBar / ai-usagebar 에서 가져온 개념.
#
# 서버는 "지금 몇 % 썼다"만 준다. 정작 궁금한 건 "리셋 전에 바닥나느냐"다.
# 주간 90% 가 위험한지 아닌지는 숫자만 봐서는 모른다 — 리셋까지 1시간 남았으면
# 여유고, 2일 남았으면 이미 끝장난 것이다.
#
# 창의 길이를 알면 추가 데이터 없이 계산된다:
#   경과율 = (창길이 - 남은시간) / 창길이
#   쓴비율 > 경과율  ->  과속. 그대로면 리셋 전에 소진된다.
#   선형 외삽: 소진까지 = (100 - 쓴%) x 경과시간 / 쓴%
#
# 이력 파일이 필요 없다는 게 핵심이다. SwiftBar 는 매분 새 프로세스라 상태를
# 들고 있을 수가 없고, 버스트 평균을 내려면 쓸데없는 쌓기 파일이 하나 늘어난다.
# 매 실행이 독립적으로 계산한다.
PACE_ARROW=" "; PACE_BURN=""; PACE_WARN=""
pace_set() {   # pace_set <쓴%> <남은초> <창길이초> -> $PACE_ARROW $PACE_BURN
  PACE_ARROW=" "; PACE_BURN=""
  local pct="${1%.*}" left="${2%.*}" win="$3" elapsed
  [ -n "$pct" ] && [ -n "$left" ] && [ -n "$win" ] || return
  [ "$win" -gt 0 ] 2>/dev/null || return
  [ "$left" -gt 0 ] 2>/dev/null || return          # 창이 이미 끝났다
  # 이미 소진된 창은 예측할 게 없다(행 자체가 빨간 100% 로 뜬다).
  [ "$pct" -ge 100 ] 2>/dev/null && return
  elapsed=$(( win - left ))
  # 창 시작 직후엔 표본이 너무 짧아 외삽이 미쳐 날뛴다.
  # 5시간 창에서 1분 만에 3% 를 쓰면 "9분 뒤 소진"이 나온다 — 거짓말이다.
  # 창의 5% 가 지나기 전에는 아무 말도 하지 않는다.
  [ "$elapsed" -gt $(( win / 20 )) ] 2>/dev/null || return
  if [ "${pct:-0}" -le 0 ] 2>/dev/null; then PACE_ARROW="↓"; return; fi

  # 경과율과 비교. 나눗셈 오차를 피하려고 양변에 곱해서 비교한다.
  #   pct/100 > elapsed/win   <=>   pct*win > 100*elapsed
  if [ $(( pct * win )) -gt $(( 100 * elapsed )) ]; then
    PACE_ARROW="↑"
    PACE_BURN=$(( (100 - pct) * elapsed / pct ))
    # 여기에 "리셋이 먼저 오면 경고 생략" 가드를 놓았었는데, 도달할 수 없는
    # 분기였다. 과속이면 소진은 반드시 리셋 전에 온다 — 식으로 똑같다:
    #   burn < left
    #   (100-pct)*elapsed/pct < win - elapsed
    #   (100-pct)*elapsed     < pct*win - pct*elapsed
    #   100*elapsed           < pct*win          <- 위의 과속 조건 그자체
    # 즉 바로 위 if 가 참이면 burn < left 도 항상 참이다. 가드를 남겨두면
    # 읽는 사람이 "어떤 과속은 경고가 안 뜼나 보다"고 오해하게 된다.
  else
    PACE_ARROW="↓"
  fi
}

# 한 줄 출력: 라벨 / 게이지 / % / 과속표시 / 리셋까지 남은 시간
row() {   # row <라벨> <%> <남은초> [창길이초]
  local label="$1" pct="$2" left="$3" win="$4"
  if [ -z "$pct" ] || [ "$pct" = "null" ]; then
    printf '  %-7s ░░░░░░░░░░░░    -- | %s color=%s\n' "$label" "$FONT" "$C_DIM"
    return
  fi
  # 네 헬퍼 모두 전역 변수로 받는다 — 예전엔 행마다 명령치환 3개(=서브셸 3개)를
  # 뗠워 행이 5개면 15개가 떴다. 내장 연산만으로 끝나는 일이라 전부 없앨다.
  bar_set "$pct"; human_left_set "$left"; color_set "$pct"; pace_set "$pct" "$left" "$win"
  # 화살표는 빈값일 때도 공백 1칸이라 아래행과 숫자 열이 안 틀어진다.
  printf '  %-7s %s %3d%%%s %s | %s %s\n' \
    "$label" "$BAR" "${pct%.*}" "$PACE_ARROW" "$LEFT" "$FONT" "$COLOR"
  # 리셋 전에 바닥나는 창은 모았다가 공급자 블록 끝에서 한꺼번에 경고한다.
  [ -n "$PACE_BURN" ] && PACE_WARN="${PACE_WARN}${label}|${PACE_BURN}|${left}"$'\n'
}

# 모인 소진 경고를 토해낸다. 공급자 행들 바로 아래에서 불린다.
pace_warn_flush() {
  local label burn left b r
  [ -n "$PACE_WARN" ] || return
  while IFS='|' read -r label burn left; do
    [ -n "$label" ] || continue
    human_left_set "$burn"; b="$LEFT"
    human_left_set "$left"; r="$LEFT"
    echo "  ⚡︎ $label — 이 속도면 $b 뒤 소진 (리셋은 $r 뒤) | $FONT color=$C_CRIT"
  done <<<"$PACE_WARN"
  PACE_WARN=""
}

# ── Claude ────────────────────────────────────────────────────────────
c5_pct=""; c5_e=""; c7_pct=""; c7_e=""; c_err=""; c_plan=""; c_refresh_err=""
c_json=""; c_scoped=""; cx_on=""; cx_pct=""; c_rexp_g=""; c_rdays=""; c_exp_s=0

# Claude OAuth 를 플러그인이 직접 회전시킨다. Codex 쪽과 같은 구조.
#
# 주소가 전부다 — 셋 다 같은 API 처럼 보이지만 결과가 다르다(실측 8/18):
#   console.anthropic.com/v1/oauth/token -> 429
#   platform.claude.com/v1/oauth/token   -> 429
#   api.anthropic.com/v1/oauth/token     -> 200
# (예전에 "직접 치면 429"라고 포기하고 claude CLI 를 대신 띄웠던 건 host 문제였다.
#  CLI 스폰은 이틀간 조용히 실패하며 재로그인까지 갔으므로 폐기.)
#
# 응답은 refresh 토큰까지 매번 회전시키고 30일 수명을 새로 준다
# -> 만료 전에 계속 회전시키는 한 재로그인이 영영 필요 없다.
#
# Keychain 값은 반드시 한 줄 JSON(-c) 이어야 한다. 개행이 섞이면
# `security -w` 가 hex 덤프를 돌려줘 Claude Code 포함 전부가 못 읽는다(실측).
claude_refresh_if_needed() {   # claude_refresh_if_needed <access-exp-epoch초>
  local exp="$1" now refresh req raw code body err current merged
  local stamp="$CACHE_DIR/.claude_refresh_attempt" lock="$CACHE_DIR/.claude_refresh_lock"

  [ "${TOKENHUD_AUTOREFRESH:-1}" = 1 ] || return
  now=$NOW

  # 파일에서 읽은 자격증명은 절대 회전시키지 않는다.
  #
  # 파일 폴백은 Keychain 을 못 읽을 때 값이라도 보여주려는 장치지,
  # 회전 주도권을 가져오는 장치가 아니다. 두 가지가 동시에 걸린다:
  #  - Keychain 을 못 읽었다면 회전 결과를 써넣는 것도 실패한다
  #    -> 서버만 회전하고 새 토큰은 잃는다 = 계정 사망(오늘 아침 그 사고).
  #  - 파일은 대개 오래된 스냅샷이라 이미 회전되어 죽은 refresh 토큰일 수 있다
  #    -> 그걸로 회전을 시도하면 멀줦한 Keychain 쪽까지 invalid_grant 으로 끌고 간다.
  # 회전은 Claude Code 가 하게 두고, 우린 보여주기만 한다.
  if [ "${c_src:-keychain}" = "file" ]; then
    c_refresh_err="refresh-readonly"; return
  fi

  # 사망 판정은 쿨다운보다도, 만료 검사보다도 앞에 둔다.
  #
  # 예전엔 이 두 검사가 refresh_ready 뒤에 있었다. 그러면 표식이 살아 있는
  # 10분 동안 함수가 조기 반환해 c_refresh_err 이 아예 안 채워진다
  # -> 드롭다운은 "자동 갱신 재시도 중"을 계속 띄우고 메뉴바 경고도 안 뜬다.
  # 실제로는 재시도가 아니라 재로그인 말고는 방법이 없는 상태였다(실측 8/23 22:35).
  # 둘 다 네트워크를 안 쓰는 로컬 판정이라 쿨다운으로 막을 이유가 없다.
  #
  # 만료 검사(`exp > 0`)보다 앞에 둬야 하는 이유는 더 고약하다. 회전이 깨지면
  # keychain 에 accessToken="" / refreshToken="" / expiresAt=0 인 껍데기가 남는데,
  # 그 상태에서 `exp > 0` 가드에 먼저 걸리면 c_refresh_err 이 빈 채로 반환된다
  # -> prompt_claude_login_if_needed 의 case 가 안 맞아 재로그인 창이 영영 안 뜨고,
  #    드롭다운도 사유를 못 적는다. 메뉴바만 `-/-` 로 굳은 채 방치된다.
  # (실측 9/16: 05:56 회전 유실 -> 07:03 invalid_grant -> 17:14 까지 10시간 무음)
  # 토큰이 없으면 만료 시각이 뭐든 자동 갱신은 불가능하다 -> 여기서 먼저 끊는다.
  refresh=$(echo "$c_tok" | jq -r '.claudeAiOauth.refreshToken // empty')
  if [ -z "$refresh" ]; then
    c_refresh_err="refresh-missing"
    # 표시는 매분 하되, 로그만 쿨다운 간격으로 남긴다.
    refresh_ready "$stamp" "${TOKENHUD_CLAUDE_REFRESH_COOLDOWN:-600}" && rlog claude "refresh-missing"
    return
  fi

  # 이 토큰은 서버가 이미 죽었다고 확정한 것이다. 더 두드려도 안 살아난다.
  # 재로그인해서 토큰이 바뀌면 지문이 달라져 이 표식은 저절로 풀린다.
  if is_dead claude "$refresh"; then
    c_refresh_err="refresh-dead"; return
  fi

  # expiresAt=0 은 "아직 안 만료됨"이 아니라 access 토큰이 아예 없다는 뜻이다.
  # refresh 토큰은 살아 있으므로 창을 기다릴 게 아니라 지금 바로 회전시킨다.
  if [ "${exp:-0}" -gt 0 ] 2>/dev/null; then
    [ "$exp" -le $((now + ${TOKENHUD_CLAUDE_REFRESH_WINDOW:-900})) ] || return
  fi

  refresh_ready "$stamp" "${TOKENHUD_CLAUDE_REFRESH_COOLDOWN:-600}" || return

  if ! mkdir "$lock" 2>/dev/null; then
    local lm=0
    [ -d "$lock" ] && lm=$(stat -f %m "$lock" 2>/dev/null || echo 0)
    if [ $((now - lm)) -ge 600 ]; then
      rmdir "$lock" 2>/dev/null || return
      mkdir "$lock" 2>/dev/null || return
    else
      return
    fi
  fi

  # 다크웨이크에서는 회전하지 않는다. 창이 2~5초라 요청 도중 다시 잠들고,
  # 그러면 서버만 회전시킨 채 새 토큰을 못 받아 계정이 죽는다(8/23 실측).
  # 화면이 켜질 때까지 미룬다 — access 토큰은 8시간짜리라 급할 이유가 없다.
  if ! system_awake; then
    rlog claude "skip — 다크웨이크(회전 보류)"
    rm -f "$stamp" 2>/dev/null   # 쿨다운 소모 없이 깨어난 뒤 바로 재시도
    rmdir "$lock"; return
  fi

  # 토큰은 ps 노출을 피해 stdin 으로 넘긴다(Codex 쪽과 동일).
  req=$(printf '%s' "$refresh" | jq -Rs \
    '{grant_type:"refresh_token",refresh_token:.,client_id:"9d1c250a-e61b-44d9-88ed-5944d1962f5e"}')
  # 회전 구간은 caffeinate 로 잠들지 못하게 붙잡고, 넉넉한 타임아웃을 쓴다.
  raw=$(printf '%s' "$req" | hold_awake "${CURL_ROT[@]}" -w '\n%{http_code}' \
          -H "Content-Type: application/json" --data-binary @- \
          "https://api.anthropic.com/v1/oauth/token" 2>/dev/null)
  code="${raw##*$'\n'}"; body="${raw%$'\n'*}"
  [ "$raw" = "$code" ] && body=""

  if [ "$code" = 200 ] \
     && printf '%s' "$body" | jq -e '.access_token | type == "string" and length > 0' >/dev/null 2>&1; then
    # 왕복 사이 Claude Code 가 먼저 회전시켰으면 이 응답을 버린다(회전 충돌 방지).
    current=$(security find-generic-password -s "Claude Code-credentials" -a "$USER" -w 2>/dev/null)
    [ -z "$current" ] && current="$c_tok"
    if [ "$(echo "$current" | jq -r '.claudeAiOauth.refreshToken // empty')" = "$refresh" ]; then
      merged=$( { printf '%s\n' "$current"; printf '%s' "$body"; } | jq -s -c --argjson now "$now" '
        .[0] as $t | .[1] as $r | $t
        | .claudeAiOauth.accessToken = $r.access_token
        | if ($r.refresh_token // "") != "" then .claudeAiOauth.refreshToken = $r.refresh_token else . end
        | .claudeAiOauth.expiresAt = (($now + $r.expires_in) * 1000)
        | if ($r.refresh_token_expires_in // 0) > 0
            then .claudeAiOauth.refreshTokenExpiresAt = (($now + $r.refresh_token_expires_in) * 1000) else . end
        | if ($r.scope // "") != "" then .claudeAiOauth.scopes = ($r.scope | split(" ")) else . end' 2>/dev/null)
      if [ -n "$merged" ] \
         && security add-generic-password -U -a "$USER" -s "Claude Code-credentials" -w "$merged" 2>/dev/null; then
        c_tok="$merged"; c_rotated=1   # 이번 실행부터 바로 새 토큰을 쓴다
        clear_dead claude
        rlog claude "ok (access +$(( $(printf '%s' "$body" | jq -r '.expires_in') / 3600 ))h, refresh 회전)"
      else
        # 서버 회전은 이미 끝났는데 저장이 실패하면 로그인 유실로 간다. 제일 크게 알린다.
        c_refresh_err="refresh-save"; rlog claude "SAVE FAIL — 회전된 토큰을 keychain 에 못 씀"
      fi
    else
      c_tok="$current"; c_rotated=1; rlog claude "skip — 다른 프로세스가 먼저 회전"
    fi
  else
    err=$(err_name "$body")
    case "$code" in
      400|401|403)
        # invalid_grant = 서버가 이 refresh 토큰을 모른다(만료/회전 유실/취소).
        # 재로그인 말고는 복구 수단이 없으므로 사망 표식을 남겨 재시도를 멈춘다.
        case "$err" in
          invalid_grant|invalid_request|invalid_client)
            mark_dead claude "$refresh"; c_refresh_err="refresh-dead" ;;
          *) c_refresh_err="refresh-expired" ;;
        esac ;;
      "")          c_refresh_err="refresh-unreachable" ;;
      *)           c_refresh_err="refresh-http-$code" ;;
    esac
    rlog claude "fail code=$code err=${err:-?} desc=$(err_desc "$body")"
  fi
  rmdir "$lock"
}

# 자격증명은 Keychain 이 1순위, `~/.claude/.credentials.json` 이 2순위다.
#
# CodexBar 도 ai-usagebar 도 둘 다 이 파일을 같이 본다. 그럴 이유가 있다:
#  - SwiftBar 는 GUI 앱의 자식으로 돌아서 security 가 ACL 프롬프트 없이
#    그냥 실패할 수 있다. 그러면 토큰이 멀줦해도 화면은 "Keychain 접근 거부"만 띄운다.
#  - Claude Code 가 회전에 실패하면 Keychain 에 accessToken="" / refreshToken="" 인
#    껍데기만 남긴다(실측 9/16). 이것도 "값은 있으나 쓸모가 없는" 경우다.
#
# 그래서 "비어있으면"이 아니라 "토큰 본체가 둘 다 없으면" 파일로 넘어간다.
# 반대로 Keychain 에 쓸만한 게 있으면 파일은 안 본다 — 파일 쪽이 더 오래된
# 스냅샷일 수 있고, 오래된 refresh 토큰으로 회전을 시도하면 그거야말로
# 오늘 겪은 invalid_grant 사고를 생산하는 길이다.
# Keychain 읽기 -> 필요하면 회전 -> 조회(또는 캐시) -> 파싱. 결과는 전역 c_* 변수.
fetch_claude() {
  CLAUDE_CRED_FILE="$HOME/.claude/.credentials.json"
  c_src="keychain"
  c_tok=$(security find-generic-password -s "Claude Code-credentials" -a "$USER" -w 2>/dev/null)

  # jq 한 번으로 필요 필드를 전부 뽑는다(스폰 절감).
  # 구분자는 | — IFS 공백문자가 아니라 빈 필드가 안 뭉개다.
  claude_tok_parse() {
    IFS='|' read -r c_plan c_exp c_rexp_g c_at_len c_rt_len <<<"$(printf '%s' "$c_tok" | jq -r '.claudeAiOauth
      | [(.subscriptionType // ""), (.expiresAt // 0), (.refreshTokenExpiresAt // 0),
         (.accessToken // "" | length), (.refreshToken // "" | length)]
      | map(tostring) | join("|")' 2>/dev/null)"
  }
  claude_tok_parse
  if [ "${c_at_len:-0}" -eq 0 ] 2>/dev/null && [ "${c_rt_len:-0}" -eq 0 ] 2>/dev/null \
     && [ -r "$CLAUDE_CRED_FILE" ]; then
    c_file=$(<"$CLAUDE_CRED_FILE")
    if printf '%s' "$c_file" | jq -e '.claudeAiOauth
         | ((.accessToken // "") != "") or ((.refreshToken // "") != "")' >/dev/null 2>&1; then
      c_tok="$c_file"; c_src="file"
      claude_tok_parse
      rlog claude "keychain 비어있음 -> .credentials.json 사용"
    fi
  fi

  if [ -n "$c_tok" ]; then
    # 토큰 만료는 응답 코드로 판정하면 안 된다.
    # 만료된 토큰으로 치면 401 이 아니라 429 가 돌아온다(실측) -> "요청 과다"로
    # 잘못 안내하게 된다. expiresAt 이 있으니 치기 전에 먼저 본다.
    now=$NOW
    c_exp_s=$(( ${c_exp%.*} / 1000 ))

    # 만료 15분 전부터 직접 회전. 성공하면 c_tok 이 새 토큰으로 바뀐다.
    c_rotated=0
    claude_refresh_if_needed "$c_exp_s"

    # 회전 결과를 반영해 만료 판정은 여기서 한 번만 한다.
    if [ "$c_rotated" = 1 ]; then
      IFS='|' read -r c_exp c_rexp_g c_at_len <<<"$(printf '%s' "$c_tok" | jq -r '.claudeAiOauth
        | [(.expiresAt // 0), (.refreshTokenExpiresAt // 0),
           (.accessToken // "" | length)] | map(tostring) | join("|")')"
      c_exp_s=$(( ${c_exp%.*} / 1000 ))
    fi
    c_dead=0
    # 토큰 본체가 비어 있으면 만료와 동급으로 친다.
    #
    # 회전이 깨지면 keychain 에 accessToken="" / expiresAt=0 인 껍데기가 남는다
    # (실측 9/13: 회전 중 네트워크 끊김 -> invalid_grant -> 토큰 본체 소실).
    # expiresAt 이 0 이면 아래 만료 검사의 `-gt 0` 이 거짓이라 가드를 통째로
    # 빠져나가고, 빈 `Bearer ` 로 조회를 때리게 된다.
    # 그리고 빈 Bearer 는 401 이 아니라 429 가 돌아온다(실측 9/14):
    #   Bearer <빈값>   -> 429   <- 이게 함정
    #   Bearer <쓰레기> -> 401
    #   Bearer <정상>   -> 200
    # 429 로 오면 throttled 로 잘못 분류돼 backoff 까지 걸리고, 화면엔
    # "요청 과다 — 잠시 후 자동 복구"라는 거짓 안내가 뜬다. 실제로는 재로그인이
    # 필요한 상태다. 그래서 조회 전에 여기서 끊는다.
    [ "${c_at_len:-0}" -eq 0 ] 2>/dev/null && c_dead=1
    [ "$c_exp_s" -gt 0 ] 2>/dev/null && [ "$c_exp_s" -le "$now" ] && c_dead=1

    # refresh 토큰까지 죽으면 자동 갱신도 끝이다(재로그인 외엔 방법 없음).
    # 정상 운영에선 회전이 30일 수명을 계속 밀어내므로 이 경고는 안전망이다.
    c_rdays=""
    [ "${c_rexp_g%.*}" -gt 0 ] 2>/dev/null && \
      c_rdays=$(( ( ${c_rexp_g%.*} / 1000 - now ) / 86400 ))

    if fresh claude; then
      # TTL 안 -> API 안 때리고 캐시 그대로. 경고도 안 띄운다(정상 동작).
      c_json=$(<"$CACHE_DIR/claude.json")
    elif [ "$c_dead" = 1 ]; then
      # 이미 죽은 토큰이면 굳이 치지 않는다(429 만 유발한다).
      # 토큰 본체가 통째로 빈 경우는 만료와 원인이 달라 문구를 나눈다
      # (만료는 자동 갱신이 살리지만, 빈 토큰은 재로그인 말고 복구가 없다).
      if [ "${c_at_len:-0}" -eq 0 ] 2>/dev/null; then c_err="token-empty"; else c_err="expired"; fi
      [ -f "$CACHE_DIR/claude.json" ] && c_json=$(<"$CACHE_DIR/claude.json") || c_json=""
    else
      c_at=$(echo "$c_tok" | jq -r '.claudeAiOauth.accessToken // ""')
      # retry-after 가 비면 command substitution 이 끝의 빈 줄을 없애므로,
      # 항상 값이 있는 http_code 를 마지막에 두고 고정 마커로 필드를 나눈다.
      raw=$("${CURL[@]}" -w '\n__TOKENHUD_RETRY__%header{retry-after}__TOKENHUD_CODE__%{http_code}' https://api.anthropic.com/api/oauth/usage \
                -H "Authorization: Bearer $c_at" \
                -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null)
      code="${raw##*__TOKENHUD_CODE__}"; raw="${raw%__TOKENHUD_CODE__*}"
      c_retry="${raw##*__TOKENHUD_RETRY__}"; c_json="${raw%__TOKENHUD_RETRY__*}"
      if [ "$code" = "200" ] && echo "$c_json" | jq -e '.five_hour' >/dev/null 2>&1; then
        echo "$c_json" > "$CACHE_DIR/claude.json"
        MT_claude=$NOW
        clear_backoff claude
      else
        case "$code" in
          401|403) c_err="expired" ;;
          429)     c_err="throttled"; set_backoff claude "${c_retry:-300}" ;;
          "")      c_err="unreachable" ;;
          *)       c_err="http $code" ;;
        esac
        [ -f "$CACHE_DIR/claude.json" ] && c_json=$(<"$CACHE_DIR/claude.json") || c_json=""
      fi
    fi
  else
    c_err="keychain"
  fi

  prompt_claude_login_if_needed

  if [ -n "$c_json" ]; then
    now=$NOW
    IFS='|' read -r c5_pct c5_at c7_pct c7_at cx_on cx_pct <<<"$(printf '%s' "$c_json" | jq -r '
      [(.five_hour.utilization // ""), (.five_hour.resets_at // ""),
       (.seven_day.utilization // ""), (.seven_day.resets_at // ""),
       (.extra_usage.is_enabled // false),
       (.extra_usage.utilization // "")] | map(tostring) | join("|")')"
    iso_epoch_set "$c5_at"; c5_e=$EPOCH
    iso_epoch_set "$c7_at"; c7_e=$EPOCH

    # 모델별 주간 한도는 최상위 seven_day_opus 에서 limits 배열로 옮겨졌다.
    #
    # seven_day_opus / seven_day_sonnet 는 이제 항상 null 이다(실측 8/23).
    # 예전 코드는 `.seven_day_opus.utilization // ""` 로 읽어서 null 에 빈 문자열이
    # 떨어졌고, `[ -n "$co_pct" ]` 가 항상 거짓이라 Opus 행이 통째로 안 그려졌다
    # -> 실제로 6% 쓰고 있던 모델이 화면에 아예 없었다.
    # 모델 이름을 박지 않고 scope 가 있는 weekly 항목을 전부 그린다
    # (서버가 모델명을 바꿔도 따라간다).
    c_scoped=$(printf '%s' "$c_json" | jq -r '
      (.limits // [])[]
      | select(type == "object")
      | select(.group == "weekly" and (.scope.model.display_name // "") != "")
      | select((.percent | type) == "number")
      | "\(.scope.model.display_name)|\(.percent)|\(.resets_at // "")"' 2>/dev/null)
  fi
}

# Codex 0.139.0 자체 구현과 같은 OAuth refresh 흐름.
# `codex login status` 는 상태만 읽고, access token 을 갱신하지 않는다(파일 mtime 실측).
# exec 모드도 갱신 전용 명령이 아니다. 메뉴 플러그인이 만료 전에 직접 회전시킨다.
codex_refresh_if_needed() {   # codex_refresh_if_needed <auth.json> <access-exp>
  local auth="$1" exp="$2" now due=0 last_refresh last_epoch
  local stamp="$CACHE_DIR/.codex_refresh_attempt" lock="$CACHE_DIR/.codex_refresh_lock"
  local refresh req raw code body err current tmp now_iso

  [ "${TOKENHUD_AUTOREFRESH:-1}" = 1 ] || return
  now=$NOW
  if [ -n "$exp" ] && [ "$exp" != "null" ]; then
    [ "$exp" -le $((now + ${TOKENHUD_CODEX_REFRESH_WINDOW:-900})) ] 2>/dev/null && due=1
  else
    # 공식 구현도 JWT exp 를 못 읽을 때만 마지막 갱신 8일을 폴백으로 쓴다.
    last_refresh=$(jq -r '.last_refresh // empty' "$auth" 2>/dev/null)
    iso_epoch_set "$last_refresh"; last_epoch=$EPOCH
    [ -n "$last_epoch" ] && [ "$last_epoch" -le $((now - 691200)) ] && due=1
  fi
  [ "$due" = 1 ] || return

  # 사망 판정은 쿨다운보다 앞에 둔다(Claude 쪽과 같은 이유).
  refresh=$(jq -r '.tokens.refresh_token // empty' "$auth" 2>/dev/null)
  if [ -z "$refresh" ]; then
    x_refresh_err="refresh-missing"
    refresh_ready "$stamp" "${TOKENHUD_CODEX_REFRESH_COOLDOWN:-600}" && rlog codex "refresh-missing"
    return
  fi

  # 서버가 이미 죽였다고 확정한 토큰이면 더 두드리지 않는다(Claude 쪽과 동일).
  if is_dead codex "$refresh"; then
    x_refresh_err="refresh-dead"; return
  fi

  # 공식 Codex 는 만료 5분 전, HUD 는 15분 전에 갱신한다.
  # HUD 가 먼저 회전시키므로 정상 동작에서는 같은 refresh token 을 동시에 쓰지 않는다.
  # 이미 열린 Codex 도 갱신 직전 auth.json 을 다시 읽어 선행 회전을 반영한다.
  refresh_ready "$stamp" "${TOKENHUD_CODEX_REFRESH_COOLDOWN:-600}" || return

  if ! mkdir "$lock" 2>/dev/null; then
    # 비정상 종료가 남긴 빈 락은 10분 뒤 회수한다.
    local lm=0
    [ -d "$lock" ] && lm=$(stat -f %m "$lock" 2>/dev/null || echo 0)
    if [ $((now - lm)) -ge 600 ]; then
      rmdir "$lock" 2>/dev/null || return
      mkdir "$lock" 2>/dev/null || return
    else
      return
    fi
  fi

  # 다크웨이크에서는 회전하지 않는다. 창이 2~5초라 요청 도중 다시 잠들고,
  # 그러면 서버만 회전시킨 채 새 토큰을 못 받아 계정이 죽는다.
  if ! system_awake; then
    rlog codex "skip — 다크웨이크(회전 보류)"
    rm -f "$stamp" 2>/dev/null
    rmdir "$lock"; return
  fi

  # 토큰은 프로세스 인자에 싣지 않고 stdin 으로 넘긴다(ps 에 노출 방지).
  req=$(printf '%s' "$refresh" | jq -Rs \
    '{client_id:"app_EMoamEEZ73f0CkXaXp7hrann",grant_type:"refresh_token",refresh_token:.}')
  raw=$(printf '%s' "$req" | hold_awake "${CURL_ROT[@]}" -w '\n%{http_code}' \
          -H "Content-Type: application/json" --data-binary @- \
          "https://auth.openai.com/oauth/token" 2>/dev/null)
  code="${raw##*$'\n'}"; body="${raw%$'\n'*}"
  [ "$raw" = "$code" ] && body=""

  if [ "$code" = 200 ] \
     && printf '%s' "$body" | jq -e '.access_token | type == "string" and length > 0' >/dev/null 2>&1; then
    # 네트워크 왕복 사이 다른 Codex 가 먼저 회전시켰다면 새 토큰을 덮어쓰지 않는다.
    current=$(jq -r '.tokens.refresh_token // empty' "$auth" 2>/dev/null)
    if [ "$current" = "$refresh" ]; then
      umask 077
      tmp=$(mktemp "${auth}.tokenhud.XXXXXX") || {
        x_refresh_err="refresh-save"; rlog codex "SAVE FAIL — mktemp"; rmdir "$lock"; return;
      }
      now_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
      { cat "$auth"; printf '\n%s\n' "$body"; } | jq -s --arg now "$now_iso" '
        .[0] as $a | .[1] as $r | $a
        | .tokens.access_token = $r.access_token
        | if ($r.id_token // "") != "" then .tokens.id_token = $r.id_token else . end
        | if ($r.refresh_token // "") != "" then .tokens.refresh_token = $r.refresh_token else . end
        | .last_refresh = $now
      ' > "$tmp" || {
        rm -f "$tmp"; x_refresh_err="refresh-save"; rlog codex "SAVE FAIL — merge"; rmdir "$lock"; return;
      }
      chmod 600 "$tmp"
      mv "$tmp" "$auth" || {
        rm -f "$tmp"; x_refresh_err="refresh-save"; rlog codex "SAVE FAIL — mv"; rmdir "$lock"; return;
      }
      clear_dead codex
      rlog codex "ok"; x_rotated=1
    else
      x_rotated=1; rlog codex "skip — 다른 Codex 가 먼저 회전"
    fi
  else
    err=$(err_name "$body")
    case "$err" in
      refresh_token_expired)     x_refresh_err="refresh-expired" ;;
      refresh_token_reused)      x_refresh_err="refresh-reused" ;;
      refresh_token_invalidated) x_refresh_err="refresh-revoked" ;;
      # 재로그인 말고는 복구가 없는 응답. 사망 표식을 남겨 재시도를 멈춘다.
      invalid_grant|invalid_request|invalid_client)
        mark_dead codex "$refresh"; x_refresh_err="refresh-dead" ;;
      *) [ -z "$code" ] && x_refresh_err="refresh-unreachable" \
                         || x_refresh_err="refresh-http-$code" ;;
    esac
    rlog codex "fail code=$code err=${err:-?} desc=$(err_desc "$body")"
  fi
  rmdir "$lock"
}

# ── Codex ─────────────────────────────────────────────────────────────
# 현재 계정은 서버와 공식 대시보드 모두 주간 창만 제공한다.
x7_pct=""; x7_e=""; x_err=""; x_plan=""; x_refresh_err=""; x_json=""; xexp=""
# auth.json 읽기 -> 필요하면 회전 -> 조회(또는 캐시) -> 파싱. 결과는 전역 x_* 변수.
fetch_codex() {
  CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
  X_AUTH="$CODEX_HOME/auth.json"
  if [ -f "$X_AUTH" ]; then
    IFS='|' read -r x_at x_acc <<<"$(jq -r '[(.tokens.access_token // ""), (.tokens.account_id // "")] | join("|")' "$X_AUTH" 2>/dev/null)"
    xexp=$(jwt_exp "$x_at")
    x_rotated=0
    codex_refresh_if_needed "$X_AUTH" "$xexp"

    # 갱신 성공 또는 다른 Codex 의 선행 갱신을 반영한다.
    if [ "$x_rotated" = 1 ]; then
      x_at=$(jq -r '.tokens.access_token // ""' "$X_AUTH" 2>/dev/null)
      xexp=$(jwt_exp "$x_at")
    fi
    x_dead=0
    [ -n "$xexp" ] && [ "$xexp" -le "$NOW" ] 2>/dev/null && x_dead=1

    if [ -n "$x_at" ]; then
      if fresh codex; then
        x_json=$(<"$CACHE_DIR/codex.json")
      elif [ "$x_dead" = 1 ]; then
        x_err="expired"
        [ -f "$CACHE_DIR/codex.json" ] && x_json=$(<"$CACHE_DIR/codex.json") || x_json=""
      else
        raw=$("${CURL[@]}" -w '\n__TOKENHUD_RETRY__%header{retry-after}__TOKENHUD_CODE__%{http_code}' \
                  "https://chatgpt.com/backend-api/wham/usage" \
                  -H "Authorization: Bearer $x_at" \
                  -H "chatgpt-account-id: $x_acc" 2>/dev/null)
        code="${raw##*__TOKENHUD_CODE__}"; raw="${raw%__TOKENHUD_CODE__*}"
        x_retry="${raw##*__TOKENHUD_RETRY__}"; x_json="${raw%__TOKENHUD_RETRY__*}"
        if [ "$code" = "200" ] && echo "$x_json" | jq -e '.rate_limit' >/dev/null 2>&1; then
          echo "$x_json" > "$CACHE_DIR/codex.json"
          MT_codex=$NOW
          clear_backoff codex
        else
          case "$code" in
            401|403) x_err="expired" ;;
            429)     x_err="throttled"; set_backoff codex "${x_retry:-300}" ;;
            "")      x_err="unreachable" ;;
            *)       x_err="http $code" ;;
          esac
          [ -f "$CACHE_DIR/codex.json" ] && x_json=$(<"$CACHE_DIR/codex.json") || x_json=""
        fi
      fi
    else
      x_err="no-token"
    fi
  else
    x_err="not-installed"
  fi

  if [ -n "$x_json" ]; then
    # 상대값(reset_after_seconds)은 캐시 중 계속 낡는다. 절대 reset_at을 사용한다.
    now=$NOW
    IFS='|' read -r x_plan x7_pct x7_at <<<"$(printf '%s' "$x_json" | jq -r '
      ([.rate_limit.primary_window, .rate_limit.secondary_window]
       | map(select(. != null and .limit_window_seconds > 21600))) as $w
      | [(.plan_type // ""),
         (if ($w|length)>0 then ($w[0].used_percent|tostring) else "" end),
         (if ($w|length)>0 then ($w[0].reset_at|tostring) else "" end)]
      | join("|")')"
    [ -n "$x7_at" ] && [ "$x7_at" != "null" ] && x7_e=${x7_at%.*}
  fi
}

# ── 실행 흐름: 스냅샷 → (필요할 때만) 전체 경로 ───────────────────────────
# SwiftBar 는 매분 플러그인을 새 프로세스로 띄운다. 값은 TTL(180초)마다만 바뀌는데
# 매분 Keychain 을 열고 jq 를 대여섯 번 띄우던 게 실행당 프로세스 약 50개(하루 7만개)였다.
# 정상 상태를 그리는 데 필요한 값만 스냅샷으로 남기고, 유효한 동안은 그것만 읽는다
# -> Keychain·jq·네트워크 0회.
#
# 스냅샷은 오류가 하나도 없을 때만 쓴다. 오류·회전·재로그인 판정은 전부
# 예전과 같은 전체 경로가 매번 다룬다. 빠른 경로는 '건강한 값 다시 그리기' 전용이다.
SNAP="$CACHE_DIR/state.sh"
SNAP_VARS="c_plan c5_pct c5_e c7_pct c7_e cx_on cx_pct c_scoped c_rexp_g x_err x_plan x7_pct x7_e DATA_AT VALID_UNTIL SNAP_IDLE"

# 스냅샷을 현재 셸에 올린다. 없거나 재로그인이 필요해졌으면 실패.
snapshot_load() {
  [ -f "$SNAP" ] || return 1
  . "$SNAP" 2>/dev/null || return 1
  [ -n "$VALID_UNTIL" ] || return 1
  c_rdays=""
  [ "${c_rexp_g%.*}" -gt 0 ] 2>/dev/null && \
    c_rdays=$(( ( ${c_rexp_g%.*} / 1000 - NOW ) / 86400 ))
  [ -n "$c_rdays" ] && [ "$c_rdays" -le 0 ] 2>/dev/null && return 1
  # 렌더러는 c_json/x_json 의 내용이 아니라 '값이 있느냐'만 본다.
  c_json=snapshot
  [ -z "$x_err" ] && x_json=snapshot
  return 0
}

# 전체 경로로 갈 때 스냅샷에서 올라온 값을 지운다. 남아 있으면 조회가 실패한
# 공급자 자리에 예전 값이 현재 값처럼 그려진다.
snapshot_reset() {
  local v
  for v in $SNAP_VARS; do printf -v "$v" '%s' ""; done
  c_json=""; x_json=""; c_rdays=""
}

# 전체 경로가 끝난 뒤 건강한 상태면 스냅샷을 남긴다. 아니면 지운다.
snapshot_save() {
  local v cap
  # Codex 미설치는 오류가 아니라 항상 그런 상태다 — 스냅샷을 막지 않는다.
  if [ -n "$c_err$c_refresh_err$x_refresh_err$relogin" ] || [ -z "$c_json" ] \
     || [ "$c_src" != "keychain" ] || [ "$MT_claude" = 0 ] \
     || { [ -n "$x_err" ] && [ "$x_err" != "not-installed" ]; } \
     || { [ -z "$x_err" ] && [ "$MT_codex" = 0 ]; }; then
    rm -f "$SNAP"
    return
  fi
  SNAP_IDLE=$IDLE_SKIP
  # 자리 비움으로 조회를 건너뛴 스냅샷은 캐시가 이미 낡았다. TTL 마다 전체 경로를
  # 돌려 회전 판정만 이어가고, 빠른 경로는 사람이 돌아오는 즉시 풀린다.
  if [ "$SNAP_IDLE" = 1 ]; then VALID_UNTIL=$(( NOW + TTL )); else VALID_UNTIL=$(( DATA_AT + TTL )); fi
  # 토큰 회전 창에 들어가면 스냅샷을 끝내 전체 경로가 회전을 맡게 한다.
  cap=$(( c_exp_s - ${TOKENHUD_CLAUDE_REFRESH_WINDOW:-900} ))
  [ "$c_exp_s" -gt 0 ] 2>/dev/null && [ "$cap" -lt "$VALID_UNTIL" ] && VALID_UNTIL=$cap
  if [ -n "$xexp" ] && [ "$xexp" -gt 0 ] 2>/dev/null; then
    cap=$(( xexp - ${TOKENHUD_CODEX_REFRESH_WINDOW:-900} ))
    [ "$cap" -lt "$VALID_UNTIL" ] && VALID_UNTIL=$cap
  fi
  {
    for v in $SNAP_VARS; do
      printf '%s=%q\n' "$v" "${!v}"
    done
  } > "$SNAP.tmp" && mv "$SNAP.tmp" "$SNAP"
}

# 동시에 두 개가 전체 경로를 돌면 같은 API 를 두 번 친다. 타이머 실행 중에
# 워처의 refreshallplugins 나 메뉴 클릭이 겹치면 실제로 그렇게 된다(SwiftBar 는 이전
# 실행을 취소해도 프로세스를 죽이지 않는다). 전체 경로는 한 번에 하나만 돈다.
# 낙은 락 회수 기준 120초 = 회전 최대 45초 + 조회 8초 x 2 에 여유.
RUN_LOCK="$CACHE_DIR/.run_lock"
run_lock() {
  local lm
  mkdir "$RUN_LOCK" 2>/dev/null && return 0
  lm=$(stat -f %m "$RUN_LOCK" 2>/dev/null || echo "$NOW")
  [ $(( NOW - lm )) -ge 120 ] || return 1
  rmdir "$RUN_LOCK" 2>/dev/null
  mkdir "$RUN_LOCK" 2>/dev/null
}

FAST=0; ROUND_DUE=0
if [ "$BUSTED" = 0 ] && [ ! -f "$BUST" ] && snapshot_load; then
  # 자리 비움 스냅샷은 사람이 돌아오면 바로 버린다(밀린 조회를 즉시 하도록).
  if [ "$NOW" -lt "$VALID_UNTIL" ] && { [ "$SNAP_IDLE" != 1 ] || user_idle; }; then
    FAST=1
  else
    ROUND_DUE=1
  fi
fi
if [ "$FAST" = 0 ]; then
  if run_lock; then
    trap 'rmdir "$RUN_LOCK" 2>/dev/null' EXIT
  elif snapshot_load; then
    # 다른 실행이 지금 조회 중이다. 중복 호출 대신 직전 값을 그린다.
    # 강제 갱신을 소모했다면 돌려놓아 다음 실행이 이어받게 한다.
    [ "$BUSTED" = 1 ] && touch "$BUST"
    FAST=1
  fi
fi

if [ "$FAST" = 0 ]; then
  snapshot_reset
  fetch_claude
  fetch_codex
fi

# 드롭다운에 적는 '언제 값인가'. 실행 시각이 아니라 서버에서 받은 시각이다.
if [ "$FAST" = 0 ]; then
  DATA_AT=$NOW
  [ "$MT_claude" -gt 0 ] && [ "$MT_claude" -lt "$DATA_AT" ] && DATA_AT=$MT_claude
  [ "$MT_codex" -gt 0 ] && [ "$MT_codex" -lt "$DATA_AT" ] && DATA_AT=$MT_codex
fi

# ── 메뉴바 타이틀 ─────────────────────────────────────────────────────
# Claude 5시간/주간 + Codex 주간을 PNG 한 장으로 합성한다.
# SwiftBar는 한 줄에 이미지 하나만 받을 수 있어 렌더러를 따로 둔다.
# "12.7" / "" / "null" -> 12 / -1 / -1
# 렌더러엔 정수만 넘긴다(Swift 쪽 Int() 가 소수점을 못 먹고 그대로 -1 로 떨어진다).
pctint_set() {   # pctint_set <변수명> <값>
  local v="${2%.*}"
  { [ -z "$v" ] || [ "$v" = "null" ]; } && v=-1
  printf -v "$1" '%s' "$v"
}
pctint_set c5 "$c5_pct"; pctint_set c7 "$c7_pct"; pctint_set x7 "$x7_pct"

# 아이콘 색은 표시하는 세 값 중 가장 급한 값을 따른다.
top=$c5
[ "$c7" -gt "$top" ] 2>/dev/null && top=$c7
[ "$x7" -gt "$top" ] 2>/dev/null && top=$x7
# 값이 하나도 없으면 초록(안전)으로 오해시키지 않는다
if   [ "$top" -lt 0 ] 2>/dev/null; then icon="⚪️"
elif [ "$top" -ge 90 ]; then icon="🔴"
elif [ "$top" -ge 70 ]; then icon="🟠"
else icon="🟢"; fi
# 흐리게 표시할지 판정.
#
# API 실패 = 곧장 흐림 은 과했다. 토큰이 3시간마다 만료되니 하루에도 몇 번씩
# 흐려졌다. 사용률은 리셋 전까지 줄지 않으므로, 리셋이 안 지난 캐시는
# 여전히 쓸 만한 값이다 -> 그 동안은 선명하게 둔다.
# 리셋이 지나 값이 실제로 틀렸을 수 있을 때만 흐리게 한다.
stale=0
if [ -n "$c_err" ] && ! cache_still_valid claude; then stale=1; fi
if [ -n "$x_err" ] && ! cache_still_valid codex;  then stale=1; fi
[ "$stale" = 1 ] && [ "$icon" != "⚪️" ] && icon="${icon}~"

# 재로그인 말고는 복구 수단이 없는 상태(refresh 토큰 사망).
# 드롭다운 경고만으로는 놓친다 — 실제로 만료 후 나흘을 모르고 지나갔다.
# 메뉴바에 ⚠️ 를 직접 박아 접지 않아도 보이게 한다.
relogin=""
[ -n "$c_rdays" ] && [ "$c_rdays" -le 0 ] 2>/dev/null && relogin=1
case "$x_refresh_err" in
  refresh-expired|refresh-reused|refresh-revoked|refresh-missing|refresh-dead) relogin=1;;
esac
case "$c_refresh_err" in
  refresh-expired|refresh-missing|refresh-dead) relogin=1;;
esac
# 토큰 본체가 빈 상태도 재로그인 외엔 복구가 없다.
[ "$c_err" = "token-empty" ] && relogin=1

[ "$FAST" = 0 ] && snapshot_save

# 렌더러가 없을 때의 텍스트 폴백.
fmt() { [ "$1" -lt 0 ] 2>/dev/null && echo "–" || echo "$1"; }
emit_text_title() {
  echo "${relogin:+⚠️}${icon}$(fmt "$c5")/$(fmt "$c7")·$(fmt "$x7") | size=13"
}

# 에셋은 플러그인 폴더 바깥에 둔다.
# SwiftBar 는 플러그인 폴더의 파일을 전부 실행하려 들기 때문에,
# PNG/소스를 같은 폴더에 두면 NSTask 예외로 앱이 통째로 죽는다(실측).
# SwiftBar 는 절대경로로 실행한다. 상대경로 실행도 문자열 조작만으로 풀린다(cd/dirname 스폰 없음).
case "$0" in */*) PLUGIN_DIR="${0%/*}";; *) PLUGIN_DIR=.;; esac
HUDIMG="${TOKENHUD_ASSETS:-$PLUGIN_DIR/../assets}/hudimg"
# 메뉴바는 항상 컬러로 그린다.
if [ "${TOKENHUD_ICON:-logo}" = "logo" ] && [ -x "$HUDIMG" ]; then
  tkey="$c5/$c7/$x7/$stale"
  TCACHE="$CACHE_DIR/title.b64"
  b64=""
  if [ -s "$TCACHE" ]; then
    { IFS= read -r _tk; IFS= read -r _tb; } < "$TCACHE"
    [ "$_tk" = "$tkey" ] && b64="$_tb"
  fi
  if [ -z "$b64" ]; then
    b64=$("$HUDIMG" "$c5" "$c7" "$x7" "$stale" 2>/dev/null)
    [ -n "$b64" ] && printf '%s\n%s\n' "$tkey" "$b64" > "$TCACHE"
  fi
  if [ -n "$b64" ]; then
    # 앞의 공백은 SwiftBar 가 빈 타이틀을 버리지 않게 하는 용도.
    # 재로그인이 필요하면 공백 대신 ⚠️ 를 이미지 옆에 그린다.
    badge=" "; [ -n "$relogin" ] && badge="⚠️"
    echo "$badge | image=$b64"
  else
    emit_text_title
  fi
else
  emit_text_title
fi
echo "---"

# ── 드롭다운 ──────────────────────────────────────────────────────────
# 헤더 로고도 값이 안 변하니 base64 를 파일로 캐싱해 재사용한다.
header() {   # header <로고이름> <텍스트>
  local f="$CACHE_DIR/logo-${1}.b64" b=""
  if [ ! -s "$f" ] && [ -x "$HUDIMG" ]; then
    "$HUDIMG" --logo "$1" 12 > "$f" 2>/dev/null
  fi
  [ -s "$f" ] && IFS= read -r b < "$f"
  if [ -n "$b" ]; then
    echo "$2 | $FONT color=$C_DIM image=$b"
  else
    echo "$2 | $FONT color=$C_DIM"
  fi
}
header claude "Claude Code${c_plan:+  ($c_plan)}"
# 캐시 파일이 몇 분 전 것인지 -> "12분 전 값" 처럼 명시
cache_age() {
  local f="$CACHE_DIR/$1.json"
  [ -f "$f" ] || { echo ""; return; }
  local m; m=$(stat -f %m "$f" 2>/dev/null) || { echo ""; return; }
  human_left $(( NOW - m ))
}

# 실패 원인 -> 사람이 읽을 문구.  why <오류> [expired문구] [도구이름]
why() {
  local t="${3:-codex}"
  case "$1" in
    keychain)            echo "Keychain 접근 거부 — 잠금 해제 후 새로고침";;
    expired)             echo "$2";;
    token-empty)         echo "토큰이 비어 있음 — $t 재로그인 필요";;
    # 남은 시간을 같이 적는다. ai-usagebar 의 "rate limited; next attempt in 4m".
    # 그냥 "잠시 후"라고만 쓰면 5분인지 1시간인지 몰라 사람이 계속 강제갱신을
    # 누른다 — 그러면 backoff 가 더 길어질 뿐이다.
    throttled)           echo "요청 과다 — $(backoff_left "$t")";;
    unreachable)         echo "네트워크 연결 안 됨";;
    not-installed)       echo "설치 안 됨";;
    no-token)            echo "로그인 안 됨";;
    refresh-missing)     echo "자동 갱신 토큰 없음 — $t 재로그인 필요";;
    refresh-expired)     echo "자동 갱신 만료 — $t 재로그인 필요";;
    refresh-dead)        echo "자동 갱신 토큰 무효 — $t 재로그인 필요";;
    refresh-reused)      echo "자동 갱신 토큰 충돌 — $t 재로그인 필요";;
    refresh-revoked)     echo "자동 갱신 취소됨 — $t 재로그인 필요";;
    refresh-unreachable) echo "자동 갱신 서버 연결 안 됨 — 재시도 예정";;
    refresh-readonly)    echo "Keychain 못 읽음 — 파일 값으로 표시 중";;
    refresh-save)        echo "자동 갱신 저장 실패 — 권한 확인 필요";;
    refresh-http-*)      echo "자동 갱신 실패 (HTTP ${1#refresh-http-}) — 재시도 예정";;
    *)                   echo "요청 실패 ($1)";;
  esac
}

if [ -z "$c_json" ]; then
  if [ -n "$c_refresh_err" ]; then
    echo "  $(why "$c_refresh_err" "" claude) | $FONT color=$C_CRIT"
  else
    echo "  $(why "$c_err" "토큰 만료 — claude 재로그인" claude) | $FONT color=$C_CRIT"
  fi
else
  if [ -n "$c_err" ]; then
    # refresh 토큰까지 죽었으면 "자동 갱신 중"은 거짓말이다.
    c_msg="토큰 만료 — 자동 갱신 재시도 중"
    [ -n "$c_rdays" ] && [ "$c_rdays" -le 0 ] 2>/dev/null && c_msg="토큰 만료 — 재로그인 전까지 멈춤"
    # 빈 토큰은 자동 갱신 대상이 아니다(회전시킬 원본이 없다).
    [ "$c_err" = "token-empty" ] && c_msg="토큰이 비어 있음 — 재로그인 필요"
    # 서버가 refresh 토큰을 거부한 상태(refresh-dead)도 마찬가지다.
    # 남은 수명이 아무리 길어도 재로그인 전에는 절대 안 풀린다.
    [ "$c_refresh_err" = "refresh-dead" ] && c_msg="토큰 만료 — 재로그인 전까지 멈춤"
    echo "  ⚠︎ $(cache_age claude) 전 값 · $(why "$c_err" "$c_msg" claude) | $FONT color=$C_WARN"
  fi
  [ -n "$c_refresh_err" ] && \
    echo "  ⚠︎ $(why "$c_refresh_err" "" claude) | $FONT color=$C_WARN"
  c5_left=""; [ -n "$c5_e" ] && c5_left=$(( c5_e - NOW ))
  c7_left=""; [ -n "$c7_e" ] && c7_left=$(( c7_e - NOW ))
  row "5시간" "$c5_pct" "$c5_left" "$WIN_5H"
  row "주간"  "$c7_pct" "$c7_left" "$WIN_7D"
  # 모델별 주간 한도(limits 배열). 서버가 주는 이름을 그대로 쓴다.
  if [ -n "$c_scoped" ]; then
    while IFS='|' read -r s_name s_pct s_at; do
      [ -n "$s_name" ] || continue
      s_left=""
      iso_epoch_set "$s_at"; [ -n "$EPOCH" ] && s_left=$(( EPOCH - NOW ))
      row "$s_name" "$s_pct" "$s_left" "$WIN_7D"
    done <<<"$c_scoped"
  fi
  if [ "$cx_on" = "true" ] && [ -n "$cx_pct" ]; then
    # 추가분은 리셋 창이 없다(월 단위 지출). pace 를 계산할 근거가 없다.
    row "추가분" "$cx_pct" ""
  fi
  pace_warn_flush
  # refresh 토큰 만료가 다가오면 미리 알린다.
  # 이게 죽으면 자동 갱신이 멈추고 재로그인 전까지 값이 고정된다.
  if [ -n "$c_rdays" ]; then
    if   [ "$c_rdays" -le 0 ] 2>/dev/null; then
      echo "  ⚠︎ 자동 갱신 만료 — claude 재로그인 필요 | $FONT color=$C_CRIT"
    elif [ "$c_rdays" -le 3 ] 2>/dev/null; then
      echo "  ⚠︎ ${c_rdays}일 뒤 재로그인 필요 (자동 갱신 만료) | $FONT color=$C_WARN"
    fi
  fi
fi

echo "---"
header openai "Codex${x_plan:+  ($x_plan)}"
if [ -z "$x_json" ]; then
  case "$x_err" in
    not-installed|no-token) echo "  $(why "$x_err") — codex login | $FONT color=$C_DIM";;
    *) if [ -n "$x_refresh_err" ]; then
         echo "  $(why "$x_refresh_err") | $FONT color=$C_CRIT"
       else
         echo "  $(why "$x_err" "토큰 만료 — 자동 갱신 재시도 중") | $FONT color=$C_CRIT"
       fi ;;
  esac
else
  [ -n "$x_err" ] && \
    echo "  ⚠︎ $(cache_age codex) 전 값 · $(why "$x_err" "토큰 만료 — 자동 갱신 재시도 중") | $FONT color=$C_WARN"
  [ -n "$x_refresh_err" ] && \
    echo "  ⚠︎ $(why "$x_refresh_err") | $FONT color=$C_WARN"
  x7_left=""; [ -n "$x7_e" ] && x7_left=$(( x7_e - NOW ))
  row "주간" "$x7_pct" "$x7_left" "$WIN_7D"
  pace_warn_flush
fi

echo "---"
# 그냥 새로고침은 TTL 캐시를 그대로 쓴다(=API 안 때림).
echo "새로고침 | refresh=true"
# 지금 당장 서버 값을 받고 싶을 때.
# 캐시를 지우지 않고 표식만 남긴다 -> API 가 실패해도 직전 값은 살아있다.
echo "지금 강제 갱신 | bash=/usr/bin/touch param1=$BUST terminal=false refresh=true"
[ -n "$relogin" ] && \
  echo "Claude 재로그인 | bash=/opt/homebrew/bin/claude param1=auth param2=login terminal=true refresh=true"
# 서버 값을 받은 시각을 보여준다(실행 시각을 찍으면 캐시가 낙아도 방금 받은 것처럼 보인다).
clock_set "$DATA_AT"
if [ -n "$c_err$x_refresh_err" ] || { [ -n "$x_err" ] && [ "$x_err" != "not-installed" ]; }; then
  echo "업데이트 $CLOCK  ·  캐시 사용중 | $SMALL color=$C_WARN"
else
  echo "업데이트 $CLOCK  ·  ${TTL}초마다 조회 | $SMALL color=$C_DIM"
fi
