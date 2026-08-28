"""ColorDetector 신뢰도 로직 단위 테스트 (합성 numpy 프레임 주입).

사용법: python scripts/test_detector.py
"""

import json
import sys
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from detector import ColorDetector, RAW_RED, RAW_GREEN, RAW_NONE

CFG = json.loads((ROOT / "config.json").read_text(encoding="utf-8"))

FAILURES = []


def check(name: str, cond: bool, detail: str = "") -> None:
    status = "PASS" if cond else "FAIL"
    print(f"[{status}] {name}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(name)


SIZE = 200  # ROI 200x200


def frame(bg=80, circle=None):
    """circle: (BGR색, 반지름)"""
    f = np.full((SIZE, SIZE, 3), bg, np.uint8)
    if circle:
        color, r = circle
        cv2.circle(f, (SIZE // 2, SIZE // 2), r, color, -1)
    return f


RED = (40, 40, 235)
RED_DIM = (30, 30, 120)   # 어두운 빨강 (밝기 급변 없이 blob_too_large 테스트용)
GREEN = (70, 210, 80)

det = ColorDetector(CFG)

# 1. 빈 회색 프레임 → no_blob (EMA 초기화)
r = det.detect(frame())
check("빈 프레임 → NONE/no_blob", r.raw == RAW_NONE and r.reason == "no_blob",
      f"실제: {r.raw}/{r.reason}")

# 2. 빨간 원 → RED
r = det.detect(frame(circle=(RED, 25)))
check("빨간 원 → RED", r.raw == RAW_RED, f"실제: {r.raw}/{r.reason}")

# 3. 초록 원 → GREEN
r = det.detect(frame(circle=(GREEN, 25)))
check("초록 원 → GREEN", r.raw == RAW_GREEN, f"실제: {r.raw}/{r.reason}")

# 4. 아주 어두운 프레임(렌즈 가림) → too_dark
r = det.detect(frame(bg=10))
check("어두운 프레임 → too_dark", r.raw == RAW_NONE and r.reason == "too_dark",
      f"실제: {r.raw}/{r.reason}")

# 5. 밝기 급변(밝은 회색으로 가림) → brightness_jump
r = det.detect(frame(bg=200))
check("밝기 급변 → brightness_jump",
      r.raw == RAW_NONE and r.reason == "brightness_jump",
      f"실제: {r.raw}/{r.reason}")

# 6. ROI 대부분을 덮는 빨간 물체 → blob_too_large (신호등이 아님)
det2 = ColorDetector(CFG)
det2.detect(frame())  # EMA 초기화
r = det2.detect(frame(circle=(RED_DIM, 94)))  # 면적 ≈ 70% > max 60%
check("과대 blob → blob_too_large",
      r.raw == RAW_NONE and r.reason == "blob_too_large",
      f"실제: {r.raw}/{r.reason} (red {r.red.area_ratio:.2f})")

# 7. 검출 히스테리시스: 진입 임계(0.5%) 미달이지만 이탈 임계(0.3%) 이상인
#    작은 초록 blob은 '직전에 GREEN이었을 때만' 유지된다
det3 = ColorDetector(CFG)
det3.detect(frame())                              # EMA 초기화, last=NONE
r_small_first = det3.detect(frame(circle=(GREEN, 7)))   # 0.38% < 0.5% → NONE
r_big = det3.detect(frame(circle=(GREEN, 25)))          # 확실한 GREEN
r_small_after = det3.detect(frame(circle=(GREEN, 7)))   # 0.38% ≥ 0.3% → 유지
check("히스테리시스: 진입 전 작은 blob 거부", r_small_first.raw == RAW_NONE,
      f"실제: {r_small_first.raw} ({r_small_first.green.area_ratio:.4f})")
check("히스테리시스: 검출 중 작은 blob 유지",
      r_big.raw == RAW_GREEN and r_small_after.raw == RAW_GREEN,
      f"실제: {r_big.raw} → {r_small_after.raw}")


# --- 7세그 숫자 획 배제: 신호등 램프는 정사각형에 가깝고, 카운트다운 숫자는 세로로 길다 ---
# 실클립 실측(data/real_signal_clip.mp4, ROI 25%): 초록 램프 종횡비 0.48~0.92,
# 빨간 7세그 숫자 획 0.12~0.42 → 임계 0.45로 분리(양쪽 여유).
def bar(color, w, h):
    """세로로 긴 막대(7세그 숫자 획 모사)."""
    f = np.full((SIZE, SIZE, 3), 80, np.uint8)
    x0, y0 = (SIZE - w) // 2, (SIZE - h) // 2
    cv2.rectangle(f, (x0, y0), (x0 + w, y0 + h), color, -1)
    return f


det_bar = ColorDetector(CFG)
r_bar = det_bar.detect(bar(RED, 12, 60))   # 종횡비 0.20, 면적 1.8% (임계 통과)
check("세로로 긴 빨간 획(숫자)은 신호등이 아니다 → NONE",
      r_bar.raw == RAW_NONE,
      f"실제: {r_bar.raw} area={r_bar.red.area_ratio:.4f} ar={r_bar.red.aspect_ratio:.2f}")

det_sq = ColorDetector(CFG)
r_sq = det_sq.detect(bar(RED, 40, 45))     # 종횡비 0.89 (램프 모양)
check("정사각형에 가까운 빨간 blob은 램프로 인정 → RED",
      r_sq.raw == RAW_RED,
      f"실제: {r_sq.raw} ar={r_sq.red.aspect_ratio:.2f}")

det_wide = ColorDetector(CFG)
r_wide = det_wide.detect(bar(GREEN, 60, 12))  # 가로로 긴 것도 램프 아님(종횡비 5.0)
check("가로로 긴 초록 blob도 램프가 아니다 → NONE",
      r_wide.raw == RAW_NONE,
      f"실제: {r_wide.raw} ar={r_wide.green.aspect_ratio:.2f}")

print("=" * 50)
if FAILURES:
    print(f"FAIL {len(FAILURES)}건: {FAILURES}")
    sys.exit(1)
print("검출기 단위 테스트 전부 PASS")
