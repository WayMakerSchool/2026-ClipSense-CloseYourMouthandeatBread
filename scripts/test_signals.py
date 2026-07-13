"""signals.py 표준 타입 단위 테스트. 실행: python scripts/test_signals.py"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from signals import (SignalReading, GREEN, RED, CLEARANCE, UNKNOWN,
                     SRC_API, SRC_VISION)

FAILURES = []


def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print(f"[{status}] {name}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(name)


r = SignalReading(color=GREEN, remain_sec=24.1, source=SRC_API, fresh_ms=120)
check("필드 보존", r.color == GREEN and r.remain_sec == 24.1
      and r.source == SRC_API and r.fresh_ms == 120)
check("raw 기본값 None", r.raw is None)
check("is_go: GREEN이면 True", r.is_go() is True)

r2 = SignalReading(color=RED, remain_sec=None, source=SRC_VISION, fresh_ms=0)
check("is_go: RED이면 False", r2.is_go() is False)
check("remain_sec None 허용", r2.remain_sec is None)

r3 = SignalReading(color=UNKNOWN, remain_sec=None, source=SRC_API, fresh_ms=0)
check("is_go: UNKNOWN이면 False", r3.is_go() is False)
check("상수 4색 구분", len({GREEN, RED, CLEARANCE, UNKNOWN}) == 4)

print("=" * 50)
if FAILURES:
    print(f"FAIL {len(FAILURES)}건: {FAILURES}")
    sys.exit(1)
print("signals 단위 테스트 전부 PASS")
