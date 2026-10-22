"""로컬 클립 시연 웹: 같은 주소에서 화면·사진·판독을 제공한다.

실행: .venv/bin/python clip_web.py --clip http://192.168.0.52
토큰: CLIP_DEVICE_TOKEN 또는 ~/.clipsense/device_token (브라우저로 보내지 않음).
실제 신호 API는 연결하지 않는다. 최종 결정은 항상 엄격 judge의 대기/확인 불가다.
"""
from __future__ import annotations

import argparse
import base64
import copy
import dataclasses
import hashlib
import http.client
import json
import math
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import cv2
import numpy as np

from clip_snapshot import (CLIP_TOKEN_HEADER, ClipFreshnessTracker,
                           VERDICT_ACCEPTED, VERDICT_REPLAY_OR_REORDER,
                           parse_capture_headers)
from detector import ColorDetector, SignalStateMachine
from judge import (REASON_READY, REASON_TEXT, WALK, evaluate)
from signal_head import SignalHeadReader
from signal_api import DEFAULT_BASE_URL, fetch_reading
from vision_adapter import to_reading

ROOT = Path(__file__).resolve().parent
MAX_JPEG = 512 * 1024
STALE_MS = 2000
REQUEST_TIMEOUT = 0.8
POLL_SECONDS = 0.25


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def clip_origin(value):
    url = urllib.parse.urlsplit(value if '://' in value else 'http://' + value)
    if (url.scheme not in ('http', 'https') or not url.hostname
            or url.username is not None or url.password is not None
            or url.path not in ('', '/') or url.query or url.fragment):
        raise ValueError('클립 주소는 http(s)://호스트[:포트] 형식이어야 합니다')
    # 잘못된 포트와 헤더 삽입을 시작 전에 거부한다.
    _ = url.port
    if any(ord(c) <= 32 for c in value):
        raise ValueError('클립 주소에 공백/제어 문자를 사용할 수 없습니다')
    return f'{url.scheme}://{url.netloc}'


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # 기기 토큰을 다른 주소로 전달하지 않는다.


def provenance(headers):
    sensor = headers.get('X-Camera-Sensor', '').strip()
    source = headers.get('X-Frame-Source', '').strip()
    if sensor.upper() == 'SIM':
        kind, label = 'sim', 'SIM · 모의 사진'
    elif sensor.upper() == 'LAPTOP' or source == 'laptop-upload':
        kind, label = 'laptop-relay', '노트북 촬영 → 보드 중계'
    elif sensor.upper() in ('OV2640', 'OV3660', 'OV5640'):
        kind, label = 'clip', '클립 센서 사진 · 현장 확인 필요'
    else:
        kind, label = 'unverified', '촬영 출처 확인 필요'
    return {'kind': kind, 'label': label, 'sensor': sensor, 'frameSource': source}


TDATA_HOST = urllib.parse.urlsplit(DEFAULT_BASE_URL).hostname
# T-Data 기존 API는 2026-10-01부터 5분 1회 제한이다. 실서버에는 이보다 자주 묻지 않는다.
TDATA_MIN_INTERVAL = 300.0


class ApiFeed:
    """신호 API를 주기적으로 읽어 최신 SignalReading 한 건을 보관한다.

    판단 시점에는 받은 뒤 흐른 시간만큼 신선도를 늘리고 잔여시간을 줄인다
    (받은 순간의 값을 그대로 쓰면 남은 시간을 실제보다 길게 믿게 된다).
    """
    def __init__(self, base_url, itst_id, direction, api_key, interval=0.5,
                 clock=time.monotonic, wall_ms=lambda: int(time.time() * 1000),
                 fetch=fetch_reading):
        self.base_url, self.itst_id, self.direction = base_url, itst_id, direction
        self.api_key, self.clock, self.wall_ms, self.fetch = api_key, clock, wall_ms, fetch
        self.simulated = urllib.parse.urlsplit(base_url).hostname != TDATA_HOST
        self.interval = interval if self.simulated else max(interval, TDATA_MIN_INTERVAL)
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.reading = None
        self.fetched_at = None
        self.polls = 0

    def poll(self):
        reading = self.fetch(self.itst_id, self.direction, self.api_key,
                             now_ms=self.wall_ms(), base_url=self.base_url, timeout=1.5)
        with self.lock:
            self.reading, self.fetched_at = reading, self.clock()
            self.polls += 1

    def run(self):
        while not self.stop.is_set():
            start = self.clock()
            self.poll()
            self.stop.wait(max(0, self.interval - (self.clock() - start)))

    def current(self):
        """지금 시점으로 늙힌 판독. 아직 못 받았으면 None."""
        with self.lock:
            reading, fetched_at = self.reading, self.fetched_at
        if reading is None:
            return None
        elapsed = max(0.0, self.clock() - fetched_at)
        remain = reading.remain_sec
        if remain is not None:
            remain = max(0.0, round(remain - elapsed, 1))
        return dataclasses.replace(reading, remain_sec=remain,
                                   fresh_ms=reading.fresh_ms + math.ceil(elapsed * 1000))

    def describe(self, reading):
        return {'configured': True, 'simulated': self.simulated,
                'label': '모의 API · 작은 교차로' if self.simulated else '서울 T-Data',
                'itstId': self.itst_id, 'direction': self.direction,
                'intervalMs': int(self.interval * 1000), 'polls': self.polls,
                'color': reading.color if reading else None,
                'remainSec': reading.remain_sec if reading else None,
                'freshMs': reading.fresh_ms if reading else None,
                'raw': reading.raw if reading else None}


