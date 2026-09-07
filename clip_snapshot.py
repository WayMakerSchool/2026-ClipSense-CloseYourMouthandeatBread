"""클립 카메라 /capture 응답 헤더 → 프레임 메타데이터, 신선도·진행 추적기(순수 로직).

app/lib/clip/clip_contract.dart · clip_snapshot.dart · clip_freshness.dart 의 Python
미러. 골든 app/test/fixtures/clip_freshness_cases.json 이 두 구현을 묶는다
(scripts/test_clip_snapshot.py ↔ app/test/clip/clip_freshness_golden_test.dart).

I/O·HTTP 없음. 부스 데모가 클립 카메라를 붙일 때(--clip-host, 미구현) 이 모듈 위에
HTTP 클라이언트를 얹는다. 실기기 검증은 아직이다 — 여기 규칙은 하드웨어 보고서
§10.3~§10.4·§11.3 과 Dart 구현을 따른 순수 논리다.

계약(clip_snapshot.dart): 헤더가 없거나 숫자가 부호 없는 십진 정수가 아니거나
response < capture 면 프레임 무효(None). 무효는 None 이다 — 기본값으로 채워
"그럴듯한" 프레임을 만들지 않는다(추측 금지).
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass

# ---- HTTP 계약 상수 — clip_contract.dart 와 글자 그대로 같다. 펌웨어 쪽 문자열은
# scripts/verify_firmware_contract.py 가 이 값으로 검사한다(복사본을 두지 않는다).
CLIP_TOKEN_HEADER = "X-Clip-Device-Token"
CLIP_FRAME_SEQ_HEADER = "X-Frame-Seq"
CLIP_CAPTURE_UPTIME_HEADER = "X-Capture-Uptime-Us"
CLIP_RESPONSE_UPTIME_HEADER = "X-Response-Uptime-Us"
CLIP_BOOT_ID_HEADER = "X-Boot-Id"
CLIP_FIRMWARE_VERSION_HEADER = "X-Firmware-Version"
CLIP_CAMERA_SENSOR_HEADER = "X-Camera-Sensor"
CLIP_SCHEMA_VERSION = "clipsense-camera-api-v1"
CLIP_CAPTURE_PATH = "/capture"
CLIP_HEALTH_PATH = "/health"
CLIP_JPEG_CONTENT_TYPE = "image/jpeg"

# Dart int.tryParse 는 2^63 이상에서 null — 같은 값을 거부해야 두 구현이 같은 프레임을
# 버린다. 자릿수 상한을 먼저 보는 이유: Python 3.11+ int() 는 4300자리를 넘으면
# ValueError 를 던지는데(Dart 는 null), 파서는 어떤 입력에도 던지지 않아야 한다.
_INT64_MAX = (1 << 63) - 1
_INT64_MAX_DIGITS = 19  # len(str(_INT64_MAX))

# Dart String.trim() 이 자르는 문자 집합(Unicode White_Space + BOM). Dart 3.35 VM 에서
# BMP 전수 조사로 확인한 값이다. Python str.strip() 과 다르다 — Python 은
# U+001C~U+001F(정보 구분자)도 자르고 U+FEFF(BOM)는 안 자른다. 헤더 값을 한쪽만
# 받아들이면 "Python 은 프레임을 받고 앱은 버린다"가 되므로 Dart 집합을 그대로 쓴다.
# 코드포인트로 적는 이유: 보이지 않는 글자를 소스에 날것으로 두면 리뷰가 불가능하다.
_DART_TRIM_CHARS = "".join(chr(cp) for cp in (
    0x0009, 0x000A, 0x000B, 0x000C, 0x000D,  # TAB LF VT FF CR
    0x0020,  # SPACE
    0x0085,  # NEXT LINE
    0x00A0,  # NO-BREAK SPACE
    0x1680,  # OGHAM SPACE MARK
    0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005,  # EN QUAD .. SIX-PER-EM SPACE
    0x2006, 0x2007, 0x2008, 0x2009, 0x200A,  # .. HAIR SPACE
    0x2028, 0x2029,  # LINE / PARAGRAPH SEPARATOR
    0x202F,  # NARROW NO-BREAK SPACE
    0x205F,  # MEDIUM MATHEMATICAL SPACE
    0x3000,  # IDEOGRAPHIC SPACE
    0xFEFF,  # ZERO WIDTH NO-BREAK SPACE (BOM)
))


@dataclass(frozen=True)
class ClipCaptureMeta:
    """`/capture` 한 응답의 메타데이터. JPEG 바이트는 여기 없다(원자적으로 함께 온
    값만 담는다). 불변·값 동등(Dart @immutable + operator== 와 같다)."""
    frame_seq: int
    capture_uptime_us: int
    response_uptime_us: int
    boot_id: str
    firmware_version: str | None = None
    camera_sensor: str | None = None

    @property
    def server_frame_age_ms(self) -> int:
        """펌웨어 안에서 프레임이 이미 늙은 시간(ms). 올림 — 보수적으로 더 오래된
        것으로 본다(§10.4). 정수 연산만 쓴다 — float 을 거치면 64비트 µs 정밀도를
        잃는다."""
        return (self.response_uptime_us - self.capture_uptime_us + 999) // 1000


def _header(headers: Mapping[str, str], name: str) -> str | None:
    """헤더 이름을 대소문자 무시로 찾는다(순회 순서상 첫 일치 — Dart 와 같다). 값은
    Dart trim() 집합으로 앞뒤를 자른다. dart:io 는 응답 헤더 키를 소문자로 주고 테스트
    클라이언트는 보낸 그대로 주므로, 대소문자를 가리면 실기기에서 모든 프레임이
    버려진다."""
    wanted = name.lower()
    for key, value in headers.items():
        if key.lower() == wanted:
            return value.strip(_DART_TRIM_CHARS)
    return None


def _non_negative_int(text: str | None) -> int | None:
    """십진 숫자만으로 된 음수 아닌 정수만 허용. float 을 거치지 않는다(64비트 µs
    보존). '1e3'·'1.5'·'NaN'·'Infinity' 는 물론 '+5'·'0x10'·'1_000' 처럼 int() 가
    받아 주는 표기도 거부한다 — 펌웨어는 부호 없는 십진수만 보낸다."""
    if text is None or text == "":
        return None
    if len(text) > _INT64_MAX_DIGITS:
        return None
    # str.isdigit() 는 "²"·"٣" 도 True 고 int() 는 "1_000" 도 받는다 — ASCII 0-9 만.
    for ch in text:
        if not ("0" <= ch <= "9"):
            return None
    n = int(text)
    return None if n > _INT64_MAX else n


def parse_capture_headers(headers: Mapping[str, str]) -> ClipCaptureMeta | None:
    """`/capture` 응답 헤더를 ClipCaptureMeta 로. 계약 위반이면 None (Dart
    parseClipHeaders 와 같은 규칙)."""
    frame_seq = _non_negative_int(_header(headers, CLIP_FRAME_SEQ_HEADER))
    capture = _non_negative_int(_header(headers, CLIP_CAPTURE_UPTIME_HEADER))
    response = _non_negative_int(_header(headers, CLIP_RESPONSE_UPTIME_HEADER))
    boot_id = _header(headers, CLIP_BOOT_ID_HEADER)
    if (frame_seq is None or capture is None or response is None
            or boot_id is None or boot_id == ""):
        return None
    # 같은 clock domain 에서 응답이 촬영보다 앞설 수는 없다 — 펌웨어 버그나 위조.
    if response < capture:
        return None

    def optional(name: str) -> str | None:
        v = _header(headers, name)
        return None if v is None or v == "" else v

    return ClipCaptureMeta(
        frame_seq=frame_seq,
        capture_uptime_us=capture,
        response_uptime_us=response,
        boot_id=boot_id,
        firmware_version=optional(CLIP_FIRMWARE_VERSION_HEADER),
        camera_sensor=optional(CLIP_CAMERA_SENSOR_HEADER),
    )


# ---- 신선도·진행 판정 — 값은 Dart ClipFrameVerdict 이름의 snake_case, 선언 순서도 같다.
VERDICT_ACCEPTED = "accepted"            # 새 프레임. captured_at_mono_ms 유효.
VERDICT_SAME_FRAME = "same_frame"        # 직전과 같은 프레임(seq·촬영시각 동일). 신선도 미갱신.
VERDICT_REPLAY_OR_REORDER = "replay_or_reorder"  # 같은 boot 안에서 seq/촬영시각 역행. 거부.
ALL_VERDICTS: tuple[str, ...] = (
    VERDICT_ACCEPTED,
    VERDICT_SAME_FRAME,
    VERDICT_REPLAY_OR_REORDER,
)


@dataclass(frozen=True)
class ClipFrameObservation:
    """ClipFreshnessTracker.observe() 의 결과. 불변."""
    verdict: str
    # 이 관측에서 bootId 가 바뀌어 이력을 폐기했는가(판정 파이프라인도 함께 리셋해야
    # 한다 — 재부팅 전 프레임으로 쌓은 debounce 이력은 무효).
    boot_changed: bool
    # 보수적 나이(ms) = rtt + 서버 프레임 나이. 거부된 프레임도 값은 계산한다(진단용).
    conservative_age_ms: int
    # 폰(호스트) 단조 시계 기준 촬영 시각(ms). accepted 일 때만 값이 있다.
    captured_at_mono_ms: int | None = None


class ClipFreshnessTracker:
    """클립 프레임의 신선도·진행(정지/역전/재부팅) 추적기(clip_freshness.dart 미러).

    기기 uptime 과 호스트 단조 시계는 다른 clock domain 이라 직접 뺄 수 없다. 그래서
    "요청 기반 보수적 추정"만 한다(§10.4):
        conservative_age_ms = rtt_ms + server_frame_age_ms
        captured_at_mono_ms = received_mono_ms - conservative_age_ms

    진행 규칙(§11.3): 새 frame_seq 일 때만 관측을 갱신하고, 같은 프레임은 신선도를
    갱신하지 않는다(정지된 카메라가 계속 "새 것"으로 보이지 않게). seq 역전은
    replay_or_reorder 로 거부하되 고수위는 유지한다. bootId 가 바뀌면 이력을 즉시
    폐기한다 — uptime 이 0 으로 돌아오는 것은 역전이 아니라 새 이력이다. uptime 역행
    만으로는 절대 리셋하지 않는다(재부팅을 숨기는 재생 공격·버그와 구분할 수 없으므로
    거부가 안전하다).
    """

    def __init__(self) -> None:
        self._boot_id: str | None = None
        self._last_accepted: ClipCaptureMeta | None = None

    @property
    def last_accepted(self) -> ClipCaptureMeta | None:
        """마지막으로 받아들인 프레임의 메타데이터(고수위). 없으면 None."""
        return self._last_accepted

    def reset(self) -> None:
        """이력 폐기. 소스 정지·재시작 시 호출한다. bootId 이력도 지우므로 다음
        프레임은 boot 가 달라도 boot_changed=False 로 첫 프레임처럼 받는다."""
        self._boot_id = None
        self._last_accepted = None

    def observe(self, meta: ClipCaptureMeta, *, rtt_ms: int,
                received_mono_ms: int) -> ClipFrameObservation:
        """응답 하나를 관측한다. rtt_ms 는 요청 전송→응답 수신의 호스트 단조 시계
        경과, received_mono_ms 는 응답을 다 받은 호스트 단조 시각. 키워드 전용 —
        두 ms 값을 자리로 바꿔 넣는 실수를 막는다(Dart 의 이름 붙은 인자와 같다)."""
        # 음수 rtt 는 시계 오류다. 0 으로 보되 나이를 줄이지는 않는다.
        rtt = 0 if rtt_ms < 0 else rtt_ms
        age = rtt + meta.server_frame_age_ms

        boot_changed = False
        if self._boot_id is not None and self._boot_id != meta.boot_id:
            boot_changed = True
            self._last_accepted = None
        self._boot_id = meta.boot_id

        last = self._last_accepted
        if last is not None:
            same_seq = meta.frame_seq == last.frame_seq
            same_capture = meta.capture_uptime_us == last.capture_uptime_us
            if same_seq and same_capture:
                return ClipFrameObservation(VERDICT_SAME_FRAME, boot_changed, age)
            # seq 와 촬영시각이 둘 다 앞서야 진행이다. 하나만 앞서면(같은 seq 에 다른
            # 촬영시각 = 원자성 위반, seq 는 앞서는데 uptime 역행 = 재부팅 숨김) 거부.
            advanced = (meta.frame_seq > last.frame_seq
                        and meta.capture_uptime_us > last.capture_uptime_us)
            if not advanced:
                return ClipFrameObservation(VERDICT_REPLAY_OR_REORDER, boot_changed, age)

        self._last_accepted = meta
        return ClipFrameObservation(
            VERDICT_ACCEPTED, boot_changed, age, received_mono_ms - age,
        )
