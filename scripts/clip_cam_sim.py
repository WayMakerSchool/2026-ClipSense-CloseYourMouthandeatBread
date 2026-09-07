"""클립 카메라 펌웨어(firmware/clipsense_cam/http_api.cpp)의 표준 라이브러리 가짜 서버.

보드 없이 앱의 클립 경로(폴링·신선도·정지·재부팅·토큰 오류)를 끝까지 돌리기 위한 것이다.
계약 경로(/health·/capture·/jpg·OPTIONS·/)는 펌웨어와 같은 상태코드·헤더·오류 본문을 내고,
frameSeq 는 획득 성공 시에만 올린다. 장애 주입은 계약 밖 경로 /__sim/ 아래에만 둔다.
실기기 검증을 대신하지 않는다 — X-Camera-Sensor: SIM 으로 자신을 밝힌다.

실행: python scripts/clip_cam_sim.py --port 8080   (토큰: --token | CLIP_DEVICE_TOKEN | ~/.clipsense/device_token)

구조(펌웨어와 1:1):
  FrameSource   — 카메라 센서 대신 JPEG 바이트를 순환 공급
  CameraSim     — CameraService 의 상태기계(bootId·uptime·frameSeq·카운터·장애), HTTP 를 모른다
  ClipCamHandler — HttpApi 의 라우팅·인증·CORS·헤더
표준 라이브러리만 쓴다(CI 파이썬 job 에 설치 단계가 없다). --video 만 cv2 가 있을 때 선택적으로 쓴다.
"""

from __future__ import annotations

import argparse
import hmac
import json
import os
import secrets
import signal
import sys
import threading
import time
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Callable, Mapping, Sequence

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "app" / "test" / "fixtures"
# 점등(f20) / 점멸 소등(f34) — app/test/fixtures/clip_qvga_fixture.json 참고.
DEFAULT_FRAMES = (FIXTURES / "clip_qvga_f20.jpg", FIXTURES / "clip_qvga_f34.jpg")

# ── 계약 상수(config.h · http_api.cpp 와 같은 문자열) ──────────────────────
SCHEMA_VERSION = "clipsense-camera-api-v1"
TOKEN_HEADER = "X-Clip-Device-Token"
CORS_ORIGINS = ("http://localhost:5173", "http://localhost:4173")
EXPOSE_HEADERS = (
    "X-Frame-Seq",
    "X-Capture-Uptime-Us",
    "X-Response-Uptime-Us",
    "X-Boot-Id",
    "X-Firmware-Version",
    "X-Camera-Sensor",
)
CACHE_CONTROL = "no-store, no-cache, must-revalidate"
BODY_MISSING_TOKEN = b'{"error":"missing_device_token"}'
BODY_INVALID_TOKEN = b'{"error":"invalid_device_token"}'
BODY_BUSY = b'{"error":"capture_busy"}'
BODY_FAILED = b'{"error":"capture_failed"}'
BODY_INSPECT_DISABLED = b'{"error":"inspect_page_disabled"}'
BODY_NOT_FOUND = b'{"error":"not_found"}'

# ── 시뮬레이터 정체(정직하게 SIM 임을 밝힌다) ──────────────────────────────
DEVICE_ID = "clipsense-cam-sim"
FIRMWARE_VERSION = "0.2.0-sim"
CAMERA_SENSOR = "SIM"
NETWORK_MODE = "STA"  # ClipNetwork::modeName() 이 내는 실제 문자열 중 하나
HOSTNAME = "clipsense-sim"
SERVER_STRING = "ClipSenseSim/0.2.0"
# 고정 진단값. jpegQuality 는 fixture 를 만든 cv2 품질(0~100)이지 ESP 의 0~63 척도가 아니다.
HEALTH_CONSTANTS = {
    "rssiDbm": -50,
    "jpegQuality": 80,
    "psramBytes": 8388608,
    "freePsramBytes": 8000000,
    "heapBytes": 400000,
    "freeHeapBytes": 300000,
    "minFreeHeapBytes": 250000,
    "wifiDisconnectCount": 0,
}

