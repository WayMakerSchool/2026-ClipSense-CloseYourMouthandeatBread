"""기존 카메라 검출기(detector.py) 상태 → 표준 SignalReading 번역.

검출 알고리즘은 바꾸지 않는다. 상태 문자열 표현만 표준화한다.
GREEN_BLINK(초록 점멸)는 CLEARANCE로 매핑한다.
"""

from __future__ import annotations

from signals import (SignalReading, GREEN, RED, CLEARANCE, UNKNOWN, SRC_VISION)
from detector import (STATE_RED, STATE_GREEN, STATE_GREEN_BLINK, STATE_UNKNOWN)

_STATE_MAP = {
    STATE_RED: RED,
    STATE_GREEN: GREEN,
    STATE_GREEN_BLINK: CLEARANCE,
    STATE_UNKNOWN: UNKNOWN,
}


def to_reading(state: str, remain_sec: float | None = None,
               fresh_ms: int = 0) -> SignalReading:
    """detector 상태 → SignalReading(source=VISION). 미지 상태는 UNKNOWN."""
    color = _STATE_MAP.get(state, UNKNOWN)
    return SignalReading(color, remain_sec, SRC_VISION, fresh_ms=fresh_ms)
