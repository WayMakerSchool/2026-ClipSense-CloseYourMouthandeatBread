/// 판단 결과를 음성으로 안내하는 출력.
///
/// SpeechOutput은 인터페이스(테스트 시 Fake 주입). speechText는 Decision을
/// 안내 문구로 바꾸는 순수 함수라 하드웨어 없이 검증된다.
library;

import 'package:flutter_tts/flutter_tts.dart';

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

/// flutter_tts 기반 실제 음성 출력. 기기 내장 한국어 TTS(오프라인).
///
/// 하드웨어·OS 의존이라 단위 테스트하지 않는다(인터페이스 뒤 격리, 실기기 수동).
/// speak 실패(권한/미지원/플랫폼 예외)는 삼켜 앱을 죽이지 않는다(Fail-Safe).
class FlutterTtsSpeech implements SpeechOutput {
  final FlutterTts _tts;

  FlutterTtsSpeech([FlutterTts? tts]) : _tts = tts ?? FlutterTts() {
    // 한국어 로케일. 실패해도 무시(기기가 지원 안 하면 기본 로케일로 동작).
    _tts.setLanguage('ko-KR').catchError((_) {});
  }

  @override
  Future<void> speak(String text) async {
    // 새 안내가 오면 이전 것을 끊고 재생.
    // stop() 실패만 국소적으로 삼킨다(이전 안내 중단은 부가 작업).
    // speak() 실패는 삼키지 않고 Future 에러로 전파한다 — 컨트롤러가
    // 최종적으로 삼켜 멀티채널 독립을 보장한다(설계 §5).
    try {
      await _tts.stop();
    } catch (_) {}
    await _tts.speak(text);
  }
}
