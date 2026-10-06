#!/bin/bash
# 절전에서 깨어나거나 네트워크가 붙으면 TokenHUD 를 즉시 갱신시킨다.
#
# 왜 필요한가:
#   맥이 자는 동안 SwiftBar 타이머도 멈춘다. 깨어나도 다음 주기(최대 1분)까지는
#   자던 시점의 옛날 값이 그대로 보인다. 네트워크가 끊겼다 붙는 경우도 같다 —
#   끊긴 동안 조회에 실패하고, 붙어도 다음 주기까지 기다린다.
#   그 공백을 없애려고 깨어남/연결 복구를 감지해 바로 새로고침한다.
#
# 동작:
#   1) 캐시 무효화 표식을 남긴다(.bust) -> 플러그인이 TTL 을 건너뛰고 서버를 친다
#   2) SwiftBar 에 새로고침을 지시한다(swiftbar://refreshallplugins)
#
# 사람이 앞에 있을 때만 발동한다. 다크웨이크(화면 꺼진 채 몇 초 깨는 것)도
# 벽시계 점프와 네트워크 재연결을 같이 일으키는데, 예전에는 그때마다 curl 확인과
# 강제 갱신을 날려 하룻밤에 20번씩 발동했다(wake.log 실측 10/5~6). 아무도 안 보는 값이다.
# 깨어남·연결 복구는 표시만 해두고, 키보드/마우스 입력이 들어오면 그때 한 번 갱신한다.
#
# launchd 가 이 스크립트를 상주시키고, 죽으면 다시 띄운다.

CACHE_DIR="$HOME/.cache/tokenhud"
[ -d "$CACHE_DIR" ] || mkdir -p "$CACHE_DIR"

# 네트워크가 실제로 살아있는지 (DNS+TCP 까지 확인).
# 404 여도 연결은 된 것이므로 curl 종료코드로 판단한다.
net_up() {
  /usr/bin/curl -s -o /dev/null --max-time 5 \
    --connect-timeout 4 https://api.anthropic.com/ 2>/dev/null
}

# 도달 가능 여부. scutil 은 시스템 상태만 읽어 트래픽이 없다(curl 은 kick 때만).
# "Not Reachable" 에도 "Reachable" 이 들어 있어 앞에 고정해 비교한다.
net_reachable() {
  case "$(scutil -r api.anthropic.com 2>/dev/null)" in Reachable*) return 0;; esac
  return 1
}

# 최근 2분 안에 키보드/마우스 입력이 있었나. 다크웨이크에서는 절대 참이 안 된다.
user_present() {
  local out v
  out=$(ioreg -c IOHIDSystem -d 4 -r -k HIDIdleTime 2>/dev/null)
  v="${out#*\"HIDIdleTime\" = }"; v="${v%%[!0-9]*}"
  [ -n "$v" ] && [ "$v" != "$out" ] && [ $(( v / 1000000000 )) -lt 120 ]
}

# debounce 는 파일로 관리한다.
# 메모리 변수로 하면 워처가 두 개 뜬 경우(unload 때 안 죽고 남은 유령 등)
# 각자 따로 세어서 중복 kick 이 나간다 — 실제로 29초 간격으로 두 번 발동했다.
KICKF="$CACHE_DIR/.last_kick"
kick() {   # kick <사유>
  local now last_k=0
  now=$(date +%s)
  [ -f "$KICKF" ] && last_k=$(stat -f %m "$KICKF" 2>/dev/null || echo 0)
  [ $(( now - last_k )) -lt 60 ] && return
  touch "$KICKF"

  touch "$CACHE_DIR/.bust"
  # 네트워크가 아직이면 잠깐 기다렸다 시도 (깨어난 직후 Wi-Fi 재연결 지연)
  local i=0
  while [ $i -lt 12 ]; do
    net_up && break
    sleep 5; i=$((i+1))
  done
  /usr/bin/open -g "swiftbar://refreshallplugins" >/dev/null 2>&1
  echo "$(date '+%m-%d %H:%M:%S') kick: $1" >> "$CACHE_DIR/wake.log"
  # 로그가 무한정 자라지 않게
  tail -200 "$CACHE_DIR/wake.log" > "$CACHE_DIR/wake.log.tmp" 2>/dev/null && \
    mv "$CACHE_DIR/wake.log.tmp" "$CACHE_DIR/wake.log"
}

# ── 깨어남 감지 ───────────────────────────────────────────────────────
# 자는 동안은 프로세스도 멈추므로, 벽시계가 크게 점프하면 잔 것으로 본다.
# (sleep 30 을 걸어두고 실제 경과가 훨씬 길면 그 차이가 잔 시간이다)
# SECONDS 는 bash 내장 벽시계 경과초라 잠든 시간만큼 같이 뛴다. 매 주기 date 스폰이 없다.
last=$SECONDS
last_net=0
net_reachable && last_net=1
pending=""   # 사람이 돌아오면 날릴 kick 사유

while true; do
  sleep 30
  gap=$(( SECONDS - last ))
  last=$SECONDS

  # 30초 자려 했는데 90초 넘게 지났다 = 절전에서 깨어남
  [ "$gap" -gt 90 ] && pending="wake (${gap}s 공백)"

  # 네트워크가 끊겼다가 다시 붙은 순간
  # steady-state: scutil only. curl confirm just on the down->up transition.
  if net_reachable; then
    if [ "$last_net" = 0 ]; then
      last_net=1
      [ -z "$pending" ] && pending="network up"
    fi
  else
    last_net=0
  fi

  [ -n "$pending" ] || continue
  user_present || continue
  kick "$pending"
  pending=""
  # kick 이 내부에서 대기하는 동안 상태가 바뀜 수 있으니 다시 읽는다
  net_reachable && last_net=1 || last_net=0
  last=$SECONDS
done
