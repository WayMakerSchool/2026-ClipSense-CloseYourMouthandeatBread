#!/bin/zsh
# 시연 한 번에 켜기: 보드 IP를 MAC으로 찾고, 작은 교차로(8765)와 클립 웹(5173)을 다시 켠다.
#   scripts/start_demo.sh          # 찾고 켜기
#   scripts/start_demo.sh --find   # 보드 IP만 찾기
#   scripts/start_demo.sh --api    # 작은 교차로 모의 API까지 연결('건너세요' 시연용)
set -u
cd "$(dirname "$0")/.."
BOARD_MAC="10:b4:1d:eb:94:ac"   # 클립 보드(XIAO ESP32S3) Wi-Fi MAC

mac_ip=$(ipconfig getifaddr en0)
if [ -z "$mac_ip" ]; then echo "Mac이 Wi-Fi에 연결돼 있지 않습니다. 핫스팟에 연결하세요."; exit 1; fi
prefix=${mac_ip%.*}
echo "Mac IP: $mac_ip — 같은 망(${prefix}.x)에서 보드를 찾는 중…"
for i in $(seq 1 254); do ping -c1 -W 300 "$prefix.$i" >/dev/null 2>&1 & done; wait
board_ip=$(arp -an | grep -i " at ${BOARD_MAC} " | sed -E 's/.*\(([0-9.]+)\).*/\1/' | head -1)
if [ -z "$board_ip" ]; then
  echo "보드를 찾지 못했습니다. 보드 USB 전원·핫스팟 거리를 확인하고 30초 뒤 다시 실행하세요."; exit 1
fi
echo "보드 IP: $board_ip"
[ "${1:-}" = "--find" ] && exit 0

for port in 5173 8765; do lsof -ti tcp:$port | xargs kill 2>/dev/null; done
sleep 1
mkdir -p output/logs
nohup .venv/bin/python scripts/mini_intersection.py > output/logs/mini_intersection.log 2>&1 &
api_args=()
if [ "${1:-}" = "--api" ]; then
  api_args=(--signal-api http://127.0.0.1:8765/tapi/v2xSignalPhaseTimingFusionInformation/1.0 --itst-id SIM-0001 --direction nt)
fi
nohup .venv/bin/python clip_web.py --clip "http://$board_ip" --vision head --rotate 180 "${api_args[@]}" > output/logs/clip_web.log 2>&1 &
sleep 3
echo ""
echo "켜짐:"
echo "  신호등 화면(휴대폰 A):  http://$mac_ip:8765"
echo "  웹 화면(Mac Chrome):    http://127.0.0.1:5173"
[ "${1:-}" = "--api" ] && echo "  모의 API 연결됨 — 둘 다 초록이고 남은 시간 7초 이상이면 '건너세요' (모의 시험, 도로 시험 아님)"
