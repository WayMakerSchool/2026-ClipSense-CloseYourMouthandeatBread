"""노트북 카메라로 찍고 → 보드(POST /frame)로 보내고 → 보드(GET /capture)에서 다시 받는다.

클립 카메라를 쓸 수 없을 때(2026-10-15: 확장 보드 불량 의심) 보드와의 실제 통신을
검증하기 위한 도구다. 보드는 받은 프레임을 /capture 로 내줄 때 반드시
X-Frame-Source: laptop-upload, X-Camera-Sensor: LAPTOP 을 붙인다 —
이 사진은 클립 촬영이 아니다.

사용:
  # 엔터를 누를 때마다 1장 찍어 보내고, 보드에서 다시 받아 저장 (3회 기록용)
  python scripts/laptop_frame_relay.py --board http://10.185.91.103 --manual --out relay_shots

  # 0.5초마다 계속 보내기 (앱·웹이 보드에서 받아 가게 할 때)
  python scripts/laptop_frame_relay.py --board http://10.185.91.103 --interval 0.5

토큰: 환경변수 CLIP_DEVICE_TOKEN 또는 ~/.clipsense/device_token (출력하지 않는다).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

TOKEN_HEADER = "X-Clip-Device-Token"
TOKEN_FILE = Path.home() / ".clipsense" / "device_token"


def load_token() -> str:
    token = os.environ.get("CLIP_DEVICE_TOKEN", "").strip()
    if not token and TOKEN_FILE.exists():
        token = TOKEN_FILE.read_text().strip()
    if not token:
        sys.exit("토큰이 없다: CLIP_DEVICE_TOKEN 또는 ~/.clipsense/device_token")
    return token


def opener() -> urllib.request.OpenerDirector:
    # 같은 핫스팟 안의 보드로 직접 간다(프록시를 타지 않게).
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def encode_qvga(frame) -> bytes:  # noqa: ANN001
    """펌웨어 기본 프로필과 같게: 중앙 4:3 → 320x240 JPEG."""
    import cv2

    h, w = frame.shape[:2]
    target_w = min(w, h * 4 // 3)
    target_h = target_w * 3 // 4
    x0, y0 = (w - target_w) // 2, (h - target_h) // 2
    four_three = frame[y0:y0 + target_h, x0:x0 + target_w]
    small = cv2.resize(four_three, (320, 240), interpolation=cv2.INTER_AREA)
    ok, buf = cv2.imencode(".jpg", small, [cv2.IMWRITE_JPEG_QUALITY, 80])
    if not ok:
        raise RuntimeError("JPEG 인코딩 실패")
    return buf.tobytes()


def upload(op, board: str, token: str, jpeg: bytes) -> dict:
    boundary = uuid.uuid4().hex
    body = (
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="frame"; filename="frame.jpg"\r\n'
        "Content-Type: image/jpeg\r\n\r\n"
    ).encode() + jpeg + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(
        f"{board}/frame", data=body, method="POST",
        headers={TOKEN_HEADER: token,
                 "Content-Type": f"multipart/form-data; boundary={boundary}"})
    with op.open(req, timeout=5) as resp:
        return json.loads(resp.read())


def fetch(op, board: str, token: str) -> tuple[dict, bytes]:
    req = urllib.request.Request(f"{board}/capture", headers={TOKEN_HEADER: token})
    with op.open(req, timeout=5) as resp:
        headers = {k: v for k, v in resp.headers.items() if k.lower().startswith("x-")}
        return headers, resp.read()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--board", required=True, help="보드 주소, 예: http://10.185.91.103")
    ap.add_argument("--camera", type=int, default=0, help="노트북 카메라 번호")
    ap.add_argument("--manual", action="store_true", help="엔터마다 1장 (3회 기록용)")
    ap.add_argument("--interval", type=float, default=0.5, help="자동 전송 간격(초)")
    ap.add_argument("--out", type=Path, help="보드에서 다시 받은 사진을 저장할 폴더")
    args = ap.parse_args()

    import cv2

    token = load_token()
    op = opener()
    cam = cv2.VideoCapture(args.camera)
    if not cam.isOpened():
        sys.exit("노트북 카메라를 열 수 없다 (시스템 설정 > 개인정보 보호 > 카메라 권한 확인)")
    for _ in range(10):  # 노출이 자리 잡도록 몇 장 버린다
        cam.read()
    if args.out:
        args.out.mkdir(parents=True, exist_ok=True)

    shot = 0
    print(f"보드 {args.board} · {'수동(엔터=1장, q=끝)' if args.manual else f'{args.interval}초마다'}")
    try:
        while True:
            if args.manual:
                if input(f"[{shot + 1}] 엔터를 누르면 찍어서 보냅니다 (q=끝): ").strip().lower() == "q":
                    break
            ok, frame = cam.read()
            if not ok:
                print("카메라 프레임을 못 읽음")
                time.sleep(0.5)
                continue
            jpeg = encode_qvga(frame)
            t0 = time.time()
            try:
                up = upload(op, args.board, token, jpeg)
                headers, back = fetch(op, args.board, token)
            except (urllib.error.URLError, OSError) as e:
                print(f"보드 통신 실패: {e}")
                time.sleep(1)
                continue
            shot += 1
            rtt = (time.time() - t0) * 1000
            same = back == jpeg
            print(f"#{shot} 보냄 {len(jpeg)}B → 보드 relaySeq={up.get('relaySeq')} · "
                  f"다시 받음 X-Frame-Seq={headers.get('X-Frame-Seq')} "
                  f"출처={headers.get('X-Frame-Source')} 센서={headers.get('X-Camera-Sensor')} · "
                  f"보낸 것과 같음={same} · 왕복 {rtt:.0f}ms")
            if args.out:
                name = args.out / f"relay_{shot:02d}_seq{headers.get('X-Frame-Seq')}.jpg"
                name.write_bytes(back)
                (args.out / "relay_log.jsonl").open("a").write(json.dumps({
                    "shot": shot, "time": time.strftime("%Y-%m-%d %H:%M:%S"),
                    "sentBytes": len(jpeg), "boardRelaySeq": up.get("relaySeq"),
                    "headers": headers, "sameAsSent": same, "roundTripMs": round(rtt),
                    "file": name.name}, ensure_ascii=False) + "\n")
            if not args.manual:
                time.sleep(args.interval)
    except KeyboardInterrupt:
        pass
    finally:
        cam.release()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
