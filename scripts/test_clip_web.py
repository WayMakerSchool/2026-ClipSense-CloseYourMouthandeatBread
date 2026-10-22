"""클립 웹의 실제 HTTP 계약과 대기 원칙 회귀 검사 (보드 실측 아님)."""
import base64
import json
import re
import subprocess
import sys
import threading
import unittest
import urllib.error
import urllib.request
from email.message import Message
from http.server import ThreadingHTTPServer
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from clip_web import ApiFeed, ClipFeed, clip_origin, make_handler
from signals import GREEN, RED, SRC_API, UNKNOWN, SignalReading
from signal_head import draw_signal_head
from scripts.clip_cam_sim import CameraSim, ClipCamSim, FrameSource
from scripts.run_web_demo import make_frames


def jpeg(color=None):
    image = np.full((240, 320, 3), 80, np.uint8)
    if color:
        cv2.circle(image, (160, 120), 11, color, -1)
    ok, buf = cv2.imencode('.jpg', image)
    assert ok
    return buf.tobytes()


def headers(seq, boot='one', sensor='SIM', **extra):
    out = Message()
    for key, value in {'Content-Type': 'image/jpeg', 'X-Frame-Seq': str(seq),
                       'X-Capture-Uptime-Us': str(seq * 250000),
                       'X-Response-Uptime-Us': str(seq * 250000 + 1000),
                       'X-Boot-Id': boot, 'X-Camera-Sensor': sensor, **extra}.items():
        out[key] = value
    return out