# ── 장애 주입(계약 밖) ─────────────────────────────────────────────────────
CONTROL_PREFIX = "/__sim/"
FAULT_MODES = (
    "none",
    "freeze",
    "capture_failed",
    "busy",
    "reboot",
    "stall",
    "drop_headers",
    "wrong_content_type",
)
DEFAULT_HOLD_MS = 1500  # 앱 kClipRequestTimeout 800ms 보다 길게 — stall 이 타임아웃을 실제로 낸다
DEFAULT_HOLD_FRAMES = 2  # 250ms 폴링에서 ≈0.5초 점등/소등 = 상태머신이 모델링한 ~1Hz 점멸
BODY_CAPTIVE_PORTAL = b"<html><body>captive portal</body></html>"

TOKEN_ENV = "CLIP_DEVICE_TOKEN"
TOKEN_FILE = Path.home() / ".clipsense" / "device_token"  # firmware/README.md 의 관례

_SOF_MARKERS = frozenset({0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF})


# ── 프레임 소스 ────────────────────────────────────────────────────────────


def jpeg_dimensions(data: bytes) -> tuple[int, int] | None:
    """SOF0..SOF15 마커에서 (width, height). 못 읽으면 None — /health 의 resolution 용."""
    n = len(data)
    if n < 4 or data[:2] != b"\xff\xd8":
        return None
    i = 2
    while i + 3 < n:
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker == 0xFF:  # 채움 바이트
            i += 1
            continue
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:  # 길이 없는 마커
            i += 2
            continue
        seg_len = (data[i + 2] << 8) | data[i + 3]
        if marker in _SOF_MARKERS:
            if i + 9 > n:
                return None
            height = (data[i + 5] << 8) | data[i + 6]
            width = (data[i + 7] << 8) | data[i + 8]
            return (width, height)
        if marker in (0xD9, 0xDA):  # EOI / SOS 앞에 SOF 가 없었다
            return None
        i += 2 + seg_len
    return None


def load_jpeg_frames(paths: Sequence[Path]) -> list[bytes]:
    """각 파일이 JPEG(FF D8)인지 확인해 바이트로 읽는다. 아니면 ValueError."""
    frames: list[bytes] = []
    for path in paths:
        path = Path(path)
        try:
            data = path.read_bytes()
        except OSError as e:
            raise ValueError(f"프레임 파일을 읽을 수 없다: {path} ({e.strerror})") from e
        if data[:2] != b"\xff\xd8":
            raise ValueError(f"JPEG 이 아니다: {path}")
        frames.append(data)
    if not frames:
        raise ValueError("프레임 파일이 하나도 없다")
    return frames


def load_video_frames(path: Path, max_frames: int = 600) -> tuple[list[bytes], float]:
    """영상을 펌웨어 기본 프로필(중앙 4:3 → 320x240, JPEG q80)로 미리 인코딩한다. cv2 필요.

    dump_clip_qvga_fixture.py 와 같은 기하를 쓴다. cv2 가 만든 JPEG 이지 OV2640 출력이 아니다.
    """
    try:
        import cv2  # noqa: PLC0415 — 선택 의존성. 없으면 --video 만 못 쓴다.
    except ImportError as e:
        raise RuntimeError("cv2 가 없다 — --video 는 opencv-python 이 있을 때만 쓸 수 있다") from e
    cap = cv2.VideoCapture(str(path))
    if not cap.isOpened():
        raise ValueError(f"영상을 열 수 없다: {path}")
    fps = cap.get(cv2.CAP_PROP_FPS)
    if not fps or fps != fps or fps <= 0:
        fps = 30.0
    frames: list[bytes] = []
    while len(frames) < max_frames:
        ok, frame = cap.read()
        if not ok:
            break
        h, w = frame.shape[:2]
        target_w = h * 4 // 3
        if target_w <= w:
            x = (w - target_w) // 2
            four_three = frame[:, x : x + target_w]
        else:
            target_h = w * 3 // 4
            y = (h - target_h) // 2
            four_three = frame[y : y + target_h, :]
        small = cv2.resize(four_three, (320, 240), interpolation=cv2.INTER_AREA)
        ok, buf = cv2.imencode(".jpg", small, [int(cv2.IMWRITE_JPEG_QUALITY), 80])
        if ok:
            frames.append(buf.tobytes())
    cap.release()
    if not frames:
        raise ValueError(f"영상에서 프레임을 읽지 못했다: {path}")
    return frames, float(fps)


