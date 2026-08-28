"""실클립의 램프를 축소해 원거리를 모사하고, 검출 한계와 임계값 트레이드오프를 잰다.

현장에서 "몇 미터까지 인식되나"를 재기 전에, 코드가 어느 크기까지 잡는지 실측한다.
프레임 전체를 줄이면 ROI도 같이 줄어 램프의 상대 크기가 그대로이므로, ROI 크기는
고정한 채 램프만 축소해 중립 배경에 합성한다(= 실제로 멀어지는 것과 같은 효과).

사용법:
    .venv/bin/python scripts/measure_detection_range.py --video data/real_signal_clip.mp4

결과 해석(2026-08-28 기준값, real_signal_clip.mp4):
    기준 거리(클립 촬영 위치)의 약 2.0배까지 8/8 검출, 2.2배에서 6/8, 2.5배부터 실패.
    한계는 화면 속 램프 폭 22px 부근.
    min_area_ratio를 0.005 → 0.002로 낮추면 3.3배까지 늘지만, 잔여시간 빨간 숫자의
    획 두 개가 붙어 램프 모양(종횡비 0.46~0.68)이 되는 프레임이 생겨 RED 오판이
    부활한다(5프레임). 형태 필터로도 못 막으므로 0.005를 유지한다 —
    거리는 사용자가 다가가 해결할 수 있지만, 오판은 사용자가 알아챌 수 없다.
"""

from __future__ import annotations

import argparse
import copy
import json
import sys
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from detector import ColorDetector  # noqa: E402

# 초록이 켜져 있는 프레임 / 초록이 꺼지고 빨간 숫자만 있는 프레임(오판 감시용).
GREEN_FRAMES = [0, 4, 20, 24, 44, 50, 66, 70]
DIGIT_FRAMES = [30, 34, 38, 54, 56, 58]
NEUTRAL_GRAY = 110


def read_frames(video: str) -> list[np.ndarray]:
    cap = cv2.VideoCapture(video)
    if not cap.isOpened():
        raise SystemExit(f"영상을 열 수 없음: {video}")
    frames = []
    while True:
        ok, f = cap.read()
        if not ok:
            break
        frames.append(f)
    cap.release()
    if not frames:
        raise SystemExit("프레임을 하나도 읽지 못했다")
    return frames


def center_roi(frame: np.ndarray, roi_frac: float) -> np.ndarray:
    fh, fw = frame.shape[:2]
    cw, ch = round(fw * roi_frac), round(fh * roi_frac)
    x, y = (fw - cw) // 2, (fh - ch) // 2
    return frame[y : y + ch, x : x + cw].copy()


def shrink_into_roi(roi: np.ndarray, scale: float) -> np.ndarray:
    """ROI 크기는 유지한 채 내용만 scale배로 줄여 중립 회색 배경에 놓는다."""
    if scale >= 1.0:
        return roi
    h, w = roi.shape[:2]
    small = cv2.resize(
        roi, (max(int(w * scale), 8), max(int(h * scale), 8)),
        interpolation=cv2.INTER_AREA,
    )
    bg = np.full((h, w, 3), NEUTRAL_GRAY, np.uint8)
    sh, sw = small.shape[:2]
    y0, x0 = (h - sh) // 2, (w - sw) // 2
    bg[y0 : y0 + sh, x0 : x0 + sw] = small
    return bg


def detect_count(cfg: dict, frames, indices, roi_frac, scale, want: str) -> int:
    hits = 0
    for i in indices:
        roi = shrink_into_roi(center_roi(frames[i], roi_frac), scale)
        # 프레임마다 새 검출기 — EMA·히스테리시스 이력 없이 순수 판정만 본다.
        if ColorDetector(cfg).detect(roi).raw == want:
            hits += 1
    return hits


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--video", default=str(ROOT / "data" / "real_signal_clip.mp4"))
    ap.add_argument("--roi-frac", type=float, default=0.25)
    ap.add_argument("--config", default=str(ROOT / "config.json"))
    ap.add_argument(
        "--lamp-width",
        type=float,
        default=48.0,
        help="원본 프레임에서 램프 폭(px). 한계 px 환산용",
    )
    args = ap.parse_args()

    with open(args.config, encoding="utf-8") as f:
        base = json.load(f)
    frames = read_frames(args.video)

    scales = [1.0, 0.8, 0.7, 0.6, 0.5, 0.45, 0.4, 0.35, 0.3]
    print(f"영상 {Path(args.video).name}, {len(frames)}프레임, ROI {args.roi_frac:.0%}")
    print("\n[1] 현재 설정에서 거리 한계")
    print("  거리배수  초록검출  램프폭")
    for s in scales:
        hits = detect_count(base, frames, GREEN_FRAMES, args.roi_frac, s, "GREEN")
        print(
            f"  x{1 / s:4.1f}     {hits}/{len(GREEN_FRAMES)}      "
            f"{args.lamp_width * s:4.0f}px"
        )

    print("\n[2] min_area_ratio를 낮추면? (거리 이득 vs 숫자 오판)")
    print("  min_area   x2.0  x2.5  x2.9  x3.3 | 숫자 프레임 RED 오판")
    for ma in [0.005, 0.003, 0.002, 0.0015, 0.001]:
        cfg = copy.deepcopy(base)
        cfg["min_area_ratio"] = ma
        row = [
            detect_count(cfg, frames, GREEN_FRAMES, args.roi_frac, s, "GREEN")
            for s in (0.5, 0.4, 0.35, 0.3)
        ]
        bad = detect_count(cfg, frames, DIGIT_FRAMES, args.roi_frac, 1.0, "RED")
        cells = "  ".join(f"{h}/{len(GREEN_FRAMES)}" for h in row)
        print(f"  {ma:.4f}    {cells} |  {bad}/{len(DIGIT_FRAMES)}")

    print(
        "\n결론: 오판 0을 유지하는 min_area_ratio=0.005를 쓴다. 거리는 사용자가"
        " 다가가 해결할 수 있지만, 빨간 숫자를 빨간불로 읽는 오판은 알아챌 수 없다."
    )


if __name__ == "__main__":
    main()
