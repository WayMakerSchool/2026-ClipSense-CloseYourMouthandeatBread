"""서울 T-Data 실시간 보행신호 API 번역기.

책임: (교차로 레코드, 방위) → SignalReading(source=API). 판단하지 않는다.
정직성: 모르는 상태값·stale·None·오류는 전부 UNKNOWN (GREEN 추측 금지).

실측 사실(2026-07-13 실제 호출):
- 응답은 레코드 배열(header/body 래핑 없음)
- 보행신호 상태: {방위}PdsgStatNm (방위 접두 nt/et/st/wt/ne/se/sw/nw)
- 보행신호 잔여: {방위}PdsgRmdrCs, 단위 1/10초 (241 = 24.1초)
- 전송시각: trsmUtcTime (epoch ms)
"""

from __future__ import annotations

import json
import math
import urllib.parse
import urllib.request

from signals import (SignalReading, GREEN, RED, CLEARANCE, UNKNOWN, SRC_API)

# API 상태 enum(SAE J2735) → 우리 색. 화이트리스트: 여기 없는 값은 UNKNOWN.
STATUS_MAP = {
    "protected-Movement-Allowed": GREEN,
    "permissive-Movement-Allowed": GREEN,
    "protected-clearance": CLEARANCE,
    "permissive-clearance": CLEARANCE,
    "stop-And-Remain": RED,
}


def _to_remain_sec(raw_cs) -> float | None:
    """1/10초 단위 잔여값 → 초. 파싱 불가/비정상 값이면 None."""
    if raw_cs is None or raw_cs == "":
        return None
    try:
        remain_sec = float(raw_cs) / 10.0
    except (TypeError, ValueError):
        return None
    # 외부 API의 NaN/Infinity/음수는 "충분한 잔여시간"의 근거가 될 수 없다.
    if not math.isfinite(remain_sec) or remain_sec < 0:
        return None
    return round(remain_sec, 1)


def parse_reading(records: list[dict], direction: str, now_ms: int,
                  stale_ms: int = 2000, itst_id=None) -> SignalReading:
    """레코드 배열 + 방위 접두사(예 'ne') → SignalReading(source=API).

    itst_id가 주어지면 records 중 itstId가 일치하는 첫 레코드만 사용한다
    (numOfRows>1일 때 다른 교차로 신호를 잘못 읽는 것을 방지).
    일치하는 레코드가 없으면 UNKNOWN. itst_id가 None이면 기존처럼 records[0]
    (하위호환).

    미지 상태/stale/신호 없음/빈 배열/itstId 불일치는 전부 color=UNKNOWN으로
    안전하게 실패.
    """
    if not records:
        return SignalReading(UNKNOWN, None, SRC_API, fresh_ms=0)

    if itst_id is None:
        rec = records[0]
    else:
        rec = next((r for r in records if str(r.get("itstId")) == str(itst_id)),
                   None)
        if rec is None:
            return SignalReading(UNKNOWN, None, SRC_API, fresh_ms=0)

    stat = rec.get(f"{direction}PdsgStatNm")
    rmdr = rec.get(f"{direction}PdsgRmdrCs")

    # 신선도 — 전송시각이 없거나 파싱 불가면 신선도를 알 수 없다.
    # 정직성 원칙: 모르면 UNKNOWN (신선하다고 거짓 가정하지 않는다). raw는 보존.
    trsm = rec.get("trsmUtcTime")
    raw = str(stat) if stat is not None else None
    if trsm is None:
        return SignalReading(UNKNOWN, None, SRC_API, fresh_ms=0, raw=raw)
    try:
        fresh_ms = int(now_ms - float(trsm))
    except (TypeError, ValueError, OverflowError):
        return SignalReading(UNKNOWN, None, SRC_API, fresh_ms=0, raw=raw)

    # 미래 시각(시계 오차 등)은 신선도를 신뢰할 수 없다 → UNKNOWN (정직성).
    # 작은 음수는 네트워크 지연/시계 미세오차로 허용, 큰 음수만 거부.
    if fresh_ms < -stale_ms:
        return SignalReading(UNKNOWN, None, SRC_API, fresh_ms=0, raw=raw)

    # stale → UNKNOWN (원문 보존)
    if fresh_ms > stale_ms:
        return SignalReading(UNKNOWN, None, SRC_API, fresh_ms=fresh_ms, raw=raw)

    color = STATUS_MAP.get(stat, UNKNOWN)
    remain = _to_remain_sec(rmdr) if color != UNKNOWN else None
    return SignalReading(color, remain, SRC_API, fresh_ms=max(0, fresh_ms), raw=raw)


DEFAULT_BASE_URL = ("https://t-data.seoul.go.kr/apig/apiman-gateway/tapi/"
                    "v2xSignalPhaseTimingFusionInformation/1.0")


def _default_opener(url: str, timeout: float):
    req = urllib.request.Request(url, headers={"User-Agent": "clipsense/1.0"})
    return urllib.request.urlopen(req, timeout=timeout)


def fetch_reading(itst_id: str, direction: str, api_key: str, *,
                  now_ms: int, base_url: str = DEFAULT_BASE_URL,
                  timeout: float = 5.0, opener=None) -> SignalReading:
    """서울 T-Data를 호출해 해당 교차로·방위 보행신호를 SignalReading으로.

    네트워크·HTTP·JSON 오류는 전부 삼켜 UNKNOWN을 반환한다 (앱을 죽이지 않음).
    opener(url, timeout)를 주입하면 네트워크 없이 테스트 가능.
    api_key는 호출자가 환경변수/설정에서 읽어 넘긴다 (여기서 하드코딩 안 함).
    """
    opener = opener or _default_opener
    params = urllib.parse.urlencode({
        "apiKey": api_key, "type": "json", "itstId": itst_id, "numOfRows": "10",
    })
    url = f"{base_url}?{params}"
    try:
        with opener(url, timeout) as resp:
            body = resp.read()
        records = json.loads(body)
        if not isinstance(records, list):
            return SignalReading(UNKNOWN, None, SRC_API, fresh_ms=0)
        return parse_reading(records, direction, now_ms=now_ms, itst_id=itst_id)
    except Exception:
        # 네트워크/HTTP/JSON/기타 — 정직하게 UNKNOWN (조용히 실패)
        return SignalReading(UNKNOWN, None, SRC_API, fresh_ms=0)
