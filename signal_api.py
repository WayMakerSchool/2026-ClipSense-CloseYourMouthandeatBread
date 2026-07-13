"""서울 T-Data 실시간 보행신호 API 번역기.

책임: (교차로 레코드, 방위) → SignalReading(source=API). 판단하지 않는다.
정직성: 모르는 상태값·stale·None·오류는 전부 UNKNOWN (GREEN 추측 금지).

실측 사실(2026-07-13 실제 호출):
- 응답은 레코드 배열(header/body 래핑 없음)
- 보행신호 상태: {방위}PdsgStatNm (방위 접두 nt/et/st/wt/ne/se/sw/nw)
- 보행신호 잔여: {방위}PdsgRmdrCs, 단위 1/10초 (241 = 24.1초)
- 전송시각: trsmUtcTime (epoch ms)
"""

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
    """1/10초 단위 잔여값 → 초. 파싱 불가/None이면 None."""
    if raw_cs is None or raw_cs == "":
        return None
    try:
        return round(float(raw_cs) / 10.0, 1)
    except (TypeError, ValueError):
        return None


def parse_reading(records: list[dict], direction: str, now_ms: int,
                  stale_ms: int = 2000) -> SignalReading:
    """레코드 배열 + 방위 접두사(예 'ne') → SignalReading(source=API).

    미지 상태/stale/신호 없음/빈 배열은 전부 color=UNKNOWN으로 안전하게 실패.
    """
    if not records:
        return SignalReading(UNKNOWN, None, SRC_API, fresh_ms=0)

    rec = records[0]
    stat = rec.get(f"{direction}PdsgStatNm")
    rmdr = rec.get(f"{direction}PdsgRmdrCs")

    # 신선도
    trsm = rec.get("trsmUtcTime")
    try:
        fresh_ms = int(now_ms - float(trsm)) if trsm is not None else 0
    except (TypeError, ValueError):
        fresh_ms = 0

    # stale → UNKNOWN (원문은 보존해 디버깅 가능)
    if fresh_ms > stale_ms:
        return SignalReading(UNKNOWN, None, SRC_API, fresh_ms=fresh_ms,
                             raw=str(stat) if stat is not None else None)

    color = STATUS_MAP.get(stat, UNKNOWN)
    remain = _to_remain_sec(rmdr) if color != UNKNOWN else None
    raw = str(stat) if stat is not None else None
    return SignalReading(color, remain, SRC_API, fresh_ms=max(0, fresh_ms), raw=raw)
