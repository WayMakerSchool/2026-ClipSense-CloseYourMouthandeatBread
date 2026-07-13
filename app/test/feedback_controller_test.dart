import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/signals/judge.dart';
import 'package:clip_sense/feedback/speech_output.dart';
import 'package:clip_sense/feedback/haptic_output.dart';
import 'package:clip_sense/feedback/feedback_controller.dart';

/// 호출을 기록하는 Fake 음성 출력. throwAsync=true면 speak가 async로 실패한다
/// (실기기 TTS 실패가 Future 에러 완료인 것을 흉내 — 동기 throw면 거짓 통과).
class FakeSpeech implements SpeechOutput {
  final List<String> spoken = [];
  bool throwAsync = false;
  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    if (throwAsync) throw Exception('tts failed');
  }
}

/// 호출을 기록하는 Fake 진동 출력.
class FakeHaptic implements HapticOutput {
  final List<Decision> played = [];
  @override
  Future<void> play(Decision d) async {
    played.add(d);
  }
}

void main() {
  test('첫 Decision은 안내됨 (speak·play 각 1회)', () async {
    final s = FakeSpeech();
    final h = FakeHaptic();
    final c = FeedbackController(s, h);
    await c.onDecision(Decision.wait);
    expect(s.spoken, ['기다리세요']);
    expect(h.played, [Decision.wait]);
  });

  test('같은 Decision 반복 시 무음', () async {
    final s = FakeSpeech();
    final h = FakeHaptic();
    final c = FeedbackController(s, h);
    await c.onDecision(Decision.wait);
    await c.onDecision(Decision.wait);
    await c.onDecision(Decision.wait);
    expect(s.spoken.length, 1);
    expect(h.played.length, 1);
  });

  test('전환 시 안내됨 (wait→walk)', () async {
    final s = FakeSpeech();
    final h = FakeHaptic();
    final c = FeedbackController(s, h);
    await c.onDecision(Decision.wait);
    await c.onDecision(Decision.walk);
    expect(s.spoken, ['기다리세요', '지금 건너셔도 됩니다']);
    expect(h.played, [Decision.wait, Decision.walk]);
  });

  test('walk 전환에 remainSec 주면 문구에 잔여시간 포함', () async {
    final s = FakeSpeech();
    final h = FakeHaptic();
    final c = FeedbackController(s, h);
    await c.onDecision(Decision.walk, remainSec: 12.0);
    expect(s.spoken, ['지금 건너셔도 됩니다, 12초 남았습니다']);
  });

  test('speech가 async로 실패해도 haptic은 호출됨 (멀티채널 독립)', () async {
    final s = FakeSpeech()..throwAsync = true;
    final h = FakeHaptic();
    final c = FeedbackController(s, h);
    // onDecision은 예외를 밖으로 던지지 않아야 한다(삼킴).
    await c.onDecision(Decision.walk);
    expect(s.spoken.length, 1); // speak는 시도됨(그리고 실패)
    expect(h.played, [Decision.walk]); // speech 실패에도 haptic 실행됨
  });

  test('unknown 전환 안내', () async {
    final s = FakeSpeech();
    final h = FakeHaptic();
    final c = FeedbackController(s, h);
    await c.onDecision(Decision.unknown);
    expect(s.spoken, ['신호를 확인할 수 없습니다. 대기하세요']);
    expect(h.played, [Decision.unknown]);
  });
}
