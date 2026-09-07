"""judge 이중 판단 단위 테스트. WALK는 오직 AND 만족일 때만.
실행: python scripts/test_judge.py"""
import dataclasses
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from signals import SignalReading, GREEN, RED, CLEARANCE, UNKNOWN, SRC_API, SRC_VISION
from judge import (
    decide, WALK, WAIT, UNKNOWN_DECISION,
    evaluate, DecisionResult, ALL_REASONS, CONTROLLER_ONLY_REASONS, REASON_TEXT,
    decision_reason_text,
    REASON_READY, REASON_SOURCES_UNAVAILABLE, REASON_CAMERA_UNAVAILABLE,
    REASON_API_UNAVAILABLE, REASON_RED_SIGNAL, REASON_CLEARANCE, REASON_CONFLICT,
    REASON_REMAINING_UNAVAILABLE, REASON_REMAINING_INSUFFICIENT,
)

FAILURES = []


def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print(f"[{status}] {name}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(name)


def api(color, remain=30.0, fresh=100):
    return SignalReading(color, remain, SRC_API, fresh_ms=fresh)

def vis(color, remain=None, fresh=100):
    return SignalReading(color, remain, SRC_VISION, fresh_ms=fresh)


# 1) 둘 다 초록 + 잔여충분 + fresh → WALK
check("둘 다 초록 → WALK",
      decide(api(GREEN, 30), vis(GREEN)) == WALK)

# 2) 불일치는 전부 WAIT (핵심 안전 규칙)
check("API초록·비전빨강 → WAIT", decide(api(GREEN), vis(RED)) == WAIT)
check("API빨강·비전초록 → WAIT", decide(api(RED), vis(GREEN)) == WAIT)
check("API초록·비전점멸 → WAIT", decide(api(GREEN), vis(CLEARANCE)) == WAIT)
check("API점멸·비전초록 → WAIT", decide(api(CLEARANCE), vis(GREEN)) == WAIT)

# 3) 둘 다 빨강 → WAIT
check("둘 다 빨강 → WAIT", decide(api(RED), vis(RED)) == WAIT)

# 4) 잔여시간 부족 → WAIT (둘 다 초록이어도)
check("잔여 부족 → WAIT",
      decide(api(GREEN, 3.0), vis(GREEN), need_sec=7.0) == WAIT)

# 5) 잔여 정보가 아예 없으면(둘 다 None) 보수적으로 WAIT
check("잔여 정보 없음 → WAIT",
      decide(api(GREEN, None), vis(GREEN, None), need_sec=7.0) == WAIT)

# 외부/어댑터가 비정상 수치를 넘겨도 WALK로 통과하면 안 된다.
check("무한대 잔여 → WAIT",
      decide(api(GREEN, float("inf")), vis(GREEN), need_sec=7.0) == WAIT)
check("NaN 잔여가 정상값과 섞여도 → WAIT",
      decide(api(GREEN, 30), vis(GREEN, float("nan")), need_sec=7.0) == WAIT)
check("음수 잔여 → WAIT",
      decide(api(GREEN, -1), vis(GREEN), need_sec=7.0) == WAIT)

# 6) 한쪽만 stale이면 → WAIT
check("한쪽 stale → WAIT",
      decide(api(GREEN, 30, fresh=5000), vis(GREEN), stale_ms=2000) == WAIT)
check("음수 신선도 → WAIT",
      decide(api(GREEN, 30, fresh=-1), vis(GREEN), stale_ms=2000) == WAIT)

# 7) 둘 다 UNKNOWN → UNKNOWN_DECISION
check("둘 다 UNKNOWN → 확인불가",
      decide(api(UNKNOWN, None), vis(UNKNOWN, None)) == UNKNOWN_DECISION)

# 8) 단일 소스(비전만, API=None) 허용 시: 비전 초록+잔여충분 → WALK
check("비전 단독 초록 → WALK (allow)",
      decide(None, vis(GREEN, 30), allow_single_source=True) == WALK)

# 9) 단일 소스 비허용 시: 비전만 있으면 → WAIT
check("단일 소스 비허용 → WAIT",
      decide(None, vis(GREEN, 30), allow_single_source=False) == WAIT)

# 10) 단일 소스라도 빨강이면 WAIT
check("비전 단독 빨강 → WAIT",
      decide(None, vis(RED), allow_single_source=True) == WAIT)

# 11) 둘 다 None → UNKNOWN_DECISION (입력 자체가 없음)
check("둘 다 None → 확인불가",
      decide(None, None) == UNKNOWN_DECISION)

# 12) 단일 소스 초록인데 잔여 없음 → WAIT (보수)
check("단일 소스 초록·잔여없음 → WAIT",
      decide(None, vis(GREEN, None), allow_single_source=True) == WAIT)

# --- 안전 정책(사용자 결정): 기본은 엄격 — 카메라 UNKNOWN이면 API 초록이어도 WAIT ---
# (allow_single_source 기본값 False. 서울 밖 단독 운용은 호출자가 명시적으로 True를 넘김)
check("기본: 비전 UNKNOWN이면 API 초록이어도 WAIT",
      decide(api(GREEN, 30), vis(UNKNOWN, None)) == WAIT)
check("기본: API UNKNOWN이면 비전 초록이어도 WAIT",
      decide(api(UNKNOWN, None), vis(GREEN, 30)) == WAIT)
check("기본: 비전 stale이면 API 초록이어도 WAIT",
      decide(api(GREEN, 30), vis(GREEN, 30, fresh=5000)) == WAIT)
check("기본: API None이면 비전 초록이어도 WAIT",
      decide(None, vis(GREEN, 30)) == WAIT)
# 명시적 opt-in은 여전히 단일 소스 WALK 허용 (서울 밖 대비)
check("opt-in: 비전 단독 초록 → WALK (allow_single_source=True)",
      decide(None, vis(GREEN, 30), allow_single_source=True) == WALK)

# --- 잔여시간 출처 정책: API 잔여가 기준, 카메라 숫자는 거부권만 ---
# (7세그 판독은 오독 가능성이 있어 단독 근거로 쓰지 않음. 더 짧으면 WAIT로만 작용)
check("정책: API 잔여 없음이면 카메라 숫자만으로 WALK 하지 않는다",
      decide(api(GREEN, None), vis(GREEN, 20)) == WAIT)
check("정책: API 잔여 충분해도 카메라 숫자가 더 짧으면 WAIT",
      decide(api(GREEN, 20), vis(GREEN, 3)) == WAIT)
check("정책: API 잔여 충분·카메라 숫자 없음 → WALK",
      decide(api(GREEN, 20), vis(GREEN, None)) == WALK)

# --- need_sec 검증: Dart _remainReason 은 need_sec 가 비유한·음수면 잔여 확인 불가로 본다.
# 이전 Python 구현은 음수 need_sec 에 30 >= -1 로 WALK 를 냈다(Dart 와의 유일한 갈림).
# NaN/∞ need_sec 는 비교가 False 라 이미 WAIT 였다 — 근거가 생긴 것만 새롭다.
check("음수 need_sec → WAIT (이전 구현은 WALK — Dart 와 불일치였다)",
      decide(api(GREEN, 30), vis(GREEN), need_sec=-1) == WAIT)
check("NaN need_sec → WAIT", decide(api(GREEN, 30), vis(GREEN), need_sec=math.nan) == WAIT)
check("Infinity need_sec → WAIT", decide(api(GREEN, 30), vis(GREEN), need_sec=math.inf) == WAIT)

# --- evaluate(): 결정 + 근거 (근거 이름은 Dart DecisionReason 의 snake_case) ---
check("evaluate: 음수 need_sec 근거는 remaining_unavailable",
      evaluate(api(GREEN, 30), vis(GREEN), need_sec=-1)
      == DecisionResult(WAIT, REASON_REMAINING_UNAVAILABLE))
check("evaluate: 둘 다 초록·잔여 충분 → WALK + ready",
      evaluate(api(GREEN, 30), vis(GREEN)) == DecisionResult(WALK, REASON_READY))
check("evaluate: 둘 다 초록·잔여 부족 → remaining_insufficient",
      evaluate(api(GREEN, 3.0), vis(GREEN)) == DecisionResult(WAIT, REASON_REMAINING_INSUFFICIENT))
check("evaluate: 불일치 → conflict",
      evaluate(api(GREEN), vis(RED)) == DecisionResult(WAIT, REASON_CONFLICT))
check("evaluate: 둘 다 점멸 → clearance",
      evaluate(api(CLEARANCE, 3), vis(CLEARANCE)) == DecisionResult(WAIT, REASON_CLEARANCE))
check("evaluate: 둘 다 빨강 → red_signal",
      evaluate(api(RED, None), vis(RED)) == DecisionResult(WAIT, REASON_RED_SIGNAL))
check("evaluate: API 점멸·비전 빨강 → conflict (불일치가 점멸보다 먼저)",
      evaluate(api(CLEARANCE, 3), vis(RED)) == DecisionResult(WAIT, REASON_CONFLICT))
check("evaluate: API 초록·비전 UNKNOWN(엄격) → camera_unavailable",
      evaluate(api(GREEN, 30), vis(UNKNOWN)) == DecisionResult(WAIT, REASON_CAMERA_UNAVAILABLE))
check("evaluate: API None·비전 초록(엄격) → api_unavailable",
      evaluate(None, vis(GREEN, 30)) == DecisionResult(WAIT, REASON_API_UNAVAILABLE))
check("evaluate: 둘 다 None → UNKNOWN + sources_unavailable",
      evaluate(None, None) == DecisionResult(UNKNOWN_DECISION, REASON_SOURCES_UNAVAILABLE))
check("evaluate: API 잔여 None·카메라 숫자 20 → remaining_unavailable",
      evaluate(api(GREEN, None), vis(GREEN, 20)) == DecisionResult(WAIT, REASON_REMAINING_UNAVAILABLE))
check("evaluate: opt-in 비전 단독 초록 30 → WALK + ready",
      evaluate(None, vis(GREEN, 30), allow_single_source=True) == DecisionResult(WALK, REASON_READY))

# 전수 격자: decide 는 evaluate().decision 의 축약이고, evaluate 는 컨트롤러 전용 이유를
# 절대 내지 않는다(판독값만 보므로 권한·연결·토큰·준비·정지·API 키를 알 수 없다).
_readings = [None]
for _color in (GREEN, RED, CLEARANCE, UNKNOWN):
    for _remain in (None, 3.0, 30.0):
        for _fresh in (0, 5000):
            _readings.append(api(_color, _remain, fresh=_fresh))
            _readings.append(vis(_color, _remain, fresh=_fresh))
_wrapper_ok = True
_controller_only_leak = []
for _a in _readings:
    for _v in _readings:
        for _single in (False, True):
            _r = evaluate(_a, _v, allow_single_source=_single)
            if decide(_a, _v, allow_single_source=_single) != _r.decision:
                _wrapper_ok = False
            if _r.reason in CONTROLLER_ONLY_REASONS or _r.reason not in ALL_REASONS:
                _controller_only_leak.append((_a, _v, _single, _r))
check("decide 는 evaluate().decision 과 같다(전수 격자)", _wrapper_ok)
check("evaluate 는 컨트롤러 전용 이유를 절대 내지 않는다(전수 격자)",
      not _controller_only_leak, detail=str(_controller_only_leak[:3]))

check("ALL_REASONS 는 15개·중복 없음·컨트롤러 전용 6개 포함",
      len(ALL_REASONS) == 15 and len(set(ALL_REASONS)) == 15
      and len(CONTROLLER_ONLY_REASONS) == 6 and CONTROLLER_ONLY_REASONS <= set(ALL_REASONS))
check("REASON_TEXT 키 집합 = ALL_REASONS (더도 덜도 아님)",
      set(REASON_TEXT) == set(ALL_REASONS),
      detail=f"text에만 {set(REASON_TEXT) - set(ALL_REASONS)} / reasons에만 {set(ALL_REASONS) - set(REASON_TEXT)}")
check("decision_reason_text 는 모든 이유에 문구가 있고 끝에 마침표가 없다",
      all(decision_reason_text(r) and not decision_reason_text(r).endswith(".") for r in ALL_REASONS))
try:
    decision_reason_text("no_such_reason")
    _unknown_raises = False
except KeyError:
    _unknown_raises = True
check("decision_reason_text 는 모르는 이유에 KeyError(기본 문구로 덮지 않음)", _unknown_raises)
try:
    _result = evaluate(api(GREEN, 30), vis(GREEN))
    _result.decision = WAIT
    _frozen = False
except dataclasses.FrozenInstanceError:
    _frozen = True
check("DecisionResult 는 불변", _frozen)

print("=" * 50)
if FAILURES:
    print(f"FAIL {len(FAILURES)}건: {FAILURES}")
    sys.exit(1)
print("judge 단위 테스트 전부 PASS")
