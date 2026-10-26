"""보드 없이 웹·판독·음성 흐름 연습. 모든 사진은 SIM 합성 입력이다.

실행: .venv/bin/python scripts/run_web_demo.py
장면 고정: --scene red | green | none. 기본은 12초씩 순환한다.
"""
from __future__ import annotations

import argparse
import secrets
import sys
import threading
from http.server import ThreadingHTTPServer
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from clip_web import ClipFeed, make_handler
from scripts.clip_cam_sim import CameraSim, ClipCamSim, FrameSource


def make_frames():
    """합성 원형 물체. 실제 보행 신호 사진/현장 성능 자료가 아니다."""
    frames = {}
    for scene, color in [('red', (40, 40, 235)), ('green', (50, 220, 60)), ('none', None)]:
        image = np.full((240, 320, 3), 80, np.uint8)
        if color is not None:
            cv2.circle(image, (160, 120), 11, color, -1)
        ok, data = cv2.imencode('.jpg', image)
        if not ok:
            raise RuntimeError('SIM JPEG 생성 실패')
        frames[scene] = data.tobytes()
    return frames


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--port', type=int, default=5173)
    parser.add_argument('--scene', choices=['cycle', 'red', 'green', 'none'], default='cycle')
    args = parser.parse_args()
    if not 0 <= args.port <= 65535:
        parser.error('--port는 0~65535여야 합니다')
    frames = make_frames()
    source = FrameSource(list(frames.values()) if args.scene == 'cycle' else [frames[args.scene]], hold_frames=48)
    token = secrets.token_hex(32)  # 실제 기기 토큰을 읽지 않는다.
    sim = ClipCamSim(CameraSim(source), token, quiet=True)
    sim.start()
    feed = ClipFeed(sim.base_url, token)
    web = None
    worker = threading.Thread(target=feed.run, daemon=True)
    try:
        allowed = set()
        web = ThreadingHTTPServer(('127.0.0.1', args.port), make_handler(feed, allowed))
        port = web.server_port
        allowed.update({f'127.0.0.1:{port}', f'localhost:{port}'})
        feed.poll()  # 첫 화면 요청 전에 SIM 사진 한 장을 준비한다.
        worker.start()
        print(f'SIM 전용 · 보드 연결 아님: http://127.0.0.1:{port}', flush=True)
        print('빨강 → 초록 → 신호 없음: 각 12초 유지' if args.scene == 'cycle'
              else f'고정 모의 장면: {args.scene}', flush=True)
        print('시작 · 음성 켜기를 누르고 실제 소리를 직접 확인하세요. 종료: Ctrl+C', flush=True)
        web.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        pass
    finally:
        feed.stop.set()
        if web:
            web.server_close()
        if worker.is_alive():
            worker.join(timeout=2)
        sim.stop()


if __name__ == '__main__':
    main()
