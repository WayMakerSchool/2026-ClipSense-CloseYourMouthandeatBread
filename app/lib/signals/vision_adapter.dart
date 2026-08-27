/// 기존 카메라 검출기 상태 → 표준 SignalReading 번역 (Python vision_adapter.py 이식).
///
/// 검출 알고리즘은 여기 없다. 상태 문자열 표현만 표준화한다.
/// GREEN_BLINK(초록 점멸)는 clearance로 매핑한다. visionStub()은 카메라 소스를
/// 주입하지 않은 테스트·하위 호환 호출자만을 위한 fail-safe fallback이다.

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

/// 카메라 소스가 없는 호출자를 위한 스텁. 항상 unknown (신호 없음).
SignalReading visionStub() {
  return const SignalReading(SignalColor.unknown, null, SignalSource.vision);
}
