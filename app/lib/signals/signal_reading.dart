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

  const SignalReading(
    this.color,
    this.remainSec,
    this.source, {
    this.freshMs = 0,
    this.raw,
  });

  /// 이 판정 하나만 볼 때 '초록'인가. (최종 결정은 judge가 함)
  bool get isGo => color == SignalColor.green;

  /// [deltaMs]만큼 시간이 지난 뒤의 같은 판정. 신선도는 그만큼 오래되고 잔여 초는
  /// 그만큼 줄어든다(0 아래로 내려가지 않음). 색·출처·원문은 그대로다.
  ///
  /// 용도: 요청 전 시각 기준으로 파싱된 API 판독을 판정 직전에 fetch 소요 시간만큼
  /// 다시 늙힌다(느린 응답이 "2초 이내"로 통과하고 잔여시간이 과대평가되는 것을
  /// 막는다). 0 이하 지연은 같은 객체를 돌려준다 — 판독을 젊게 만들지 않는다.
  /// 비유한 잔여(NaN/∞)는 손대지 않는다(judge가 불가로 처리).
  SignalReading aged(int deltaMs) {
    if (deltaMs <= 0) return this;
    final remain = remainSec;
    final agedRemain = remain == null || !remain.isFinite
        ? remain
        : (remain - deltaMs / 1000).clamp(0.0, double.infinity).toDouble();
    return SignalReading(
      color,
      agedRemain,
      source,
      freshMs: freshMs + deltaMs,
      raw: raw,
    );
  }
}
