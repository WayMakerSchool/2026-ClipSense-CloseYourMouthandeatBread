"""신호 검출(HSV 색상 기반) + 상태 머신.

딥러닝 없이 OpenCV 색상 필터만 사용한다.

- ColorDetector: ROI 프레임 1장 → 프레임 단위 판정(RED / GREEN / NONE)
- SignalStateMachine: 프레임 판정 이력 → 디바운스된 상태
  (RED / GREEN / GREEN_BLINK / UNKNOWN) 및 상태 전환 이벤트
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field

import cv2
import numpy as np

# 프레임 단위 판정 값
RAW_RED = "RED"
RAW_GREEN = "GREEN"
RAW_NONE = "NONE"

# 상태 머신 상태
STATE_RED = "RED"
STATE_GREEN = "GREEN"
STATE_GREEN_BLINK = "GREEN_BLINK"
STATE_UNKNOWN = "UNKNOWN"

# 상태 → 음성 파일 key (voice.py)
VOICE_KEY = {
    STATE_RED: "red",
    STATE_GREEN: "green",
    STATE_GREEN_BLINK: "blink",
    STATE_UNKNOWN: "unknown",
}


@dataclass
class ColorStat:
    """한 색상 마스크의 분석 결과."""
    area_ratio: float = 0.0     # 최대 blob 면적 / ROI 면적
    circularity: float = 0.0    # 4πA/P² (원=1.0, 보행자 아이콘은 낮음)
    aspect_ratio: float = 0.0   # bbox 가로/세로 (램프≈1, 7세그 숫자 획은 가늘고 김)
    valid: bool = False


@dataclass
class FrameResult:
    raw: str = RAW_NONE
    red: ColorStat = field(default_factory=ColorStat)
    green: ColorStat = field(default_factory=ColorStat)
    red_mask: np.ndarray | None = None
    green_mask: np.ndarray | None = None
    brightness: float = 0.0   # ROI 평균 밝기 (HSV V)
    reason: str = ""          # raw=NONE인 이유: too_dark / brightness_jump /
                              # blob_too_large / no_blob (신뢰도 판단 근거)


class ColorDetector:
    """HSV 색상 마스킹 + blob 분석으로 프레임 단위 판정을 낸다.

    신뢰도 낮은 프레임은 정직하게 NONE 처리한다 (reason에 근거 기록):
    - too_dark: ROI 평균 밝기가 임계 미만 (렌즈/ROI 가림)
    - brightness_jump: 평균 밝기가 이동평균 대비 급변 (가림/조명 급변 순간)
    - blob_too_large: 검출 blob이 ROI 대부분을 덮음 (신호등이 아닌 물체)
    - no_blob: 유효한 색상 blob 없음

    검출 히스테리시스: 직전 프레임에 검출된 색은 면적 임계를 완화해
    (exit_factor 배) 경계값 부근에서 GREEN↔NONE이 튀는 것을 줄인다.
    """

    def __init__(self, cfg: dict):
        self.red_ranges = [
            (np.array(r["lower"]), np.array(r["upper"])) for r in cfg["hsv"]["red"]
        ]
        self.green_ranges = [
            (np.array(r["lower"]), np.array(r["upper"])) for r in cfg["hsv"]["green"]
        ]
        self.min_area_ratio = cfg["min_area_ratio"]
        self.max_area_ratio = cfg["max_area_ratio"]
        # 참고: 차량 신호(원형)는 0.6+, 보행자 아이콘(사람 모양)은 0.2~0.4 수준
        self.min_circularity = cfg["min_circularity"]
        # 램프 bbox 종횡비 허용 범위(7세그 숫자 획 배제). 실측 근거는 _analyze 주석.
        self.min_aspect_ratio = cfg.get("min_aspect_ratio", 0.45)
        self.max_aspect_ratio = cfg.get("max_aspect_ratio", 2.2)
        self.min_brightness = cfg["min_brightness"]
        self.brightness_jump = cfg["brightness_jump"]
        self.ema_alpha = cfg["brightness_ema_alpha"]
        self.valid_exit_factor = cfg["valid_exit_factor"]
        k = cfg["morph_kernel"]
        self._kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k))
        self._brightness_ema: float | None = None
        self._last_raw = RAW_NONE

    def _mask(self, hsv: np.ndarray, ranges) -> np.ndarray:
        mask = None
        for lower, upper in ranges:
            m = cv2.inRange(hsv, lower, upper)
            mask = m if mask is None else cv2.bitwise_or(mask, m)
        if mask is None:
            return np.zeros(hsv.shape[:2], np.uint8)
        mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, self._kernel)
        mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, self._kernel)
        return mask

    def _analyze(self, mask: np.ndarray, roi_area: int,
                 min_area_ratio: float) -> ColorStat:
        contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL,
                                       cv2.CHAIN_APPROX_SIMPLE)
        if not contours:
            return ColorStat()
        largest = max(contours, key=cv2.contourArea)
        area = cv2.contourArea(largest)
        perimeter = cv2.arcLength(largest, True)
        circularity = (4 * np.pi * area / (perimeter * perimeter)
                       if perimeter > 0 else 0.0)
        area_ratio = area / roi_area
        _, _, bw, bh = cv2.boundingRect(largest)
        aspect_ratio = bw / bh if bh > 0 else 0.0
        # 신호등 램프는 bbox가 정사각형에 가깝다. 잔여시간 7세그 숫자의 획은
        # 가늘고 길어(실측 0.12~0.42) 면적·원형도만으로는 걸러지지 않는다.
        # ROI를 좁힐수록 숫자가 면적 기준을 넘기므로 형태로 배제한다.
        shape_ok = (self.min_aspect_ratio <= aspect_ratio
                    <= self.max_aspect_ratio)
        valid = (min_area_ratio <= area_ratio <= self.max_area_ratio
                 and circularity >= self.min_circularity and shape_ok)
        return ColorStat(area_ratio, circularity, aspect_ratio, valid)

    def detect(self, roi_bgr: np.ndarray) -> FrameResult:
        blurred = cv2.GaussianBlur(roi_bgr, (5, 5), 0)
        hsv = cv2.cvtColor(blurred, cv2.COLOR_BGR2HSV)
        roi_area = roi_bgr.shape[0] * roi_bgr.shape[1]
        brightness = float(hsv[..., 2].mean())

        if self._brightness_ema is None:
            self._brightness_ema = brightness
        jumped = abs(brightness - self._brightness_ema) > self.brightness_jump
        self._brightness_ema += self.ema_alpha * (brightness - self._brightness_ema)

        # 마스크는 신뢰도와 무관하게 계산 (디버그 뷰 표시용)
        red_mask = self._mask(hsv, self.red_ranges)
        green_mask = self._mask(hsv, self.green_ranges)

        def thr(color_raw: str) -> float:
            if self._last_raw == color_raw:
                return self.min_area_ratio * self.valid_exit_factor
            return self.min_area_ratio

        red = self._analyze(red_mask, roi_area, thr(RAW_RED))
        green = self._analyze(green_mask, roi_area, thr(RAW_GREEN))

        reason = ""
        if brightness < self.min_brightness:
            raw, reason = RAW_NONE, "too_dark"
        elif jumped:
            raw, reason = RAW_NONE, "brightness_jump"
        elif red.valid and green.valid:
            raw = RAW_RED if red.area_ratio >= green.area_ratio else RAW_GREEN
        elif red.valid:
            raw = RAW_RED
        elif green.valid:
            raw = RAW_GREEN
        else:
            raw = RAW_NONE
            oversized = max(red.area_ratio, green.area_ratio)
            reason = ("blob_too_large" if oversized > self.max_area_ratio
                      else "no_blob")

        self._last_raw = raw
        return FrameResult(raw=raw, red=red, green=green,
                           red_mask=red_mask, green_mask=green_mask,
                           brightness=brightness, reason=reason)


@dataclass
class Transition:
    t: float
    old: str
    new: str


class SignalStateMachine:
    """디바운스 + 점멸 감지 상태 머신.

    매 프레임 update(t, raw)를 호출한다. t는 영상 입력이면 프레임 시각
    (frame_idx / fps), 카메라면 경과 시간(초). 상태가 바뀔 때만
    Transition을 반환하므로 음성은 전환당 정확히 1회 재생된다.

    디바운스는 raw 판정의 '연속' 횟수를 그대로 센다 — 판정이 조금이라도
    흔들리면 카운트가 리셋되어 안내가 나가지 않는 안전한 방향으로 실패한다.

    판정 우선순위(매 프레임):
      1. RED 연속 N프레임          → RED   (빨강은 점멸 패턴과 무관하므로 최우선)
      2. GREEN↔NONE 토글 ≥ M회/2초 → GREEN_BLINK
      3. GREEN 연속 N프레임        → GREEN (점멸 켜짐 구간의 연속 GREEN은 2가 먼저 잡음)
      4. NONE 지속 ≥ 1.5초         → UNKNOWN (점멸 꺼짐 구간(~0.5초)보다 길어야 함)

    점멸 이탈 히스테리시스: 진입은 토글 ≥ M이지만, GREEN_BLINK에서 GREEN으로
    복귀하려면 윈도에 토글이 0이어야 한다(2초간 완전 안정). 느린 점멸에서
    토글 수가 임계 경계에 걸려 GREEN↔BLINK가 플래핑하는 것을 막는다.

    판정 보류 NONE(reason이 too_dark/brightness_jump/blob_too_large/
    camera_fail)은 '실제 소등'과 구분해 점멸 이력에 넣지 않는다 — 모니터
    촬영 시 노출 변동으로 생기는 NONE 런이 가짜 점멸로 집계되는 것을 막는다.
    UNKNOWN 전환용 NONE 지속시간에는 그대로 포함된다(정직 상태 경로 유지).
    """

    HOLD_REASONS = frozenset(
        {"too_dark", "brightness_jump", "blob_too_large", "camera_fail"})

    def __init__(self, cfg: dict):
        self.state = STATE_UNKNOWN  # 초기 상태 (시작 시 안내 없음)
        self.debounce_frames = cfg["debounce_frames"]
        self.blink_window = cfg["blink_window_seconds"]
        self.blink_min_toggles = cfg["blink_min_toggles"]
        self.blink_min_segment = cfg["blink_min_segment_seconds"]
        self.unknown_after = cfg["unknown_after_seconds"]

        self._consec_raw = None
        self._consec_count = 0
        self._history: deque[tuple[float, str]] = deque()  # (t, raw)
        self._last_active_t: float | None = None  # 마지막으로 NONE이 아니었던 시각

    def _count_blink_toggles(self, now: float) -> int:
        """윈도 내 GREEN↔NONE 토글 수. 토글 양쪽 구간이 모두 최소 지속시간
        (blink_min_segment) 이상일 때만 센다 — 검출 경계에서 튀는 짧은
        플리커가 가짜 점멸로 잡히는 것을 막는다 (실제 점멸은 ~0.5초 구간)."""
        runs = []  # (값, 시작 시각)
        for t, v in self._history:
            if not runs or runs[-1][0] != v:
                runs.append((v, t))
        toggles = 0
        for i in range(1, len(runs)):
            a, start_a = runs[i - 1]
            b, start_b = runs[i]
            if {a, b} != {RAW_GREEN, RAW_NONE}:
                continue
            dur_a = start_b - start_a
            dur_b = (runs[i + 1][1] if i + 1 < len(runs) else now) - start_b
            if dur_a >= self.blink_min_segment and dur_b >= self.blink_min_segment:
                toggles += 1
        return toggles

    def resume(self) -> None:
        """블로킹 UI(ROI 선택 등)로 시간이 점프한 뒤 호출. 상태는 유지하되
        시간 기반 이력을 비워 가짜 UNKNOWN/전환이 나가지 않게 한다."""
        self._history.clear()
        self._consec_raw = None
        self._consec_count = 0
        self._last_active_t = None

    def update(self, t: float, raw: str, reason: str = "") -> Transition | None:
        if raw == self._consec_raw:
            self._consec_count += 1
        else:
            self._consec_raw = raw
            self._consec_count = 1

        # 판정 보류 NONE은 점멸 이력에서 제외 (실제 소등 no_blob만 집계)
        if not (raw == RAW_NONE and reason in self.HOLD_REASONS):
            self._history.append((t, raw))
        while self._history and self._history[0][0] < t - self.blink_window:
            self._history.popleft()

        if raw != RAW_NONE:
            self._last_active_t = t
        elif self._last_active_t is None:
            self._last_active_t = t  # 시작부터 NONE이면 여기서부터 지속 시간 측정

        debounced = self._consec_count >= self.debounce_frames
        none_duration = t - self._last_active_t

        toggles = self._count_blink_toggles(t)
        blink_exit_ok = self.state != STATE_GREEN_BLINK or toggles == 0

        target = None
        if raw == RAW_RED and debounced:
            target = STATE_RED
        elif toggles >= self.blink_min_toggles:
            target = STATE_GREEN_BLINK
        elif raw == RAW_GREEN and debounced and blink_exit_ok:
            target = STATE_GREEN
        elif raw == RAW_NONE and none_duration >= self.unknown_after:
            target = STATE_UNKNOWN

        if target is not None and target != self.state:
            old = self.state
            self.state = target
            return Transition(t=t, old=old, new=target)
        return None
