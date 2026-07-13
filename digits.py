"""잔여 시간 숫자 읽기 (5단계, 선택 기능) — 7-세그먼트 디코딩, 딥러닝 없음.

보행 신호 잔여시간 표시기는 붉은 LED 7-세그먼트 형태가 표준적이다.
숫자 ROI → 빨강 마스크 → 열 투영으로 자릿수 분리 → 자릿수별 7개
세그먼트 영역 샘플링 → 패턴 테이블 디코딩.

정직성 원칙: 모든 자릿수가 유효 패턴으로 디코딩될 때만 값을 내고,
아니면 None("판독 불가"). 시간 안정화(최근 5프레임 다수결)까지 통과해야
stable 값이 된다. 어설픈 추측은 하지 않는다.
"""

from collections import Counter, deque

import cv2
import numpy as np

# 세그먼트 이름: a=상단, b=우상, c=우하, d=하단, e=좌하, f=좌상, g=중앙
DIGIT_PATTERNS = {
    "abcdef": 0, "bc": 1, "abged": 2, "abgcd": 3, "fgbc": 4,
    "afgcd": 5, "afgedc": 6, "abc": 7, "abcdefg": 8, "abcdfg": 9,
}
# 정규화 좌표 (x1, y1, x2, y2) — 자릿수 셀 안에서 각 세그먼트를 샘플링할 영역
SEGMENT_REGIONS = {
    "a": (0.25, 0.00, 0.75, 0.18),
    "b": (0.70, 0.12, 1.00, 0.44),
    "c": (0.70, 0.56, 1.00, 0.88),
    "d": (0.25, 0.82, 0.75, 1.00),
    "e": (0.00, 0.56, 0.30, 0.88),
    "f": (0.00, 0.12, 0.30, 0.44),
    "g": (0.25, 0.41, 0.75, 0.59),
}


def _normalize_pattern(segs: set[str]) -> str:
    return "".join(sorted(segs))


# 패턴 테이블을 정렬 키로 재색인
_PATTERNS_SORTED = {_normalize_pattern(set(k)): v for k, v in DIGIT_PATTERNS.items()}


