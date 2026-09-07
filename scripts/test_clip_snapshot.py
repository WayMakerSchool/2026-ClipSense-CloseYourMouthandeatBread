"""clip_snapshot 단위·골든 테스트 — app/test/fixtures/clip_freshness_cases.json 을 Dart
(app/test/clip/clip_freshness_golden_test.dart)와 함께 읽는다. Dart 가 기준: 여기서
실패하면 clip_snapshot.py 가 뒤처진 것이다(골든을 Python 에 맞추지 않는다).
실행: python scripts/test_clip_snapshot.py"""
import dataclasses
import json
import sys
from collections.abc import Mapping
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from clip_snapshot import (
    parse_capture_headers, ClipCaptureMeta, ClipFreshnessTracker, ClipFrameObservation,
    ALL_VERDICTS, VERDICT_ACCEPTED, VERDICT_SAME_FRAME, VERDICT_REPLAY_OR_REORDER,
    CLIP_TOKEN_HEADER, CLIP_FRAME_SEQ_HEADER, CLIP_CAPTURE_UPTIME_HEADER,
    CLIP_RESPONSE_UPTIME_HEADER, CLIP_BOOT_ID_HEADER, CLIP_FIRMWARE_VERSION_HEADER,
    CLIP_CAMERA_SENSOR_HEADER, CLIP_SCHEMA_VERSION, CLIP_CAPTURE_PATH, CLIP_HEALTH_PATH,
    CLIP_JPEG_CONTENT_TYPE,
)

GOLDEN = ROOT / "app" / "test" / "fixtures" / "clip_freshness_cases.json"
GOLDEN_REL = "app/test/fixtures/clip_freshness_cases.json"
FAILURES = []


