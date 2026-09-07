"""이중 판단 엔진: API + 비전 → WALK / WAIT / UNKNOWN (+ 근거).

안전 핵심 (브리프 Fail-Safe):
- WALK는 두 소스가 모두 GREEN + 잔여시간 충분 + 둘 다 fresh일 때만.
- 하나라도 불일치/부족/stale → WAIT.
- 잔여시간 기준은 API. 카메라 숫자(7세그)는 거부권만 — API 잔여가 없으면
  카메라 숫자가 충분해도 WAIT, 카메라 숫자가 더 짧으면 WAIT.
- 두 소스 모두 UNKNOWN 또는 입력 없음 → UNKNOWN_DECISION.
- 기본(allow_single_source=False)은 엄격: 두 소스 모두 GREEN일 때만
  WALK. 한쪽이 UNKNOWN/stale/없음이라 단일 소스만 가용하면 무조건 WAIT
  — 카메라가 조용히 실패해도 API 단독으로 WALK가 나가지 않는다.
- 서울 밖 카메라 단독 운용처럼 단일 소스 WALK가 불가피한 배치는,
  호출자가 명시적으로 allow_single_source=True를 넘겨 opt-in한다.

근거 이름은 Dart app/lib/signals/judge.dart DecisionReason 과 같다(snake_case,
선언 순서도 같다) — 골든 app/test/fixtures/judge_cases.json 이 두 구현을 묶는다
(scripts/test_judge_golden.py ↔ app/test/judge_golden_test.dart). evaluate() 는
Dart evaluate() 의 분기 순서를 그대로 옮긴 것이다. 보고서가 "Python 은 Dart 앱의
미러"라고 말하므로, 여기가 뒤처지면 골든이 두 쪽 CI 를 함께 깨뜨린다.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from signals import SignalReading, GREEN, CLEARANCE, UNKNOWN

WALK = "WALK"
WAIT = "WAIT"
UNKNOWN_DECISION = "UNKNOWN"

# 판정 근거 — 값은 Dart DecisionReason 이름의 snake_case. 화면·음성이 "왜 기다려야
# 하는지" 설명할 수 있게 결정과 함께 보존한다.
REASON_READY = "ready"
REASON_SOURCES_UNAVAILABLE = "sources_unavailable"
REASON_CAMERA_UNAVAILABLE = "camera_unavailable"
REASON_CAMERA_DENIED = "camera_denied"
REASON_CLIP_UNREACHABLE = "clip_unreachable"
REASON_CLIP_TOKEN_REJECTED = "clip_token_rejected"
REASON_CAMERA_STARTING = "camera_starting"
REASON_CAMERA_STALLED = "camera_stalled"
REASON_API_UNAVAILABLE = "api_unavailable"
REASON_API_KEY_MISSING = "api_key_missing"
REASON_RED_SIGNAL = "red_signal"
REASON_CLEARANCE = "clearance"
REASON_CONFLICT = "conflict"
REASON_REMAINING_UNAVAILABLE = "remaining_unavailable"
REASON_REMAINING_INSUFFICIENT = "remaining_insufficient"

# Dart enum 선언 순서 그대로. 골든이 이 순서를 검사한다.
ALL_REASONS: tuple[str, ...] = (
    REASON_READY,
    REASON_SOURCES_UNAVAILABLE,
    REASON_CAMERA_UNAVAILABLE,
    REASON_CAMERA_DENIED,
    REASON_CLIP_UNREACHABLE,
    REASON_CLIP_TOKEN_REJECTED,
    REASON_CAMERA_STARTING,
    REASON_CAMERA_STALLED,
    REASON_API_UNAVAILABLE,
    REASON_API_KEY_MISSING,
    REASON_RED_SIGNAL,
    REASON_CLEARANCE,
    REASON_CONFLICT,
    REASON_REMAINING_UNAVAILABLE,
    REASON_REMAINING_INSUFFICIENT,
)

# evaluate() 는 이 여섯을 절대 내지 않는다 — 판독값만 보므로 권한·연결·토큰·준비 중·
# 정지·API 키 여부를 알 수 없다. Dart 에서도 GuidanceController 가 VisionSource
# 상태를 보고 camera_unavailable 을 이 값들로 바꿔 넣는다(결정은 wait 그대로).
# 여기 두는 이유는 화면·음성 문구 어휘를 Dart 와 1:1 로 맞추기 위해서다.
CONTROLLER_ONLY_REASONS: frozenset[str] = frozenset({
    REASON_CAMERA_DENIED,
    REASON_CLIP_UNREACHABLE,
    REASON_CLIP_TOKEN_REJECTED,
    REASON_CAMERA_STARTING,
    REASON_CAMERA_STALLED,
    REASON_API_KEY_MISSING,
})

# 근거의 짧은 한국어 설명 — Dart decisionReasonText 와 글자 그대로 같다.
# 끝에 마침표를 두지 않는다: 화면('기다리세요. {이유}.')과 음성('{이유}. 기다리세요')이
# 조합할 때 마침표를 붙이므로, 넣으면 ".." 가 된다.
REASON_TEXT: dict[str, str] = {
    REASON_READY: "API와 카메라가 모두 초록입니다",
    REASON_SOURCES_UNAVAILABLE: "API와 카메라 신호를 확인할 수 없습니다",
    REASON_CAMERA_UNAVAILABLE: "카메라가 신호등을 찾지 못했습니다. 신호등을 향해 주세요",
    REASON_CAMERA_DENIED: "카메라 권한이 없습니다. 설정에서 카메라를 허용해 주세요",
    REASON_CLIP_UNREACHABLE: "클립 카메라에 연결할 수 없습니다. 전원과 Wi-Fi 연결을 확인해 주세요",
    REASON_CLIP_TOKEN_REJECTED: "클립 카메라가 접속을 거부했습니다. 기기 토큰 설정을 확인해 주세요",
    REASON_CAMERA_STARTING: "카메라를 준비하는 중입니다",
    REASON_CAMERA_STALLED: "카메라 영상이 멈췄습니다. 화면을 두 번 눌러 다시 시작해 주세요",
    REASON_API_UNAVAILABLE: "신호 정보를 아직 받지 못했습니다",
    REASON_API_KEY_MISSING: "T-Data API 키가 설정되지 않았습니다",
    REASON_RED_SIGNAL: "빨간불입니다",
    REASON_CLEARANCE: "초록불이 곧 끝납니다",
    REASON_CONFLICT: "API와 카메라 신호가 일치하지 않습니다",
    REASON_REMAINING_UNAVAILABLE: "남은 시간을 확인할 수 없습니다",
    REASON_REMAINING_INSUFFICIENT: "안전하게 건널 시간이 부족합니다",
}


def decision_reason_text(reason: str) -> str:
    """근거의 짧은 한국어 설명. 모르는 근거는 KeyError — 프로그래밍 오류를 기본
    문구로 덮지 않는다(엉뚱한 안내가 조용히 나가면 안 된다)."""
    return REASON_TEXT[reason]


@dataclass(frozen=True)
class DecisionResult:
    """최종 결정과 근거. 불변 — 판정 뒤에 결정만 바꿔치기할 수 없다."""
    decision: str  # WALK | WAIT | UNKNOWN_DECISION
    reason: str    # ALL_REASONS 중 하나


def _usable(r: SignalReading | None, stale_ms: int) -> bool:
    """이 판정을 판단에 쓸 수 있는가 (존재 + UNKNOWN 아님 + fresh)."""
    if r is None or r.color == UNKNOWN:
        return False
    try:
        return math.isfinite(r.fresh_ms) and 0 <= r.fresh_ms <= stale_ms
    except TypeError:
        return False


def _remain_reason(readings: list[SignalReading], need_sec: float) -> str:
    """가용한 잔여시간 중 가장 짧은 것이 need_sec 이상이면 ready, 아니면 부족.
    잔여 정보가 하나도 없거나 수치가 비정상이면 보수적으로 확인 불가
    (충분함을 증명 못 하므로). Dart _remainReason 과 같은 순서."""
    remains = [r.remain_sec for r in readings if r.remain_sec is not None]
    if not remains:
        return REASON_REMAINING_UNAVAILABLE
    try:
        # need_sec 가 음수·NaN·∞ 면 호출자 설정 오류다. Dart 와 같이 잔여 확인 불가로
        # 보고 WALK 를 내지 않는다(이전 구현은 음수 need_sec 에 30 >= -1 로 WALK 를
        # 냈다 — Dart 와의 유일한 갈림. NaN/∞ need_sec 는 비교가 False 라 이미 WAIT
        # 였지만 근거 없이 WAIT 였다).
        if not math.isfinite(need_sec) or need_sec < 0:
            return REASON_REMAINING_UNAVAILABLE
        # NaN은 비교 순서에 따라 min()에서 무시될 수 있고, Infinity는 그대로
        # 통과한다. 외부 데이터가 비정상이면 WALK 근거로 쓰지 않는다.
        if any(not math.isfinite(value) or value < 0 for value in remains):
            return REASON_REMAINING_UNAVAILABLE
        if min(remains) >= need_sec:
            return REASON_READY
        return REASON_REMAINING_INSUFFICIENT
    except TypeError:
        # 숫자가 아닌 값(어댑터 오류) — 확인 불가
        return REASON_REMAINING_UNAVAILABLE


def evaluate(api: SignalReading | None, vision: SignalReading | None, *,
             need_sec: float = 7.0, stale_ms: int = 2000,
             allow_single_source: bool = False) -> DecisionResult:
    """최종 보행 결정과 근거. 기본은 엄격 — 두 소스 모두 GREEN일 때만 WALK.

    분기 순서는 Dart evaluate() 와 같다: 둘 다 불가 → 둘 다 가용(AND) → 단일
    소스(엄격이면 WAIT + 어느 쪽이 빠졌는지) → opt-in 단일 소스 판정.
    """
    api_ok = _usable(api, stale_ms)
    vis_ok = _usable(vision, stale_ms)

    # 둘 다 못 씀 → 확인 불가
    if not api_ok and not vis_ok:
        return DecisionResult(UNKNOWN_DECISION, REASON_SOURCES_UNAVAILABLE)

    # 두 소스 다 가용: AND 규칙
    if api_ok and vis_ok:
        if api.color == GREEN and vision.color == GREEN:
            # 잔여시간의 기준은 API. 카메라 7세그 판독은 오독 가능성이 있어
            # 단독 근거로 쓰지 않고, API보다 짧을 때만 WAIT로 작용한다(거부권).
            if api.remain_sec is None:
                return DecisionResult(WAIT, REASON_REMAINING_UNAVAILABLE)
            reason = _remain_reason([api, vision], need_sec)
            return DecisionResult(WALK if reason == REASON_READY else WAIT, reason)
        # 불일치가 점멸보다 먼저 — "곧 끝난다"보다 "두 소스가 다르다"가 더 중요한 정보다.
        if api.color != vision.color:
            return DecisionResult(WAIT, REASON_CONFLICT)
        if api.color == CLEARANCE:
            return DecisionResult(WAIT, REASON_CLEARANCE)
        return DecisionResult(WAIT, REASON_RED_SIGNAL)

    # 단일 소스만 가용 → 엄격 모드면 WAIT. 어느 쪽이 빠졌는지를 이유에 남긴다
    # — 카메라 미인식이면 "신호등을 향하라", API 미응답이면 "기다리라"로
    # 사용자가 취할 행동이 다르다(결정은 둘 다 WAIT, 안전 정책 불변).
    if not allow_single_source:
        return DecisionResult(
            WAIT,
            REASON_CAMERA_UNAVAILABLE if api_ok else REASON_API_UNAVAILABLE,
        )
    single = api if api_ok else vision
    if single.color == GREEN:
        reason = _remain_reason([single], need_sec)
        return DecisionResult(WALK if reason == REASON_READY else WAIT, reason)
    if single.color == CLEARANCE:
        return DecisionResult(WAIT, REASON_CLEARANCE)
    return DecisionResult(WAIT, REASON_RED_SIGNAL)


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

    기존 호출자용 축약 API — 근거가 필요하면 evaluate() 를 쓴다.
    """
    return evaluate(api, vision, need_sec=need_sec, stale_ms=stale_ms,
                    allow_single_source=allow_single_source).decision
