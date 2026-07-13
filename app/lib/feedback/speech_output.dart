/// 판단 결과를 음성으로 안내하는 출력.
///
/// SpeechOutput은 인터페이스(테스트 시 Fake 주입). speechText는 Decision을
/// 안내 문구로 바꾸는 순수 함수라 하드웨어 없이 검증된다.
library;

import '../signals/judge.dart';

/// 음성 출력 인터페이스. 실제 구현은 FlutterTtsSpeech(Task 3).
abstract class SpeechOutput {
  Future<void> speak(String text);
}

/// Decision → 안내 문구(순수 함수).
///
/// walk에만 remainSec을 붙인다(전환 시 스냅샷 1회, 반올림 정수 초).
/// unknown은 상태 서술에 그치지 않고 행동 지시(대기)를 포함한다 — Fail-Safe.
String speechText(Decision d, {double? remainSec}) {
  switch (d) {
    case Decision.walk:
      if (remainSec != null) {
        return '지금 건너셔도 됩니다, ${remainSec.round()}초 남았습니다';
      }
      return '지금 건너셔도 됩니다';
    case Decision.wait:
      return '기다리세요';
    case Decision.unknown:
      return '신호를 확인할 수 없습니다. 대기하세요';
  }
}