def guidance_text(decision, vision_state, api_configured):
    """화면·음성 문구. 잔여 초는 넣지 않는다 — 매초 문구가 바뀌면 음성이 계속 다시 읽는다."""
    if not api_configured:
        # API 없이 카메라만: 초록이어도 남은 시간을 모르므로 대기(10/19 문구 유지).
        if vision_state == 'RED':
            return '빨간불로 판독했습니다. 기다리세요.'
        if vision_state in ('GREEN', 'GREEN_BLINK'):
            return '초록불로 판독했습니다. 실제 남은 시간을 확인할 수 없습니다. 기다리세요.'
        return '신호를 확인할 수 없습니다. 기다리세요.'
    if decision.decision == WALK:
        return f'{REASON_TEXT[REASON_READY]}. 건너세요.'
    return f'{REASON_TEXT[decision.reason]}. 기다리세요.'


class ClipFeed:
    """한 폴링 루프가 JPEG·메타데이터·판독을 원자적으로 교체한다."""
    def __init__(self, origin, token, roi_fraction=0.25, clock=time.monotonic, api=None,
                 vision='center', rotate=0):
        self.origin, self.token, self.roi_fraction = origin, token, roi_fraction
        self.clock = clock
        self.api = api
        # center: 중앙 ROI의 색 (10/19 방식) · head: 사진 전체에서 신호등 몸체·램프·숫자
        self.vision = vision
        # 클립 카메라 장착 방향 보정(180이면 상하좌우 반전). 판독과 화면에 같은 사진을 쓴다.
        self.rotate = rotate
        self.cfg = json.loads((ROOT / 'config.json').read_text())
        files = ['config.json', 'detector.py', 'judge.py', 'vision_adapter.py',
                 'clip_snapshot.py', 'clip_web.py', 'web_clip/index.html',
                 'web_clip/app.js', 'web_clip/style.css',
                 'scripts/run_web_demo.py', 'scripts/clip_cam_sim.py',
                 'signal_head.py', 'digits.py']
        hashes = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                  for name in files}
        self.rules = {'version': 'clip-web-rules-2026-10-19-v1', 'sha256': hashes,
                      'config': copy.deepcopy(self.cfg), 'roiFraction': roi_fraction,
                      'vision': vision, 'rotate': rotate,
                      'staleMs': STALE_MS, 'requestTimeoutMs': 800,
                      'pollMs': 250, 'apiConnected': api is not None,
                      'apiSimulated': bool(api and api.simulated),
                      'method': ('신호등 몸체 찾기 + 위 빨강/아래 초록 칸 + 7-세그먼트 숫자 + 연속 8프레임 확인'
                                 if vision == 'head' else 'OpenCV HSV + 모양 규칙 + 연속 8프레임 확인'),
                      'opencv': cv2.__version__, 'numpy': np.__version__}
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.tracker = ClipFreshnessTracker()
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        self.last_received = None
        self.captured = None
        self.last_received_at = None
        self.frame = None
        self.connection = 'starting'
        self.error = None
        self.reset_pipeline()

    def reset_pipeline(self):
        self.detector = ColorDetector(self.cfg)
        self.head = SignalHeadReader(self.cfg)
        self.machine = SignalStateMachine(self.cfg)

    def fail(self, code):
        with self.lock:
            self.connection, self.error, self.frame = code, code, None
            self.captured = None
            self.reset_pipeline()

    def accept(self, jpeg, headers, rtt_ms, now):
        meta = parse_capture_headers(headers)
        if meta is None:
            self.fail('bad_headers')
            return
        if headers.get('Content-Type', '').split(';')[0].strip().lower() != 'image/jpeg':
            self.fail('bad_content_type')
            return
        # 펌웨어의 QVGA JPEG만 받는다. 압축 해제 전에 SOF 크기를 검사한다.
        from scripts.clip_cam_sim import jpeg_dimensions
        if len(jpeg) > MAX_JPEG or jpeg_dimensions(jpeg) != (320, 240):
            self.fail('bad_jpeg')
            return
        image = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)
        if image is None or image.shape != (240, 320, 3):
            self.fail('bad_jpeg')
            return
        shown = jpeg
        if self.rotate == 180:
            image = cv2.rotate(image, cv2.ROTATE_180)
            ok, buf = cv2.imencode('.jpg', image, [cv2.IMWRITE_JPEG_QUALITY, 90])
            if not ok:
                self.fail('bad_jpeg')
                return
            shown = buf.tobytes()  # 원본 해시는 jpegSha256에 그대로 남긴다
        with self.lock:
            self.last_received, self.last_received_at = now, utc_now()
            obs = self.tracker.observe(meta, rtt_ms=rtt_ms, received_mono_ms=int(now * 1000))
            if obs.boot_changed:
                self.reset_pipeline()
            if obs.verdict == VERDICT_REPLAY_OR_REORDER:
                self.connection, self.error, self.frame = 'replay_or_reorder', obs.verdict, None
                self.captured = None
                self.reset_pipeline()
                return
            if obs.verdict != VERDICT_ACCEPTED:
                self.connection = 'same_frame'
                if self.captured is None or (now - self.captured) * 1000 > STALE_MS:
                    self.frame = None
                    self.reset_pipeline()
                return  # 같은 사진으로 연속 프레임 수나 신선도를 갱신하지 않는다.
            if obs.conservative_age_ms > STALE_MS:
                self.connection, self.error, self.frame = 'stale', 'stale', None
                self.captured = None
                self.reset_pipeline()
                return
            captured = obs.captured_at_mono_ms / 1000
            if self.captured is None or (now - self.captured) * 1000 > STALE_MS:
                self.reset_pipeline()
            self.captured = captured
            h, w = image.shape[:2]
            if self.vision == 'head':
                head = self.head.read(image)
                raw, reason = head.raw, head.reason
                vision_info = {
                    'roi': head.head or [0, 0, w, h], 'boxes': head.boxes,
                    'digits': head.digits, 'digitsFrame': head.digits_frame,
                    'red': {'area_ratio': head.red_area}, 'green': {'area_ratio': head.green_area},
                    'brightness': None}
            else:
                rw, rh = max(1, int(w * self.roi_fraction)), max(1, int(h * self.roi_fraction))
                x, y = (w - rw) // 2, (h - rh) // 2
                result = self.detector.detect(image[y:y+rh, x:x+rw])
                raw, reason = result.raw, result.reason
                vision_info = {
                    'roi': [x, y, rw, rh], 'boxes': [{'label': 'ROI', 'rect': [x, y, rw, rh]}],
                    'digits': None, 'digitsFrame': None,
                    'red': vars(result.red), 'green': vars(result.green),
                    'brightness': result.brightness}
            self.machine.update(captured, raw, reason)
            self.frame = {
                'jpeg': base64.b64encode(shown).decode('ascii'), 'rotated': self.rotate,
                'jpegSha256': hashlib.sha256(jpeg).hexdigest(),
                'seq': meta.frame_seq, 'bootId': meta.boot_id,
                'captureUptimeUs': meta.capture_uptime_us,
                'responseUptimeUs': meta.response_uptime_us,
                'receivedAt': self.last_received_at,
                'firmware': meta.firmware_version, 'source': provenance(headers),
                'raw': raw, 'stable': self.machine.state,
                'detectorReason': reason, 'rttMs': rtt_ms, **vision_info,
            }
            self.connection, self.error = 'connected', None

    def poll(self):
        start = self.clock()
        request = urllib.request.Request(self.origin + '/capture', headers={
            CLIP_TOKEN_HEADER: self.token, 'Cache-Control': 'no-cache'})
        try:
            with self.opener.open(request, timeout=REQUEST_TIMEOUT) as resp:
                # timeout은 read 호출별 제한이므로 전체 왕복 시간도 판정에서 검사한다.
                jpeg = resp.read(MAX_JPEG + 1)
                headers = resp.headers
            now = self.clock()
            if now - start > REQUEST_TIMEOUT:
                self.fail('timeout')
                return
            self.accept(jpeg, headers, math.ceil((now - start) * 1000), now)
        except urllib.error.HTTPError as exc:
            code = exc.code
            exc.close()
            self.fail('token_rejected' if code in (401, 403) else f'http_{code}')
        except (urllib.error.URLError, OSError, http.client.HTTPException, ValueError, cv2.error):
            self.fail('unreachable')

    def run(self):
        while not self.stop.is_set():
            start = self.clock()
            self.poll()
            # 토큰 거부 시 인증 설정 후 서버를 다시 시작한다.
            if self.connection == 'token_rejected':
                return
            self.stop.wait(max(0, POLL_SECONDS - (self.clock() - start)))

    def snapshot(self):
        now = self.clock()
        with self.lock:
            age = None if self.captured is None else max(0, math.ceil((now - self.captured) * 1000))
            frame = copy.deepcopy(self.frame) if age is not None and age <= STALE_MS else None
            status = self.connection
            if self.frame and frame is None:
                status = 'stale'
                self.reset_pipeline()
            state = frame['stable'] if frame else 'UNKNOWN'
            # 전환 중/미검출 프레임에서 이전 확정색으로 안내하지 않는다.
            # 점멸 확정은 프레임마다 켜짐/꺼짐이 바뀌는 것이 정상이므로 그대로 둔다.
            if frame and frame['raw'] != state and state != 'GREEN_BLINK':
                state = 'UNKNOWN'
            api_reading = self.api.current() if self.api else None
            # 숫자 판독은 '올림한 초'로 표시되고 사진도 age만큼 지났으므로, 보수적으로
            # (숫자 - 1초 - 사진 나이)를 카메라 잔여시간으로 쓴다. judge는 API보다 짧을 때만 반영한다.
            vision_remain = None
            if frame and frame.get('digits') is not None and state in ('GREEN', 'GREEN_BLINK'):
                vision_remain = max(0.0, round(frame['digits'] - 1 - age / 1000, 1))
            decision = evaluate(api_reading, to_reading(state, remain_sec=vision_remain,
                                                        fresh_ms=age or 0))
            text = guidance_text(decision, state, self.api is not None)
            api_info = (self.api.describe(api_reading) if self.api
                        else {'configured': False})
            return {'serverTime': utc_now(), 'connection': status, 'error': self.error,
                    'visionState': state, 'visionRemainSec': vision_remain, 'api': api_info,
                    'lastReceivedAt': self.last_received_at, 'ageMs': age,
                    'validForMs': max(0, STALE_MS - age) if frame else 0,
                    'frame': frame, 'decision': decision.decision,
                    'decisionReason': decision.reason, 'guidance': text,
                    'clipOrigin': self.origin, 'rules': self.rules}


