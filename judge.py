"""이중 판단 엔진: API + 비전 → WALK / WAIT / UNKNOWN.

안전 핵심 (브리프 Fail-Safe):
- WALK는 두 소스가 모두 GREEN + 잔여시간 충분 + 둘 다 fresh일 때만.
- 하나라도 불일치/부족/stale → WAIT.
- 두 소스 모두 UNKNOWN 또는 입력 없음 → UNKNOWN_DECISION.
- 기본(allow_single_source=False)은 엄격: 두 소스 모두 GREEN일 때만
  WALK. 한쪽이 UNKNOWN/stale/없음이라 단일 소스만 가용하면 무조건 WAIT
  — 카메라가 조용히 실패해도 API 단독으로 WALK가 나가지 않는다.
- 서울 밖 카메라 단독 운용처럼 단일 소스 WALK가 불가피한 배치는,
  호출자가 명시적으로 allow_single_source=True를 넘겨 opt-in한다.
"""

from __future__ import annotations

import math

from signals import SignalReading, GREEN, UNKNOWN

WALK = "WALK"
WAIT = "WAIT"
UNKNOWN_DECISION = "UNKNOWN"


def _usable(r: SignalReading | None, stale_ms: int) -> bool:
    """이 판정을 판단에 쓸 수 있는가 (존재 + UNKNOWN 아님 + fresh)."""
    if r is None or r.color == UNKNOWN:
        return False
    try:
        return math.isfinite(r.fresh_ms) and 0 <= r.fresh_ms <= stale_ms
    except TypeError:
        return False


def _remain_ok(readings: list[SignalReading], need_sec: float) -> bool:
    """가용한 잔여시간 중 가장 짧은 것이 need_sec 이상인가.
    잔여 정보가 하나도 없으면 보수적으로 False (충분함을 증명 못 하므로)."""
    remains = [r.remain_sec for r in readings if r.remain_sec is not None]
    if not remains:
        return False
    # NaN은 비교 순서에 따라 min()에서 무시될 수 있고, Infinity는 그대로
    # 통과한다. 외부 데이터가 비정상이면 WALK 근거로 쓰지 않는다.
    try:
        if any(not math.isfinite(value) or value < 0 for value in remains):
            return False
    except TypeError:
        return False
    return min(remains) >= need_sec


def decide(api: SignalReading | None, vision: SignalReading | None, *,
           need_sec: float = 7.0, stale_ms: int = 2000,
           allow_single_source: bool = False) -> str:
    """최종 보행 결정.

    기본은 엄격 — 두 소스(API + 비전) 모두 GREEN + 잔여시간 충분 + 둘 다
    fresh일 때만 WALK. 한쪽이 UNKNOWN이거나 stale이거나 아예 입력이
    없어서 단일 소스만 가용한 경우, 기본값(allow_single_source=False)에서는
    무조건 WAIT — API만 초록이라고 카메라가 조용히 실패한 채로 WALK를
    내보내지 않는다.

    서울 밖처럼 카메라(비전) 단독 운용이 불가피한 배치에서만, 호출자가
    명시적으로 allow_single_source=True를 넘겨 단일 소스 WALK를 opt-in
    한다. 두 소스 모두 UNKNOWN이거나 입력 자체가 없으면 항상
    UNKNOWN_DECISION.
    """
    api_ok = _usable(api, stale_ms)
    vis_ok = _usable(vision, stale_ms)

    # 둘 다 못 씀 → 확인 불가
    if not api_ok and not vis_ok:
        return UNKNOWN_DECISION

    # 두 소스 다 가용: AND 규칙
    if api_ok and vis_ok:
        both_green = api.color == GREEN and vision.color == GREEN
        # 잔여시간의 기준은 API. 카메라 7세그 판독은 오독 가능성이 있어
        # 단독 근거로 쓰지 않고, API보다 짧을 때만 WAIT로 작용한다(거부권).
        if (both_green and api.remain_sec is not None
                and _remain_ok([api, vision], need_sec)):
            return WALK
        return WAIT

    # 단일 소스만 가용
    if not allow_single_source:
        return WAIT
    single = api if api_ok else vision
    if single.color == GREEN and _remain_ok([single], need_sec):
        return WALK
    return WAIT
