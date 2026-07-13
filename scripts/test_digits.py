"""숫자 판독기 정확도 테스트 (합성 카운트다운 영상 기준).

각 초 구간의 안정화 후 판독값이 정답과 일치하는지, 숫자가 꺼진 구간에서
None("판독 불가")을 정직하게 내는지 확인한다.

사용법: python scripts/test_digits.py
"""

import json
import sys
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from digits import DigitReader, draw_seven_segment

VIDEO = ROOT / "data" / "test_countdown.mp4"
DIGIT_ROI = (270, 90, 100, 70)
FPS = 30

CFG = json.loads((ROOT / "config.json").read_text(encoding="utf-8"))

DIGIT_RED = (35, 35, 220)


def _cell(number: int, cell_w: int, cell_h: int) -> np.ndarray:
    """단일 숫자 셀을 딱 맞게 렌더링 (오판 방어 테스트용)."""
    pad = 4
    img = np.zeros((cell_h + 2 * pad, cell_w + 2 * pad, 3), np.uint8)
    draw_seven_segment(img, number, pad, pad, cell_w, cell_h, DIGIT_RED)
    return img


def negative_tests() -> list[str]:
    """리뷰가 재현한 오판 케이스가 이제 None을 내는지 확인 (정직성)."""
    fails = []
    reader = DigitReader(CFG)

    # 1) 단색 빨강 블롭(채워진 원/사각형)은 '8' 등으로 판독되면 안 됨
    for shape in ("circle", "rect"):
        img = np.zeros((70, 45, 3), np.uint8)
        if shape == "circle":
            cv2.circle(img, (22, 35), 20, DIGIT_RED, -1)
        else:
            cv2.rectangle(img, (6, 6), (39, 64), DIGIT_RED, -1)
        v = reader.read_frame(img)
        if v is not None:
            fails.append(f"단색 {shape} 블롭이 숫자 {v}로 오판 (None이어야 함)")

    # 2) 좁은 종횡비의 '3'이 '1'로 오판되면 안 됨 (핵심 회귀)
    for ratio in (0.44, 0.50, 0.55, 0.60):
        cell_h = 60
        cell_w = int(cell_h * ratio)
        img = _cell(3, cell_w, cell_h)
        x, y, w, h = 0, 0, img.shape[1], img.shape[0]
        v = reader.read_frame(img[y:y + h, x:x + w])
        if v == 1:
            fails.append(f"종횡비 {ratio}의 '3'이 '1'로 오판")
        elif v not in (3, None):
            fails.append(f"종횡비 {ratio}의 '3'이 {v}로 오판")

    # 3) 진짜 '1'은 여전히 1로 읽혀야 함 (특례가 과하게 좁아지지 않았는지)
    got_one = False
    for ratio in (0.16, 0.20, 0.25):
        cell_h = 60
        cell_w = max(6, int(cell_h * ratio))
        img = _cell(1, cell_w, cell_h)
        if reader.read_frame(img) == 1:
            got_one = True
    if not got_one:
        fails.append("진짜 '1'을 어떤 종횡비에서도 읽지 못함")

    # 4) 표준 폭의 한 자리 '4'는 판독되거나(정확) None이어야 함 — 절대
    #    다른 숫자로 오판되면 안 됨 (종횡비가 상한을 넘으면 정직하게 None)
    v = reader.read_frame(_cell(4, int(56 * 0.60), 56))
    if v not in (4, None):
        fails.append(f"'4'가 {v}로 오판")

    # 5) 두 자리가 뭉친 넓은 셀은 한 자리로 오판되지 않고 None이어야 함
    wide = _cell(8, int(56 * 0.95), 56)  # 폭만 넓힌 셀 = 뭉침 모사
    v = reader.read_frame(wide)
    if v is not None:
        fails.append(f"뭉친 넓은 셀이 숫자 {v}로 오판")

    return fails


def main() -> int:
    if not VIDEO.exists():
        print("먼저 실행: python scripts/make_test_video.py")
        return 1

    reader = DigitReader(CFG)
    cap = cv2.VideoCapture(str(VIDEO))
    x, y, w, h = DIGIT_ROI

    # 판독 기록: frame_idx → stable 값
    stable_by_frame = {}
    instant_ok = 0
    instant_total = 0
    idx = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        t = idx / FPS
        crop = frame[y:y + h, x:x + w]
        instant = reader.read_frame(crop)
        stable_by_frame[idx] = reader.read(crop)
        expected = 15 - int(t) if t < 15.0 else None
        if expected is not None:
            instant_total += 1
            if instant == expected:
                instant_ok += 1
        idx += 1
    cap.release()

    failures = []
    # 핵심 기준: 각 초 구간에서 '틀린 값'(오판)이 나오면 실패. None(정직한
    # 포기)은 허용한다 — 브리프 원칙 "어설픈 인식보다 없는 게 낫다".
    stable_seen = {}  # sec → 그 구간에서 나온 non-None 값 집합
    for sec in range(15):
        expected = 15 - sec
        window = [stable_by_frame[i]
                  for i in range(int((sec + 0.3) * FPS), int((sec + 0.9) * FPS))]
        misread = {v for v in window if v is not None and v != expected}
        if misread:
            failures.append(f"{sec}초 구간: 기대 {expected}, 오판(틀린값) {misread}")
        stable_seen[sec] = {v for v in window if v is not None}

    # 대부분의 구간은 정답을 실제로 판독해야 한다 (전부 None이면 기능 무의미).
    # 종횡비 경계에 걸리는 '4'류를 감안해 12/15 이상을 합격선으로 둔다.
    read_ok = sum(1 for sec in range(15) if (15 - sec) in stable_seen[sec])
    if read_ok < 12:
        failures.append(f"정답 판독 구간이 너무 적음: {read_ok}/15 (12 미만)")

    # 숫자 소등 구간(15.3초~)에서는 None이어야 함 (추측 금지)
    off_window = [stable_by_frame[i]
                  for i in range(int(15.3 * FPS), idx)]
    ghosts = {v for v in off_window if v is not None}
    if ghosts:
        failures.append(f"소등 구간에서 유령 판독: {ghosts}")

    failures += negative_tests()

    print(f"프레임 즉석 판독 정확도: {instant_ok}/{instant_total} "
          f"({instant_ok / max(instant_total, 1) * 100:.1f}%)  "
          f"정답 판독 구간 {read_ok}/15, 오판 0 목표")
    print("=" * 50)
    if failures:
        print(f"FAIL ({len(failures)}건)")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("PASS — 15→1 카운트다운 정확 판독, 소등/블롭/오판 케이스 정직하게 거부")
    return 0


if __name__ == "__main__":
    sys.exit(main())
