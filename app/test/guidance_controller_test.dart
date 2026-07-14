import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/signals/signal_reading.dart';
import 'package:clip_sense/signals/judge.dart';
import 'package:clip_sense/feedback/speech_output.dart';
import 'package:clip_sense/feedback/haptic_output.dart';
import 'package:clip_sense/feedback/feedback_controller.dart';
import 'package:clip_sense/app/guidance_controller.dart';

class FakeSpeech implements SpeechOutput {
  final List<String> spoken = [];
  @override
  Future<void> speak(String text) async => spoken.add(text);
}

class FakeHaptic implements HapticOutput {
  final List<Decision> played = [];
  @override
  Future<void> play(Decision d) async => played.add(d);
}

void main() {
  late FakeSpeech speech;
  late FakeHaptic haptic;
  late FeedbackController feedback;

  setUp(() {
    speech = FakeSpeech();
    haptic = FakeHaptic();
    feedback = FeedbackController(speech, haptic);
  });

  // 주입할 fetch: 지정한 SignalReading을 반환.
  GuidanceController make(SignalReading apiReading,
      {bool allowSingleSource = true}) {
    return GuidanceController(
      feedback: feedback,
      allowSingleSource: allowSingleSource,
      fetch: (itstId, direction, apiKey, {required nowMs}) async => apiReading,
    );
  }

  test('초기 상태: 정지·unknown', () {
    final c = make(const SignalReading(SignalColor.red, null, SignalSource.api));
    expect(c.running, isFalse);
    expect(c.decision, Decision.unknown);
    c.dispose();
  });

  test('API 초록·충분 → tick 후 walk + 잔여시간 + 음성', () async {
    final c = make(const SignalReading(
        SignalColor.green, 15.0, SignalSource.api, freshMs: 0));
    await c.tickOnce();
    expect(c.decision, Decision.walk);
    expect(c.remainSec, 15.0);
    expect(speech.spoken.single, contains('건너'));
    expect(haptic.played.single, Decision.walk);
    c.dispose();
  });

  test('API 초록이지만 4초(부족) → wait', () async {
    final c = make(const SignalReading(
        SignalColor.green, 4.0, SignalSource.api, freshMs: 0));
    await c.tickOnce();
    expect(c.decision, Decision.wait);
    c.dispose();
  });

  test('API 빨강 → wait', () async {
    final c = make(const SignalReading(
        SignalColor.red, null, SignalSource.api, freshMs: 0));
    await c.tickOnce();
    expect(c.decision, Decision.wait);
    c.dispose();
  });

  test('fetch가 throw해도 tick은 unknown으로 수렴(타이머 안 죽음)', () async {
    final c = GuidanceController(
      feedback: feedback,
      fetch: (itstId, direction, apiKey, {required nowMs}) async =>
          throw Exception('network'),
    );
    await c.tickOnce();
    expect(c.decision, Decision.unknown);
    c.dispose();
  });

  test('toggle: 정지→시작→정지', () {
    final c = make(const SignalReading(SignalColor.red, null, SignalSource.api));
    expect(c.running, isFalse);
    c.toggle();
    expect(c.running, isTrue);
    c.toggle();
    expect(c.running, isFalse);
    c.dispose();
  });

  test('stop 후 running=false, 상태 알림', () {
    final c = make(const SignalReading(SignalColor.red, null, SignalSource.api));
    c.start();
    expect(c.running, isTrue);
    c.stop();
    expect(c.running, isFalse);
    c.dispose();
  });

  test('stop()은 walk 판정을 지운다 — 정지 후 화면/스크린리더에 오래된 '
      '"건너세요"가 남으면 안 됨(안전)', () async {
    final c = make(const SignalReading(
        SignalColor.green, 15.0, SignalSource.api, freshMs: 0));
    c.start();
    await c.tickOnce(); // walk 판정 확정
    expect(c.decision, Decision.walk);
    expect(c.remainSec, 15.0);
    c.stop();
    expect(c.decision, Decision.unknown);
    expect(c.remainSec, isNull);
    expect(c.running, isFalse);
    c.dispose();
  });

  test('notifyListeners: tick이 리스너를 부른다', () async {
    final c = make(const SignalReading(
        SignalColor.green, 15.0, SignalSource.api, freshMs: 0));
    var notified = 0;
    c.addListener(() => notified++);
    await c.tickOnce();
    expect(notified, greaterThan(0));
    c.dispose();
  });

  test('dispose 경합: fetch 도중 dispose되면 재개된 tick이 notifyListeners를 부르지 않음', () async {
    final fetchStarted = Completer<void>();
    final releaseFetch = Completer<SignalReading>();
    final c = GuidanceController(
      feedback: feedback,
      fetch: (itstId, direction, apiKey, {required nowMs}) async {
        fetchStarted.complete();
        return releaseFetch.future; // dispose()가 끝날 때까지 tick을 붙잡아 둠
      },
    );
    var notified = 0;
    c.addListener(() => notified++);

    final pending = c.tickOnce(); // fire-and-forget처럼 await하지 않음(start()와 동일한 경합)
    await fetchStarted.future; // fetch 호출 시점까지만 대기 → tick이 await 중
    c.dispose(); // 아직 in-flight인 tick보다 먼저 dispose

    releaseFetch.complete(const SignalReading(
        SignalColor.green, 15.0, SignalSource.api, freshMs: 0));
    // 위 completion으로 tickOnce()의 await _fetch(...) 뒤가 재개된다.
    // _disposed 가드가 없다면 여기서 notifyListeners()가 disposed 객체에 호출되어 throw.
    await expectLater(pending, completes);

    expect(notified, 0); // dispose 이후 재개된 tick은 리스너를 부르면 안 됨
  });
}
