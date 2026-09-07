"""judge 골든 테스트 — app/test/fixtures/judge_cases.json 을 Dart
(app/test/judge_golden_test.dart)와 함께 읽는다. Dart 가 기준: 여기서 실패하면
judge.py 가 뒤처진 것이다(골든을 Python 에 맞추지 않는다).
실행: python scripts/test_judge_golden.py"""
import inspect
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from signals import SignalReading, GREEN, RED, CLEARANCE, UNKNOWN, SRC_API, SRC_VISION
from judge import (
    evaluate, decide, WALK, WAIT, UNKNOWN_DECISION,
    ALL_REASONS, CONTROLLER_ONLY_REASONS, REASON_TEXT, decision_reason_text,
)

GOLDEN = ROOT / "app" / "test" / "fixtures" / "judge_cases.json"
GOLDEN_REL = "app/test/fixtures/judge_cases.json"
FAILURES = []


def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print(f"[{status}] {name}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(name)


def _reject(token):
    # Dart jsonDecode 는 bare NaN/Infinity 를 못 읽는다. Python 만 통과하는 골든이
    # 생기지 않게 여기서도 거부한다.
    raise ValueError(f"골든에 bare {token} — 문자열로 써야 한다(Dart jsonDecode 가 못 읽는다)")


with GOLDEN.open(encoding="utf-8") as f:
    golden = json.load(f, parse_constant=_reject)

_NON_FINITE = {"NaN": math.nan, "Infinity": math.inf, "-Infinity": -math.inf}


def _double(v):
    """골든 숫자 → float. bool 은 int 의 하위형이라 조용히 1.0 이 되므로 거부
    (Dart 의 `is num` 검사는 bool 을 던진다 — 같은 엄격함)."""
    if v is None:
        return None
    if isinstance(v, bool):
        raise ValueError(f"골든 숫자 인코딩 오류(bool): {v!r}")
    if isinstance(v, str):
        if v not in _NON_FINITE:
            raise ValueError(f"골든 숫자 인코딩 오류: {v!r}")
        return _NON_FINITE[v]
    if isinstance(v, (int, float)):
        return float(v)
    raise ValueError(f"골든 숫자 인코딩 오류: {v!r}")


def _int(v):
    """Dart `as int` 는 100.0·true 를 거부한다 — 같은 규칙."""
    if type(v) is not int:
        raise ValueError(f"골든 정수 인코딩 오류: {v!r}")
    return v


COLOR = {"green": GREEN, "red": RED, "clearance": CLEARANCE, "unknown": UNKNOWN}
DECISION = {"walk": WALK, "wait": WAIT, "unknown": UNKNOWN_DECISION}


def _reading(m, src):
    if m is None:
        return None
    # 필수 키는 [] 로 색인 — 로더가 기본값을 채우면 골든이 무엇을 검사하는지 흐려진다.
    return SignalReading(COLOR[m["color"]], _double(m["remain"]), src,
                         fresh_ms=_int(m["fresh"]))


defaults = golden["defaults"]
cases = golden["cases"]
golden_reasons = golden["reasons"]
never_emitted = set(golden["never_emitted_by_evaluate"])

# --- 어휘: 이름·순서·문구가 Dart(골든)와 1:1 ---
check("골든 스키마", golden["schema"] == "clipsense-judge-golden-v1")
check("decisions 어휘 = [WALK, WAIT, UNKNOWN_DECISION] 순서",
      [DECISION[d] for d in golden["decisions"]] == [WALK, WAIT, UNKNOWN_DECISION])
_only_golden = [r for r in golden_reasons if r not in ALL_REASONS]
_only_py = [r for r in ALL_REASONS if r not in golden_reasons]
check("reasons 어휘·순서 = ALL_REASONS",
      list(ALL_REASONS) == golden_reasons,
      detail=f"골든에만 {_only_golden} / judge.py 에만 {_only_py} / "
             f"순서 golden={golden_reasons} py={list(ALL_REASONS)} → "
             f"{GOLDEN_REL}(reasons) 과 judge.py(REASON_*·ALL_REASONS) 를 Dart 선언 순서로")
check("never_emitted_by_evaluate = CONTROLLER_ONLY_REASONS",
      never_emitted == set(CONTROLLER_ONLY_REASONS),
      detail=f"골든에만 {sorted(never_emitted - set(CONTROLLER_ONLY_REASONS))} / "
             f"judge.py 에만 {sorted(set(CONTROLLER_ONLY_REASONS) - never_emitted)}")
check("never_emitted 는 reasons 안에", never_emitted <= set(golden_reasons))
for r in golden_reasons:
    check(f"reason_text 는 decision_reason_text 와 글자 그대로 같다: {r}",
          r in REASON_TEXT and decision_reason_text(r) == golden["reason_text"][r],
          detail=f"golden={golden['reason_text'].get(r)!r} py={REASON_TEXT.get(r)!r}")
check("reason_text 키 집합 = reasons = REASON_TEXT (더도 덜도 아님)",
      set(golden["reason_text"]) == set(golden_reasons) == set(REASON_TEXT),
      detail=f"golden_text={sorted(golden['reason_text'])} reasons={sorted(golden_reasons)} "
             f"py={sorted(REASON_TEXT)}")

# --- 기본값: 골든 defaults 가 장식이 아니다. Dart 쪽은 kNeedSec/kStaleMs 와 묶고, 여기서는
# evaluate/decide 의 시그니처 기본값과 묶는다 — 정책 상수가 바뀌면 Python 이 조용히
# 7.0/2000 에 남지 못한다.
for fn in (evaluate, decide):
    params = inspect.signature(fn).parameters
    check(f"{fn.__name__} 기본값 need_sec = 골든 defaults ({defaults['need_sec']})",
          params["need_sec"].default == defaults["need_sec"],
          detail=f"py={params['need_sec'].default}")
    check(f"{fn.__name__} 기본값 stale_ms = 골든 defaults ({defaults['stale_ms']})",
          params["stale_ms"].default == _int(defaults["stale_ms"]),
          detail=f"py={params['stale_ms'].default}")
    check(f"{fn.__name__} 기본값 allow_single_source = 골든 defaults ({defaults['allow_single_source']})",
          params["allow_single_source"].default is defaults["allow_single_source"],
          detail=f"py={params['allow_single_source'].default}")


def _api(remain, fresh=100):
    return SignalReading(GREEN, remain, SRC_API, fresh_ms=fresh)


def _vis(fresh=100):
    return SignalReading(GREEN, None, SRC_VISION, fresh_ms=fresh)


_explicit_defaults = dict(need_sec=_double(defaults["need_sec"]),
                          stale_ms=_int(defaults["stale_ms"]),
                          allow_single_source=defaults["allow_single_source"])
for a, v, decision, reason in [
    (_api(7.0), _vis(), WALK, "ready"),
    (_api(6.9), _vis(), WAIT, "remaining_insufficient"),
    (_api(30), _vis(2000), WALK, "ready"),
    (_api(30), _vis(2001), WAIT, "camera_unavailable"),
    (None, _api(30), WAIT, "api_unavailable"),
]:
    implicit = evaluate(a, v)
    explicit = evaluate(a, v, **_explicit_defaults)
    check(f"인자 없는 호출 = 골든 defaults 명시 호출 (경계: api={a} vision={v})",
          implicit == explicit and (implicit.decision, implicit.reason) == (decision, reason)
          and decide(a, v) == implicit.decision,
          detail=f"implicit={implicit} explicit={explicit} want=({decision}, {reason})")

# --- 케이스 ---
check("케이스 30개 이상", len(cases) >= 30, detail=str(len(cases)))
check("케이스 이름 중복 없음", len({c["name"] for c in cases}) == len(cases))
check("never_emitted_by_evaluate 이유는 어떤 케이스 기대값에도 없다",
      all(c["expect"]["reason"] not in never_emitted for c in cases))

for c in cases:
    api = _reading(c["api"], SRC_API)
    vision = _reading(c["vision"], SRC_VISION)
    # 선택 키만 .get — 없으면 골든 defaults (Dart 와 같은 규칙).
    kwargs = dict(
        need_sec=_double(c.get("need_sec", defaults["need_sec"])),
        stale_ms=_int(c.get("stale_ms", defaults["stale_ms"])),
        allow_single_source=c.get("allow_single_source", defaults["allow_single_source"]),
    )
    exp = c["expect"]
    result = evaluate(api, vision, **kwargs)
    check(f"golden: {c['name']}",
          result.decision == DECISION[exp["decision"]] and result.reason == exp["reason"],
          detail=f"got {result} want ({DECISION[exp['decision']]}, {exp['reason']})")
    check(f"decide == evaluate.decision: {c['name']}",
          decide(api, vision, **kwargs) == result.decision)
    uses_defaults = not any(k in c for k in ("need_sec", "stale_ms", "allow_single_source"))
    if uses_defaults:
        check(f"인자 없는 호출과 같다: {c['name']}", evaluate(api, vision) == result)

# --- 전수 격자: evaluate 는 컨트롤러 전용 이유를 절대 내지 않고, 어휘 밖의 값도 내지 않는다
# (Dart judge_golden_test 의 격자와 같은 입력).
readings = [None]
for color in (GREEN, RED, CLEARANCE, UNKNOWN):
    for remain in (None, 3.0, 30.0):
        for fresh in (0, 5000):
            readings.append(SignalReading(color, remain, SRC_API, fresh_ms=fresh))
            readings.append(SignalReading(color, remain, SRC_VISION, fresh_ms=fresh))
_grid_bad = []
for a in readings:
    for v in readings:
        for single in (False, True):
            r = evaluate(a, v, allow_single_source=single)
            if (r.reason in CONTROLLER_ONLY_REASONS or r.reason not in golden_reasons
                    or r.decision not in (WALK, WAIT, UNKNOWN_DECISION)):
                _grid_bad.append((a, v, single, r))
check("evaluate 는 컨트롤러 전용 이유를 어떤 입력에도 내지 않는다(전수 격자)",
      not _grid_bad, detail=str(_grid_bad[:3]))

print("=" * 50)
if FAILURES:
    print(f"FAIL {len(FAILURES)}건: {FAILURES}")
    sys.exit(1)
print("judge 골든 테스트 전부 PASS")
