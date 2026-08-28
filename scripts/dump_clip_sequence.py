"""실클립 전체 프레임을 앱과 같은 중앙 ROI로 잘라 Python 파이프라인(ColorDetector →
SignalStateMachine)에 통과시키고, 그 시퀀스를 Dart 동등성 테스트용 JSON으로 덤프한다.

`dump_roi_fixture.py`가 **한 프레임**의 픽셀을 고정한다면, 이 스크립트는 **시퀀스 전체의
판정 흐름**을 고정한다. 단일 프레임이 맞아도 EMA·히스테리시스·디바운스가 누적되는
경로에서 Dart와 Python이 갈라질 수 있기 때문이다(실기기 촬영 전에 잡아야 하는 차이).

제3자 클립을 저장소에 넣지 않으므로 픽셀은 다운샘플한 소수 프레임만 담고(용량 상한),
나머지 프레임은 Python 판정 결과만 시퀀스로 기록한다. Dart 테스트는 담긴 프레임에 대해
raw/valid/면적/밝기와 상태머신 상태 전이를 대조한다.

사용법:
    .venv/bin/python scripts/dump_clip_sequence.py \
        --video data/real_signal_clip.mp4 --roi-frac 0.25 --stride 4 \
        --out app/test/fixtures/real_signal_sequence

출력:
    <out>.bgr    담긴 프레임들의 BGR 바이트를 이어 붙인 것(프레임당 w*h*3)
    <out>.json   메타 + frames[] (index, t, raw, reason, brightness, 면적/원형도, state)
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

from detector import ColorDetector, SignalStateMachine  # noqa: E402

MAX_PIXEL_BYTES = 900 * 1024


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
    try:
        return str(p.resolve().relative_to(ROOT))
    except ValueError:
        return str(p)


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--video", required=True)
    ap.add_argument("--roi-frac", type=float, default=0.25)
    ap.add_argument(
        "--pixel-frames",
        default="",
        help="픽셀을 담을 프레임 번호(쉼표). 비우면 --stride 간격",
    )
    ap.add_argument("--stride", type=int, default=4, help="픽셀을 담을 프레임 간격")
    ap.add_argument("--fps", type=float, default=30.0, help="상태머신 시간축 fps")
    ap.add_argument("--out", required=True)
    ap.add_argument("--config", default=str(ROOT / "config.json"))
    args = ap.parse_args()

    with open(args.config, encoding="utf-8") as f:
        cfg = json.load(f)

    cap = cv2.VideoCapture(args.video)
    if not cap.isOpened():
        raise SystemExit(f"영상을 열 수 없음: {args.video}")

    detector = ColorDetector(cfg)
    machine = SignalStateMachine(cfg)

    wanted: set[int] | None = None
    if args.pixel_frames:
        wanted = {int(x) for x in args.pixel_frames.split(",") if x.strip()}

    frames: list[dict] = []
    pixels = bytearray()
    crop = None
    frame_size = None
    index = 0

    while True:
        ok, frame = cap.read()
        if not ok:
            break
        fh, fw = frame.shape[:2]
        if crop is None:
            crop = center_crop(fw, fh, args.roi_frac)
            frame_size = [fw, fh]
        x, y, w, h = crop
        roi = frame[y : y + h, x : x + w].copy()

        res = detector.detect(roi)
        t = index / args.fps
        machine.update(t, res.raw, reason=res.reason)

        keep = index in wanted if wanted is not None else index % args.stride == 0
        if keep and len(pixels) + w * h * 3 <= MAX_PIXEL_BYTES:
            pixels.extend(roi.tobytes())
        else:
            keep = False

        frames.append(
            {
                "index": index,
                "t": round(t, 6),
                "pixels": keep,
                "raw": res.raw,
                "reason": res.reason,
                "brightness": round(res.brightness, 4),
                "green_area_ratio": round(res.green.area_ratio, 6),
                "green_valid": res.green.valid,
                "red_area_ratio": round(res.red.area_ratio, 6),
                "red_valid": res.red.valid,
                "state": machine.state,
            }
        )
        index += 1

    cap.release()
    if crop is None:
        raise SystemExit("프레임을 하나도 읽지 못했다")

    x, y, w, h = crop
    kept = [f["index"] for f in frames if f["pixels"]]
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.with_suffix(".bgr").write_bytes(bytes(pixels))
    meta = {
        "width": w,
        "height": h,
        "channels": 3,
        "layout": "BGR row-major, frames concatenated (w*h*3 each)",
        "source": Path(args.video).name,
        "source_frame_size": frame_size,
        "crop": {"x": x, "y": y, "width": w, "height": h, "roi_frac": args.roi_frac},
        "fps": args.fps,
        "stride": args.stride,
        "pixel_frames_arg": args.pixel_frames,
        "frame_count": len(frames),
        "pixel_frame_indices": kept,
        "sha256": hashlib.sha256(bytes(pixels)).hexdigest(),
        "regenerate_cmd": (
            f"python scripts/dump_clip_sequence.py --video data/{Path(args.video).name} "
            f"--roi-frac {args.roi_frac} "
            + (
                f"--pixel-frames {args.pixel_frames} "
                if args.pixel_frames
                else f"--stride {args.stride} "
            )
            + f"--out {relative_to_root(out)}"
        ),
        "opencv_version": cv2.__version__,
        "frames": frames,
    }
    out.with_suffix(".json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=1) + "\n", encoding="utf-8"
    )

    counts: dict[str, int] = {}
    states: dict[str, int] = {}
    for f in frames:
        counts[f["raw"]] = counts.get(f["raw"], 0) + 1
        states[f["state"]] = states.get(f["state"], 0) + 1
    print(f"{len(frames)}프레임, ROI {w}x{h} (x={x} y={y}), 픽셀 담긴 프레임 {len(kept)}개")
    print(f"raw: {counts}")
    print(f"state: {states}")
    print(f"저장: {out.with_suffix('.bgr')} ({len(pixels)}B), {out.with_suffix('.json')}")


if __name__ == "__main__":
    main()
