"""이중 판단 엔진: API + 비전 → WALK / WAIT / UNKNOWN.

안전 핵심 (브리프 Fail-Safe):
- WALK는 두 소스가 모두 GREEN + 잔여시간 충분 + 둘 다 fresh일 때만.
- 하나라도 불일치/부족/stale → WAIT.
- 두 소스 모두 UNKNOWN 또는 입력 없음 → UNKNOWN_DECISION.
- 단일 소스만 가용할 때는 allow_single_source로 정책 제어(서울 밖 카메라 단독).
"""

from signals import SignalReading, GREEN, UNKNOWN

WALK = "WALK"
WAIT = "WAIT"
UNKNOWN_DECISION = "UNKNOWN"


def _usable(r: SignalReading | None, stale_ms: int) -> bool:
    """이 판정을 판단에 쓸 수 있는가 (존재 + UNKNOWN 아님 + fresh)."""
    return r is not None and r.color != UNKNOWN and r.fresh_ms <= stale_ms


def _remain_ok(readings: list[SignalReading], need_sec: float) -> bool:
    """가용한 잔여시간 중 가장 짧은 것이 need_sec 이상인가.
    잔여 정보가 하나도 없으면 보수적으로 False (충분함을 증명 못 하므로)."""
    remains = [r.remain_sec for r in readings if r.remain_sec is not None]
    if not remains:
        return False
    return min(remains) >= need_sec


def decide(api: SignalReading | None, vision: SignalReading | None, *,
           need_sec: float = 7.0, stale_ms: int = 2000,
           allow_single_source: bool = True) -> str:
    """최종 보행 결정. 기본은 AND(둘 다 초록)일 때만 WALK."""
    api_ok = _usable(api, stale_ms)
    vis_ok = _usable(vision, stale_ms)

    # 둘 다 못 씀 → 확인 불가
    if not api_ok and not vis_ok:
        return UNKNOWN_DECISION

    # 두 소스 다 가용: AND 규칙
    if api_ok and vis_ok:
        both_green = api.color == GREEN and vision.color == GREEN
        if both_green and _remain_ok([api, vision], need_sec):
            return WALK
        return WAIT

    # 단일 소스만 가용
    if not allow_single_source:
        return WAIT
    single = api if api_ok else vision
    if single.color == GREEN and _remain_ok([single], need_sec):
        return WALK
    return WAIT
