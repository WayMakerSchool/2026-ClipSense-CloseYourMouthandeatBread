"""보행 신호등 몸체를 찾아 그 안의 램프 색과 옆 잔여시간 숫자를 읽는다.

중앙 고정 ROI 대신 사진 전체에서 신호등을 찾는다. 판독 규칙:
- 신호등 몸체 = 어두운 세로 직사각형(높이/폭 1.4~3.2, 사각형 채움 0.75 이상).
- 빨강은 몸체 **위 칸**, 초록은 **아래 칸**에서만 인정한다. 보행 신호등의 램프
  배치와 같다. 몸체 밖의 색 물체나 칸이 뒤바뀐 색은 신호로 보지 않는다.
- 잔여시간 숫자 = 몸체 오른쪽, 아래 램프 높이에 있는 어두운 상자의 빨간 7-세그먼트.
  숫자는 판단을 더 조심스럽게 만드는 데만 쓴다(judge에서 API보다 짧으면 WAIT).

정직성: 몸체를 못 찾거나 두 칸이 동시에 켜지면 NONE(확인 불가)이다.
"""
from __future__ import annotations

import copy
from dataclasses import dataclass, field

import cv2
import numpy as np

from detector import RAW_GREEN, RAW_NONE, RAW_RED, ColorDetector
from digits import DigitReader

# 몸체로 볼 '어두움' 기준. 휴대폰 화면·조명에 따라 검정이 회색으로 뜨므로(실측 몸체 V≈80,
# 배경 V≈196) 고정값 대신 사진 밝기 중간값의 60%를 쓰고 120을 넘기지 않는다.
DARK_FRACTION = 0.6
DARK_V_MAX = 120
MIN_HEAD_AREA = 0.01   # 몸체 bbox 최소 면적(사진 대비)
HEAD_ASPECT = (1.4, 3.2)
MIN_RECT_FILL = 0.75   # 윤곽 면적 / bbox 면적 — 직사각형다움
# 숫자 상자는 숫자가 테두리에 가까우면 어두운 테두리가 얇아져 윤곽이 오목해진다.
MIN_BOX_FILL = 0.5
# 숫자 상자 안 빨강 기준. QVGA JPEG은 색차를 절반 해상도로 저장해 획 둘레가 어두운
# 빨강으로 번진다(기본 digits.red_hsv S≥100·V≥80으로는 합성 0~99 중 70개 판독 불가).
# 번짐은 밝기가 낮아 V 기준이 걸러낸다. 휴대폰 화면을 클립 카메라로 찍으면 채도가
# 떨어진다(2026-10-22 실측 숫자 획 S≈99·V≈166). S≥80·V≥130에서 실측 '11'과 합성 0~99를
# 모두 읽었다.
DIGIT_RED_HSV = [{'lower': [0, 80, 130], 'upper': [10, 255, 255]},
                 {'lower': [170, 80, 130], 'upper': [180, 255, 255]}]


@dataclass
class HeadResult:
    raw: str = RAW_NONE
    reason: str = ''
    head: list | None = None        # [x, y, w, h]
    lamp: list | None = None        # 판독에 쓴 칸
    digit_box: list | None = None
    digits_frame: int | None = None  # 이 프레임 즉석 판독
    digits: int | None = None        # 최근 프레임 다수결 확정값
    red_area: float = 0.0
    green_area: float = 0.0
    boxes: list = field(default_factory=list)