class FrameSource:
    """JPEG 바이트를 순환 공급한다. 각 프레임을 hold_frames 번 연속으로 낸 뒤 다음으로 넘어간다.

    앱은 250ms 마다 폴링하므로 매 폴링마다 바꾸면 2초에 8번 토글돼 램프처럼 보이지 않는다.
    기본 2회 유지 = ≈0.5초 점등/0.5초 소등 ≈ 상태머신이 모델링한 ~1Hz 점멸.
    """

    def __init__(self, frames: Sequence[bytes], hold_frames: int = DEFAULT_HOLD_FRAMES) -> None:
        self._frames = [bytes(f) for f in frames]
        if not self._frames:
            raise ValueError("프레임이 없다")
        if hold_frames < 1:
            raise ValueError("hold_frames 는 1 이상이어야 한다")
        self._hold = hold_frames
        self._count = 0

    @property
    def first(self) -> bytes:
        return self._frames[0]

    def next(self) -> bytes:
        idx = (self._count // self._hold) % len(self._frames)
        self._count += 1
        return self._frames[idx]

    def __len__(self) -> int:
        return len(self._frames)


class TimedFrameSource(FrameSource):
    """--video 용: 경과 시간 × fps 로 프레임을 골라 실시간으로 반복 재생한다."""

    def __init__(self, frames: Sequence[bytes], fps: float,
                 mono_ns: Callable[[], int] = time.monotonic_ns) -> None:
        super().__init__(frames, hold_frames=1)
        if fps <= 0:
            raise ValueError("fps 는 양수여야 한다")
        self._fps = fps
        self._mono_ns = mono_ns
        self._t0 = mono_ns()

    def next(self) -> bytes:
        elapsed_s = (self._mono_ns() - self._t0) / 1e9
        return self._frames[int(elapsed_s * self._fps) % len(self._frames)]


# ── 카메라 상태기계(CameraService 의 짝) ───────────────────────────────────


@dataclass(frozen=True)
class Shot:
    frame_seq: int
    capture_uptime_us: int
    jpeg: bytes


@dataclass(frozen=True)
class CaptureOutcome:
    kind: str  # 'ok' | 'busy' | 'failed'
    shot: Shot | None = None


class CameraSim:
    """bootId·부팅 기준 uptime·frameSeq·카운터·장애 상태. 잠금 하나로 camera_service.cpp 의 mutex 를 흉내낸다.

    시계와 bootId 생성기를 주입할 수 있어 테스트가 결정적이다. capture_uptime_us 는
    max(now, 직전+1) — µs 시계가 같은 값을 두 번 주더라도 "frameSeq 가 오르면 captureUptime 도
    오른다"는 계약이 깨지지 않게 한다.
    """

    def __init__(
        self,
        frames: FrameSource,
        *,
        mono_ns: Callable[[], int] = time.monotonic_ns,
        boot_id_factory: Callable[[], str] = lambda: secrets.token_hex(4),  # 펌웨어 "%08x" 와 같은 8 hex
    ) -> None:
        self._frames = frames
        self._mono_ns = mono_ns
        self._boot_id_factory = boot_id_factory
        self._lock = threading.Lock()
        self.fault_mode = "none"
        self.hold_ms = DEFAULT_HOLD_MS
        self.reset_reason = "POWERON_RESET"
        self.build_timestamp = time.strftime("%b %d %Y %H:%M:%S")  # 펌웨어 __DATE__ " " __TIME__ 꼴
        dims = jpeg_dimensions(frames.first)
        self._resolution = f"{dims[0]}x{dims[1]}" if dims else "0x0"
        self._boot()

    def _boot(self) -> None:
        self.boot_id = self._boot_id_factory()
        self._epoch_ns = self._mono_ns()
        self.frame_seq = 0
        self.capture_ok_count = 0
        self.capture_error_count = 0
        self.capture_busy_count = 0
        self._last_capture_us = 0
        self._last_shot: Shot | None = None

    def uptime_us(self) -> int:
        return max(0, (self._mono_ns() - self._epoch_ns) // 1000)

    def set_fault(self, mode: str, hold_ms: int | None = None) -> None:
        if mode not in FAULT_MODES:
            raise ValueError("unknown_fault_mode")
        if hold_ms is not None and (isinstance(hold_ms, bool) or not isinstance(hold_ms, int) or hold_ms < 0):
            raise ValueError("bad_hold_ms")
        with self._lock:
            if hold_ms is not None:
                self.hold_ms = hold_ms
            if mode == "reboot":  # 1회성 사건이지 지속 상태가 아니다
                self._reboot_locked()
                self.fault_mode = "none"
            else:
                self.fault_mode = mode

    def reboot(self) -> None:
        with self._lock:
            self._reboot_locked()

    def _reboot_locked(self) -> None:
        self._boot()
        self.reset_reason = "SW_RESET"

    def capture(self) -> CaptureOutcome:
        with self._lock:
            mode = self.fault_mode
            if mode == "busy":
                self.capture_busy_count += 1
                return CaptureOutcome("busy")
            if mode == "capture_failed":
                # 실패 시 마지막 JPEG 을 재전송하지 않는다(§10.3) — 503 으로 끝난다.
                self.capture_error_count += 1
                return CaptureOutcome("failed")
            if mode == "freeze" and self._last_shot is not None:
                # 정지: 같은 JPEG·같은 frameSeq·같은 captureUptime. 앱의 sameFrame 판정이 잡아야 할 그 상황.
                return CaptureOutcome("ok", self._last_shot)
            capture_us = max(self.uptime_us(), self._last_capture_us + 1)
            jpeg = self._frames.next()
            self.frame_seq += 1  # 획득 성공 시에만
            self.capture_ok_count += 1
            self._last_capture_us = capture_us
            shot = Shot(self.frame_seq, capture_us, jpeg)
            self._last_shot = shot
            return CaptureOutcome("ok", shot)

    def health(self) -> dict:
        """handleHealth() 와 같은 26개 키, 같은 순서."""
        with self._lock:
            return {
                "schemaVersion": SCHEMA_VERSION,
                "deviceId": DEVICE_ID,
                "bootId": self.boot_id,
                "firmwareVersion": FIRMWARE_VERSION,
                "buildTimestamp": self.build_timestamp,
                "cameraSensorPid": CAMERA_SENSOR,
                "cameraOk": True,
                "networkMode": NETWORK_MODE,
                "hostname": HOSTNAME,
                "uptimeMs": self.uptime_us() // 1000,
                "rssiDbm": HEALTH_CONSTANTS["rssiDbm"],
                "frameSeq": self.frame_seq,
                "lastCaptureUptimeUs": self._last_capture_us,
                "captureOkCount": self.capture_ok_count,
                "captureErrorCount": self.capture_error_count,
                "captureBusyCount": self.capture_busy_count,
                "wifiDisconnectCount": HEALTH_CONSTANTS["wifiDisconnectCount"],
                "resolution": self._resolution,
                "jpegQuality": HEALTH_CONSTANTS["jpegQuality"],
                "psramBytes": HEALTH_CONSTANTS["psramBytes"],
                "freePsramBytes": HEALTH_CONSTANTS["freePsramBytes"],
                "heapBytes": HEALTH_CONSTANTS["heapBytes"],
                "freeHeapBytes": HEALTH_CONSTANTS["freeHeapBytes"],
                "minFreeHeapBytes": HEALTH_CONSTANTS["minFreeHeapBytes"],
                "resetReason": self.reset_reason,
                "lastError": "",
            }

    def state(self) -> dict:
        """계약 밖 진단(/__sim/state). 토큰은 어디에도 없다."""
        with self._lock:
            return {
                "simulator": True,
                "fault": {"mode": self.fault_mode, "hold_ms": self.hold_ms},
                "bootId": self.boot_id,
                "frameSeq": self.frame_seq,
                "captureOkCount": self.capture_ok_count,
                "captureErrorCount": self.capture_error_count,
                "captureBusyCount": self.capture_busy_count,
                "frames": len(self._frames),
                "uptimeMs": self.uptime_us() // 1000,
            }


# ── HTTP(HttpApi 의 짝) ────────────────────────────────────────────────────


class _Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    block_on_close = False  # stall 중인 핸들러 스레드를 stop() 이 기다리지 않게

    def __init__(self, address: tuple[str, int], camera: CameraSim, token: str, quiet: bool) -> None:
        super().__init__(address, ClipCamHandler)
        self.camera = camera
        self.token = token
        self.quiet = quiet

    def handle_error(self, request, client_address) -> None:  # noqa: ANN001
        exc = sys.exc_info()[1]
        if isinstance(exc, (BrokenPipeError, ConnectionResetError)):
            return  # 폰이 800ms 타임아웃으로 먼저 끊은 것 — 정상 시나리오
        if not self.quiet:
            print(f"[sim] 요청 처리 오류: {exc!r}", file=sys.stderr)


class ClipCamHandler(BaseHTTPRequestHandler):
    """HttpApi::begin() 의 라우팅 표를 그대로 옮긴다. HTTP/1.0, 요청당 연결 하나(펌웨어도 Connection: close)."""

    server: _Server  # type: ignore[assignment]

    def version_string(self) -> str:
        return SERVER_STRING

    # ── 로그: 메서드·경로·상태만. 헤더(토큰)는 절대 찍지 않는다 ──
    def log_message(self, format: str, *args) -> None:  # noqa: A002
        if not self.server.quiet:
            print("[sim] " + (format % args), file=sys.stderr)

    def log_request(self, code="-", size="-") -> None:  # noqa: ANN001
        if not self.server.quiet:
            print(f"[sim] {self.command} {self._route_path()} {code}", file=sys.stderr)

    def send_response(self, code: int, message: str | None = None) -> None:
        # 기본 구현이 붙이는 Server/Date 헤더를 빼 펌웨어(WebServer)의 응답 헤더 집합에 맞춘다.
        self.log_request(code)
        self.send_response_only(code, message)

    def _route_path(self) -> str:
        return self.path.split("?", 1)[0]

    # ── 라우팅 ──
    def do_GET(self) -> None:  # noqa: N802
        path = self._route_path()
        if path == "/health":
            self._handle_health()
        elif path in ("/capture", "/jpg"):  # /jpg 는 호환 별칭
            self._handle_capture()
        elif path == "/":
            self._handle_root()
        elif path == CONTROL_PREFIX + "state":
            self._send_json(200, self.server.camera.state())
        else:
            self._not_found()

    def do_OPTIONS(self) -> None:  # noqa: N802
        if self._route_path() in ("/health", "/capture", "/jpg"):
            self._handle_options()
        else:
            self._not_found()

    def do_POST(self) -> None:  # noqa: N802
        if self._route_path() == CONTROL_PREFIX + "fault":
            self._handle_fault()
        else:
            self._not_found()

    # 펌웨어는 GET/OPTIONS 만 등록하므로 나머지 메서드는 모두 onNotFound 다.
    do_HEAD = do_PUT = do_DELETE = do_PATCH = do_POST  # noqa: N815

    # ── 공통 ──
    def _allowed_origin(self) -> str | None:
        origin = (self.headers.get("Origin") or "").strip()
        return origin if origin in CORS_ORIGINS else None  # 와일드카드 없음(§10.1)

    def _common_headers(self, expose_capture_headers: bool) -> None:
        # 판정에 쓰는 응답은 절대 캐시되면 안 된다(오래된 프레임이 새 것처럼 보인다).
        self.send_header("Cache-Control", CACHE_CONTROL)
        self.send_header("Pragma", "no-cache")
        origin = self._allowed_origin()
        if origin is not None:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
            if expose_capture_headers:
                self.send_header("Access-Control-Expose-Headers", ", ".join(EXPOSE_HEADERS))

    def _send(
        self,
        status: int,
        content_type: str | None,
        body: bytes = b"",
        extra: Sequence[tuple[str, str]] = (),
        *,
        common: bool = True,
        expose: bool = False,
    ) -> None:
        self.send_response(status)
        if common:
            self._common_headers(expose)
        if content_type:
            self.send_header("Content-Type", content_type)
        for key, value in extra:
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _send_json(self, status: int, payload: dict) -> None:
        self._send(status, "application/json", json.dumps(payload, separators=(",", ":")).encode())

    def _not_found(self) -> None:
        self._send(404, "application/json", BODY_NOT_FOUND)

    def _authorize(self) -> bool:
        """401/403 을 직접 보내고 False. ESP32 코어 WebServer::hasHeader 는 빈 값을 '없음'으로 본다."""
        raw = self.headers.get(TOKEN_HEADER)  # email.message 는 이름 대소문자를 가리지 않는다
        token = (raw or "").strip()
        if not token:
            self._send(401, "application/json", BODY_MISSING_TOKEN)
            return False
        # 회선 바이트끼리 상수 시간 비교(http.server 는 latin-1 로 디코드해 준다).
        if not hmac.compare_digest(token.encode("latin-1"), self.server.token.encode("utf-8")):
            self._send(403, "application/json", BODY_INVALID_TOKEN)
            return False
        return True

    # ── 계약 경로 ──
    def _handle_options(self) -> None:
        origin = self._allowed_origin()
        if origin is None:
            # 허용하지 않은 origin 의 preflight 는 CORS 헤더 없이 거절한다.
            self._send(403, "text/plain", b"origin not allowed", common=False)
            return
        # 펌웨어 send(204) 는 기본 mime(text/html)·Content-Length: 0 을 낸다.
        self._send(
            204,
            "text/html",
            b"",
            [
                ("Access-Control-Allow-Origin", origin),
                ("Vary", "Origin"),
                ("Access-Control-Allow-Methods", "GET, OPTIONS"),
                ("Access-Control-Allow-Headers", TOKEN_HEADER),
                ("Access-Control-Max-Age", "600"),
            ],
            common=False,
        )

    def _handle_health(self) -> None:
        if not self._authorize():
            return
        self._send_json(200, self.server.camera.health())

    def _handle_capture(self) -> None:
        if not self._authorize():
            return
        camera = self.server.camera
        mode = camera.fault_mode
        if mode == "wrong_content_type":
            # 캡티브 포털·다른 서버 흉내: 획득하지 않으므로 frameSeq 도 움직이지 않는다.
            self._send(200, "text/html; charset=utf-8", BODY_CAPTIVE_PORTAL)
            return
        outcome = camera.capture()
        if outcome.kind == "busy":
            self._send(409, "application/json", BODY_BUSY)
            return
        if outcome.kind == "failed":
            self._send(503, "application/json", BODY_FAILED)
            return
        shot = outcome.shot
        assert shot is not None
        if mode == "stall":
            time.sleep(camera.hold_ms / 1000.0)  # 획득은 이미 끝났고 응답만 붙든다
        # 응답 직전 uptime. stall 뒤에 재는 이유: serverFrameAge 가 붙든 시간을 정직하게 반영해야
        # 앱의 보수적 age 계산이 의미를 가진다. 시계가 멈춘 가짜 시계에서도 capture 보다 작지 않게.
        response_us = max(camera.uptime_us(), shot.capture_uptime_us)
        extra = [
            ("X-Frame-Seq", str(shot.frame_seq)),
            ("X-Capture-Uptime-Us", str(shot.capture_uptime_us)),
            ("X-Response-Uptime-Us", str(response_us)),
            ("X-Boot-Id", camera.boot_id),
            ("X-Firmware-Version", FIRMWARE_VERSION),
            ("X-Camera-Sensor", CAMERA_SENSOR),
        ]
        if mode == "drop_headers":
            extra = [h for h in extra if h[0] != "X-Frame-Seq"]
        try:
            self._send(200, "image/jpeg", shot.jpeg, extra, expose=True)
        except (BrokenPipeError, ConnectionResetError):
            pass  # 폰이 타임아웃으로 먼저 끊었다

    def _handle_root(self) -> None:
        # CLIP_ENABLE_INSPECT_PAGE 0 — 무인증 공개 카메라를 만들지 않는다.
        self._send(404, "application/json", BODY_INSPECT_DISABLED)

    # ── 계약 밖 제어 ──
    def _handle_fault(self) -> None:
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length < 0 or length > 4096:
            self._send_json(400, {"error": "bad_json"})
            return
        try:
            payload = json.loads(self.rfile.read(length) or b"")
        except (ValueError, UnicodeDecodeError):
            self._send_json(400, {"error": "bad_json"})
            return
        if not isinstance(payload, dict):
            self._send_json(400, {"error": "bad_json"})
            return
        mode = payload.get("mode")
        hold_ms = payload.get("hold_ms")
        if not isinstance(mode, str) or mode not in FAULT_MODES:
            self._send_json(400, {"error": "unknown_fault_mode", "modes": list(FAULT_MODES)})
            return
        try:
            self.server.camera.set_fault(mode, hold_ms)
        except ValueError:
            self._send_json(400, {"error": "bad_hold_ms"})
            return
        self._send_json(200, self.server.camera.state())


class ClipCamSim:
    """서버 수명 관리. start() 는 데몬 스레드에서 serve_forever, stop() 은 shutdown+close."""

    def __init__(self, camera: CameraSim, token: str, *, host: str = "127.0.0.1", port: int = 0,
                 quiet: bool = False) -> None:
        if not token:
            raise ValueError("토큰이 비어 있다")
        self._server = _Server((host, port), camera, token, quiet)
        self._thread: threading.Thread | None = None

    @property
    def host(self) -> str:
        return self._server.server_address[0]

    @property
    def port(self) -> int:
        return self._server.server_address[1]

    @property
    def base_url(self) -> str:
        return f"http://{self.host}:{self.port}"

    def start(self) -> int:
        self._thread = threading.Thread(
            target=self._server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True, name="clip-cam-sim"
        )
        self._thread.start()
        return self.port

    def stop(self) -> None:
        self._server.shutdown()
        self._server.server_close()
        if self._thread is not None:
            self._thread.join(5.0)


# ── 토큰·CLI ───────────────────────────────────────────────────────────────


def resolve_token(
    cli_token: str | None,
    env: Mapping[str, str] = os.environ,
    token_file: Path = TOKEN_FILE,
) -> tuple[str, str]:
    """(token, source∈{'cli','env','file'}). 우선순위 --token > CLIP_DEVICE_TOKEN > ~/.clipsense/device_token."""
    if cli_token:
        return cli_token, "cli"
    env_token = (env.get(TOKEN_ENV) or "").strip()
    if env_token:
        return env_token, "env"
    try:
        file_token = Path(token_file).read_text(encoding="utf-8").strip()
    except OSError:
        file_token = ""
    if file_token:
        return file_token, "file"
    raise ValueError("기기 토큰이 없다: --token, CLIP_DEVICE_TOKEN, ~/.clipsense/device_token 중 하나가 필요하다")


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="클립 카메라 펌웨어 시뮬레이터(표준 라이브러리). 실기기 검증을 대신하지 않는다.",
    )
    p.add_argument("--host", default="127.0.0.1", help="기본 루프백. 실제 폰에서 붙을 때만 0.0.0.0")
    p.add_argument("--port", type=int, default=8080, help="0 이면 OS 가 고른다(첫 줄에 찍힌다)")
    p.add_argument("--token", help="기기 토큰. 명령줄은 ps 에 보이므로 CLIP_DEVICE_TOKEN 환경변수 권장")
    p.add_argument("--jpeg", action="append", metavar="PATH[,PATH...]",
                   help="순환할 JPEG. 기본: fixture 점등 f20 / 소등 f34")
    p.add_argument("--hold-frames", type=int, default=DEFAULT_HOLD_FRAMES,
                   help=f"프레임당 연속 제공 횟수(기본 {DEFAULT_HOLD_FRAMES} ≈ 250ms 폴링에서 1Hz 점멸)")
    p.add_argument("--video", metavar="PATH", help="cv2 가 있을 때만. 중앙 4:3 → 320x240, 실시간 반복")
    p.add_argument("--max-frames", type=int, default=600, help="--video 에서 미리 인코딩할 최대 프레임 수")
    p.add_argument("--fault", choices=[m for m in FAULT_MODES if m != "reboot"], default="none",
                   help="시작 시 장애 모드(reboot 는 실행 중 POST /__sim/fault 로만)")
    p.add_argument("--hold-ms", type=int, default=DEFAULT_HOLD_MS,
                   help=f"stall 에서 응답을 붙드는 시간(기본 {DEFAULT_HOLD_MS} > 앱 타임아웃 800)")
    p.add_argument("--quiet", action="store_true", help="요청 로그를 찍지 않는다")
    return p


def main(argv: Sequence[str] | None = None) -> int:
    args = build_arg_parser().parse_args(argv)
    try:
        token, source = resolve_token(args.token)
    except ValueError as e:
        print(f"오류: {e}", file=sys.stderr)
        return 2
    try:
        frames: FrameSource
        if args.video:
            video_frames, fps = load_video_frames(Path(args.video), args.max_frames)
            frames = TimedFrameSource(video_frames, fps)
        else:
            paths = [Path(p) for item in (args.jpeg or []) for p in item.split(",") if p]
            frames = FrameSource(load_jpeg_frames(paths or list(DEFAULT_FRAMES)), args.hold_frames)
        camera = CameraSim(frames)
        camera.set_fault(args.fault, args.hold_ms)
        server = ClipCamSim(camera, token, host=args.host, port=args.port, quiet=args.quiet)
    except (ValueError, RuntimeError, OSError) as e:
        print(f"오류: {e}", file=sys.stderr)
        return 2

    server.start()
    print(
        f"listening {server.base_url} bootId={camera.boot_id} frames={len(frames)} "
        f"fault={camera.fault_mode} sensor={CAMERA_SENSOR} token=set({source})",
        flush=True,
    )

    def _terminate(signum, frame):  # noqa: ANN001, ARG001
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, _terminate)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass
    finally:
        server.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
