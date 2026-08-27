import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/signals/signal_reading.dart';
import 'package:clip_sense/signals/judge.dart';
import 'package:clip_sense/feedback/speech_output.dart';
import 'package:clip_sense/feedback/haptic_output.dart';
import 'package:clip_sense/feedback/feedback_controller.dart';
import 'package:clip_sense/app/guidance_controller.dart';
import 'package:clip_sense/camera/camera_vision_source.dart';

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

/// announceStopped 호출 횟수를 세는 Fake. 문구 조합은 실제 FeedbackController를
/// 그대로 타게 두어(super 호출) 호출이 speech까지 닿는지도 함께 본다.
class CountingFeedback extends FeedbackController {
  int stoppedCalls = 0;
  CountingFeedback(super.speech, super.haptic);

  @override
  Future<void> announceStopped() {
    stoppedCalls++;
    return super.announceStopped();
  }
}

class FakeVisionSource implements VisionSource {
  SignalReading reading;
  final Completer<void>? startGate;
  int startCalls = 0;
  int stopCalls = 0;

  FakeVisionSource(this.reading, {this.startGate});

  @override
  SignalReading get latestReading => reading;

  @override
  Future<void> start() async {
    startCalls++;
    await startGate?.future;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}

void main() {
  late FakeSpeech speech;
  late FakeHaptic haptic;
  late CountingFeedback feedback;

  setUp(() {
    speech = FakeSpeech();
    haptic = FakeHaptic();
    feedback = CountingFeedback(speech, haptic);
  });

  // 주입할 fetch: 지정한 SignalReading을 반환.
  GuidanceController make(
    SignalReading apiReading, {
    bool allowSingleSource = true,
  }) {
    return GuidanceController(
      feedback: feedback,
      itstId: '1850',
      direction: 'st',
      allowSingleSource: allowSingleSource,
      fetch: (itstId, direction, apiKey, {required nowMs}) async => apiReading,
    );
  }

  test('초기 상태: 정지·unknown', () {
    final c = make(
      const SignalReading(SignalColor.red, null, SignalSource.api),
    );
    expect(c.running, isFalse);
    expect(c.decision, Decision.unknown);
    c.dispose();
  });

  test('API 초록·충분 → tick 후 walk + 잔여시간 + 음성', () async {
    final c = make(
      const SignalReading(
        SignalColor.green,
        15.0,
        SignalSource.api,
        freshMs: 0,
      ),
    );
    await c.tickOnce();
    expect(c.decision, Decision.walk);
    expect(c.remainSec, 15.0);
    expect(speech.spoken.single, contains('건너'));
    expect(haptic.played.single, Decision.walk);
    c.dispose();
  });

  test('API 초록이지만 4초(부족) → wait', () async {
    final c = make(
      const SignalReading(SignalColor.green, 4.0, SignalSource.api, freshMs: 0),
    );
    await c.tickOnce();
    expect(c.decision, Decision.wait);
    c.dispose();
  });

  test('API 빨강 → wait', () async {
    final c = make(
      const SignalReading(SignalColor.red, null, SignalSource.api, freshMs: 0),
    );
    await c.tickOnce();
    expect(c.decision, Decision.wait);
    c.dispose();
  });

  test('엄격 AND: API 초록 + 카메라 초록일 때만 walk하고 짧은 잔여시간을 표시', () async {
    final vision = FakeVisionSource(
      const SignalReading(
        SignalColor.green,
        11.0,
        SignalSource.vision,
        freshMs: 0,
      ),
    );
    final c = GuidanceController(
      feedback: feedback,
      itstId: '1850',
      direction: 'st',
      vision: vision,
      fetch: (itstId, direction, apiKey, {required nowMs}) async =>
          const SignalReading(
            SignalColor.green,
            15.0,
            SignalSource.api,
            freshMs: 0,
          ),
    );

    await c.tickOnce();

    expect(c.decision, Decision.walk);
    expect(c.remainSec, 11.0);
    c.dispose();
  });

  test('엄격 AND: API가 초록이어도 카메라가 unknown이면 wait', () async {
    final vision = FakeVisionSource(
      const SignalReading(SignalColor.unknown, null, SignalSource.vision),
    );
    final c = GuidanceController(
      feedback: feedback,
      itstId: '1850',
      direction: 'st',
      vision: vision,
      fetch: (itstId, direction, apiKey, {required nowMs}) async =>
          const SignalReading(
            SignalColor.green,
            15.0,
            SignalSource.api,
            freshMs: 0,
          ),
    );

    await c.tickOnce();

    expect(c.decision, Decision.wait);
    expect(c.remainSec, isNull);
    c.dispose();
  });

  test('start/stop은 VisionSource 수명주기를 함께 제어한다', () async {
    final vision = FakeVisionSource(
      const SignalReading(SignalColor.red, null, SignalSource.vision),
    );
    final c = GuidanceController(
      feedback: feedback,
      itstId: '1850',
      direction: 'st',
      vision: vision,
      fetch: (itstId, direction, apiKey, {required nowMs}) async =>
          const SignalReading(SignalColor.red, null, SignalSource.api),
    );

    c.start();
    await Future<void>.delayed(Duration.zero);
    expect(vision.startCalls, 1);

    c.stop();
    await Future<void>.delayed(Duration.zero);
    expect(vision.stopCalls, greaterThanOrEqualTo(1));
    c.dispose();
  });

  test('카메라 start 대기 중 stop되면 늦은 start 완료 뒤에도 다시 stop한다', () async {
    final gate = Completer<void>();
    final vision = FakeVisionSource(
      const SignalReading(SignalColor.unknown, null, SignalSource.vision),
      startGate: gate,
    );
    final c = GuidanceController(
      feedback: feedback,
      itstId: '1850',
      direction: 'st',
      vision: vision,
      fetch: (itstId, direction, apiKey, {required nowMs}) async =>
          const SignalReading(SignalColor.red, null, SignalSource.api),
    );

    c.start();
    c.stop();
    expect(vision.stopCalls, greaterThanOrEqualTo(1));

    gate.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(vision.stopCalls, greaterThanOrEqualTo(2));
    c.dispose();
  });

  test('dispose는 실행 중이 아니어도 VisionSource.stop을 보장한다', () async {
    final vision = FakeVisionSource(
      const SignalReading(SignalColor.unknown, null, SignalSource.vision),
    );
    final c = GuidanceController(
      feedback: feedback,
      itstId: '1850',
      direction: 'st',
      vision: vision,
      fetch: (itstId, direction, apiKey, {required nowMs}) async =>
          const SignalReading(SignalColor.red, null, SignalSource.api),
    );

    c.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(vision.stopCalls, 1);
  });

  test('fetch가 throw해도 tick은 unknown으로 수렴(타이머 안 죽음)', () async {
    final c = GuidanceController(
      feedback: feedback,
      itstId: '1850',
      direction: 'st',
      fetch: (itstId, direction, apiKey, {required nowMs}) async =>
          throw Exception('network'),
    );
    await c.tickOnce();
    expect(c.decision, Decision.unknown);
    c.dispose();
  });

  test('toggle: 정지→시작→정지', () {
    final c = make(
      const SignalReading(SignalColor.red, null, SignalSource.api),
    );
    expect(c.running, isFalse);
    c.toggle();
    expect(c.running, isTrue);
    c.toggle();
    expect(c.running, isFalse);
    c.dispose();
  });

  test('stop 후 running=false, 상태 알림', () {
    final c = make(
      const SignalReading(SignalColor.red, null, SignalSource.api),
    );
    c.start();
    expect(c.running, isTrue);
    c.stop();
    expect(c.running, isFalse);
    c.dispose();
  });

  test('stop()은 walk 판정을 지운다 — 정지 후 화면/스크린리더에 오래된 '
      '"건너세요"가 남으면 안 됨(안전)', () async {
    final c = make(
      const SignalReading(
        SignalColor.green,
        15.0,
        SignalSource.api,
        freshMs: 0,
      ),
    );
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
    final c = make(
      const SignalReading(
        SignalColor.green,
        15.0,
        SignalSource.api,
        freshMs: 0,
      ),
    );
    var notified = 0;
    c.addListener(() => notified++);
    await c.tickOnce();
    expect(notified, greaterThan(0));
    c.dispose();
  });

  test(
    'dispose 경합: fetch 도중 dispose되면 재개된 tick이 notifyListeners를 부르지 않음',
    () async {
      final fetchStarted = Completer<void>();
      final releaseFetch = Completer<SignalReading>();
      final c = GuidanceController(
        feedback: feedback,
        itstId: '1850',
        direction: 'st',
        fetch: (itstId, direction, apiKey, {required nowMs}) async {
          fetchStarted.complete();
          return releaseFetch.future; // dispose()가 끝날 때까지 tick을 붙잡아 둠
        },
      );
      var notified = 0;
      c.addListener(() => notified++);

      final pending = c
          .tickOnce(); // fire-and-forget처럼 await하지 않음(start()와 동일한 경합)
      await fetchStarted.future; // fetch 호출 시점까지만 대기 → tick이 await 중
      c.dispose(); // 아직 in-flight인 tick보다 먼저 dispose

      releaseFetch.complete(
        const SignalReading(
          SignalColor.green,
          15.0,
          SignalSource.api,
          freshMs: 0,
        ),
      );
      // 위 completion으로 tickOnce()의 await _fetch(...) 뒤가 재개된다.
      // _disposed 가드가 없다면 여기서 notifyListeners()가 disposed 객체에 호출되어 throw.
      await expectLater(pending, completes);

      expect(notified, 0); // dispose 이후 재개된 tick은 리스너를 부르면 안 됨
    },
  );

  test('tick은 생성자의 itstId·direction을 fetch에 전달한다', () async {
    String? gotItst, gotDir;
    final c = GuidanceController(
      feedback: feedback,
      itstId: '4031',
      direction: 'et',
      fetch: (itstId, direction, apiKey, {required nowMs}) async {
        gotItst = itstId;
        gotDir = direction;
        return const SignalReading(
          SignalColor.red,
          null,
          SignalSource.api,
          freshMs: 0,
        );
      },
    );
    await c.tickOnce();
    expect(gotItst, '4031');
    expect(gotDir, 'et');
    c.dispose();
  });

  test('동시에 요청한 tick은 하나의 fetch만 공유한다', () async {
    final releaseFetch = Completer<SignalReading>();
    var calls = 0;
    final c = GuidanceController(
      feedback: feedback,
      itstId: '1850',
      direction: 'st',
      fetch: (itstId, direction, apiKey, {required nowMs}) {
        calls++;
        return releaseFetch.future;
      },
    );

    final first = c.tickOnce();
    final second = c.tickOnce();
    expect(calls, 1);

    releaseFetch.complete(
      const SignalReading(SignalColor.red, null, SignalSource.api),
    );
    await Future.wait([first, second]);
    expect(calls, 1);
    c.dispose();
  });

  test('stop 중 돌아온 느린 API 응답은 상태·음성·진동을 되살리지 않는다', () async {
    final fetchStarted = Completer<void>();
    final releaseFetch = Completer<SignalReading>();
    final vision = FakeVisionSource(
      const SignalReading(SignalColor.green, 15, SignalSource.vision),
    );
    final c = GuidanceController(
      feedback: feedback,
      itstId: '1850',
      direction: 'st',
      vision: vision,
      fetch: (itstId, direction, apiKey, {required nowMs}) {
        fetchStarted.complete();
        return releaseFetch.future;
      },
    );

    c.start();
    await fetchStarted.future;
    final pending = c.tickOnce();
    c.stop();
    releaseFetch.complete(
      const SignalReading(SignalColor.green, 15, SignalSource.api),
    );
    await pending;

    expect(c.running, isFalse);
    expect(c.decision, Decision.unknown);
    // 정지 음성 한 번뿐 — 늦게 도착한 초록 판정의 "건너세요"가 붙으면 안 된다.
    expect(speech.spoken, [kStoppedSpeechText]);
    expect(haptic.played, isEmpty);
    c.dispose();
  });

  // 정지 안내: 전맹 사용자는 정지(탭·백그라운드)를 화면으로 알 수 없으므로
  // 실행 중이던 안내가 멈출 때 한 번 말한다. 화면을 떠나는 dispose()는 말하지
  // 않고, 이미 정지된 상태의 stop()도 말하지 않는다(중복 안내 방지).
  group('정지 안내', () {
    const red = SignalReading(SignalColor.red, null, SignalSource.api);

    test('toggle로 정지하면 announceStopped 1회 + 정지 음성, 진동 없음', () async {
      final c = make(red);
      c.toggle(); // 시작
      c.toggle(); // 정지
      await Future<void>.delayed(Duration.zero);
      expect(feedback.stoppedCalls, 1);
      expect(speech.spoken, [kStoppedSpeechText]);
      expect(haptic.played, isEmpty);
      c.dispose();
    });

    test('시작·정지를 반복하면 정지마다 1회', () async {
      final c = make(red);
      c.toggle();
      c.toggle();
      c.toggle();
      c.toggle();
      await Future<void>.delayed(Duration.zero);
      expect(feedback.stoppedCalls, 2);
      c.dispose();
    });

    test('dispose로 화면을 떠날 때는 정지 음성이 없다', () async {
      final c = make(red);
      c.start();
      c.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(feedback.stoppedCalls, 0);
      expect(speech.spoken, isNot(contains(kStoppedSpeechText)));
    });

    test('정지 상태에서 stop()은 announceStopped를 부르지 않는다', () async {
      final c = make(red);
      c.stop();
      c.stop();
      await Future<void>.delayed(Duration.zero);
      expect(feedback.stoppedCalls, 0);
      expect(speech.spoken, isEmpty);
      c.dispose();
    });

    test('stop(announce: false)는 실행 중이어도 말하지 않는다', () async {
      final c = make(red);
      c.start();
      c.stop(announce: false);
      await Future<void>.delayed(Duration.zero);
      expect(feedback.stoppedCalls, 0);
      expect(c.running, isFalse);
      expect(c.decision, Decision.unknown);
      c.dispose();
    });
  });

  test('기본 API 키가 비어 있으면 네트워크 호출 없이 원인을 명시한다', () async {
    final c = GuidanceController(
      feedback: feedback,
      itstId: '1850',
      direction: 'st',
      vision: FakeVisionSource(
        const SignalReading(SignalColor.unknown, null, SignalSource.vision),
      ),
      apiKey: '',
    );

    await c.tickOnce();

    expect(c.decision, Decision.unknown);
    expect(c.reason, DecisionReason.apiKeyMissing);
    expect(speech.spoken.single, contains('API 키'));
    c.dispose();
  });
}