def _dark_rects(image_bgr):
    """어두운 영역의 바깥 윤곽 → (bbox, 채움비율) 목록. 켜진 램프·숫자는 구멍이라 무시된다."""
    hsv = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2HSV)
    dark_v = int(min(DARK_V_MAX, DARK_FRACTION * float(np.median(hsv[..., 2]))))
    dark = cv2.inRange(hsv[..., 2], 0, dark_v)
    dark = cv2.morphologyEx(dark, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    contours, _ = cv2.findContours(dark, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    out = []
    for c in contours:
        x, y, w, h = cv2.boundingRect(c)
        if w < 4 or h < 4:
            continue
        out.append(((x, y, w, h), cv2.contourArea(c) / float(w * h)))
    return out


class SignalHeadReader:
    def __init__(self, cfg: dict):
        # 칸 안에서는 램프가 켜질 때 밝기가 크게 뛰는 것이 정상이다. 기존 검출기의
        # 밝기 급변 거부를 끄고, 몸체를 찾았다는 구조 조건을 신뢰 근거로 삼는다.
        head_cfg = copy.deepcopy(cfg)
        head_cfg['brightness_jump'] = 256
        self.top = ColorDetector(head_cfg)
        self.bottom = ColorDetector(head_cfg)
        digit_cfg = copy.deepcopy(cfg)
        digit_cfg.setdefault('digits', {})['red_hsv'] = DIGIT_RED_HSV
        self.digits = DigitReader(digit_cfg)

    def locate(self, image_bgr):
        H, W = image_bgr.shape[:2]
        rects = _dark_rects(image_bgr)
        heads = [(r, fill) for r, fill in rects
                 if r[2] * r[3] >= MIN_HEAD_AREA * W * H
                 and HEAD_ASPECT[0] <= r[3] / r[2] <= HEAD_ASPECT[1]
                 and fill >= MIN_RECT_FILL
                 and r[0] > 0 and r[1] > 0 and r[0] + r[2] < W and r[1] + r[3] < H]
        if not heads:
            return None, None
        head = max(heads, key=lambda t: t[0][2] * t[0][3])[0]
        hx, hy, hw, hh = head
        lamp_cy = hy + 0.75 * hh
        box = None
        for (x, y, w, h), fill in rects:
            # 몸체 오른쪽, 아래 램프 높이의 어두운 상자 (몸체 높이의 15~60%)
            if (x >= hx + hw and x - (hx + hw) <= hw and fill >= MIN_BOX_FILL
                    and 0.15 * hh <= h <= 0.6 * hh and abs(y + h / 2 - lamp_cy) <= 0.2 * hh):
                if box is None or x < box[0]:
                    box = (x, y, w, h)
        return head, box

    def read(self, image_bgr) -> HeadResult:
        head, box = self.locate(image_bgr)
        if head is None:
            self.digits.read(None)
            return HeadResult(reason='no_signal_head')
        hx, hy, hw, hh = head
        half = hh // 2
        top = self.top.detect(image_bgr[hy:hy + half, hx:hx + hw])
        bottom = self.bottom.detect(image_bgr[hy + half:hy + hh, hx:hx + hw])
        red_on, green_on = top.red.valid, bottom.green.valid
        result = HeadResult(head=list(head), red_area=top.red.area_ratio,
                            green_area=bottom.green.area_ratio)
        if red_on and green_on:
            result.raw, result.reason = RAW_NONE, 'both_lamps'
        elif red_on:
            result.raw, result.lamp = RAW_RED, [hx, hy, hw, half]
        elif green_on:
            result.raw, result.lamp = RAW_GREEN, [hx, hy + half, hw, hh - half]
        else:
            result.reason = 'lamp_off'
        if box is not None:
            x, y, w, h = box
            m = max(1, min(w, h) // 12)  # 상자 테두리 안쪽만 본다
            crop = image_bgr[y + m:y + h - m, x + m:x + w - m]
            result.digit_box = list(box)
            result.digits_frame = self.digits.read_frame(crop)
            result.digits = self.digits.read(crop)
        else:
            result.digits = self.digits.read(None)
        result.boxes = [{'label': '신호등', 'rect': result.head}]
        if result.lamp:
            result.boxes.append({'label': '램프', 'rect': result.lamp})
        if result.digit_box:
            result.boxes.append({'label': '숫자', 'rect': result.digit_box})
        return result


def draw_signal_head(image, x, y, w, h, phase, lamp_on=True, digits=None,
                     housing=(16, 16, 16), off=(38, 38, 38)):
    """테스트·연습용 합성 신호등(그리기 전용). phase: red | green | clearance."""
    from digits import draw_seven_segment
    cv2.rectangle(image, (x, y), (x + w - 1, y + h - 1), housing, -1)
    r = int(0.37 * w)
    red = (0, 0, 255) if phase == 'red' else off
    green = (0, 224, 0) if phase in ('green', 'clearance') and lamp_on else off
    cv2.circle(image, (x + w // 2, y + h // 4), r, red, -1)
    cv2.circle(image, (x + w // 2, y + 3 * h // 4), r, green, -1)
    bx, bh, bw = x + w + max(2, w // 8), int(0.31 * h), int(0.86 * w)
    by = y + 3 * h // 4 - bh // 2
    cv2.rectangle(image, (bx, by), (bx + bw - 1, by + bh - 1), housing, -1)
    if digits is not None and phase != 'red':
        dh = int(bh * 0.7)
        dw = int(dh * 0.55)
        # 자릿수 사이 간격이 좁으면 JPEG 색 번짐(색차 절반 해상도)·흐림 뒤 두 자리가 붙어
        # '12'를 못 읽는다. QVGA JPEG 실측으로 숫자 폭의 80%는 띄워야 분리된다.
        gap = max(4, int(dw * 0.8))
        text_w = len(str(digits)) * dw + (len(str(digits)) - 1) * gap
        draw_seven_segment(image, digits, bx + (bw - text_w) // 2, by + (bh - dh) // 2,
                           dw, dh, (0, 0, 255), gap=gap)
    return (bx, by, bw, bh)
