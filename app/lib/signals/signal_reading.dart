/// 보행 신호 판정의 공유 표준 타입 (Python signals.py 이식).
///
/// signal_api / vision_adapter / judge 세 모듈이 이 표현으로만 대화한다.
/// 색은 4-값 enum이며, unknown은 "모른다"는 1급 상태다 (추측 금지).

library;

/// 신호 색 (4-값 고정).
enum SignalColor {
  green, // 건널 수 있음 (보행 초록)
  red, // 멈춤 (보행 빨강)
  clearance, // 초록 점멸 (곧 끝남 — 새로 건너기 시작 금지)
  unknown, // 확인 불가 (모르는 값/오래된 데이터/오류/신호 없음)
}

/// 판정 출처.
enum SignalSource { api, vision }

/// 한 소스(API 또는 비전)의 보행 신호 판정 한 건. 불변.
class SignalReading {
  final SignalColor color; // 4색 중 하나
  final double? remainSec; // 남은 초. 모르면 null (색과 독립)
  final SignalSource source; // api | vision
  final int freshMs; // 이 값이 몇 ms 전 것인지 (신선도)
  final String? raw; // 디버그용 원문 (예: 'protected-Movement-Allowed')

  const SignalReading(this.color, this.remainSec, this.source,
      {this.freshMs = 0, this.raw});

  /// 이 판정 하나만 볼 때 '초록'인가. (최종 결정은 judge가 함)
  bool get isGo => color == SignalColor.green;
}
