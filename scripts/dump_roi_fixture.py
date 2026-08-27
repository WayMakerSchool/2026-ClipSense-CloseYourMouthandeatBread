"""실클립 한 프레임의 중앙 ROI를 원시 BGR fixture로 덤프하고, 같은 바이트를 Python
detector.py 경로(ColorDetector)로 판정한 결과를 stdout에 출력한다.

Dart 검출기(app/lib/vision)가 실제 서울 보행등 프레임에서 Python 원본과 같은 판정을
내는지 고정하는 fixture(app/test/fixtures/real_signal_roi.*)를 만드는 용도.

사용법:
    .venv/bin/python scripts/dump_roi_fixture.py \
        --video data/real_signal_clip.mp4 --frame 0 --roi-frac 0.25 \
        --out app/test/fixtures/real_signal_roi

출력:
    <out>.bgr   헤더 없는 BGR 바이트(행 우선, [B,G,R,B,G,R,...]) — Dart RoiImage.bytes 그대로
    <out>.json  width/height/source/frame_index/crop/생성 명령 + Python 기준 판정(python_reference)

크롭은 앱 frame_converter._centerCrop과 동일: 폭·높이 = round(dim*frac)(반올림은 Dart
.round()와 같은 0.5 올림), 오프셋 = (dim - crop) // 2. 제3자 클립이므로 단일 프레임·축소
크롭만 저장한다(200KB 이하).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from pathlib import Path

import cv2

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from detector import ColorDetector  # noqa: E402

MAX_FIXTURE_BYTES = 200 * 1024


def round_half_up(x: float) -> int:
    """Dart num.round()와 같은 반올림(0.5는 0에서 먼 쪽). 양수 전제."""
    return int(math.floor(x + 0.5))


def center_crop(width: int, height: int, roi_frac: float) -> tuple[int, int, int, int]:
    """(x, y, w, h). app/lib/camera/frame_converter.dart _centerCrop 과 동일."""
    if not (0 < roi_frac <= 1):
        raise ValueError(f"roi_frac must be in (0, 1]: {roi_frac}")
    cw = min(max(round_half_up(width * roi_frac), 1), width)
    ch = min(max(round_half_up(height * roi_frac), 1), height)
    return (width - cw) // 2, (height - ch) // 2, cw, ch


def relative_to_root(p: Path) -> str:
    """저장소 루트 아래면 상대 경로, 아니면 그대로."""
    try:
        return str(p.resolve().relative_to(ROOT))
    except ValueError:
        return str(p)


def read_frame(video: Path, frame_index: int):
    cap = cv2.VideoCapture(str(video))
    if not cap.isOpened():
        raise SystemExit(f"영상을 열 수 없음: {video}")
    frame = None
    for i in range(frame_index + 1):
        ok, frame = cap.read()
        if not ok:
            raise SystemExit(f"프레임 {frame_index} 없음 (총 {i}프레임)")
    cap.release()
    return frame


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--video", required=True, help="입력 mp4 경로")
    ap.add_argument("--frame", type=int, default=0, help="프레임 번호(0부터)")
    ap.add_argument("--roi-frac", type=float, default=0.25, help="중앙 ROI 비율 (앱 kRoiFrac)")
    ap.add_argument("--out", required=True, help="출력 경로 접두사 (<out>.bgr, <out>.json)")
    ap.add_argument("--config", default=str(ROOT / "config.json"), help="detector 설정 JSON")
    args = ap.parse_args()

    frame = read_frame(Path(args.video), args.frame)
    fh, fw = frame.shape[:2]
    x, y, w, h = center_crop(fw, fh, args.roi_frac)
    roi = frame[y:y + h, x:x + w].copy()  # 연속 메모리로 (tobytes 행 우선 보장)
    raw = roi.tobytes()
    if len(raw) != w * h * 3:
        raise SystemExit(f"바이트 수 불일치: {len(raw)} != {w * h * 3}")
    if len(raw) > MAX_FIXTURE_BYTES:
        raise SystemExit(f"fixture가 {MAX_FIXTURE_BYTES}B 초과: {len(raw)}B — roi_frac을 줄여라")

    with open(args.config, encoding="utf-8") as f:
        cfg = json.load(f)
    det = ColorDetector(cfg)  # 새 검출기 — EMA 초기화·이력 없음(Dart 테스트와 같은 조건)
    res = det.detect(roi)
    reference = {
        "raw": res.raw,
        "reason": res.reason,
        "brightness": round(res.brightness, 4),
        "green_area_ratio": round(res.green.area_ratio, 6),
        "green_circularity": round(res.green.circularity, 6),
        "green_valid": res.green.valid,
        "red_area_ratio": round(res.red.area_ratio, 6),
        "red_circularity": round(res.red.circularity, 6),
        "red_valid": res.red.valid,
    }

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.with_suffix(".bgr").write_bytes(raw)
    meta = {
        "width": w,
        "height": h,
        "channels": 3,
        "layout": "BGR row-major, no header (RoiImage.bytes)",
        "source": Path(args.video).name,
        "source_frame_size": [fw, fh],
        "frame_index": args.frame,
        "crop": {"x": x, "y": y, "width": w, "height": h, "roi_frac": args.roi_frac},
        "sha256": hashlib.sha256(raw).hexdigest(),
        # 재생성 명령(저장소 루트 기준). 클립은 gitignore된 data/ 아래에 두는 것이 관례.
        "regenerate_cmd": (
            f"python scripts/dump_roi_fixture.py --video data/{Path(args.video).name} "
            f"--frame {args.frame} --roi-frac {args.roi_frac} --out {relative_to_root(out)}"
        ),
        "opencv_version": cv2.__version__,
        "python_reference": reference,
    }
    out.with_suffix(".json").write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(f"프레임 {args.frame} ({fw}x{fh}) → ROI x={x} y={y} {w}x{h}, {len(raw)}B")
    print(f"저장: {out.with_suffix('.bgr')}, {out.with_suffix('.json')}")
    print("Python detector.py 판정:")
    for k, v in reference.items():
        print(f"  {k}: {v}")


if __name__ == "__main__":
    main()
