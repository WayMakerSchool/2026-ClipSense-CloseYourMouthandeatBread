/// 기존 카메라 검출기 상태 → 표준 SignalReading 번역 (Python vision_adapter.py 이식).
///
/// 검출 알고리즘은 여기 없다. 상태 문자열 표현만 표준화한다.
/// GREEN_BLINK(초록 점멸)는 clearance로 매핑한다. 실제 카메라 검출기(Dart)는
/// 아직 없으므로 visionStub()이 그 자리를 대신해 항상 unknown을 반환한다.

library;

import 'signal_reading.dart';

const Map<String, SignalColor> _stateMap = {
  'RED': SignalColor.red,
  'GREEN': SignalColor.green,
  'GREEN_BLINK': SignalColor.clearance,
  'UNKNOWN': SignalColor.unknown,
};

/// 검출기 상태 문자열 → SignalReading(source: vision). 미지 상태는 unknown.
SignalReading toReading(String state, {double? remainSec, int freshMs = 0}) {
  final color = _stateMap[state] ?? SignalColor.unknown;
  return SignalReading(color, remainSec, SignalSource.vision, freshMs: freshMs);
}

/// 실제 카메라 검출기 자리의 스텁. 항상 unknown (신호 없음).
/// judge가 "카메라 신호 없음" 상황(단일소스 경로)을 겪게 한다.
SignalReading visionStub() {
  return const SignalReading(SignalColor.unknown, null, SignalSource.vision);
}
