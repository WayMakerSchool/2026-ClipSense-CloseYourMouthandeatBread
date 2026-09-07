#!/usr/bin/env python3
"""클립 카메라가 보낼 법한 QVGA 전체 프레임 JPEG fixture 를 실클립에서 만든다.

펌웨어 기본 프로필은 320x240(4:3) 전체 프레임 JPEG 이다. 실클립(1280x720, 16:9)을
그대로 줄이면 가로가 눌리므로, 먼저 중앙 960x720(4:3)을 잘라 OV2640 원생 비율에
맞춘 뒤 INTER_AREA 로 320x240 으로 줄이고 cv2 JPEG(q80)으로 인코딩한다.

각 프레임을 Python detector.py 로 ROI 비율 1.0/0.5/0.25 에서 판정한 결과를
python_reference 로 함께 기록한다(Dart 테스트가 같은 값을 재현하는지 고정).
프레임 20은 점등(초록), 34는 점멸 소등 프레임(real_signal_sequence.json 참고).

    .venv/bin/python scripts/dump_clip_qvga_fixture.py \
        --video data/real_signal_clip.mp4 --frames 20,34 --quality 80 \
        --out app/test/fixtures/clip_qvga

주의: 제3자 클립이라 저장소에는 이 QVGA 프레임 2장만 둔다(각 10KB 미만).
cv2 가 인코딩한 JPEG 이지 OV2640 이 만든 JPEG 이 아니다 — 코덱·기하 회귀용이며
클립 카메라의 실제 인식 거리를 말해 주지 않는다. 품질 단위도 다르다: 펌웨어
config.h 의 CLIP_JPEG_QUALITY=12 는 esp32-camera 의 0~63 척도(낮을수록 고화질)이고
여기 --quality 80 은 cv2 의 0~100 척도라 서로 같은 압축률이 아니다.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

import cv2

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from detector import ColorDetector  # noqa: E402


def center_crop(img, frac):
    h, w = img.shape[:2]
    cw, ch = int(round(w * frac)), int(round(h * frac))
    x, y = (w - cw) // 2, (h - ch) // 2
    return img[y : y + ch, x : x + cw]


def to_qvga(frame):
    h, w = frame.shape[:2]
    target_w = h * 4 // 3
    x = (w - target_w) // 2
    four_three = frame[:, x : x + target_w]
    return cv2.resize(four_three, (320, 240), interpolation=cv2.INTER_AREA)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--video", default="data/real_signal_clip.mp4")
    ap.add_argument("--frames", default="20,34")
    ap.add_argument("--quality", type=int, default=80)
    ap.add_argument("--config", default="config.json")
    ap.add_argument("--out", default="app/test/fixtures/clip_qvga")
    args = ap.parse_args()

    cfg = json.load(open(args.config, encoding="utf-8"))
    wanted = [int(f) for f in args.frames.split(",")]
    cap = cv2.VideoCapture(args.video)
    frames = {}
    index = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if index in wanted:
            frames[index] = frame
        index += 1
    missing = [f for f in wanted if f not in frames]
    if missing:
        print(f"프레임 없음: {missing}")
        return 2

    meta = {
        "schema": "clipsense-qvga-fixture-v1",
        "source": Path(args.video).name,
        "source_frame_size": [frames[wanted[0]].shape[1], frames[wanted[0]].shape[0]],
        "geometry": "center 4:3 crop (960x720) -> INTER_AREA 320x240 -> cv2 JPEG",
        "jpeg_quality": args.quality,
        "opencv_version": cv2.__version__,
        "regenerate_cmd": (
            f"python scripts/dump_clip_qvga_fixture.py --video {args.video} "
            f"--frames {args.frames} --quality {args.quality} --out {args.out}"
        ),
        "frames": [],
    }
    for idx in wanted:
        qvga = to_qvga(frames[idx])
        ok, buf = cv2.imencode(".jpg", qvga, [cv2.IMWRITE_JPEG_QUALITY, args.quality])
        assert ok
        jpeg = buf.tobytes()
        path = Path(f"{args.out}_f{idx}.jpg")
        path.write_bytes(jpeg)
        # 판정 기준은 "디코드된 JPEG" — Dart 도 같은 바이트를 디코드하므로.
        decoded = cv2.imdecode(buf, cv2.IMREAD_COLOR)
        refs = {}
        for frac in (1.0, 0.5, 0.25):
            r = ColorDetector(cfg).detect(center_crop(decoded, frac))
            refs[str(frac)] = {
                "raw": r.raw,
                "reason": r.reason,
                "green_area_ratio": round(r.green.area_ratio, 5),
                "red_area_ratio": round(r.red.area_ratio, 5),
                "brightness": round(float(r.brightness), 2),
            }
        meta["frames"].append(
            {
                "frame_index": idx,
                "file": path.name,
                "bytes": len(jpeg),
                "sha256": hashlib.sha256(jpeg).hexdigest(),
                "python_reference": refs,
            }
        )
        print(f"{path.name}: {len(jpeg)}B  " + "  ".join(
            f"roi={k}:{v['raw'] or 'NONE'}({v['green_area_ratio']:.4f})" for k, v in refs.items()
        ))
    Path(f"{args.out}_fixture.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=1) + "\n", encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
