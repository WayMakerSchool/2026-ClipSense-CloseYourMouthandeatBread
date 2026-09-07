#!/usr/bin/env python3
"""클립 카메라 프레임 크기·ROI 비율에 따른 검출 가능성 실측.

펌웨어 기본 프로필은 QVGA(320x240) 전체 프레임을 보낸다. 폰 경로는 1280x720
프레임의 중앙 25%(320x180)를 쓰므로 같은 ROI 비율을 클립 프레임에 그대로 쓰면
램프가 몇 픽셀로 줄어든다. 실제 서울 보행등 클립(data/real_signal_clip.mp4,
gitignore)을 QVGA/VGA로 줄이고 중앙 크롭 비율별로 Python detector.py 를 통과시켜
GREEN 프레임 수와 초록 blob 면적 비율을 기록한다.

2026-09-07 실측(84프레임, 16:9 원본을 4:3으로 리사이즈 — 실제 클립 카메라
센서는 4:3 원생이라 왜곡이 없으므로 이 표는 하한 추정이다):

    320x240 roi=1.0  -> GREEN  0/84  green_area max=0.0023  (전부 no_blob)
    320x240 roi=0.5  -> GREEN 59/84  green_area max=0.0069
    320x240 roi=0.25 -> GREEN 42/84  green_area max=0.0275
    640x480 roi=1.0  -> GREEN  0/84  green_area max=0.0043  (전부 no_blob)
    640x480 roi=0.5  -> GREEN 66/84  green_area max=0.0091
    640x480 roi=0.25 -> GREEN 30/84  green_area max=0.0291

결론: 전체 프레임(roi=1.0)은 min_area_ratio 0.005 를 절대 넘지 못한다 → 클립
소스는 중앙 크롭이 필수. 이 표만 보면 0.5 가 가장 많은 프레임을 잡지만, 4:3 으로
정직하게 자른 QVGA fixture(scripts/dump_clip_qvga_fixture.py)에서는 0.5 가 점멸
**소등** 프레임(34)에서도 GREEN(0.82%) 을 내 점멸을 놓치므로 기본값은 0.25 다
(app/lib/app/config.dart kClipRoiFrac). 0.25 는 조준이 없는 옷깃 카메라에서 램프가
크롭 밖으로 나가는 프레임이 늘어나는 대가가 있다(안전 방향: 못 보면 대기).
실기기 프레임으로 다시 측정할 것.

    .venv/bin/python scripts/measure_clip_frame_size.py [--video PATH]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from detector import ColorDetector  # noqa: E402


def center_crop(img: np.ndarray, frac: float) -> np.ndarray:
    h, w = img.shape[:2]
    cw, ch = int(w * frac), int(h * frac)
    x, y = (w - cw) // 2, (h - ch) // 2
    return img[y : y + ch, x : x + cw]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--video", default="data/real_signal_clip.mp4")
    ap.add_argument("--config", default="config.json")
    args = ap.parse_args()

    if not Path(args.video).exists():
        print(f"영상 없음: {args.video} (gitignore 된 실클립이 필요하다)")
        return 2
    cfg = json.load(open(args.config, encoding="utf-8"))
    cap = cv2.VideoCapture(args.video)
    frames = []
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        frames.append(frame)
    if not frames:
        print("프레임을 읽지 못했다")
        return 2
    print(f"frames: {len(frames)} source: {frames[0].shape[1]}x{frames[0].shape[0]}")

    for size in [(320, 240), (640, 480)]:
        for frac in [1.0, 0.5, 0.25]:
            det = ColorDetector(cfg)
            greens = 0
            areas = []
            reasons: dict[str, int] = {}
            for frame in frames:
                small = cv2.resize(frame, size, interpolation=cv2.INTER_AREA)
                result = det.detect(center_crop(small, frac))
                greens += result.raw == "GREEN"
                areas.append(result.green.area_ratio)
                reasons[result.reason] = reasons.get(result.reason, 0) + 1
            print(
                f"{size[0]}x{size[1]} roi={frac:<4} -> GREEN {greens:2d}/{len(frames)}"
                f"  green_area max={max(areas):.4f} mean={float(np.mean(areas)):.4f}"
                f"  reasons={reasons}"
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
