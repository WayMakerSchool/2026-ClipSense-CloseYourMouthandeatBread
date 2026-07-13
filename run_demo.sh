#!/usr/bin/env bash
# Clip sense 부스 데모 실행기 — 크래시 시 자동 재시작.
#
# 정상 종료(q/ESC = exit 0)면 루프를 빠져나가고,
# 예기치 못한 크래시(0 아닌 종료)면 잠깐 뒤 자동 재시작한다.
#
# 사용법:
#   ./run_demo.sh                 # 웹캠(카메라 0), 저장된 ROI 사용
#   ./run_demo.sh --reselect-roi  # ROI 다시 지정하고 시작
#   CAM=1 ./run_demo.sh           # 다른 카메라 인덱스
#   ./run_demo.sh --video data/reference.mp4   # 영상 파일로 (리허설)

set -u
cd "$(dirname "$0")"

PY=".venv/bin/python"
[ -x "$PY" ] || PY="python3"   # venv 없으면 시스템 파이썬으로 폴백

CAM="${CAM:-0}"

# --video 등 입력 인자가 오면 그대로, 아니면 기본 카메라 모드
if printf '%s\n' "$@" | grep -q -- '--video\|--camera'; then
    INPUT_ARGS=("$@")
else
    INPUT_ARGS=(--camera "$CAM" "$@")
fi

echo "Clip sense 데모 시작 (종료: 디버그 창에서 q 또는 ESC)"
echo "입력: ${INPUT_ARGS[*]}"

FAST_FAILS=0   # 10초 안에 죽은 연속 횟수 (즉시 크래시 폭주 방지)

while true; do
    START=$(date +%s)
    "$PY" main.py "${INPUT_ARGS[@]}"
    CODE=$?
    RAN=$(( $(date +%s) - START ))

    if [ "$CODE" -eq 0 ]; then
        echo "정상 종료했습니다."
        break
    fi
    if [ "$CODE" -eq 2 ]; then
        # 설정/사용법 오류 — 재시작해도 계속 실패하므로 즉시 멈춘다
        echo ""
        echo "!! 설정 오류로 종료했습니다 (위 메시지 참고). 재시작하지 않습니다."
        echo "   ROI를 다시 잡으려면: ./run_demo.sh --reselect-roi"
        exit 2
    fi

    # 10초 이상 돌다가 죽었으면 일시적 문제로 보고 카운터 리셋,
    # 즉시 죽는 게 반복되면(폭주) 백오프를 늘려 로그 홍수·CPU 낭비를 막는다
    if [ "$RAN" -ge 10 ]; then
        FAST_FAILS=0
        WAIT=2
    else
        FAST_FAILS=$((FAST_FAILS + 1))
        WAIT=$((FAST_FAILS < 5 ? 2 : 10))
    fi
    echo ""
    echo "!! 예기치 못한 종료 (코드 $CODE). ${WAIT}초 후 재시작합니다..."
    if [ "$FAST_FAILS" -ge 5 ]; then
        echo "   즉시 크래시가 계속됩니다. Ctrl+C로 멈추고 README의 문제 해결을 보세요."
    fi
    sleep "$WAIT"
done
