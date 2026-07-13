"""VoicePlayer 쿨다운/force 로직 테스트 (볼륨 0으로 무음 실행).

사용법: python scripts/test_voice.py
"""

import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from voice import VoicePlayer

FAILURES = []


def check(name: str, cond: bool) -> None:
    print(f"[{'PASS' if cond else 'FAIL'}] {name}")
    if not cond:
        FAILURES.append(name)


player = VoicePlayer(volume=0.0, cooldown=3.0)
print(f"백엔드: {player.backend} (볼륨 0 — 소리 안 남)")

check("첫 재생 → True", player.play("red") is True)
check("재생 중 같은 key 재요청 → False (쿨다운)", player.play("red") is False)
check("같은 key force → True (전환 안내는 반드시 재생)",
      player.play("red", force=True) is True)
check("다른 key는 즉시 재생 → True", player.play("unknown") is True)
# unknown이 red를 끊었으므로 red의 종료 시각은 '끊긴 시점'으로 당겨졌어야 함
# → 3초 쿨다운은 지금부터: 아직 쿨다운 내이므로 일반 재생은 거부
check("끊긴 직후에도 쿨다운은 유지", player.play("red") is False)
time.sleep(3.1)  # red가 끊긴 시점 + 3초 경과
check("끊긴 시점 기준 쿨다운 경과 후 재생 → True", player.play("red") is True)

player.close()
print("=" * 50)
if FAILURES:
    print(f"FAIL {len(FAILURES)}건: {FAILURES}")
    sys.exit(1)
print("음성 로직 테스트 전부 PASS")
