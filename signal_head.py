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

# 몸체로 볼 '어두움' 기준. 휴대폰 화면을 찍으면 몸체 V≈80, 꺼진 램프 V≈100~110, 배경 V≈170~196
# 이다(2026-10-22 실측). 고정 비율(중간값×0.6≈98)은 꺼진 램프를 몸체에서 떨어뜨려 몸체가 반토막
# 났다. 밝기 분포를 두 무리로 나누는 Otsu 값(중간값×0.85 이하)을 쓰고, 켜진 램프·숫자처럼 선명한
# 색 픽셀(LIT_HSV)도 몸체 마스크에 합친다. 실사진 기록 세션에서 빨강 2%→39%, 초록 0%→41%.
DARK_MEDIAN_CAP = 0.85
LIT_HSV = ((0, 80, 120), (180, 255, 255))
MIN_HEAD_AREA = 0.01   # 몸체 bbox 최소 면적(사진 대비)
HEAD_ASPECT = (1.3, 3.2)
MIN_RECT_FILL = 0.65   # 윤곽 면적 / bbox 면적 — 직사각형다움(흐린 실사진 기준)
# 칸 안에서는 켜진 램프가 칸의 60% 이상을 덮는 것이 정상이다(실측 0.71). 기존 검출기의
# '너무 큰 덩어리 = 신호등 아님' 상한(0.6)을 칸 검사에서만 올린다.
CELL_MAX_AREA = 0.95
# 추적: 이번 사진에서 몸체를 못 찾아도 최근 TRACK_MAX_MISSES장 안에 찾은 자리가 여전히 몸체처럼
# (몸체 마스크가 TRACK_MIN_FILL 이상 채움) 보이면 그 자리로 램프·숫자를 읽는다. 카메라가 딴 곳을
# 보면 그 자리가 몸체처럼 보이지 않아 추적하지 않는다. 실사진 1,915장 재판독: 맞는 안내 321→355,
# 빨간 화면에 초록 계열 6→6, 초록 화면에 빨강 5→5, 점멸 확정 전 '초록' 18→20(모두 대기 안내).
TRACK_MAX_MISSES = 2
TRACK_MIN_FILL = 0.6
# 숫자 상자가 있어야 할 자리(몸체 크기 대비). 작은 교차로 화면 배치(몸체 35×70, 간격 4,
# 상자 34×22, 아래 램프 높이)와 같다. 상자 윤곽을 따로 못 찾았을 때만 쓴다.
BOX_GEOMETRY = {'gap': 4 / 35, 'width': 34 / 35, 'height': 22 / 70, 'center_y': 0.75}
# 숫자 상자는 숫자가 테두리에 가까우면 어두운 테두리가 얇아져 윤곽이 오목해진다.
MIN_BOX_FILL = 0.5
# 숫자 상자 안 빨강 기준과 7-세그먼트 판정값(신호등 모드 전용, main.py의 digits 설정은 그대로).
# 2026-10-22 실사진 기록 세션(숫자 상자 300장, 정답=작은 교차로 남은 초)에서 앞 절반으로 고르고
# 뒤 절반으로 검증했다: 기존(S≥80·V≥130, 켜짐 0.5·꺼짐 0.2·채움 0.65) 60개 정답/2개 오답 →
# 아래 값 71개/1개. 합성 JPEG 0~99는 100개 모두 읽는다. 획 둘레 JPEG 번짐은 V가 낮아 V≥160이
# 걸러내고, 휴대폰 화면 촬영은 채도가 낮아 S 기준은 50으로 둔다.
DIGIT_PARAMS = {'seg_on_ratio': 0.4, 'seg_off_ratio': 0.25, 'max_cell_fill': 0.75}
# 휴대폰 밝기를 낮추면 숫자 획이 어두워져(실측 V≈128) 고정 기준(V≥160)을 못 넘는다. 고정 기준으로
# 못 읽을 때만, 숫자 상자 안 '빨간 정도(R−max(G,B))' 분포에서 Otsu로 기준을 정해 다시 읽는다.
# 실사진 300장(앞 절반으로 고르고 뒤 절반으로 검증): 원래 밝기 정답 71→78, 밝기 75%·60%로 낮춘
# 사진에서 0→57·52. 오답은 1→2·3·1, 빈 상자(빨강 신호 238장)에서 숫자 0건, 합성 0~99 모두 읽음.
ADAPTIVE_DIGITS = {'min_redness': 25, 'min_otsu': 15,
                   'params': {'seg_on_ratio': 0.5, 'seg_off_ratio': 0.3, 'max_cell_fill': 0.75}}
DIGIT_RED_HSV = [{'lower': [0, 50, 160], 'upper': [10, 255, 255]},
                 {'lower': [170, 50, 160], 'upper': [180, 255, 255]}]


