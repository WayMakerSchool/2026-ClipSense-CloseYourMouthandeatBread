"""vision_adapter 상태 매핑 단위 테스트. 실행: python scripts/test_vision_adapter.py"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from signals import GREEN, RED, CLEARANCE, UNKNOWN, SRC_VISION
from detector import STATE_RED, STATE_GREEN, STATE_GREEN_BLINK, STATE_UNKNOWN
from vision_adapter import to_reading

FAILURES = []


def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print(f"[{status}] {name}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(name)


check("RED 매핑", to_reading(STATE_RED).color == RED)
check("GREEN 매핑", to_reading(STATE_GREEN).color == GREEN)
check("GREEN_BLINK→CLEARANCE", to_reading(STATE_GREEN_BLINK).color == CLEARANCE)
check("UNKNOWN 매핑", to_reading(STATE_UNKNOWN).color == UNKNOWN)

r = to_reading(STATE_GREEN, remain_sec=12.0, fresh_ms=100)
check("source=VISION", r.source == SRC_VISION)
check("잔여·신선도 보존", r.remain_sec == 12.0 and r.fresh_ms == 100)
check("잔여 기본 None", to_reading(STATE_RED).remain_sec is None)

# 모르는 상태 문자열(방어): 매핑에 없으면 UNKNOWN
check("미지 상태 → UNKNOWN", to_reading("SOMETHING_ELSE").color == UNKNOWN)

print("=" * 50)
if FAILURES:
    print(f"FAIL {len(FAILURES)}건: {FAILURES}")
    sys.exit(1)
print("vision_adapter 단위 테스트 전부 PASS")
