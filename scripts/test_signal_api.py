"""signal_api 파싱·매핑·안전망 단위 테스트 (네트워크 없음, 실측 픽스처).
실행: python scripts/test_signal_api.py"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from signals import GREEN, RED, CLEARANCE, UNKNOWN, SRC_API
from signal_api import parse_reading, STATUS_MAP

FAILURES = []


def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print(f"[{status}] {name}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(name)


# 실측 응답을 본뜬 레코드 (trsmUtcTime, 방위별 Pdsg 필드).
# 잔여는 1/10초 단위 정수 문자열/숫자로 온다 (실측: 241 = 24.1초).
NOW = 1_783_943_330_618
def rec(**over):
    base = {
        "itstId": "1537", "trsmUtcTime": NOW,
        "ntPdsgStatNm": None, "ntPdsgRmdrCs": None,
        "nePdsgStatNm": "protected-Movement-Allowed", "nePdsgRmdrCs": 241,
        "nwPdsgStatNm": "stop-And-Remain", "nwPdsgRmdrCs": 281,
        "stPdsgStatNm": "protected-clearance", "stPdsgRmdrCs": 33,
    }
    base.update(over)
    return base


# 1) 초록 매핑 + 잔여 1/10초 → 초 변환
r = parse_reading([rec()], "ne", now_ms=NOW)
check("초록 매핑", r.color == GREEN, f"실제 {r.color}")
check("잔여 241→24.1초", r.remain_sec == 24.1, f"실제 {r.remain_sec}")
check("source=API", r.source == SRC_API)
check("raw 원문 보존", r.raw == "protected-Movement-Allowed")

# 2) 빨강 매핑
r = parse_reading([rec()], "nw", now_ms=NOW)
check("빨강 매핑", r.color == RED, f"실제 {r.color}")

# 3) 점멸(clearance) 매핑
r = parse_reading([rec()], "st", now_ms=NOW)
check("clearance→CLEARANCE", r.color == CLEARANCE, f"실제 {r.color}")

# 4) 해당 방위 신호 없음(None) → UNKNOWN
r = parse_reading([rec()], "nt", now_ms=NOW)
check("None 방위 → UNKNOWN", r.color == UNKNOWN, f"실제 {r.color}")
check("None이면 잔여도 None", r.remain_sec is None)

# 5) 처음 보는 상태 문자열 → UNKNOWN (추측 금지), raw 보존
r = parse_reading([rec(nePdsgStatNm="some-New-Phase")], "ne", now_ms=NOW)
check("미지 상태 → UNKNOWN", r.color == UNKNOWN, f"실제 {r.color}")
check("미지여도 raw 보존", r.raw == "some-New-Phase")

# 6) stale (전송시각이 now보다 stale_ms 이상 과거) → UNKNOWN
r = parse_reading([rec()], "ne", now_ms=NOW + 5000, stale_ms=2000)
check("stale → UNKNOWN", r.color == UNKNOWN, f"실제 {r.color}")

# 7) fresh 판정: fresh_ms가 now - trsm 로 계산됨
r = parse_reading([rec()], "ne", now_ms=NOW + 500, stale_ms=2000)
check("fresh_ms 계산", r.color == GREEN and r.fresh_ms == 500,
      f"실제 color={r.color} fresh={r.fresh_ms}")

# 8) 빈 레코드 배열 → UNKNOWN (터지지 않음)
r = parse_reading([], "ne", now_ms=NOW)
check("빈 배열 → UNKNOWN", r.color == UNKNOWN, f"실제 {r.color}")

# 9) 잔여값이 문자열이어도 처리
r = parse_reading([rec(nePdsgRmdrCs="241")], "ne", now_ms=NOW)
check("문자열 잔여 처리", r.remain_sec == 24.1, f"실제 {r.remain_sec}")

# 10) STATUS_MAP은 알려진 5개만, 나머지는 매핑에 없음
check("STATUS_MAP 알려진 값만",
      set(STATUS_MAP) == {"protected-Movement-Allowed", "permissive-Movement-Allowed",
                          "protected-clearance", "permissive-clearance",
                          "stop-And-Remain"},
      f"실제 {sorted(STATUS_MAP)}")

print("=" * 50)
if FAILURES:
    print(f"FAIL {len(FAILURES)}건: {FAILURES}")
    sys.exit(1)
print("signal_api 파싱 단위 테스트 전부 PASS")
