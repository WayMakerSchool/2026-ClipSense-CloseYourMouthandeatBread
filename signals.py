"""보행 신호 판정의 공유 표준 타입.

signal_api / vision_adapter / judge 세 모듈이 이 표현으로만 대화한다.
색 enum은 4-값 고정이며, UNKNOWN은 "모른다"는 1급 상태다 (추측 금지).
"""

from dataclasses import dataclass

# 신호 색 (4-값 고정)
GREEN = "GREEN"          # 건널 수 있음 (보행 초록)
RED = "RED"              # 멈춤 (보행 빨강)
CLEARANCE = "CLEARANCE"  # 초록 점멸 (곧 끝남 — 새로 건너기 시작 금지)
UNKNOWN = "UNKNOWN"      # 확인 불가 (모르는 값/오래된 데이터/오류/신호 없음)

# 판정 출처
SRC_API = "API"
SRC_VISION = "VISION"


@dataclass
class SignalReading:
    """한 소스(API 또는 비전)의 보행 신호 판정 한 건."""
    color: str            # 위 4-값 중 하나
    remain_sec: float | None  # 남은 초. 모르면 None (색과 독립적으로 채워짐)
    source: str           # SRC_API | SRC_VISION
    fresh_ms: int         # 이 값이 몇 ms 전 것인지 (신선도)
    raw: str | None = None    # 디버그용 원문 (예: 'protected-Movement-Allowed')

    def is_go(self) -> bool:
        """이 판정 하나만 볼 때 '초록'인가. (최종 결정은 judge가 함)"""
        return self.color == GREEN
