"""SignalStateMachine 단위 테스트 (영상 없이 판정 시퀀스를 직접 주입).

사용법: python scripts/test_state_machine.py
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from detector import (SignalStateMachine, RAW_RED, RAW_GREEN, RAW_NONE,
                      STATE_RED, STATE_GREEN, STATE_GREEN_BLINK, STATE_UNKNOWN)

CFG = json.loads((ROOT / "config.json").read_text(encoding="utf-8"))

FAILURES = []


def check(name: str, cond: bool, detail: str = "") -> None:
    status = "PASS" if cond else "FAIL"
    print(f"[{status}] {name}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(name)


def run(fps: float, segments: list[tuple]):
    """segments: (지속 초, raw 값[, reason]) 목록 → 전환 리스트 반환."""
    sm = SignalStateMachine(CFG)
    transitions = []
    frame = 0
    for seg in segments:
        duration, raw = seg[0], seg[1]
        reason = seg[2] if len(seg) > 2 else ""
        for _ in range(round(duration * fps)):
            tr = sm.update(frame / fps, raw, reason)
            if tr:
                transitions.append(tr)
            frame += 1
    return transitions, sm


def blink_segments(seconds: float, period: float = 1.0):
    """초록 점멸: period의 절반 켜짐/꺼짐 반복."""
    segs = []
    t = 0.0
    while t < seconds - 1e-9:
        segs.append((period / 2, RAW_GREEN))
        segs.append((period / 2, RAW_NONE))
        t += period
    return segs


def states_of(transitions):
    return [tr.new for tr in transitions]


# 1. 기본 사이클 (30fps): 빨강→초록→점멸→빨강
trs, _ = run(30, [(5, RAW_RED), (4, RAW_GREEN), *blink_segments(3), (4, RAW_RED)])
check("기본 사이클 30fps",
      states_of(trs) == [STATE_RED, STATE_GREEN, STATE_GREEN_BLINK, STATE_RED],
      f"실제: {states_of(trs)}")

# 2. 같은 사이클을 15fps / 60fps에서 (프레임 디바운스 vs 시간 기반 점멸 상호작용)
for fps in (15, 60):
    trs, _ = run(fps, [(5, RAW_RED), (4, RAW_GREEN), *blink_segments(3), (4, RAW_RED)])
    check(f"기본 사이클 {fps}fps",
          states_of(trs) == [STATE_RED, STATE_GREEN, STATE_GREEN_BLINK, STATE_RED],
          f"실제: {states_of(trs)}")

# 3. 1프레임 노이즈 글리치가 상태를 흔들지 않아야 함
trs, _ = run(30, [(3, RAW_RED), (1 / 30, RAW_GREEN), (3, RAW_RED)])
check("1프레임 글리치 무시", states_of(trs) == [STATE_RED], f"실제: {states_of(trs)}")

# 4. 점멸 후 다시 안정 초록 → GREEN 복귀 (윈도에서 토글이 빠진 뒤)
trs, _ = run(30, [(4, RAW_GREEN), *blink_segments(3), (5, RAW_GREEN)])
check("점멸 후 안정 초록 복귀",
      states_of(trs) == [STATE_GREEN, STATE_GREEN_BLINK, STATE_GREEN],
      f"실제: {states_of(trs)}")

# 5. 점멸 꺼짐 구간(0.5초)에서 스퓨리어스 UNKNOWN 없어야 함
trs, _ = run(30, [(4, RAW_GREEN), *blink_segments(6)])
check("점멸 중 UNKNOWN 없음", STATE_UNKNOWN not in states_of(trs),
      f"실제: {states_of(trs)}")

# 6. 소등 → UNKNOWN 시점이 unknown_after(1.5초) 근처
trs, _ = run(30, [(3, RAW_RED), (3, RAW_NONE)])
unknown_trs = [tr for tr in trs if tr.new == STATE_UNKNOWN]
check("소등 1.5초 후 UNKNOWN",
      len(unknown_trs) == 1 and 3.0 + 1.4 <= unknown_trs[0].t <= 3.0 + 1.8,
      f"실제: {[(tr.new, round(tr.t, 2)) for tr in trs]}")

# 7. 전환당 이벤트 1회: 안정 구간이 길어도 같은 상태 반복 전환 없음
trs, _ = run(30, [(30, RAW_RED)])
check("긴 안정 구간에 전환 1회", states_of(trs) == [STATE_RED], f"실제: {states_of(trs)}")

# 8. 느린 점멸(1.5초 주기): 토글 수가 임계 경계에 걸려도 GREEN↔BLINK
#    플래핑 없이 BLINK에 한 번 진입해 유지되어야 함 (이탈 히스테리시스)
trs, _ = run(30, [(4, RAW_GREEN), *blink_segments(6, period=1.5)])
check("느린 점멸 플래핑 없음",
      states_of(trs) == [STATE_GREEN, STATE_GREEN_BLINK],
      f"실제: {states_of(trs)}")

# 9. 주기적 플리커(RED,RED,NONE 반복 — 모니터 촬영 간섭 시나리오):
#    raw가 8프레임 연속인 적이 없으므로 어떤 전환도 나가면 안 됨
flicker = [(1 / 30, RAW_RED), (1 / 30, RAW_RED), (1 / 30, RAW_NONE)] * 100
trs, _ = run(30, flicker)
check("주기적 플리커에 전환 없음", states_of(trs) == [], f"실제: {states_of(trs)}")

# 10. 안정 GREEN 중 2프레임짜리 검출 dropout 2회/2초 (자동노출 딥 등):
#     구간이 blink_min_segment(0.15초)보다 짧으므로 가짜 점멸 금지
trs, _ = run(30, [(3, RAW_GREEN), (2 / 30, RAW_NONE), (0.7, RAW_GREEN),
                  (2 / 30, RAW_NONE), (3, RAW_GREEN)])
check("짧은 dropout이 가짜 점멸 안 만듦", states_of(trs) == [STATE_GREEN],
      f"실제: {states_of(trs)}")

# 11. 모니터 촬영 밴딩: 밝기 급변으로 인한 '판정 보류' NONE 런(0.4초, 1Hz)은
#     점멸 집계에서 제외되어 가짜 GREEN_BLINK가 나가면 안 됨
banding = [(3, RAW_GREEN)] + [(0.6, RAW_GREEN),
                              (0.4, RAW_NONE, "brightness_jump")] * 6
trs, _ = run(30, banding)
check("판정 보류 NONE은 점멸로 안 잡힘", states_of(trs) == [STATE_GREEN],
      f"실제: {states_of(trs)}")

# 12. 같은 패턴이라도 '실제 소등'(reason 없음)이면 점멸로 잡혀야 함
#     (11번 방어가 진짜 점멸 감지를 죽이지 않았는지 확인)
real_blink = [(3, RAW_GREEN)] + [(0.6, RAW_GREEN), (0.4, RAW_NONE)] * 6
trs, _ = run(30, real_blink)
check("실제 소등 패턴은 여전히 점멸 감지",
      states_of(trs) == [STATE_GREEN, STATE_GREEN_BLINK],
      f"실제: {states_of(trs)}")

# 13. 판정 보류가 1.5초 이상 지속되면 UNKNOWN 경로는 그대로 동작해야 함
trs, _ = run(30, [(3, RAW_RED), (2.5, RAW_NONE, "camera_fail")])
check("판정 보류 지속 → UNKNOWN 정상 전환",
      states_of(trs) == [STATE_RED, STATE_UNKNOWN], f"실제: {states_of(trs)}")

print("=" * 50)
if FAILURES:
    print(f"FAIL {len(FAILURES)}건: {FAILURES}")
    sys.exit(1)
print("단위 테스트 전부 PASS")
