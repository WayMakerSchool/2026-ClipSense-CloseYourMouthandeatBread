"""클립 카메라 HTTP 계약 블랙박스 검사 — 시뮬레이터와 실제 보드에 똑같이 쓴다.

소스를 보지 않고 응답만 본다(verify_firmware_contract.py 는 소스를 본다). 하나라도 FAIL 이면 1 로 끝난다.
시뮬레이터 통과는 보드 동작을 증명하지 않는다 — 대상이 SIM 인지 보드인지 요약 줄에 밝힌다.

실행: python scripts/check_clip_cam_contract.py http://127.0.0.1:8080 [--token T]   (토큰: --token | CLIP_DEVICE_TOKEN | ~/.clipsense/device_token; 명령줄 토큰은 ps 에 보이므로 env 권장)

검사 규칙은 앱(app/lib/clip/clip_snapshot.dart·clip_snapshot_client.dart)이 프레임을 받아들이는 규칙을
그대로 옮긴 것이다 — 부호 없는 십진수만, 문자열 헤더 비어 있지 않음, responseUptime >= captureUptime,
FF D8. 여기를 통과하는 보드는 앱이 받아들이는 보드다. 경고 등급은 없다: 계약 위반은 전부 FAIL.
표준 라이브러리만 쓰고 시뮬레이터 모듈을 import 하지 않는다(블랙박스).
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Mapping, Sequence
from urllib.parse import urlsplit

HEALTH_FIELDS = (
    "schemaVersion",
    "deviceId",
    "bootId",
    "firmwareVersion",
    "buildTimestamp",
    "cameraSensorPid",
    "cameraOk",
    "networkMode",
    "hostname",
    "uptimeMs",
    "rssiDbm",
    "frameSeq",
    "lastCaptureUptimeUs",
    "captureOkCount",
    "captureErrorCount",
    "captureBusyCount",
    "wifiDisconnectCount",
    "resolution",
    "jpegQuality",
    "psramBytes",
    "freePsramBytes",
    "heapBytes",
    "freeHeapBytes",
    "minFreeHeapBytes",
    "resetReason",
    "lastError",
)
CAPTURE_HEADERS = (
    "X-Frame-Seq",
    "X-Capture-Uptime-Us",
    "X-Response-Uptime-Us",
    "X-Boot-Id",
    "X-Firmware-Version",
    "X-Camera-Sensor",
)
INT_HEADERS = CAPTURE_HEADERS[:3]
STR_HEADERS = CAPTURE_HEADERS[3:]
SCHEMA_VERSION = "clipsense-camera-api-v1"
TOKEN_HEADER = "X-Clip-Device-Token"
TOKEN_ENV = "CLIP_DEVICE_TOKEN"
TOKEN_FILE = Path.home() / ".clipsense" / "device_token"
DEFAULT_ORIGIN = "http://localhost:5173"
DISALLOWED_ORIGIN = "http://evil.example"
JPEG_MAGIC = b"\xff\xd8"
_INT64_MAX = (1 << 63) - 1


@dataclass
class HttpReply:
    status: int
    headers: dict[str, str] = field(default_factory=dict)  # 키는 소문자
    body: bytes = b""
    error: str = ""  # 연결·시간 초과면 status 0 과 함께 채워진다

    def media_type(self) -> str:
        return self.headers.get("content-type", "").split(";")[0].strip().lower()

    def json(self) -> dict | None:
        try:
            value = json.loads(self.body)
        except ValueError:
            return None
        return value if isinstance(value, dict) else None


def normalize_base_url(base_url: str) -> str:
    """'127.0.0.1:8080' 처럼 스킴 없이 줘도 받는다(앱의 CLIP_CAM_HOST 와 같은 꼴)."""
    base = base_url.strip()
    if "://" not in base:
        base = "http://" + base
    return base.rstrip("/")


def fetch(
    base_url: str,
    method: str,
    path: str,
    *,
    headers: Mapping[str, str] | None = None,
    body: bytes | None = None,
    timeout_s: float = 3.0,
) -> HttpReply:
    """요청 하나 = 연결 하나(Connection: close). base_url 의 경로 접두어를 존중한다. 연결 실패는 OSError."""
    parts = urlsplit(normalize_base_url(base_url))
    if parts.scheme != "http" or not parts.hostname:
        raise ValueError(f"http://host[:port][/prefix] 꼴이어야 한다: {base_url}")
    conn = http.client.HTTPConnection(parts.hostname, parts.port or 80, timeout=timeout_s)
    try:
        send_headers = {"Connection": "close", **(headers or {})}
        conn.request(method, parts.path.rstrip("/") + path, body=body, headers=send_headers)
        resp = conn.getresponse()
        data = resp.read()
        return HttpReply(resp.status, {k.lower(): v for k, v in resp.getheaders()}, data)
    finally:
        conn.close()


def _header(headers: Mapping[str, str], name: str) -> str | None:
    wanted = name.lower()
    for key, value in headers.items():
        if key.lower() == wanted:
            return value.strip()
    return None


def _non_negative_int(text: str | None) -> int | None:
    # Dart _nonNegativeInt 와 같은 규칙: 십진 숫자만, 19자리 초과(int64 넘침)는 무효.
    if text is None or not re.fullmatch(r"[0-9]+", text) or len(text) > 19:
        return None
    value = int(text)
    return None if value > _INT64_MAX else value


def parse_capture_headers(headers: Mapping[str, str]) -> dict | None:
    """Dart parseClipHeaders 의 거울. 계약 위반이면 None — 기본값으로 채우지 않는다."""
    seq = _non_negative_int(_header(headers, "X-Frame-Seq"))
    capture = _non_negative_int(_header(headers, "X-Capture-Uptime-Us"))
    response = _non_negative_int(_header(headers, "X-Response-Uptime-Us"))
    boot_id = _header(headers, "X-Boot-Id")
    if seq is None or capture is None or response is None or not boot_id:
        return None
    if response < capture:
        return None
    return {
        "frame_seq": seq,
        "capture_uptime_us": capture,
        "response_uptime_us": response,
        "boot_id": boot_id,
        "firmware_version": _header(headers, "X-Firmware-Version") or None,
        "camera_sensor": _header(headers, "X-Camera-Sensor") or None,
    }


def detect_target(base_url: str, timeout_s: float = 3.0) -> str:
    """'SIM' 이면 시뮬레이터(GET /__sim/state 가 simulator=true). 아니면 'board'. 정보용일 뿐 검사가 아니다."""
    try:
        reply = fetch(base_url, "GET", "/__sim/state", timeout_s=timeout_s)
    except (OSError, ValueError):
        return "board"
    payload = reply.json() or {}
    return "SIM" if reply.status == 200 and payload.get("simulator") is True else "board"


_SECRET_WORDS = frozenset({"ssid", "password", "passwd", "psk", "secret", "token"})


def _looks_like_secret_key(key: str) -> bool:
    """camelCase/snake_case 를 단어로 쪼개 비교한다 — 부분 문자열로 보면 정당한 rssiDbm 이 'ssid' 에 걸린다."""
    words = re.findall(r"[A-Z]?[a-z]+|[A-Z]+(?![a-z])|\d+", key)
    return any(w.lower() in _SECRET_WORDS for w in words)


@dataclass
class CheckResult:
    name: str
    ok: bool
    detail: str = ""


def run_checks(base_url: str, token: str, *, origin: str = DEFAULT_ORIGIN, timeout_s: float = 3.0) -> list[CheckResult]:
    results: list[CheckResult] = []

    def add(name: str, ok: bool, detail: str = "") -> None:
        results.append(CheckResult(name, bool(ok), "" if ok else detail))

    def req(method: str, path: str, headers: Mapping[str, str] | None = None) -> HttpReply:
        # 연결 실패를 예외로 끝내지 않고 status 0 응답으로 바꿔 각 검사가 이유와 함께 FAIL 하게 한다.
        try:
            return fetch(base_url, method, path, headers=headers, timeout_s=timeout_s)
        except OSError as e:
            return HttpReply(0, error=f"연결 불가: {e!r}")

    def summary(r: HttpReply) -> str:
        return r.error or f"status={r.status} content-type={r.headers.get('content-type')!r} body={r.body[:80]!r}"

    auth = {TOKEN_HEADER: token}

    # ── 인증 ──
    no_token = req("GET", "/capture")
    add(
        "토큰 없음 → 401 missing_device_token",
        no_token.status == 401 and no_token.media_type() == "application/json"
        and (no_token.json() or {}).get("error") == "missing_device_token",
        summary(no_token),
    )
    if no_token.error:
        return results  # 연결이 안 되면 나머지는 같은 이유로 실패한다 — 한 번만 보고한다
    bad_token = req("GET", "/capture", {TOKEN_HEADER: token + "x"})
    add(
        "토큰 불일치 → 403 invalid_device_token",
        bad_token.status == 403 and bad_token.media_type() == "application/json"
        and (bad_token.json() or {}).get("error") == "invalid_device_token",
        summary(bad_token),
    )
    add(
        "401/403 에도 Cache-Control no-store",
        "no-store" in no_token.headers.get("cache-control", "") and "no-store" in bad_token.headers.get("cache-control", ""),
        f"401={no_token.headers.get('cache-control')!r} 403={bad_token.headers.get('cache-control')!r}",
    )

    # ── /health ──
    health = req("GET", "/health", auth)
    health_json = health.json()
    add(
        "/health 200 application/json",
        health.status == 200 and health.media_type() == "application/json" and health_json is not None,
        summary(health),
    )
    health_json = health_json or {}
    add(
        f"/health schemaVersion == {SCHEMA_VERSION}",
        health_json.get("schemaVersion") == SCHEMA_VERSION,
        repr(health_json.get("schemaVersion")),
    )
    missing_fields = [k for k in HEALTH_FIELDS if k not in health_json]
    add(f"/health 필수 필드 {len(HEALTH_FIELDS)}개", not missing_fields, f"누락: {missing_fields}")
    boot_id = health_json.get("bootId")
    add(
        "/health bootId 8자리 소문자 hex",
        isinstance(boot_id, str) and re.fullmatch(r"[0-9a-f]{8}", boot_id) is not None,
        repr(boot_id),
    )
    leaky = [k for k in health_json if _looks_like_secret_key(k)]
    add("/health 에 ssid·password 키 없음", not leaky, str(leaky))

    # ── /capture ──
    cap1 = req("GET", "/capture", auth)
    add("/capture 200 image/jpeg", cap1.status == 200 and cap1.media_type() == "image/jpeg", summary(cap1))
    missing_headers = [h for h in CAPTURE_HEADERS if h.lower() not in cap1.headers]
    add("/capture 헤더 6개 존재", not missing_headers, f"누락: {missing_headers}")
    int_values = {h: cap1.headers.get(h.lower(), "").strip() for h in INT_HEADERS}
    add(
        "정수 헤더는 부호 없는 십진수(X-Frame-Seq·X-Capture-Uptime-Us·X-Response-Uptime-Us)",
        all(re.fullmatch(r"[0-9]+", v) for v in int_values.values()),
        str(int_values),
    )
    str_values = {h: cap1.headers.get(h.lower(), "").strip() for h in STR_HEADERS}
    add(
        "문자열 헤더 비어 있지 않음(X-Boot-Id·X-Firmware-Version·X-Camera-Sensor)",
        all(str_values.values()),
        str(str_values),
    )
    meta1 = parse_capture_headers(cap1.headers)
    add(
        "responseUptime >= captureUptime",
        meta1 is not None and meta1["response_uptime_us"] >= meta1["capture_uptime_us"],
        str(int_values),
    )
    add("본문 JPEG 매직 FF D8", len(cap1.body) >= 2 and cap1.body[:2] == JPEG_MAGIC, f"앞 4바이트={cap1.body[:4]!r}")
    add("Cache-Control no-store", "no-store" in cap1.headers.get("cache-control", ""), repr(cap1.headers.get("cache-control")))
    add(
        "X-Boot-Id == /health bootId",
        meta1 is not None and meta1["boot_id"] == boot_id,
        f"header={str_values.get('X-Boot-Id')!r} health={boot_id!r}",
    )

    cap2 = req("GET", "/capture", auth)
    meta2 = parse_capture_headers(cap2.headers)
    add(
        "연속 두 capture: frameSeq 엄격 증가",
        meta1 is not None and meta2 is not None and meta2["frame_seq"] > meta1["frame_seq"],
        f"{meta1 and meta1['frame_seq']} → {meta2 and meta2['frame_seq']}",
    )
    add(
        "연속 두 capture: captureUptime 엄격 증가",
        meta1 is not None and meta2 is not None and meta2["capture_uptime_us"] > meta1["capture_uptime_us"],
        f"{meta1 and meta1['capture_uptime_us']} → {meta2 and meta2['capture_uptime_us']}",
    )

    jpg = req("GET", "/jpg", auth)
    add(
        "/jpg 별칭이 /capture 와 같은 계약",
        jpg.status == 200 and jpg.media_type() == "image/jpeg" and parse_capture_headers(jpg.headers) is not None
        and jpg.body[:2] == JPEG_MAGIC,
        summary(jpg),
    )

    # ── CORS ──
    cors = req("GET", "/capture", {**auth, "Origin": origin})
    exposed = [s.strip() for s in cors.headers.get("access-control-expose-headers", "").split(",") if s.strip()]
    add(
        "허용 origin GET /capture → Allow-Origin 에코 + Expose-Headers 6개",
        cors.status == 200 and cors.headers.get("access-control-allow-origin") == origin
        and all(h in exposed for h in CAPTURE_HEADERS),
        f"allow-origin={cors.headers.get('access-control-allow-origin')!r} exposed={exposed}",
    )
    preflight = req("OPTIONS", "/capture", {"Origin": origin})
    allow_headers = [s.strip().lower() for s in preflight.headers.get("access-control-allow-headers", "").split(",")]
    add(
        f"OPTIONS preflight(허용 origin) → 204, Allow-Headers ∋ {TOKEN_HEADER}",
        preflight.status == 204 and preflight.headers.get("access-control-allow-origin") == origin
        and TOKEN_HEADER.lower() in allow_headers,
        f"status={preflight.status} allow-origin={preflight.headers.get('access-control-allow-origin')!r} "
        f"allow-headers={preflight.headers.get('access-control-allow-headers')!r}",
    )
    denied = req("OPTIONS", "/capture", {"Origin": DISALLOWED_ORIGIN})
    cors_keys = [k for k in denied.headers if k.startswith("access-control-")]
    add(
        "OPTIONS preflight(비허용 origin) → 403, CORS 헤더 없음",
        denied.status == 403 and not cors_keys,
        f"status={denied.status} cors={cors_keys}",
    )

    # ── 닫힌 경로 ──
    root = req("GET", "/")
    add(
        "조준 페이지 GET / → 404 inspect_page_disabled",
        root.status == 404 and (root.json() or {}).get("error") == "inspect_page_disabled",
        summary(root),
    )
    nope = req("GET", "/nope")
    add("미지 경로 → 404 not_found", nope.status == 404 and (nope.json() or {}).get("error") == "not_found", summary(nope))
    return results


def print_results(results: Sequence[CheckResult]) -> None:
    for r in results:
        print(f"[PASS] {r.name}" if r.ok else f"[FAIL] {r.name} — {r.detail}")


def _resolve_token(cli_token: str | None) -> str:
    if cli_token:
        return cli_token
    env_token = (os.environ.get(TOKEN_ENV) or "").strip()
    if env_token:
        return env_token
    try:
        file_token = TOKEN_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        file_token = ""
    if file_token:
        return file_token
    raise ValueError("기기 토큰이 없다: --token, CLIP_DEVICE_TOKEN, ~/.clipsense/device_token 중 하나가 필요하다")


def main(argv: Sequence[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="클립 카메라 HTTP 계약 블랙박스 검사(시뮬레이터·보드 공용)")
    ap.add_argument("base_url", help="http://host[:port][/prefix] 또는 host:port")
    ap.add_argument("--token", help="기기 토큰. 명령줄은 ps 에 보이므로 CLIP_DEVICE_TOKEN 환경변수 권장")
    ap.add_argument("--origin", default=DEFAULT_ORIGIN, help="CORS 검사에 쓸 허용 origin")
    ap.add_argument("--timeout", type=float, default=3.0, help="요청당 제한 시간(초)")
    args = ap.parse_args(argv)
    try:
        token = _resolve_token(args.token)
    except ValueError as e:
        print(f"오류: {e}", file=sys.stderr)
        return 2
    base = normalize_base_url(args.base_url)

    print(f"=== 클립 카메라 계약 검사: {base} ===")
    target = detect_target(base, args.timeout)
    if target == "SIM":
        print("[INFO] 대상: SIM(시뮬레이터 — 보드 동작을 증명하지 않음)")
    else:
        print("[INFO] 대상: 보드 또는 미지 서버")
    results = run_checks(base, token, origin=args.origin, timeout_s=args.timeout)
    print_results(results)
    ok = sum(1 for r in results if r.ok)
    print(f"계약 검사 {ok}/{len(results)} PASS · 대상: {'SIM' if target == 'SIM' else 'board'}")
    return 0 if ok == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
