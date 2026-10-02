#!/usr/bin/env bash
# ClipSense 시연 실행기 — 실제 앱 판정 코드를 클립 카메라 시뮬레이터에 붙여 한 흐름을 재생한다.
#
#   scripts/run_demo_flow.sh                       # 초록 정지 프레임 + 가정 API → 보행 안내까지
#   scripts/run_demo_flow.sh --scene blink         # 초록 점멸(실제 프레임 2장 교대) → 대기
#   scripts/run_demo_flow.sh --fault freeze --fault-at 8   # 도중에 카메라 정지 주입
#   scripts/run_demo_flow.sh --api nokey           # API 키 미설정 상태 그대로
#   scripts/run_demo_flow.sh --api live            # 서울 T-Data 실서버 (키 필요, 5분 1회 제한)
#   scripts/run_demo_flow.sh --video data/real_signal_clip.mp4   # 로컬 실촬영 영상 사용
#   scripts/run_demo_flow.sh --webcam 0             # 노트북 카메라를 클립 카메라 대신 사용(라이브)
#
# 카메라 입력은 app/test/fixtures/clip_qvga_f20.jpg(초록 점등)·f34.jpg(점멸 소등) — 실제 서울
# 보행신호등 촬영본에서 펌웨어 기본 프로필(320x240 JPEG)로 뽑은 프레임이다.
# 실기기 시연이 아니다: 보드 대신 시뮬레이터가 같은 HTTP 계약으로 프레임을 낸다.
set -euo pipefail
cd "$(dirname "$0")/.."

SCENE=steady; API=scripted; SECONDS_RUN=25; VIDEO=""; WEBCAM=0; FAULT=""; FAULT_AT=0; FAULT_FOR=5
ITST=1537; DIR=ne
while [ $# -gt 0 ]; do
  case "$1" in
    --scene) SCENE="$2"; shift 2;;
    --api) API="$2"; shift 2;;
    --seconds) SECONDS_RUN="$2"; shift 2;;
    --video) VIDEO="$2"; SCENE=video; shift 2;;
    --webcam) WEBCAM="$2"; SCENE=webcam; shift 2;;
    --fault) FAULT="$2"; shift 2;;
    --fault-at) FAULT_AT="$2"; shift 2;;
    --fault-for) FAULT_FOR="$2"; shift 2;;
    --itst) ITST="$2"; shift 2;;
    --dir) DIR="$2"; shift 2;;
    -h|--help) sed -n '2,14p' "$0"; exit 0;;
    *) echo "알 수 없는 옵션: $1" >&2; exit 2;;
  esac
done

PY=.venv/bin/python; [ -x "$PY" ] || PY=python3
F20=app/test/fixtures/clip_qvga_f20.jpg; F34=app/test/fixtures/clip_qvga_f34.jpg
case "$SCENE" in
  steady) SIM_INPUT=(--jpeg "$F20");;
  blink)  SIM_INPUT=(--jpeg "$F20,$F34" --hold-frames 2);;
  video)  SIM_INPUT=(--video "$VIDEO");;
  webcam) SIM_INPUT=(--webcam "$WEBCAM");;
  *) echo "--scene 은 steady|blink 중 하나 (또는 --video/--webcam)" >&2; exit 2;;
esac

KEY_DEFINE=()
if [ "$API" = live ]; then
  KEY="${TDATA_KEY:-}"
  [ -z "$KEY" ] && [ -f "$HOME/.clipsense/tdata_key" ] && KEY="$(tr -d '\r\n ' < "$HOME/.clipsense/tdata_key")"
  [ -z "$KEY" ] && { echo "--api live 에는 TDATA_KEY 또는 ~/.clipsense/tdata_key 가 필요합니다." >&2; exit 2; }
  KEY_DEFINE=(--dart-define=TDATA_KEY="$KEY")
fi

TOKEN="$("$PY" -c 'import secrets; print(secrets.token_hex(16))')"
LOG="$(mktemp)"
CLIP_DEVICE_TOKEN="$TOKEN" "$PY" scripts/clip_cam_sim.py --port 0 --quiet "${SIM_INPUT[@]}" >"$LOG" 2>&1 &
SIM_PID=$!
trap 'kill $SIM_PID 2>/dev/null || true; rm -f "$LOG"' EXIT
for _ in $(seq 1 100); do grep -q listening "$LOG" && break; sleep 0.1; done
URL="$(grep -o 'http://[0-9.:]*' "$LOG" | head -1)"
[ -n "$URL" ] || { cat "$LOG" >&2; exit 1; }

echo "ClipSense 시연 — 장면: $SCENE · API: $API · 교차로 $ITST/$DIR · ${SECONDS_RUN}초"
echo "카메라: 클립 카메라 시뮬레이터 $URL (실제 신호등 프레임, 실기기 아님)"
[ "$API" = scripted ] && echo "API: 가정값(SCRIPTED) — 실측 아님. 초록 20초에서 줄어들다 빨강"
echo

cd app
flutter test test/demo/demo_flow_test.dart --reporter expanded \
  --dart-define=CLIP_SIM_URL="$URL" --dart-define=CLIP_SIM_TOKEN="$TOKEN" \
  --dart-define=DEMO_API="$API" --dart-define=DEMO_SECONDS="$SECONDS_RUN" \
  --dart-define=DEMO_ITST="$ITST" --dart-define=DEMO_DIR="$DIR" \
  --dart-define=DEMO_FAULT="$FAULT" --dart-define=DEMO_FAULT_AT="$FAULT_AT" \
  --dart-define=DEMO_FAULT_FOR="$FAULT_FOR" \
  ${KEY_DEFINE[@]+"${KEY_DEFINE[@]}"} 2>&1 | sed -n 's/^│ //p'