class DigitReader:
    def __init__(self, cfg: dict):
        d = cfg.get("digits", {})
        # 숫자 판독은 신호등 검출과 요구가 다르다: 신호등 빨강 범위는 어두운
        # LED까지 잡으려 넓게 잡지만, 숫자는 범위가 넓으면 세그먼트가 뭉쳐
        # 오판이 난다. 그래서 digits.red_hsv가 있으면 그걸 우선 쓰고,
        # 없으면 신호등 빨강 범위로 폴백한다.
        red_cfg = d.get("red_hsv") or cfg["hsv"]["red"]
        self.red_ranges = [
            (np.array(r["lower"]), np.array(r["upper"])) for r in red_cfg
        ]
        self.seg_on_ratio = d.get("seg_on_ratio", 0.5)    # 이 이상이면 세그먼트 점등
        self.seg_off_ratio = d.get("seg_off_ratio", 0.2)  # 이 이하면 소등. 사이면 모호→None
        self.min_fill = d.get("min_cell_fill", 0.08)      # 셀 최소 점등 비율
        self.max_fill = d.get("max_cell_fill", 0.65)      # 초과 시 단색 블롭(숫자 아님)
        # 한 자리 셀 종횡비 상한. 정상 한 자리는 ~0.5~0.6, 카운트다운 '4'가 0.80.
        # 뭉친 두 자리(0.83+)·회전으로 넓어진 '4'(0.86)는 이 위라 None으로 거부된다.
        self.max_aspect = d.get("max_cell_aspect", 0.82)
        self.stable_window = d.get("stable_window", 5)    # 시간 다수결 창(프레임)
        self.stable_votes = d.get("stable_votes", 3)      # 다수결 최소 표
        self._kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
        self._recent: deque = deque(maxlen=self.stable_window)

    def _mask(self, roi_bgr: np.ndarray) -> np.ndarray:
        hsv = cv2.cvtColor(cv2.GaussianBlur(roi_bgr, (3, 3), 0), cv2.COLOR_BGR2HSV)
        mask = None
        for lower, upper in self.red_ranges:
            m = cv2.inRange(hsv, lower, upper)
            mask = m if mask is None else cv2.bitwise_or(mask, m)
        return cv2.morphologyEx(mask, cv2.MORPH_CLOSE, self._kernel)

    def _split_cells(self, mask: np.ndarray) -> list[np.ndarray]:
        """열 투영의 공백으로 자릿수 셀을 분리한다.

        심한 블러/번짐으로 자릿수 사이 공백이 메워져 두 자리가 한 셀로 뭉치면,
        폭이 한 자리 최대 종횡비(max_aspect)를 넘는다. 그런 셀은 폭을 셀 높이로
        나눠 자릿수를 추정하고 균등 분할해 실제로 쪼갠다 — 종횡비 상한 하나로
        '4'(넓은 한 자리)와 뭉침을 가르는 얇은 마진에 의존하지 않기 위함이다.
        """
        col_lit = mask.any(axis=0)
        if not col_lit.any():
            return []
        cells = []
        in_run = False
        start = 0
        for x, lit in enumerate(list(col_lit) + [False]):
            if lit and not in_run:
                in_run, start = True, x
            elif not lit and in_run:
                in_run = False
                cells.append((start, x))
        boxes = []
        for x1, x2 in cells:
            sub = mask[:, x1:x2]
            rows = np.flatnonzero(sub.any(axis=1))
            if rows.size == 0:
                continue
            boxes.append(sub[rows[0]:rows[-1] + 1, :])
        if not boxes:
            return []
        # 노이즈 셀 제거: 가장 큰 셀 높이의 60% 미만은 버림
        max_h = max(b.shape[0] for b in boxes)
        return [b for b in boxes if b.shape[0] >= 0.6 * max_h]
        # 참고: 심한 블러로 두 자리가 한 셀로 뭉친 경우 여기서 쪼개려 시도했으나,
        # 회전된 단일 '4'가 뭉친 두 자리와 종횡비(0.86 vs 0.83)·중앙 골 깊이
        # (0.17 vs 0.4~0.5) 양쪽에서 완전히 겹쳐 기하 규칙으로 구분 불가함을
        # 실측했다. 따라서 재분할하지 않고, 넓은 뭉친 셀은 _decode_cell의 종횡비
        # 안전망이 None으로 거부한다 — "어설픈 인식보다 None"(브리프 원칙).

    def _seg_ratio(self, cell: np.ndarray, region_key: str) -> float:
        h, w = cell.shape
        nx1, ny1, nx2, ny2 = SEGMENT_REGIONS[region_key]
        x1, x2 = int(nx1 * w), max(int(nx1 * w) + 1, int(nx2 * w))
        y1, y2 = int(ny1 * h), max(int(ny1 * h) + 1, int(ny2 * h))
        region = cell[y1:y2, x1:x2]
        return region.mean() / 255.0 if region.size else 0.0

    def _decode_cell(self, cell: np.ndarray) -> int | None:
        h, w = cell.shape
        if h < 8 or w < 2:
            return None
        fill = cell.mean() / 255.0
        if fill < self.min_fill:
            return None

        # '1'은 b·c 세로열만 켜져 셀이 매우 좁고 거의 꽉 찬다(fill이 높음).
        # 세그먼트 영역 샘플링·fill 상한 검사보다 먼저 처리해야 한다 —
        # 안 그러면 좁고 꽉 찬 '1'이 단색 블롭으로 오인돼 걸러진다.
        # 진짜 '1'의 폭은 세그먼트 두께 수준(≈0.12~0.25h)이라 임계를 0.30h로
        # 두면 '3'(폭 ≥0.35h)이 섞이지 않고, 거의 모든 행이 세로로 채워져야 한다.
        if w < 0.30 * h:
            col_cov = (cell.mean(axis=0) / 255.0 >= self.seg_on_ratio)
            row_cov = (cell.mean(axis=1) / 255.0 >= self.seg_on_ratio).mean()
            return 1 if (col_cov.mean() > 0.6 and row_cov > 0.8) else None

        # 한 자리치고 너무 넓은 셀 = 뭉친 두 자리이거나 회전으로 뭉개진 것.
        # 종횡비만으로는 회전된 '4'(0.86)와 뭉침(0.83)을 못 가르므로, 둘 다
        # None으로 거부한다 (추측 대신 정직한 포기). 카운트다운 '4'(0.80)는 통과.
        if w > self.max_aspect * h:
            return None

        # 셀 대부분이 채워짐 = 단색 빨강 블롭(등화/반사/스미어)이지 숫자가 아님.
        # '8'조차 바운딩 박스 fill은 ~0.5대라 상한을 넘지 않는다 → 정직하게 None.
        if fill > self.max_fill:
            return None

        # 이중 임계: on/off 사이 모호한 세그먼트가 하나라도 있으면 이 셀은
        # 판독 불가(None). 세그먼트 1개의 애매함이 이웃 숫자로 둔갑하는 것을 막는다.
        segs = set()
        for name in SEGMENT_REGIONS:
            r = self._seg_ratio(cell, name)
            if r >= self.seg_on_ratio:
                segs.add(name)
            elif r > self.seg_off_ratio:
                return None  # 모호 구간 → 정직하게 판독 포기
        return _PATTERNS_SORTED.get(_normalize_pattern(segs))

    def read_frame(self, roi_bgr: np.ndarray) -> int | None:
        """한 프레임 즉석 판독. 모든 자릿수가 유효할 때만 값, 아니면 None."""
        cells = self._split_cells(self._mask(roi_bgr))
        # 작은 노이즈 얼룩이 유령 숫자(특히 '1')로 읽히지 않게
        # 셀 높이가 ROI 높이의 35% 이상일 때만 숫자로 인정
        cells = [c for c in cells if c.shape[0] >= 0.35 * roi_bgr.shape[0]]
        if not 1 <= len(cells) <= 2:
            return None
        digits = [self._decode_cell(c) for c in cells]
        if any(d is None for d in digits):
            return None
        value = int("".join(str(d) for d in digits))
        return value

    def read(self, roi_bgr) -> int | None:
        """시간 안정화 판독: 최근 프레임 다수결로 확정된 값(없으면 None).

        roi_bgr=None은 '프레임 없음'(카메라 공백 등)으로 취급해 None을 투표에
        넣는다 — 공백 동안 이전 값이 stale하게 남는 것을 막는다.
        """
        self._recent.append(None if roi_bgr is None else self.read_frame(roi_bgr))
        counts = Counter(v for v in self._recent if v is not None)
        if not counts:
            return None
        value, votes = counts.most_common(1)[0]
        return value if votes >= self.stable_votes else None


