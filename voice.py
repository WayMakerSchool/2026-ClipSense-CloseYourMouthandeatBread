"""안내 음성 재생 모듈.

- 사전 생성된 wav 파일(assets/voice/)만 재생한다. 런타임 인터넷 불필요.
- 같은 안내는 쿨다운(기본 3초, 재생 종료 시점부터) 내 반복 재생하지 않는다.
  단, 상태 전환 안내는 반드시 들려야 하므로 force=True로 쿨다운을 우회한다.
- 다른 안내(상태 전환)는 즉시 재생하며, 재생 중이던 음성은 끊는다.

백엔드: macOS에서는 afplay 서브프로세스(기본). cv2(HighGUI)와 pygame이
서로 다른 SDL2 사본을 로드해 objc 클래스가 중복되는 문제가 이 환경에서
실측 확인되어, 부스 안정성을 위해 GUI(cv2)와 오디오를 프로세스 분리한다.
afplay가 없는 플랫폼(Windows 등)에서는 pygame으로 폴백.

테스트: python voice.py --test
"""

import argparse
import os
import shutil
import subprocess
import sys
import time
import wave
from pathlib import Path

VOICE_DIR = Path(__file__).resolve().parent / "assets" / "voice"

# detector 상태 이름 → 음성 파일 key
KEYS = ["green", "red", "blink", "unknown"]


def _wav_length(path: Path) -> float:
    with wave.open(str(path), "rb") as w:
        return w.getnframes() / w.getframerate()


class VoicePlayer:
    def __init__(self, voice_dir: Path = VOICE_DIR, cooldown: float = 3.0,
                 volume: float = 1.0, backend: str | None = None):
        self.cooldown = cooldown
        self.volume = volume
        # key → 해당 안내 재생이 끝나는(끝난) 시각. 쿨다운은 이 시점부터 계산
        self._play_ends_at: dict[str, float] = {}
        self._paths: dict[str, Path] = {}
        self._lengths: dict[str, float] = {}

        missing = []
        for key in KEYS:
            path = Path(voice_dir) / f"{key}.wav"
            if path.exists():
                self._paths[key] = path
                self._lengths[key] = _wav_length(path)
            else:
                missing.append(str(path))
        if missing:
            raise FileNotFoundError(
                "음성 파일이 없습니다. 먼저 실행하세요: "
                "python scripts/generate_voice.py\n누락: " + ", ".join(missing)
            )

        self.backend = backend or ("afplay" if shutil.which("afplay")
                                   else "pygame")
        self._proc: subprocess.Popen | None = None   # afplay용
        self._playing_key: str | None = None

        if self.backend == "pygame":
            os.environ.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")
            import pygame
            self._pygame = pygame
            pygame.mixer.init(frequency=44100)
            self._sounds = {k: pygame.mixer.Sound(str(p))
                            for k, p in self._paths.items()}
            for s in self._sounds.values():
                s.set_volume(volume)
            self._channel = pygame.mixer.Channel(0)

    def _is_busy(self) -> bool:
        if self.backend == "afplay":
            return self._proc is not None and self._proc.poll() is None
        return self._channel.get_busy()

    def _stop_current(self) -> None:
        """재생 중이면 끊고, 끊긴 안내의 종료 시각을 실제(지금)로 당긴다."""
        if not self._is_busy():
            return
        now = time.monotonic()
        if self._playing_key is not None:
            ends = self._play_ends_at.get(self._playing_key)
            if ends is not None and ends > now:
                self._play_ends_at[self._playing_key] = now
        if self.backend == "afplay":
            self._proc.terminate()
            self._proc.wait()
        else:
            self._channel.stop()

    def play(self, key: str, block: bool = False, force: bool = False) -> bool:
        """key 안내를 재생. 쿨다운으로 건너뛰면 False, 재생하면 True.

        force=True는 쿨다운을 무시한다. 상태 전환 안내는 안전상 반드시
        들려야 하므로 force로 재생한다 (예: UNKNOWN에서 복귀 직후 재안내).
        """
        if key not in self._paths:
            raise KeyError(f"알 수 없는 안내 key: {key} (가능: {KEYS})")

        now = time.monotonic()
        ends_at = self._play_ends_at.get(key)
        if not force and ends_at is not None and now < ends_at + self.cooldown:
            return False

        self._stop_current()  # 새 안내가 이전 안내보다 우선
        self._play_ends_at[key] = now + self._lengths[key]
        self._playing_key = key

        if self.backend == "afplay":
            self._proc = subprocess.Popen(
                ["afplay", "-v", str(self.volume), str(self._paths[key])],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if block:
                self._proc.wait()
        else:
            self._channel.play(self._sounds[key])
            if block:
                while self._channel.get_busy():
                    time.sleep(0.05)
        return True

    def close(self) -> None:
        self._stop_current()
        if self.backend == "pygame":
            self._pygame.mixer.quit()


def _run_test() -> None:
    player = VoicePlayer()
    print(f"음성 디렉토리: {VOICE_DIR}  백엔드: {player.backend}")
    for key in KEYS:
        print(f"재생 중: {key} ({player._lengths[key]:.1f}초)")
        played = player.play(key, block=True)
        assert played, f"{key} 재생이 예상과 달리 건너뛰어짐"
        time.sleep(0.3)

    # 쿨다운: 방금 재생한 안내를 즉시 재요청하면 건너뜀
    suppressed = not player.play("unknown")
    print(f"쿨다운 (3초 내 같은 안내 재요청 → 건너뜀): "
          f"{'정상' if suppressed else '실패'}")
    # force: 상태 전환 안내는 쿨다운 무시하고 재생되어야 함
    forced = player.play("unknown", block=True, force=True)
    print(f"force 재생 (전환 안내는 쿨다운 무시): {'정상' if forced else '실패'}")
    player.close()
    if not suppressed or not forced:
        sys.exit(1)
    print("테스트 완료: 4개 음성 순서대로 재생 + 쿨다운/force 동작 확인.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="안내 음성 재생 모듈")
    parser.add_argument("--test", action="store_true",
                        help="4개 안내 음성을 순서대로 재생하고 쿨다운/force 확인")
    args = parser.parse_args()
    if args.test:
        _run_test()
    else:
        parser.print_help()