class WebTests(unittest.TestCase):
    def setUp(self):
        self.now = 100.0
        self.feed = ClipFeed('http://127.0.0.1:9', 'test-token', clock=lambda: self.now)

    def push(self, seq, color=(50, 220, 60), **kw):
        self.now += 0.25
        self.feed.accept(jpeg(color), headers(seq, **kw), 10, self.now)
        return self.feed.snapshot()

    def test_three_scenes_and_same_jpeg(self):
        for color, expected, text in [((40, 40, 235), 'RED', '빨간불'),
                                       ((50, 220, 60), 'GREEN', '남은 시간'),
                                       (None, 'NONE', '확인할 수 없습니다')]:
            self.setUp()
            for i in range(1, 10):
                snap = self.push(i, color)
            self.assertEqual(snap['frame']['raw'], expected)
            self.assertIn(text, snap['guidance'])
            self.assertNotEqual(snap['decision'], 'WALK')
            self.assertEqual(base64.b64decode(snap['frame']['jpeg']), jpeg(color))

    def test_duplicate_does_not_debounce_or_refresh(self):
        snap = self.push(1)
        for _ in range(9):
            snap = self.push(1)
        self.assertIsNone(snap['frame'])
        self.assertGreater(snap['ageMs'], 2000)
        self.assertNotEqual(snap['decision'], 'WALK')

    def test_snapshot_expires_without_new_request(self):
        for i in range(1, 10):
            self.push(i)
        self.now += 2.1
        snap = self.feed.snapshot()
        self.assertEqual(snap['connection'], 'stale')
        self.assertIsNone(snap['frame'])
        self.assertEqual(snap['validForMs'], 0)
        self.assertIn('확인할 수 없습니다', snap['guidance'])
        snap = self.push(10)
        self.assertEqual(snap['frame']['stable'], 'UNKNOWN')

    def test_reboot_resets_eight_frame_history(self):
        for i in range(1, 10):
            self.push(i)
        snap = self.push(1, boot='new')
        self.assertEqual(snap['frame']['stable'], 'UNKNOWN')
        self.assertIn('확인할 수 없습니다', snap['guidance'])

    def test_reorder_rejected_and_history_cleared(self):
        for i in range(1, 10):
            self.push(i)
        snap = self.push(2)
        self.assertEqual(snap['connection'], 'replay_or_reorder')
        self.assertIsNone(snap['frame'])
        self.assertEqual(self.push(10)['frame']['stable'], 'UNKNOWN')

    def test_bad_metadata_mime_and_jpeg_invalidate(self):
        for kind in ['headers', 'mime', 'jpeg', 'old']:
            self.setUp()
            self.push(1)
            meta, body = headers(2), jpeg()
            if kind == 'headers':
                del meta['X-Boot-Id']
            elif kind == 'mime':
                meta.replace_header('Content-Type', 'text/html')
            elif kind == 'jpeg':
                body = b'not-a-jpeg'
            else:
                meta.replace_header('X-Response-Uptime-Us', '999999999')
            self.feed.accept(body, meta, 10, self.now)
            self.assertIsNone(self.feed.snapshot()['frame'], kind)

    def test_failure_immediate_and_recovery_debounces(self):
        for i in range(1, 10):
            self.push(i)
        self.feed.fail('unreachable')
        self.assertIsNone(self.feed.snapshot()['frame'])
        snap = self.push(10)
        self.assertEqual(snap['frame']['stable'], 'UNKNOWN')

    def test_sim_laptop_and_sensor_labels(self):
        for i, (sensor, source, kind) in enumerate([
                ('SIM', '', 'sim'), ('LAPTOP', 'laptop-upload', 'laptop-relay'),
                ('OV3660', '', 'clip'), ('', '', 'unverified')], 1):
            snap = self.push(i, sensor=sensor, **{'X-Frame-Source': source})
            self.assertEqual(snap['frame']['source']['kind'], kind)

    def test_url_restrictions(self):
        self.assertEqual(clip_origin('192.168.0.52'), 'http://192.168.0.52')
        for bad in ['http://user:secret@host', 'http://host/capture', 'file:///a',
                    'http://host?a=b', 'http://host:invalid', 'http://host\n']:
            with self.assertRaises(ValueError):
                clip_origin(bad)

    def test_boardless_launcher_needs_no_device_token(self):
        # port=0은 OS가 비어 있는 포트를 선택해 동시 검사 충돌을 피한다.
        proc = subprocess.Popen([sys.executable, str(ROOT / 'scripts/run_web_demo.py'),
                                 '--port', '0', '--scene', 'green'],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            line = proc.stdout.readline()
            self.assertIn('SIM 전용', line)
            origin = re.search(r'http://127\.0\.0\.1:\d+', line).group()
            op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with op.open(origin + '/api/frame', timeout=2) as resp:
                snap = json.loads(resp.read())
            self.assertEqual(snap['frame']['source']['kind'], 'sim')
            self.assertEqual(snap['frame']['raw'], 'GREEN')
            self.assertNotEqual(snap['decision'], 'WALK')
            self.assertIn('scripts/run_web_demo.py', snap['rules']['sha256'])
        finally:
            proc.terminate()
            proc.communicate(timeout=3)
        self.assertEqual(set(make_frames()), {'red', 'green', 'none'})

    def test_real_http_sim_and_web_token_never_exposed(self):
        sim = ClipCamSim(CameraSim(FrameSource([jpeg((50, 220, 60))])), 'unit-token', quiet=True)
        sim.start()
        web = None
        try:
            feed = ClipFeed(sim.base_url, 'unit-token')
            for _ in range(9):
                feed.poll()
            self.assertEqual(feed.snapshot()['frame']['raw'], 'GREEN')
            web = ThreadingHTTPServer(('127.0.0.1', 0), make_handler(feed, set()))
            address = f'127.0.0.1:{web.server_port}'
            web.RequestHandlerClass = make_handler(feed, {address})
            threading.Thread(target=web.serve_forever, daemon=True).start()
            op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with op.open(f'http://{address}/api/frame') as resp:
                raw = resp.read()
                self.assertEqual(resp.headers['Cache-Control'], 'no-store')
                self.assertNotIn(b'unit-token', raw)
                self.assertEqual(json.loads(raw)['frame']['source']['kind'], 'sim')
            for extra in [{'Host': 'attacker.example'}, {'Origin': 'https://attacker.example'},
                          {'Sec-Fetch-Site': 'cross-site'}]:
                req = urllib.request.Request(f'http://{address}/api/frame', headers=extra)
                with self.assertRaises(urllib.error.HTTPError) as error:
                    op.open(req)
                self.assertEqual(error.exception.code, 403)
                error.exception.close()
            # 일반 링크에서 들어오는 최상위 페이지 탐색은 허용한다.
            req = urllib.request.Request(f'http://{address}/', headers={'Sec-Fetch-Site': 'cross-site'})
            with op.open(req) as resp:
                self.assertEqual(resp.status, 200)
            bad = ClipFeed(sim.base_url, 'wrong-token')
            bad.poll()
            self.assertEqual(bad.snapshot()['connection'], 'token_rejected')
        finally:
            if web:
                web.shutdown()
                web.server_close()
            sim.stop()


class ApiJudgeTests(unittest.TestCase):
    """작은 교차로/T-Data 판독을 붙였을 때의 엄격 AND (네트워크 없음)."""
    def setUp(self):
        self.now = 100.0
        self.seq = 0
        self.answer = SignalReading(GREEN, 10.0, SRC_API, fresh_ms=100)
        self.api = ApiFeed('http://127.0.0.1:8765/tapi/x', 'SIM-0001', 'nt', 'sim',
                           clock=lambda: self.now, wall_ms=lambda: 0,
                           fetch=lambda *a, **k: self.answer)
        self.feed = ClipFeed('http://127.0.0.1:9', 'test-token', clock=lambda: self.now,
                             api=self.api)

    def scene(self, color, frames=9):
        snap = None
        for _ in range(frames):
            self.now += 0.25
            self.seq += 1  # 프레임 번호는 장면이 바뀌어도 이어진다(역행은 버려진다)
            self.api.poll()
            self.feed.accept(jpeg(color), headers(self.seq), 10, self.now)
            snap = self.feed.snapshot()
        return snap

    def test_both_green_with_time_walks(self):
        snap = self.scene((50, 220, 60))
        self.assertEqual(snap['decision'], 'WALK')
        self.assertIn('건너세요', snap['guidance'])
        self.assertTrue(snap['api']['simulated'])
        self.assertEqual(snap['api']['label'], '모의 API · 작은 교차로')

    def test_guidance_has_no_countdown_so_speech_does_not_repeat(self):
        first = self.scene((50, 220, 60))['guidance']
        self.answer = SignalReading(GREEN, 9.0, SRC_API, fresh_ms=100)
        self.assertEqual(self.scene((50, 220, 60))['guidance'], first)

    def test_short_remaining_waits(self):
        self.answer = SignalReading(GREEN, 5.0, SRC_API, fresh_ms=100)
        snap = self.scene((50, 220, 60))
        self.assertEqual((snap['decision'], snap['decisionReason']),
                         ('WAIT', 'remaining_insufficient'))
        self.assertIn('시간이 부족합니다. 기다리세요', snap['guidance'])

    def test_remaining_counts_down_between_api_polls(self):
        self.scene((50, 220, 60))
        self.now += 1.9  # 다음 조회 전: 받은 10초에서 흐른 시간만큼 줄어야 한다
        reading = self.api.current()
        self.assertAlmostEqual(reading.remain_sec, 8.1, places=1)
        self.assertGreaterEqual(reading.fresh_ms, 2000)

    def test_api_not_refreshed_goes_stale_and_waits(self):
        self.scene((50, 220, 60))
        self.now += 2.2
        self.feed.captured = self.now  # 카메라는 신선하다고 두고 API만 늙힌다
        snap = self.feed.snapshot()
        self.assertEqual((snap['decision'], snap['decisionReason']), ('WAIT', 'api_unavailable'))

    def test_conflict_waits(self):
        self.answer = SignalReading(RED, 20.0, SRC_API, fresh_ms=100)
        snap = self.scene((50, 220, 60))
        self.assertEqual((snap['decision'], snap['decisionReason']), ('WAIT', 'conflict'))
        self.assertIn('일치하지 않습니다', snap['guidance'])

    def test_api_green_but_camera_sees_nothing_waits(self):
        snap = self.scene(None)
        self.assertEqual((snap['decision'], snap['decisionReason']), ('WAIT', 'camera_unavailable'))

    def test_api_unknown_waits(self):
        self.answer = SignalReading(UNKNOWN, None, SRC_API, fresh_ms=0)
        snap = self.scene((50, 220, 60))
        self.assertNotEqual(snap['decision'], 'WALK')

    def test_real_tdata_is_never_polled_faster_than_policy(self):
        real = ApiFeed('https://t-data.seoul.go.kr/apig/apiman-gateway/tapi/'
                       'v2xSignalPhaseTimingFusionInformation/1.0', '2691', 'nt', 'k',
                       interval=0.5)
        self.assertFalse(real.simulated)
        self.assertGreaterEqual(real.interval, 300)


def head_jpeg(phase='green', digits=None, ball=None, swap=False, lamp_on=True, no_head=False):
    image = np.full((240, 320, 3), 128, np.uint8)
    if not no_head:
        draw_signal_head(image, 90, 30, 64, 128, phase, lamp_on=lamp_on, digits=digits)
    if swap:  # 초록을 위 칸에 칠한다 — 보행 신호등 배치가 아니다
        cv2.circle(image, (122, 62), 23, (0, 224, 0), -1)
        cv2.circle(image, (122, 126), 23, (38, 38, 38), -1)
    if ball:
        cv2.circle(image, (290, 210), 18, ball, -1)
    ok, buf = cv2.imencode('.jpg', image, [cv2.IMWRITE_JPEG_QUALITY, 90])
    assert ok
    return buf.tobytes()


class SignalHeadTests(unittest.TestCase):
    """--vision head: 사진 전체에서 신호등 몸체·칸별 램프·숫자를 찾는다."""
    def setUp(self):
        self.now, self.seq = 100.0, 0
        self.answer = SignalReading(GREEN, 12.0, SRC_API, fresh_ms=100)
        self.api = ApiFeed('http://127.0.0.1:8765/tapi/x', 'SIM-0001', 'nt', 'sim',
                           clock=lambda: self.now, wall_ms=lambda: 0,
                           fetch=lambda *a, **k: self.answer)
        self.feed = ClipFeed('http://127.0.0.1:9', 'test-token', clock=lambda: self.now,
                             api=self.api, vision='head')

    def run_frames(self, frames=9, **kw):
        snap = None
        for _ in range(frames):
            self.now += 0.25
            self.seq += 1
            self.api.poll()
            self.feed.accept(head_jpeg(**kw), headers(self.seq), 10, self.now)
            snap = self.feed.snapshot()
        return snap

    def test_head_green_with_digits_walks(self):
        snap = self.run_frames(phase='green', digits=12)
        self.assertEqual(snap['frame']['raw'], 'GREEN')
        self.assertEqual(snap['frame']['digits'], 12)
        self.assertEqual([b['label'] for b in snap['frame']['boxes']], ['신호등', '램프', '숫자'])
        self.assertEqual(snap['decision'], 'WALK')

    def test_ball_outside_head_is_ignored(self):
        snap = self.run_frames(phase='green', digits=12, ball=(0, 0, 255))
        self.assertEqual(snap['frame']['raw'], 'GREEN')
        self.assertEqual(snap['decision'], 'WALK')

    def test_colored_ball_without_head_is_not_a_signal(self):
        image = np.full((240, 320, 3), 128, np.uint8)
        cv2.circle(image, (160, 120), 30, (0, 224, 0), -1)
        ok, buf = cv2.imencode('.jpg', image)
        for _ in range(9):
            self.now += 0.25
            self.seq += 1
            self.api.poll()
            self.feed.accept(buf.tobytes(), headers(self.seq), 10, self.now)
        snap = self.feed.snapshot()
        self.assertEqual(snap['frame']['detectorReason'], 'no_signal_head')
        self.assertEqual((snap['decision'], snap['decisionReason']), ('WAIT', 'camera_unavailable'))

    def test_green_in_top_cell_is_not_green(self):
        snap = self.run_frames(phase='red', swap=True)
        self.assertNotEqual(snap['frame']['raw'], 'GREEN')
        self.assertNotEqual(snap['decision'], 'WALK')

    def test_red_head_with_api_red_waits_red(self):
        self.answer = SignalReading(RED, 15.0, SRC_API, fresh_ms=100)
        snap = self.run_frames(phase='red')
        self.assertEqual((snap['decision'], snap['decisionReason']), ('WAIT', 'red_signal'))
        self.assertIn('빨간불입니다', snap['guidance'])

    def blink_then(self, **after):
        # 초록 점멸(켜짐/꺼짐 0.5초)을 확정시킨 뒤 다른 장면을 넣는다.
        snap = None
        for i in range(16):
            snap = self.run_frames(frames=2, phase='clearance', digits=5, lamp_on=(i % 2 == 0))
        self.assertEqual(snap['visionState'], 'GREEN_BLINK')
        return self.run_frames(frames=1, **after)

    def test_blink_is_not_carried_onto_red_frame(self):
        self.feed.api = None
        snap = self.blink_then(phase='red')
        self.assertEqual(snap['visionState'], 'UNKNOWN')
        self.assertNotIn('초록', snap['guidance'])

    def test_blink_is_not_carried_when_no_signal_head(self):
        self.feed.api = None
        snap = self.blink_then(no_head=True)
        self.assertEqual(snap['visionState'], 'UNKNOWN')
        self.assertNotIn('초록', snap['guidance'])

    def test_blink_guidance_explains_why(self):
        self.feed.api = None
        snap = None
        for i in range(16):
            snap = self.run_frames(frames=2, phase='clearance', digits=5, lamp_on=(i % 2 == 0))
        self.assertEqual(snap['visionState'], 'GREEN_BLINK')
        self.assertIn('깜박', snap['guidance'])

    def test_tracking_bridges_one_missed_frame_but_not_a_scene_change(self):
        from signal_head import SignalHeadReader
        reader = SignalHeadReader(self.feed.cfg)
        decode = lambda data: cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
        self.assertEqual(reader.read(decode(head_jpeg('green', 9))).raw, 'GREEN')
        # 몸체 윤곽이 끊긴 사진(몸체 위에 회색 줄): 새로 찾지는 못해도 같은 자리를 이어 쓴다
        cut = decode(head_jpeg('green', 9))
        cv2.rectangle(cut, (88, 90), (156, 96), (128, 128, 128), -1)
        res = reader.read(cut)
        self.assertTrue(res.tracked)
        self.assertEqual(res.raw, 'GREEN')
        # 카메라가 딴 곳(회색 벽)을 보면 이어 쓰지 않는다
        wall = np.full((240, 320, 3), 128, np.uint8)
        res = reader.read(wall)
        self.assertFalse(res.tracked)
        self.assertEqual(res.reason, 'no_signal_head')

    def test_tracking_stops_after_limit(self):
        from signal_head import SignalHeadReader, TRACK_MAX_MISSES
        reader = SignalHeadReader(self.feed.cfg)
        decode = lambda data: cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
        reader.read(decode(head_jpeg('red')))
        cut = decode(head_jpeg('red'))
        cv2.rectangle(cut, (88, 90), (156, 96), (128, 128, 128), -1)
        results = [reader.read(cut) for _ in range(TRACK_MAX_MISSES + 1)]
        self.assertTrue(all(r.tracked for r in results[:TRACK_MAX_MISSES]))
        self.assertFalse(results[-1].tracked)

    def test_dim_screen_digits_still_read(self):
        # 휴대폰 밝기를 낮춘 화면처럼 사진 밝기를 60%로 줄여도 숫자를 읽는다
        from signal_head import SignalHeadReader
        img = cv2.imdecode(np.frombuffer(head_jpeg('green', 12), np.uint8), cv2.IMREAD_COLOR)
        hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV).astype(np.float32)
        hsv[..., 2] *= 0.6
        dim = cv2.cvtColor(np.clip(hsv, 0, 255).astype(np.uint8), cv2.COLOR_HSV2BGR)
        self.assertEqual(SignalHeadReader(self.feed.cfg).read(dim).digits_frame, 12)

    def test_blank_digit_box_reads_nothing(self):
        from signal_head import SignalHeadReader
        img = cv2.imdecode(np.frombuffer(head_jpeg('red'), np.uint8), cv2.IMREAD_COLOR)
        res = SignalHeadReader(self.feed.cfg).read(img)
        self.assertIsNotNone(res.digit_box)
        self.assertIsNone(res.digits_frame)

    def test_digits_shorter_than_api_veto_walk(self):
        # API는 12초라 하는데 신호등 숫자는 6 → 카메라 잔여 4.x초 → 대기
        snap = self.run_frames(phase='green', digits=6)
        self.assertEqual(snap['frame']['digits'], 6)
        self.assertLess(snap['visionRemainSec'], 7)
        self.assertEqual((snap['decision'], snap['decisionReason']), ('WAIT', 'remaining_insufficient'))


if __name__ == '__main__':
    unittest.main()