def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print(f"[{status}] {name}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(name)


def _reject(token):
    raise ValueError(f"골든에 bare {token} — 문자열로 써야 한다(Dart jsonDecode 가 못 읽는다)")


with GOLDEN.open(encoding="utf-8") as f:
    golden = json.load(f, parse_constant=_reject)


def _int(v):
    """Dart `as int` 는 100.0·true 를 거부한다 — 같은 규칙."""
    if type(v) is not int:
        raise ValueError(f"골든 정수 인코딩 오류: {v!r}")
    return v


def _opt_int(v):
    return None if v is None else _int(v)


# --- 계약 상수·어휘 ---
check("골든 스키마", golden["schema"] == "clipsense-clip-freshness-golden-v1")
_py_contract = {
    "token_header": CLIP_TOKEN_HEADER,
    "frame_seq_header": CLIP_FRAME_SEQ_HEADER,
    "capture_uptime_header": CLIP_CAPTURE_UPTIME_HEADER,
    "response_uptime_header": CLIP_RESPONSE_UPTIME_HEADER,
    "boot_id_header": CLIP_BOOT_ID_HEADER,
    "firmware_version_header": CLIP_FIRMWARE_VERSION_HEADER,
    "camera_sensor_header": CLIP_CAMERA_SENSOR_HEADER,
    "schema_version": CLIP_SCHEMA_VERSION,
    "capture_path": CLIP_CAPTURE_PATH,
    "health_path": CLIP_HEALTH_PATH,
    "jpeg_content_type": CLIP_JPEG_CONTENT_TYPE,
}
_diff = {k: (golden["contract"].get(k), _py_contract.get(k))
         for k in set(golden["contract"]) | set(_py_contract)
         if golden["contract"].get(k) != _py_contract.get(k)}
check("contract 블록 = Python 상수 11개", golden["contract"] == _py_contract and len(_py_contract) == 11,
      detail=f"(golden, py) 차이 {_diff} → {GOLDEN_REL} contract 와 clip_snapshot.py CLIP_* 갱신")
check("verdicts 어휘·순서 = ALL_VERDICTS", golden["verdicts"] == list(ALL_VERDICTS),
      detail=f"golden={golden['verdicts']} py={list(ALL_VERDICTS)} → Dart ClipFrameVerdict 선언 순서로")
check("VERDICT_* 상수가 ALL_VERDICTS 를 이룬다",
      ALL_VERDICTS == (VERDICT_ACCEPTED, VERDICT_SAME_FRAME, VERDICT_REPLAY_OR_REORDER))

header_cases = golden["header_cases"]
sequences = golden["sequences"]
check("헤더 케이스 16개 이상", len(header_cases) >= 16, detail=str(len(header_cases)))
check("시퀀스 10개 이상", len(sequences) >= 10, detail=str(len(sequences)))
_names = [c["name"] for c in header_cases] + [s["name"] for s in sequences]
check("이름 중복 없음", len(set(_names)) == len(_names))

# --- 헤더 케이스 ---
for c in header_cases:
    meta = parse_capture_headers(c["headers"])
    exp = c["expect"]
    if exp is None:
        check(f"header: {c['name']}", meta is None, detail=repr(meta))
        continue
    want = (_int(exp["frame_seq"]), _int(exp["capture_uptime_us"]), _int(exp["response_uptime_us"]),
            exp["boot_id"], exp["firmware_version"], exp["camera_sensor"],
            _int(exp["server_frame_age_ms"]))
    got = None if meta is None else (
        meta.frame_seq, meta.capture_uptime_us, meta.response_uptime_us, meta.boot_id,
        meta.firmware_version, meta.camera_sensor, meta.server_frame_age_ms)
    check(f"header: {c['name']}", got == want, detail=f"got {got} want {want}")

# --- 시퀀스 ---
for s in sequences:
    tracker = ClipFreshnessTracker()
    for i, step in enumerate(s["steps"]):
        if step.get("reset") is True:
            tracker.reset()
            check(f"sequence: {s['name']} [step {i} reset]", tracker.last_accepted is None)
            continue
        m = step["meta"]
        meta = ClipCaptureMeta(frame_seq=_int(m["seq"]), capture_uptime_us=_int(m["capture"]),
                               response_uptime_us=_int(m["response"]), boot_id=m["boot"])
        o = tracker.observe(meta, rtt_ms=_int(step["rtt_ms"]),
                            received_mono_ms=_int(step["received_mono_ms"]))
        e = step["expect"]
        last = tracker.last_accepted
        got = (o.verdict, o.boot_changed, o.conservative_age_ms, o.captured_at_mono_ms,
               None if last is None else last.frame_seq)
        want = (e["verdict"], e["boot_changed"], _int(e["conservative_age_ms"]),
                _opt_int(e["captured_at_mono_ms"]), _opt_int(e["last_accepted_seq"]))
        check(f"sequence: {s['name']} [step {i}]", got == want, detail=f"got {got} want {want}")
        check(f"sequence: {s['name']} [step {i}] accepted ⇔ captured_at 있음(골든 자체 일관성)",
              (e["verdict"] == VERDICT_ACCEPTED) == (e["captured_at_mono_ms"] is not None))

# --- Python 전용: 언어 특성에서 오는 함정 ---
BASE = {
    "X-Frame-Seq": "1482",
    "X-Capture-Uptime-Us": "372800221",
    "X-Response-Uptime-Us": "372812505",
    "X-Boot-Id": "a83f219c",
    "X-Firmware-Version": "0.2.0",
    "X-Camera-Sensor": "OV3660",
}

_meta = parse_capture_headers(BASE)
try:
    _meta.frame_seq = 1
    _frozen = False
except dataclasses.FrozenInstanceError:
    _frozen = True
check("ClipCaptureMeta 는 불변", _frozen)
check("ClipCaptureMeta 값 동등성(같은 값 ==, 다른 seq !=)",
      parse_capture_headers(BASE) == parse_capture_headers(dict(BASE))
      and hash(parse_capture_headers(BASE)) == hash(parse_capture_headers(dict(BASE)))
      and parse_capture_headers(BASE) != parse_capture_headers({**BASE, "X-Frame-Seq": "1"}))

_obs = ClipFreshnessTracker().observe(_meta, rtt_ms=0, received_mono_ms=0)
try:
    _obs.verdict = VERDICT_SAME_FRAME
    _frozen = False
except dataclasses.FrozenInstanceError:
    _frozen = True
check("ClipFrameObservation 은 불변", _frozen and isinstance(_obs, ClipFrameObservation))


class _ReadOnlyHeaders(Mapping):
    """dict 가 아닌 Mapping(예: http.client 의 HTTPMessage 래퍼)도 받아야 한다."""

    def __init__(self, d):
        self._d = dict(d)

    def __getitem__(self, k):
        return self._d[k]

    def __iter__(self):
        return iter(self._d)

    def __len__(self):
        return len(self._d)


check("parse_capture_headers 는 dict 가 아닌 Mapping 도 받는다",
      parse_capture_headers(_ReadOnlyHeaders(BASE)) == parse_capture_headers(BASE))

try:
    ClipFreshnessTracker().observe(_meta, 0, 0)
    _kw_only = False
except TypeError:
    _kw_only = True
check("observe 는 키워드 전용(rtt_ms, received_mono_ms 위치 인자 거부)", _kw_only)

# str.isdigit() 는 위첨자 2(U+00B2)·아랍-인도 숫자도 True — ASCII 0-9 만 허용해야 Dart 와 같다.
check("str.isdigit 함정: U+00B2(²) 도 무효",
      chr(0xB2).isdigit() and parse_capture_headers({**BASE, "X-Frame-Seq": chr(0xB2)}) is None)
# Python 3.11+ int() 는 4300자리 넘는 문자열에 ValueError — 파서는 던지지 않고 None 이어야 한다.
try:
    _huge = parse_capture_headers({**BASE, "X-Frame-Seq": "1" * 5000})
    _no_raise = True
except ValueError:
    _huge, _no_raise = "raised", False
check("5000자리 숫자 → None (예외 없음)", _no_raise and _huge is None, detail=repr(_huge))
check("int64 최대는 허용, +1 은 무효(Dart int.tryParse 와 같은 경계)",
      parse_capture_headers({**BASE, "X-Frame-Seq": str((1 << 63) - 1)}).frame_seq == (1 << 63) - 1
      and parse_capture_headers({**BASE, "X-Frame-Seq": str(1 << 63)}) is None)


def _age(capture, response):
    return ClipCaptureMeta(1, capture, response, "b").server_frame_age_ms


check("server_frame_age_ms 는 정수 올림(0→0, 1→1, 1000→1, 1001→2, 12284→13)",
      [_age(0, d) for d in (0, 1, 1000, 1001, 12284)] == [0, 1, 1, 2, 13])
check("server_frame_age_ms 는 2^53 초과에서도 정확(정수 연산)",
      _age(9007199254740993, 9007199254741993) == 1)

print("=" * 50)
if FAILURES:
    print(f"FAIL {len(FAILURES)}건: {FAILURES}")
    sys.exit(1)
print("clip_snapshot 단위·골든 테스트 전부 PASS")