def make_handler(feed, allowed_hosts):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass  # 요청에 포함될 수 있는 개인정보를 로그로 남기지 않는다.

        def do_GET(self):
            host = self.headers.get('Host', '')
            path = urllib.parse.urlsplit(self.path).path
            if (host not in allowed_hosts or (path == '/api/frame' and (
                    self.headers.get('Sec-Fetch-Site') == 'cross-site'
                    or self.headers.get('Origin', 'http://' + host) != 'http://' + host))):
                self.send_error(403)
                return
            if path == '/api/frame':
                body = json.dumps(feed.snapshot(), ensure_ascii=False).encode()
                content_type = 'application/json; charset=utf-8'
            elif path in ('/', '/app.js', '/style.css'):
                name = 'index.html' if path == '/' else path[1:]
                body = (ROOT / 'web_clip' / name).read_bytes()
                content_type = {'index.html': 'text/html; charset=utf-8',
                                'app.js': 'text/javascript; charset=utf-8',
                                'style.css': 'text/css; charset=utf-8'}[name]
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('Content-Security-Policy', "default-src 'self'; img-src 'self' data:; connect-src 'self'; style-src 'self'; script-src 'self'; frame-ancestors 'none'; base-uri 'none'")
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass
    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--clip', required=True, help='예: http://192.168.0.52')
    parser.add_argument('--listen', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=5173)
    parser.add_argument('--allow-host', action='append', default=[], help='폰 접속 시 Mac의 LAN IP (포트 제외)')
    parser.add_argument('--roi-fraction', type=float, default=0.25, help='중앙 ROI 비율, 시작 후 고정')
    parser.add_argument('--vision', choices=['center', 'head'], default='center',
                        help='center: 중앙 ROI 색 · head: 사진 전체에서 신호등 몸체·램프·숫자 찾기')
    parser.add_argument('--rotate', type=int, choices=[0, 180], default=0,
                        help='클립 카메라가 거꾸로 달렸으면 180')
    parser.add_argument('--signal-api', help='신호 API 주소. 작은 교차로 예: '
                        'http://127.0.0.1:8765/tapi/v2xSignalPhaseTimingFusionInformation/1.0')
    parser.add_argument('--itst-id', help='교차로 ID (작은 교차로 기본 SIM-0001)')
    parser.add_argument('--direction', default='nt', help='보행신호 방위 접두사 (nt/et/st/wt/ne/se/sw/nw)')
    parser.add_argument('--api-interval', type=float, default=0.5, help='API 조회 간격(초). 실 T-Data는 300초 이상으로 강제')
    args = parser.parse_args()
    try:
        origin = clip_origin(args.clip)
    except ValueError as exc:
        parser.error(str(exc))
    if not 0 < args.roi_fraction <= 1:
        parser.error('--roi-fraction은 0 초과 1 이하여야 합니다')
    if not 0 <= args.port <= 65535:
        parser.error('--port는 0~65535여야 합니다')
    token_path = Path.home() / '.clipsense/device_token'
    token = os.environ.get('CLIP_DEVICE_TOKEN', '').strip()
    if not token and token_path.exists():
        token = token_path.read_text().strip()
    if not token or any(ord(c) < 32 or ord(c) > 126 for c in token):
        parser.error('유효한 토큰이 없습니다. CLIP_DEVICE_TOKEN 또는 ~/.clipsense/device_token을 설정하세요')
    api = None
    if args.signal_api:
        if args.direction not in ('nt', 'et', 'st', 'wt', 'ne', 'se', 'sw', 'nw'):
            parser.error('--direction은 nt/et/st/wt/ne/se/sw/nw 중 하나여야 합니다')
        if not args.api_interval > 0:
            parser.error('--api-interval은 0보다 커야 합니다')
        api_url = urllib.parse.urlsplit(args.signal_api)
        if api_url.scheme not in ('http', 'https') or not api_url.hostname or api_url.query:
            parser.error('--signal-api는 쿼리 없는 http(s) 주소여야 합니다')
        simulated = api_url.hostname != TDATA_HOST
        key_path = Path.home() / '.clipsense/tdata_key'
        api_key = os.environ.get('TDATA_KEY', '').strip()
        if not api_key and not simulated and key_path.exists():
            api_key = key_path.read_text().strip()
        if not api_key:
            if not simulated:
                parser.error('T-Data 키가 없습니다. TDATA_KEY 또는 ~/.clipsense/tdata_key를 설정하세요')
            api_key = 'sim'  # 실제 키를 모의 서버로 보내지 않는다.
        itst_id = args.itst_id or ('SIM-0001' if simulated else None)
        if not itst_id:
            parser.error('실제 T-Data에는 --itst-id가 필요합니다')
        api = ApiFeed(args.signal_api, itst_id, args.direction, api_key, args.api_interval)
    feed = ClipFeed(origin, token, args.roi_fraction, api=api, vision=args.vision,
                    rotate=args.rotate)
    hosts = {'localhost', '127.0.0.1', *args.allow_host}
    if args.listen != '0.0.0.0':
        hosts.add(args.listen)
    allowed = set()
    server = ThreadingHTTPServer((args.listen, args.port), make_handler(feed, allowed))
    port = server.server_port
    allowed.update(f'{host}:{port}' for host in hosts)
    if port == 80:
        allowed.update(hosts)
    worker = threading.Thread(target=feed.run, daemon=True)
    worker.start()
    if api:
        threading.Thread(target=api.run, daemon=True).start()
    print(f'ClipSense 웹: http://127.0.0.1:{port}  → 클립: {origin}', flush=True)
    if api:
        print(f'신호 API: {api.describe(None)["label"]} · {api.base_url} · 교차로 {api.itst_id} '
              f'· {api.direction} · {api.interval}초마다', flush=True)
    print('실제 음성은 웹의 시작 버튼을 누른 뒤 확인하세요. 종료: Ctrl+C', flush=True)
    try:
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        pass
    finally:
        feed.stop.set()
        if api:
            api.stop.set()
        server.server_close()
        worker.join(timeout=2)


if __name__ == '__main__':
    main()
