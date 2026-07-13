"""한국어 안내 음성 파일 생성 스크립트 (개발 시 1회 실행, 인터넷 필요).

edge-tts로 mp3를 만든 뒤 ffmpeg(없으면 macOS afconvert)로 wav 변환하여
assets/voice/ 에 저장한다. 부스 런타임에는 이 스크립트가 필요 없다.

사용법:
    python scripts/generate_voice.py
"""

import asyncio
import shutil
import subprocess
import sys
from pathlib import Path

import edge_tts

VOICE = "ko-KR-SunHiNeural"

# key는 voice.py 및 detector 상태 이름과 1:1 대응
PHRASES = [
    ("green", "지금 건너셔도 됩니다."),
    ("red", "빨간불입니다. 기다려 주세요."),
    ("blink", "곧 신호가 끝납니다. 서두르지 마세요."),
    ("unknown", "신호를 확인할 수 없습니다. 직접 확인해 주세요."),
]

OUT_DIR = Path(__file__).resolve().parent.parent / "assets" / "voice"


def mp3_to_wav(mp3_path: Path, wav_path: Path) -> None:
    if shutil.which("ffmpeg"):
        cmd = ["ffmpeg", "-y", "-loglevel", "error", "-i", str(mp3_path),
               "-ar", "44100", "-ac", "1", str(wav_path)]
    elif shutil.which("afconvert"):
        cmd = ["afconvert", "-f", "WAVE", "-d", "LEI16@44100", "-c", "1",
               str(mp3_path), str(wav_path)]
    else:
        sys.exit("오류: ffmpeg 또는 afconvert가 필요합니다 (wav 변환용).")
    subprocess.run(cmd, check=True)


async def generate(key: str, text: str) -> Path:
    mp3_path = OUT_DIR / f"{key}.mp3"
    wav_path = OUT_DIR / f"{key}.wav"
    await edge_tts.Communicate(text, VOICE).save(str(mp3_path))
    mp3_to_wav(mp3_path, wav_path)
    mp3_path.unlink()
    return wav_path


async def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    ok = True
    for key, text in PHRASES:
        try:
            wav = await generate(key, text)
        except Exception as e:  # noqa: BLE001 - 어떤 실패든 정직하게 보고
            print(f"[실패] {key}: {e}")
            ok = False
            continue
        size = wav.stat().st_size
        if size < 1000:
            print(f"[실패] {key}: 파일이 비정상적으로 작음 ({size} bytes)")
            ok = False
        else:
            print(f"[생성] {wav}  ({size // 1024} KB)  \"{text}\"")
    if not ok:
        sys.exit(1)
    print(f"\n완료: {len(PHRASES)}개 음성 파일 → {OUT_DIR}")


if __name__ == "__main__":
    asyncio.run(main())
