"""파이프라인 자동 검증: 합성 영상 → 상태 전환 시퀀스가 정답과 일치하는지 확인.

사용법:
    python scripts/run_pipeline_test.py
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ROI = "390,70,120,220"
TOLERANCE = 0.7  # 초

# 시나리오: (영상, [(예상 시각, from, to, voice)])
# 예상 시각 = 합성 영상 타임라인 + 디바운스/점멸 감지/밝기 EMA 수렴 지연
SCENARIOS = [
    ("test_synthetic.mp4", [
        (0.3, "UNKNOWN", "RED", "red"),          # 디바운스 8프레임 ≈ 0.27초
        (5.3, "RED", "GREEN", "green"),
        (10.7, "GREEN", "GREEN_BLINK", "blink"),  # 점멸 시작 9.0 + 토글 3회 누적
        (12.3, "GREEN_BLINK", "RED", "red"),
        (17.5, "RED", "UNKNOWN", "unknown"),      # 소등 16.0 + 1.5초
    ]),
    # 3단계: 가림 → 3초 내 '확인 불가' 안내 → 복귀 시 현재 상태 재안내
    ("test_occlusion.mp4", [
        (0.3, "UNKNOWN", "RED", "red"),
        (5.5, "RED", "UNKNOWN", "unknown"),       # 가림 4.0 + 1.5초 (< 3초 요구)
        (7.0, "UNKNOWN", "RED", "red"),           # 손 뗌 6.5 + EMA 수렴 + 디바운스
    ]),
    # 5단계: 카운트다운 15→1 판독 (숫자는 상태 판정과 독립, 안내 미연동)
    ("test_countdown.mp4", [
        (0.3, "UNKNOWN", "GREEN", "green"),
        (15.3, "GREEN", "RED", "red"),
    ]),
]

DIGIT_ROI = "270,90,100,70"
DIGITS_RE = re.compile(r"DIGITS t=[\d.]+ value=(\S+)")

TRANSITION_RE = re.compile(
    r"TRANSITION t=([\d.]+) from=(\S+) to=(\S+) voice=(\S+) played=(\S+)")


def run_scenario(video_name: str, expected) -> list[str]:
    video = ROOT / "data" / video_name
    if not video.exists():
        return [f"{video_name} 없음 — 먼저 실행: python scripts/make_test_video.py"]

    cmd = [sys.executable, str(ROOT / "main.py"), "--video", str(video),
           "--roi", ROI, "--headless", "--mute"]
    is_countdown = "countdown" in video_name
    if is_countdown:
        cmd += ["--digit-roi", DIGIT_ROI]
    proc = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    print(proc.stdout)
    if proc.returncode != 0:
        return [f"main.py 비정상 종료 (code {proc.returncode})\n{proc.stderr}"]

    got = [(float(m[1]), m[2], m[3], m[4])
           for m in TRANSITION_RE.finditer(proc.stdout)]

    failures = []
    if len(got) != len(expected):
        failures.append(f"전환 개수 불일치: 예상 {len(expected)}개, 실제 {len(got)}개")
    for i, ((et, ef, eto, ev), g) in enumerate(zip(expected, got)):
        gt, gf, gto, gv = g
        if (gf, gto, gv) != (ef, eto, ev):
            failures.append(f"[{i}] 전환 불일치: 예상 {ef}->{eto}({ev}), "
                            f"실제 {gf}->{gto}({gv})")
        elif abs(gt - et) > TOLERANCE:
            failures.append(f"[{i}] 시각 불일치: 예상 {et:.1f}s ±{TOLERANCE}, "
                            f"실제 {gt:.2f}s")

    # 음성 이벤트가 전환당 정확히 1회인지 (TRANSITION 로그 = 재생 호출 지점)
    voice_counts = {}
    for _, _, _, v in got:
        voice_counts[v] = voice_counts.get(v, 0) + 1
    expected_counts = {}
    for _, _, _, v in expected:
        expected_counts[v] = expected_counts.get(v, 0) + 1
    if voice_counts != expected_counts:
        failures.append(f"음성 호출 횟수 불일치: 예상 {expected_counts}, "
                        f"실제 {voice_counts}")

    # 카운트다운 시나리오: 판독된 숫자는 (1) 오판 없이 15→1의 부분수열이고
    # (2) 단조 감소하며 (3) 소등 후 None으로 끝나야 한다. None(정직한 포기)은
    # 허용 — 종횡비 경계의 '4'류. 실제 종횡비 캘리브레이션은 참조 영상에서.
    if is_countdown:
        values = [None if v == "None" else int(v)
                  for v in DIGITS_RE.findall(proc.stdout)]
        numbers = [v for v in values if v is not None]
        expected_set = set(range(1, 16))
        misread = [n for n in numbers if n not in expected_set]
        if misread:
            failures.append(f"숫자 오판(15~1 밖): {misread}")
        # 단조 감소 (같은 값 반복은 허용, 증가는 오판 신호)
        increasing = [(a, b) for a, b in zip(numbers, numbers[1:]) if b > a]
        if increasing:
            failures.append(f"숫자가 증가함(오판 신호): {increasing[:5]}")
        if len(set(numbers)) < 8:
            failures.append(f"판독된 서로 다른 숫자가 너무 적음: {sorted(set(numbers))}")
        # 마지막으로 로그된 숫자가 1이어야 함 (카운트다운이 1까지 내려감).
        # 소등 구간의 None-없음은 로그하지 않으므로 값 로그의 끝은 마지막 유효 숫자.
        if numbers and numbers[-1] != 1:
            failures.append(f"카운트다운 마지막 숫자가 1이 아님: {numbers[-1]}")
    return failures

def main() -> int:
    all_failures = []
    for video_name, expected in SCENARIOS:
        print(f"--- 시나리오: {video_name} ---")
        fails = run_scenario(video_name, expected)
        all_failures.extend(f"{video_name}: {f}" for f in fails)

    print("=" * 50)
    if all_failures:
        print(f"FAIL ({len(all_failures)}건)")
        for f in all_failures:
            print(f"  - {f}")
        return 1
    print(f"PASS — {len(SCENARIOS)}개 시나리오 전환 시퀀스 모두 정답 일치, "
          "음성 전환당 1회")
    return 0


if __name__ == "__main__":
    sys.exit(main())
