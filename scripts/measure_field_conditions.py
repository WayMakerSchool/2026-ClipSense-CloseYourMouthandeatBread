"""실클립을 변형해 야외 조건(야간·역광·조준 흔들림·자동노출 수렴)에서 검출이
버티는지 잰다. 실기기 촬영 전에 코드로 확인할 수 있는 것을 모아 둔 하니스.

거리 한계는 별도 스크립트(measure_detection_range.py)에서 다룬다.

사용법:
    .venv/bin/python scripts/measure_field_conditions.py

결과 요약(2026-08-28, real_signal_clip.mp4, ROI 25%):
    야간(배경만 어둡게)      ROI 평균 밝기 12까지 8/8 — 밝기 게이트를 유효 blob이
                             없을 때만 걸도록 고친 뒤 회복(고치기 전 0/8).
    역광(배경만 밝게)        3배까지 8/8.
    조준 흔들림(ROI 이동)    램프가 ROI 안에 있으면 100px 이동까지 8/8.
    자동노출 수렴            어두운 시작에서 3번째 처리 프레임(~0.3초)에 첫 GREEN.
                             노출이 크게 뛰는 순간 brightness_jump로 1프레임 보류(정상).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from detector import ColorDetector  # noqa: E402

GREEN_FRAMES = [0, 4, 20, 24, 44, 50, 66, 70]


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


def center_roi(frame: np.ndarray, roi_frac: float, shift_x: int = 0) -> np.ndarray:
    fh, fw = frame.shape[:2]
    cw, ch = round(fw * roi_frac), round(fh * roi_frac)
    x = max(0, min((fw - cw) // 2 + shift_x, fw - cw))
    y = (fh - ch) // 2
    return frame[y : y + ch, x : x + cw].copy()


def relight(cfg: dict, roi: np.ndarray, background_gain: float) -> np.ndarray:
    """램프 픽셀 밝기는 유지한 채 배경만 밝기를 조절한다(야간·역광 모사)."""
    mask = ColorDetector(cfg).detect(roi).green_mask
    out = roi.astype(np.float32) * background_gain
    if mask is not None:
        out[mask > 0] = roi[mask > 0]
    return out.clip(0, 255).astype(np.uint8)


def green_hits(cfg: dict, rois) -> int:
    return sum(1 for roi in rois if ColorDetector(cfg).detect(roi).raw == "GREEN")


def mean_brightness(rois) -> float:
    return float(
        np.mean([cv2.cvtColor(r, cv2.COLOR_BGR2HSV)[..., 2].mean() for r in rois])
    )


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--video", default=str(ROOT / "data" / "real_signal_clip.mp4"))
    ap.add_argument("--roi-frac", type=float, default=0.25)
    ap.add_argument("--config", default=str(ROOT / "config.json"))
    args = ap.parse_args()

    with open(args.config, encoding="utf-8") as f:
        cfg = json.load(f)
    frames = read_frames(args.video)
    n = len(GREEN_FRAMES)
    base = [center_roi(frames[i], args.roi_frac) for i in GREEN_FRAMES]

    print(f"영상 {Path(args.video).name}, ROI {args.roi_frac:.0%}, 초록 프레임 {n}개\n")

    print("[1] 야간 — 배경만 어둡게, LED 램프 밝기는 유지")
    print("  배경감쇠  ROI평균V  검출")
    for gain in [1.0, 0.6, 0.4, 0.25, 0.15, 0.08]:
        rois = [relight(cfg, r, gain) for r in base]
        print(f"  {gain:5.2f}    {mean_brightness(rois):6.1f}   {green_hits(cfg, rois)}/{n}")

    print("\n[2] 역광 — 배경만 밝게(하늘), 램프는 유지")
    print("  배경증폭  ROI평균V  검출")
    for gain in [1.0, 1.5, 2.0, 2.5, 3.0]:
        rois = [relight(cfg, r, gain) for r in base]
        print(f"  {gain:5.2f}    {mean_brightness(rois):6.1f}   {green_hits(cfg, rois)}/{n}")

    print("\n[3] 조준 흔들림 — ROI를 옆으로 이동")
    print("  이동px  검출")
    for shift in [0, 20, 40, 60, 80, 100]:
        rois = [center_roi(frames[i], args.roi_frac, shift) for i in GREEN_FRAMES]
        print(f"  {shift:4d}    {green_hits(cfg, rois)}/{n}")

    print("\n[4] 자동노출 수렴 — 어두운 첫 프레임에서 시작(연속 처리, EMA 이력 유지)")
    detector = ColorDetector(cfg)
    schedule = [0.35] * 3 + [0.5] * 3 + [0.7] * 3 + [0.85] * 3 + [1.0] * 10
    roi0 = center_roi(frames[20], args.roi_frac)
    first_green = None
    for step, gain in enumerate(schedule):
        dim = (roi0.astype(np.float32) * gain).clip(0, 255).astype(np.uint8)
        result = detector.detect(dim)
        if result.raw == "GREEN" and first_green is None:
            first_green = step
    if first_green is None:
        print("  GREEN 없음")
    else:
        # 카메라는 3프레임당 1회 처리(kCameraProcessEveryN), 30fps 가정.
        print(
            f"  첫 GREEN: {first_green}번째 처리 프레임 "
            f"(3프레임당 1회 처리·30fps 기준 약 {first_green * 3 / 30:.1f}초)"
        )


if __name__ == "__main__":
    main()
