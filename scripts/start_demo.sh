#!/bin/zsh
# 시연 한 번에 켜기: 보드 IP를 MAC으로 찾고, 작은 교차로(8765)와 클립 웹(5173)을 다시 켠다.
#   scripts/start_demo.sh          # 찾고 켜기
#   scripts/start_demo.sh --find   # 보드 IP만 찾기
#   scripts/start_demo.sh --api    # 작은 교차로 모의 API까지 연결('건너세요' 시연용)
#   scripts/start_demo.sh --wifi   # USB가 꽂혀 있어도 Wi-Fi로 사진 받기
set -u
cd "$(dirname "$0")/.."
BOARD_MAC="10:b4:1d:eb:94:ac"   # 클립 보드(XIAO ESP32S3) Wi-Fi MAC

mac_ip=$(ipconfig getifaddr en0)
if [ -z "$mac_ip" ]; then echo "Mac이 Wi-Fi에 연결돼 있지 않습니다. 핫스팟에 연결하세요."; exit 1; fi
prefix=${mac_ip%.*}
echo "Mac IP: $mac_ip"
find_board() {
  for i in $(seq 1 254); do ping -c1 -W 300 "$prefix.$i" >/dev/null 2>&1 & done; wait
  arp -an | grep -i " at ${BOARD_MAC} " | sed -E 's/.*\(([0-9.]+)\).*/\1/' | head -1
}
usb=$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)
board_ip=""
if [ -n "$usb" ] && [[ " $* " != *" --wifi "* ]] && [[ " $* " != *" --find "* ]]; then
  echo "보드가 USB로 꽂혀 있음($usb) → 사진을 USB로 받습니다(Wi-Fi 찾기 생략)."
else
  echo "같은 망(${prefix}.x)에서 보드를 Wi-Fi로 찾는 중…"
  board_ip=$(find_board)
fi
if [ -z "$board_ip" ] && { [ -z "$usb" ] || [[ " $* " == *" --wifi "* ]] || [[ " $* " == *" --find "* ]]; }; then
  # USB를 다시 꽂았을 때 30초 안에 핫스팟에 못 붙으면 보드는 복구 AP 모드로 남는다(스스로 다시
  # 접속하지 않음). USB로 연결돼 있으면 리셋해서 다시 접속시키고 한 번 더 찾는다.
  port=$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)
  if [ -n "$port" ]; then
    echo "못 찾음 → 보드를 리셋해서 다시 접속시킵니다(약 30초)…"
    .venv/bin/python -c "import serial,time; s=serial.Serial('$port',115200); s.dtr=False; s.rts=True; time.sleep(0.15); s.rts=False; s.close()"
    for n in 1 2 3; do sleep 10; board_ip=$(find_board); [ -n "$board_ip" ] && break; done
  fi
fi
if [ -z "$board_ip" ] && { [ -z "$usb" ] || [[ " $* " == *" --wifi "* ]] || [[ " $* " == *" --find "* ]]; }; then
  echo "보드를 찾지 못했습니다. 보드 USB 전원, 핫스팟 휴대폰 화면 켜짐·거리(50cm 안)를 확인하고 다시 실행하세요."; exit 1
fi
[ -n "$board_ip" ] && echo "보드 IP: $board_ip"
[[ " $* " == *" --find "* ]] && exit 0

for port in 5173 8765; do lsof -ti tcp:$port | xargs kill 2>/dev/null; done
sleep 1
mkdir -p output/logs
nohup .venv/bin/python scripts/mini_intersection.py > output/logs/mini_intersection.log 2>&1 &
api_args=()
if [[ " $* " == *" --api "* ]]; then
  api_args=(--signal-api http://127.0.0.1:8765/tapi/v2xSignalPhaseTimingFusionInformation/1.0 --itst-id SIM-0001 --direction nt)
fi
# 보드가 USB로 꽂혀 있으면 사진을 USB로 받는다(Wi-Fi가 약해도 한 장 20ms 안팎). --wifi면 Wi-Fi로.
if [ -n "$usb" ] && [[ " $* " != *" --wifi "* ]]; then clip_src="serial:$usb"; else clip_src="http://$board_ip"; fi
nohup .venv/bin/python clip_web.py --clip "$clip_src" --vision head --rotate 180 "${api_args[@]}" > output/logs/clip_web.log 2>&1 &
sleep 3
echo ""
echo "켜짐:"
echo "  신호등 화면(휴대폰 A):  http://$mac_ip:8765"
echo "  웹 화면(Mac Chrome):    http://127.0.0.1:5173"
echo "  사진 받는 길:           $clip_src"
[[ " $* " == *" --api "* ]] && echo "  모의 API 연결됨 — 둘 다 초록이고 남은 시간 7초 이상이면 '건너세요' (모의 시험, 도로 시험 아님)"
exit 0
