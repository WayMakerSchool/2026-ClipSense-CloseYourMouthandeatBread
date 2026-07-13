"""합성 신호등 테스트 영상 생성 (reference.mp4가 오기 전 파이프라인 검증용).

정답 타임라인을 알고 있으므로 상태 머신을 자동 검증할 수 있다.
검출 파이프라인 자체는 실제와 동일하게 동작한다(가짜 아님) —
입력만 합성일 뿐 HSV 마스킹·blob·상태 머신 모두 진짜 경로를 탄다.

영상 1 — test_synthetic.mp4 (기본 사이클, 30fps, 640x480):
    0.0 -  5.0  빨간불
    5.0 -  9.0  초록불
    9.0 - 12.0  초록 점멸 (0.5초 켜짐 / 0.5초 꺼짐)
   12.0 - 16.0  빨간불
   16.0 - 18.0  전체 소등 (UNKNOWN 확인용)

영상 2 — test_occlusion.mp4 (3단계 가림 시나리오):
    0.0 -  4.0  빨간불
    4.0 -  6.5  손으로 가림 (화면 전체 밝은 회색 — 밝기 급변 + 색상 소실)
    6.5 - 11.0  빨간불 (복귀 시 재안내 확인)

영상 3 — test_countdown.mp4 (5단계 잔여시간 숫자):
    0.0 - 15.0  초록불 + 잔여시간 15→1 (붉은 7-세그먼트, 1초 간격)
   15.0 - 17.0  빨간불, 숫자 소등

신호등 램프 영역 ROI: (390, 70, 120, 220)
숫자 패널 ROI: (270, 90, 100, 70)
"""

import sys
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from digits import draw_seven_segment

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
FPS = 30
W, H = 640, 480

# 신호등 위치
HOUSING = (380, 60, 140, 240)          # x, y, w, h
RED_CENTER, GREEN_CENTER = (450, 130), (450, 250)
LAMP_R = 32
ROI = (390, 70, 120, 220)

RED_ON = (40, 40, 235)     # BGR
GREEN_ON = (70, 210, 80)
LAMP_OFF = (32, 32, 32)


def lamp_state(t: float) -> tuple[bool, bool]:
    """(red_on, green_on)"""
    if t < 5.0:
        return True, False
    if t < 9.0:
        return False, True
    if t < 12.0:  # 1Hz 점멸: 0.5초 켜짐 / 0.5초 꺼짐
        return False, (t % 1.0) < 0.5
    if t < 16.0:
        return True, False
    return False, False


def make_frame(t: float, rng: np.random.Generator) -> np.ndarray:
    frame = np.full((H, W, 3), 70, np.uint8)
    # 배경: 거리 느낌의 그라데이션 + 노이즈
    grad = np.linspace(90, 40, H, dtype=np.uint8)[:, None]
    frame[:] = np.repeat(grad, W, axis=1)[..., None]
    cv2.rectangle(frame, (0, 380), (W, H), (60, 60, 65), -1)  # 도로

    x, y, w, h = HOUSING
    cv2.rectangle(frame, (x, y), (x + w, y + h), (45, 45, 45), -1)
    cv2.rectangle(frame, (x, y), (x + w, y + h), (25, 25, 25), 3)

    red_on, green_on = lamp_state(t)
    cv2.circle(frame, RED_CENTER, LAMP_R, RED_ON if red_on else LAMP_OFF, -1)
    cv2.circle(frame, GREEN_CENTER, LAMP_R, GREEN_ON if green_on else LAMP_OFF, -1)
    if red_on:  # 점등 글로우
        cv2.circle(frame, RED_CENTER, LAMP_R + 6, (30, 30, 120), 4)
    if green_on:
        cv2.circle(frame, GREEN_CENTER, LAMP_R + 6, (40, 100, 40), 4)

    noise = rng.integers(-12, 13, frame.shape, dtype=np.int16)
    return np.clip(frame.astype(np.int16) + noise, 0, 255).astype(np.uint8)


def make_occlusion_frame(t: float, rng: np.random.Generator) -> np.ndarray:
    if 4.0 <= t < 6.5:  # 손으로 가림: 화면 전체 밝은 회색 + 노이즈
        frame = np.full((H, W, 3), 150, np.uint8)
        noise = rng.integers(-12, 13, frame.shape, dtype=np.int16)
        return np.clip(frame.astype(np.int16) + noise, 0, 255).astype(np.uint8)
    # 가림 전후: 빨간불 고정 (make_frame의 t<5.0 구간 재사용)
    return make_frame(1.0, rng)


DIGIT_PANEL = (270, 90, 100, 70)  # x, y, w, h — 숫자 패널 ROI
DIGIT_RED = (35, 35, 220)


def make_countdown_frame(t: float, rng: np.random.Generator) -> np.ndarray:
    frame = np.full((H, W, 3), 70, np.uint8)
    grad = np.linspace(90, 40, H, dtype=np.uint8)[:, None]
    frame[:] = np.repeat(grad, W, axis=1)[..., None]
    cv2.rectangle(frame, (0, 380), (W, H), (60, 60, 65), -1)

    x, y, w, h = HOUSING
    cv2.rectangle(frame, (x, y), (x + w, y + h), (45, 45, 45), -1)

    px, py, pw, ph = DIGIT_PANEL
    cv2.rectangle(frame, (px, py), (px + pw, py + ph), (30, 30, 30), -1)

    if t < 15.0:
        cv2.circle(frame, GREEN_CENTER, LAMP_R, GREEN_ON, -1)
        cv2.circle(frame, RED_CENTER, LAMP_R, LAMP_OFF, -1)
        remaining = 15 - int(t)
        digit_w, digit_h = 34, 54
        n_digits = len(str(remaining))
        total_w = n_digits * digit_w + (n_digits - 1) * 6
        draw_seven_segment(frame, remaining, px + (pw - total_w) // 2,
                           py + (ph - digit_h) // 2, digit_w, digit_h, DIGIT_RED)
    else:
        cv2.circle(frame, RED_CENTER, LAMP_R, RED_ON, -1)
        cv2.circle(frame, GREEN_CENTER, LAMP_R, LAMP_OFF, -1)

    noise = rng.integers(-12, 13, frame.shape, dtype=np.int16)
    return np.clip(frame.astype(np.int16) + noise, 0, 255).astype(np.uint8)


def write_video(name: str, duration: float, frame_fn) -> None:
    path = DATA_DIR / name
    writer = cv2.VideoWriter(str(path), cv2.VideoWriter_fourcc(*"mp4v"),
                             FPS, (W, H))
    if not writer.isOpened():
        raise SystemExit("오류: VideoWriter를 열 수 없습니다.")
    rng = np.random.default_rng(42)
    n = int(duration * FPS)
    for i in range(n):
        writer.write(frame_fn(i / FPS, rng))
    writer.release()
    print(f"생성: {path} ({n}프레임, {duration}초, {FPS}fps)")


def main() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    write_video("test_synthetic.mp4", 18.0, make_frame)
    write_video("test_occlusion.mp4", 11.0, make_occlusion_frame)
    write_video("test_countdown.mp4", 17.0, make_countdown_frame)
    print(f"ROI: {','.join(map(str, ROI))}")
    print(f"숫자 ROI: {','.join(map(str, DIGIT_PANEL))}")


if __name__ == "__main__":
    main()
