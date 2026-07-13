"""HSV 튜닝 도우미 — ROI 안의 색/형태 통계를 콘솔에 요약 출력.

디버그 창을 캡처해 보내는 대신, 이 스크립트의 텍스트 출력만 붙여넣으면
어느 임계를 어떻게 바꿀지 판단할 수 있다. 영상 파일이든 웹캠이든 동작한다.

사용법:
    # 영상 파일 (경로 B — 웹캠 노이즈 없이 가장 깨끗)
    python scripts/tune_hsv.py --video data/reference.mp4 --roi x,y,w,h

    # 웹캠으로 모니터 촬영 (경로 A — 부스와 동일 조건)
    python scripts/tune_hsv.py --camera 0 --roi x,y,w,h

    # ROI를 모르면 --roi 없이 실행 → 첫 프레임에서 드래그로 지정
    python scripts/tune_hsv.py --video data/reference.mp4

무엇을 보나:
- 현재 config로 검출되는 빨강/초록 마스크 비율·원형도·판정
- ROI 안에서 '실제로 가장 많은 색'의 HSV 값 (config 범위와 비교용)
- 이 두 가지를 프레임 구간별로 요약해서, 신호가 바뀌는 지점의 색을 보여준다
"""

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from detector import ColorDetector, RAW_RED, RAW_GREEN, RAW_NONE


def dominant_hsv(roi_bgr: np.ndarray) -> tuple:
    """ROI에서 밝은(채도·명도 높은) 픽셀들의 대표 HSV. 신호등 램프 후보."""
    hsv = cv2.cvtColor(cv2.GaussianBlur(roi_bgr, (5, 5), 0), cv2.COLOR_BGR2HSV)
    h, s, v = hsv[..., 0], hsv[..., 1], hsv[..., 2]
    bright = (s > 80) & (v > 80)  # 채도·명도 높은 픽셀만 (배경 제외)
    if bright.sum() < 20:
        return None
    return (int(np.median(h[bright])), int(np.median(s[bright])),
            int(np.median(v[bright])), int(bright.sum()))


def main() -> int:
    parser = argparse.ArgumentParser(description="HSV 튜닝 도우미")
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument("--video")
    src.add_argument("--camera", type=int)
    parser.add_argument("--roi", help="x,y,w,h")
    parser.add_argument("--config", default=str(ROOT / "config.json"))
    parser.add_argument("--every", type=float, default=0.5,
                        help="몇 초마다 한 줄 요약할지 (기본 0.5초)")
    args = parser.parse_args()

    cfg = json.loads(Path(args.config).read_text(encoding="utf-8"))
    cap = cv2.VideoCapture(args.video if args.video else args.camera)
    if not cap.isOpened():
        print("오류: 입력을 열 수 없습니다.")
        return 1
    fps = cap.get(cv2.CAP_PROP_FPS)
    if not fps or fps <= 0 or fps > 240:
        fps = 30.0

    ok, first = cap.read()
    if not ok:
        print("오류: 첫 프레임 실패.")
        return 1

    if args.roi:
        roi = tuple(int(v) for v in args.roi.split(","))
    else:
        print("신호등 영역을 드래그하고 Enter (등 크기의 2~3배 여유).")
        x, y, w, h = cv2.selectROI("tune: drag signal ROI", first)
        cv2.destroyAllWindows()
        roi = (int(x), int(y), int(w), int(h))
        if roi[2] == 0 or roi[3] == 0:
            print("ROI 미지정. 종료.")
            return 1
    print(f"ROI={list(roi)}  fps={fps:.1f}")
    print("config HSV 빨강:", cfg["hsv"]["red"], "초록:", cfg["hsv"]["green"])
    print("-" * 78)
    print(f"{'t(s)':>6} {'판정':>6} {'red%':>6} {'redCirc':>7} "
          f"{'grn%':>6} {'grnCirc':>7} {'ROI대표HSV(밝은픽셀)':>20}")

    detector = ColorDetector(cfg)
    x, y, w, h = roi
    fh, fw = first.shape[:2]
    x, w = max(0, x), min(w, fw - x)
    y, h = max(0, y), min(h, fh - y)

    raw_counter = Counter()
    frame_idx = 0
    next_report = 0.0
    cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        t = frame_idx / fps
        crop = frame[y:y + h, x:x + w]
        res = detector.detect(crop)
        raw_counter[res.raw] += 1
        if t >= next_report:
            dom = dominant_hsv(crop)
            dom_s = (f"H{dom[0]} S{dom[1]} V{dom[2]} (n={dom[3]})"
                     if dom else "밝은픽셀 거의없음")
            reason = f" [{res.reason}]" if res.reason else ""
            print(f"{t:6.1f} {res.raw:>6} {res.red.area_ratio * 100:6.2f} "
                  f"{res.red.circularity:7.2f} {res.green.area_ratio * 100:6.2f} "
                  f"{res.green.circularity:7.2f}  {dom_s}{reason}")
            next_report += args.every
        frame_idx += 1
    cap.release()

    total = sum(raw_counter.values())
    print("-" * 78)
    print(f"전체 {total}프레임 판정 분포: "
          f"RED {raw_counter[RAW_RED]} / GREEN {raw_counter[RAW_GREEN]} / "
          f"NONE {raw_counter[RAW_NONE]}")
    print("\n[이 출력을 그대로 붙여넣으면 HSV 임계 조정을 도와드립니다]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