def draw_seven_segment(img: np.ndarray, number: int, x: int, y: int,
                       digit_w: int, digit_h: int, color, gap: int = 6) -> None:
    """합성 테스트 영상용 7-세그먼트 숫자 그리기 (검증 대상 아님, 그리기 전용)."""
    text = str(number)
    th = max(2, digit_h // 8)  # 세그먼트 두께
    for i, ch in enumerate(text):
        d = int(ch)
        on = set(next(k for k, v in DIGIT_PATTERNS.items() if v == d))
        ox = x + i * (digit_w + gap)
        seg_rects = {
            "a": (ox + th, y, ox + digit_w - th, y + th),
            "b": (ox + digit_w - th, y + th, ox + digit_w, y + digit_h // 2 - th // 2),
            "c": (ox + digit_w - th, y + digit_h // 2 + th // 2,
                  ox + digit_w, y + digit_h - th),
            "d": (ox + th, y + digit_h - th, ox + digit_w - th, y + digit_h),
            "e": (ox, y + digit_h // 2 + th // 2, ox + th, y + digit_h - th),
            "f": (ox, y + th, ox + th, y + digit_h // 2 - th // 2),
            "g": (ox + th, y + digit_h // 2 - th // 2,
                  ox + digit_w - th, y + digit_h // 2 + th // 2),
        }
        for name in on:
            x1, y1, x2, y2 = seg_rects[name]
            cv2.rectangle(img, (x1, y1), (x2, y2), color, -1)
