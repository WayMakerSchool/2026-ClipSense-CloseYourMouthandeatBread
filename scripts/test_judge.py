"""judge 이중 판단 단위 테스트. WALK는 오직 AND 만족일 때만.
실행: python scripts/test_judge.py"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from signals import SignalReading, GREEN, RED, CLEARANCE, UNKNOWN, SRC_API, SRC_VISION
from judge import decide, WALK, WAIT, UNKNOWN_DECISION

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

print("=" * 50)
if FAILURES:
    print(f"FAIL {len(FAILURES)}건: {FAILURES}")
    sys.exit(1)
print("judge 단위 테스트 전부 PASS")