class _RednessDigitReader(DigitReader):
    """숫자 상자 안에서 빨간 정도의 분포로 기준을 정하는 판독기(어두운 화면용)."""
    def _mask(self, roi_bgr):
        b = cv2.GaussianBlur(roi_bgr, (3, 3), 0).astype(np.int16)
        red = np.clip(b[..., 2] - np.maximum(b[..., 1], b[..., 0]), 0, 255).astype(np.uint8)
        empty = np.zeros(red.shape, np.uint8)
        if red.size == 0 or int(red.max()) < ADAPTIVE_DIGITS['min_redness']:
            return empty  # 빨간 것이 없다 = 빈 상자
        t, mask = cv2.threshold(red, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
        if t < ADAPTIVE_DIGITS['min_otsu']:
            return empty  # 숫자와 배경이 갈리지 않는다
        return cv2.morphologyEx(mask, cv2.MORPH_CLOSE, self._kernel)


class HeadDigitReader(DigitReader):
    """고정 기준으로 먼저 읽고, 못 읽으면 빨간 정도 분포 기준으로 다시 읽는다. 시간 다수결은 그대로."""
    def __init__(self, fixed_cfg, adaptive_cfg):
        super().__init__(fixed_cfg)
        self._fallback = _RednessDigitReader(adaptive_cfg)

    def read_frame(self, roi_bgr):
        value = super().read_frame(roi_bgr)
        return value if value is not None else self._fallback.read_frame(roi_bgr)


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
    tracked: bool = False            # 이번 사진에서 몸체를 새로 찾지 못해 직전 위치를 이어 썼는가


def _head_mask(image_bgr):
    """몸체 후보 마스크: 어두운 픽셀 ∪ 선명한 색 픽셀(켜진 램프·숫자)."""
    hsv = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2HSV)
    v = hsv[..., 2]
    otsu, _ = cv2.threshold(cv2.GaussianBlur(v, (5, 5), 0), 0, 255,
                            cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    dark_v = int(min(otsu, DARK_MEDIAN_CAP * float(np.median(v))))
    mask = cv2.bitwise_or(cv2.inRange(v, 0, dark_v), cv2.inRange(hsv, *LIT_HSV))
    kernel = np.ones((3, 3), np.uint8)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)
    return cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)


def _dark_rects(image_bgr):
    """몸체 후보 마스크의 바깥 윤곽 → (bbox, 채움비율) 목록."""
    contours, _ = cv2.findContours(_head_mask(image_bgr), cv2.RETR_EXTERNAL,
                                   cv2.CHAIN_APPROX_SIMPLE)
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
        head_cfg['max_area_ratio'] = CELL_MAX_AREA
        self.top = ColorDetector(head_cfg)
        self.bottom = ColorDetector(head_cfg)
        digit_cfg = copy.deepcopy(cfg)
        digit_cfg.setdefault('digits', {})['red_hsv'] = DIGIT_RED_HSV
        digit_cfg['digits'].update(DIGIT_PARAMS)
        adaptive_cfg = copy.deepcopy(digit_cfg)
        adaptive_cfg['digits'].update(ADAPTIVE_DIGITS['params'])
        self.digits = HeadDigitReader(digit_cfg, adaptive_cfg)
        self._last_head = None
        self._last_box = None
        self._misses = 0

    def _track(self, image_bgr):
        """직전에 찾은 몸체 자리가 아직 몸체처럼 보이면 (head, box), 아니면 (None, None)."""
        if self._last_head is None or self._misses >= TRACK_MAX_MISSES:
            return None, None
        x, y, w, h = self._last_head
        region = _head_mask(image_bgr)[y:y + h, x:x + w]
        if region.size == 0 or region.mean() / 255 < TRACK_MIN_FILL:
            return None, None
        return self._last_head, self._last_box

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
        if box is None:
            box = self._box_at_expected_place(image_bgr, head)
        return head, box

    @staticmethod
    def _box_at_expected_place(image_bgr, head):
        """따로 떨어진 숫자 상자 윤곽이 없을 때(휴대폰 테두리 등과 붙은 경우), 몸체 오른쪽
        아래 램프 높이의 '있어야 할 자리'만 잘라 그 안의 어두운/숫자 픽셀 범위를 상자로 본다.
        잘못 자르면 DigitReader가 None을 내므로 틀린 숫자로 이어지지 않는다."""
        H, W = image_bgr.shape[:2]
        hx, hy, hw, hh = head
        cy = hy + BOX_GEOMETRY['center_y'] * hh
        x0 = int(hx + hw + BOX_GEOMETRY['gap'] * hw)
        x1 = int(x0 + BOX_GEOMETRY['width'] * hw)
        y0 = int(cy - BOX_GEOMETRY['height'] * hh / 2)
        y1 = int(cy + BOX_GEOMETRY['height'] * hh / 2)
        if x0 >= W - 4 or y0 < 0 or y1 > H:
            return None
        x1 = min(x1, W)
        roi = _head_mask(image_bgr)[y0:y1, x0:x1]
        if roi.size == 0 or roi.mean() / 255 < 0.5:
            return None
        cols = np.flatnonzero(roi.mean(axis=0) > 127)
        rows = np.flatnonzero(roi.mean(axis=1) > 127)
        if cols.size < 4 or rows.size < 4:
            return None
        return (x0 + int(cols[0]), y0 + int(rows[0]),
                int(cols[-1] - cols[0] + 1), int(rows[-1] - rows[0] + 1))

    def read(self, image_bgr) -> HeadResult:
        head, box = self.locate(image_bgr)
        tracked = False
        if head is None:
            head, box = self._track(image_bgr)
            tracked = head is not None
        if head is None:
            self._misses += 1
            self.digits.read(None)
            return HeadResult(reason='no_signal_head')
        if tracked:
            self._misses += 1
        else:
            self._last_head, self._last_box, self._misses = head, box, 0
        hx, hy, hw, hh = head
        half = hh // 2
        top = self.top.detect(image_bgr[hy:hy + half, hx:hx + hw])
        bottom = self.bottom.detect(image_bgr[hy + half:hy + hh, hx:hx + hw])
        red_on, green_on = top.red.valid, bottom.green.valid
        result = HeadResult(head=list(head), red_area=top.red.area_ratio,
                            green_area=bottom.green.area_ratio, tracked=tracked)
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
