"""숫자 판독 강건성 테스트 — 실기 왜곡을 합성 숫자에 주입해 측정.

합성 카운트다운(test_digits.py)은 이상적 조건이라 100%가 나온다. 실기
표시기는 블러·압축·색편차·기울기·저해상도가 섞인다. 이 테스트는 0~99 전
숫자에 그런 왜곡을 걸어:

  1. 오판(틀린 '값'을 확신하는 경우)이 0인지  ← 절대 기준. 하나라도 있으면 FAIL
  2. 조건별 정확 판독률(None은 오판이 아니라 '정직한 포기')  ← 참고 지표

브리프 원칙: "어설픈 숫자 인식보다 없는 게 낫다." → 오판 0이 합격선,
정확도는 채택 판단 자료.

사용법: python scripts/test_digits_robust.py
"""

import json
import sys
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from digits import DigitReader, draw_seven_segment

CFG = json.loads((ROOT / "config.json").read_text(encoding="utf-8"))
RED = (35, 35, 220)

# 재현성: 고정 시드 (Math.random 없이)
RNG = np.random.default_rng(20260713)


def render_number(number: int, cell_h=56, ratio=0.60, gap=6,
                  margin=14) -> np.ndarray:
    """숫자를 어두운 패널 위 붉은 7-세그먼트로 렌더. 실기 배치와 유사."""
    cell_w = int(cell_h * ratio)
    n = len(str(number))
    w = margin * 2 + n * cell_w + (n - 1) * gap
    h = margin * 2 + cell_h
    img = np.full((h, w, 3), 22, np.uint8)  # 어두운 패널
    draw_seven_segment(img, number, margin, margin, cell_w, cell_h, RED, gap=gap)
    return img


def distort(img: np.ndarray, kind: str) -> np.ndarray:
    if kind == "clean":
        return img
    if kind == "blur":
        return cv2.GaussianBlur(img, (5, 5), 1.5)
    if kind == "heavy_blur":
        return cv2.GaussianBlur(img, (9, 9), 3.0)
    if kind == "jpeg":
        ok, enc = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 30])
        return cv2.imdecode(enc, cv2.IMREAD_COLOR)
    if kind == "downscale":
        h, w = img.shape[:2]
        small = cv2.resize(img, (max(8, w // 3), max(8, h // 3)))
        return cv2.resize(small, (w, h), interpolation=cv2.INTER_LINEAR)
    if kind == "noise":
        noise = RNG.integers(-30, 31, img.shape, dtype=np.int16)
        return np.clip(img.astype(np.int16) + noise, 0, 255).astype(np.uint8)
    if kind == "warm_awb":  # 따뜻한 화이트밸런스 드리프트 (빨강 채도 저하)
        shifted = img.astype(np.int16)
        shifted[..., 0] = np.clip(shifted[..., 0] + 40, 0, 255)  # B 증가
        shifted[..., 1] = np.clip(shifted[..., 1] + 25, 0, 255)  # G 증가
        return shifted.astype(np.uint8)
    if kind == "rotate":  # 약간의 기울기 (카메라 각도)
        h, w = img.shape[:2]
        m = cv2.getRotationMatrix2D((w / 2, h / 2), 4.0, 1.0)
        return cv2.warpAffine(img, m, (w, h), borderValue=(22, 22, 22))
    raise ValueError(kind)


CONDITIONS = ["clean", "blur", "heavy_blur", "jpeg", "downscale",
              "noise", "warm_awb", "rotate"]


def read_with_stabilization(reader: DigitReader, roi: np.ndarray) -> int | None:
    """실사용처럼 같은 프레임을 stable_window회 공급해 안정화 값을 얻는다."""
    val = None
    for _ in range(reader.stable_window):
        val = reader.read(roi)
    return val


def main() -> int:
    numbers = list(range(0, 100))  # 0~99 전 범위
    misreads = []          # (조건, 정답, 판독값) — 틀린 값 (치명적)
    stats = {c: {"correct": 0, "none": 0} for c in CONDITIONS}

    for cond in CONDITIONS:
        for target in numbers:
            img = distort(render_number(target), cond)
            reader = DigitReader(CFG)   # 숫자마다 새 판독기 (창 오염 방지)
            val = read_with_stabilization(reader, img)
            if val is None:
                stats[cond]["none"] += 1
            elif val == target:
                stats[cond]["correct"] += 1
            else:
                misreads.append((cond, target, val))

    total = len(numbers)
    print("조건별 판독 결과 (정확 / None(정직포기) / 오판):")
    for c in CONDITIONS:
        s = stats[c]
        mis = sum(1 for m in misreads if m[0] == c)
        print(f"  {c:11}: 정확 {s['correct']:3}/{total}  "
              f"None {s['none']:3}  오판 {mis}")

    print("=" * 56)
    if misreads:
        print(f"FAIL — 오판(틀린 값 확신) {len(misreads)}건 발견:")
        for cond, tgt, val in misreads[:20]:
            print(f"  [{cond}] 정답 {tgt} → '{val}'로 오판")
        return 1

    # 오판 0 = 합격. 정확도는 참고 지표로 출력.
    clean_acc = stats["clean"]["correct"] / total * 100
    print(f"PASS — 전 조건 오판 0건 (틀린 값 없음). "
          f"이상 조건 정확도 {clean_acc:.0f}%.")
    print("  → 왜곡되면 틀린 값 대신 None으로 물러난다 (정직성 원칙 준수).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
