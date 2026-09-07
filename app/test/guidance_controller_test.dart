import 'dart:async';

import 'package:camera/camera.dart';
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

  /// 테스트가 주입하는 소스 상태·진단(권한 거부 매핑·진단 노출 검증용).
  @override
  VisionSourceStatus status;
  @override
  VisionDiagnostics? diagnostics;

  FakeVisionSource(
    this.reading, {
    this.startGate,
    this.status = VisionSourceStatus.idle,
    this.diagnostics,
  });

  @override
  SignalReading get latestReading => reading;

  /// 위젯 테스트에서는 camera 플러그인 CameraController를 만들 수 없다.
  @override
  CameraController? get previewController => null;

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
      // 고정 시계: fetch 소요 0ms → 재-aging 없이 주입한 값 그대로 판정된다.
      clock: () => 0,
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

  // 카메라 권한 거부: judge는 판독값만 보므로 "미인식"과 "권한 없음"을 구분할 수
  // 없다. 컨트롤러가 VisionSource 상태를 보고 이유만 바꾼다 — 결정은 그대로
  // wait(안전 정책 불변), 문구는 "설정에서 허용"으로 사용자가 고칠 수 있게.
  group('카메라 권한 거부 이유 매핑', () {
    const apiGreen = SignalReading(
      SignalColor.green,
      15.0,
      SignalSource.api,
      freshMs: 0,
    );
    const visionUnknown = SignalReading(
      SignalColor.unknown,
      null,
      SignalSource.vision,
    );

    GuidanceController withVision(
      FakeVisionSource vision, {
      SignalReading apiReading = apiGreen,
      String? apiKey,
    }) {
      return GuidanceController(
        feedback: feedback,
        itstId: '1850',
        direction: 'st',
        vision: vision,
        apiKey: apiKey ?? 'test-key',
        fetch: (itstId, direction, apiKey, {required nowMs}) async =>
            apiReading,
      );
    }

    test('status=permissionDenied → 이유 cameraDenied, 결정은 wait', () async {
      final vision = FakeVisionSource(
        visionUnknown,
        status: VisionSourceStatus.permissionDenied,
      );
      final c = withVision(vision);

      await c.tickOnce();

      expect(c.decision, Decision.wait);
      expect(c.reason, DecisionReason.cameraDenied);
      expect(c.remainSec, isNull);
      expect(speech.spoken.single, '카메라 권한이 없습니다. 설정에서 카메라를 허용해 주세요. 기다리세요');
      c.dispose();
    });

    test('status=streaming(미인식) → 이유는 cameraUnavailable 유지', () async {
      final vision = FakeVisionSource(
        visionUnknown,
        status: VisionSourceStatus.streaming,
      );
      final c = withVision(vision);

      await c.tickOnce();

      expect(c.decision, Decision.wait);
      expect(c.reason, DecisionReason.cameraUnavailable);
      c.dispose();
    });

    test('starting·unavailable·failed·idle도 cameraUnavailable 유지', () async {
      for (final status in [
        VisionSourceStatus.idle,
        VisionSourceStatus.starting,
        VisionSourceStatus.unavailable,
        VisionSourceStatus.failed,
      ]) {
        final c = withVision(FakeVisionSource(visionUnknown, status: status));
        await c.tickOnce();
        expect(c.decision, Decision.wait, reason: '$status');
        expect(c.reason, DecisionReason.cameraUnavailable, reason: '$status');
        c.dispose();
      }
    });

    test('권한 거부여도 카메라 판독이 살아 있으면(이유가 카메라 불가가 아니면) 매핑하지 않는다', () async {
      // 상태가 잘못 남아 있어도 judge 결과가 cameraUnavailable일 때만 바꾼다.
      final vision = FakeVisionSource(
        const SignalReading(SignalColor.red, null, SignalSource.vision),
        status: VisionSourceStatus.permissionDenied,
      );
      final c = withVision(vision);

      await c.tickOnce();

      expect(c.decision, Decision.wait);
      expect(c.reason, DecisionReason.conflict);
      c.dispose();
    });

    test('API 키 누락이 권한 거부보다 우선한다', () async {
      final vision = FakeVisionSource(
        visionUnknown,
        status: VisionSourceStatus.permissionDenied,
      );
      final c = GuidanceController(
        feedback: feedback,
        itstId: '1850',
        direction: 'st',
        vision: vision,
        apiKey: '',
      );

      await c.tickOnce();

      expect(c.decision, Decision.unknown);
      expect(c.reason, DecisionReason.apiKeyMissing);
      c.dispose();
    });

    test('권한 거부 → 허용 후 재시작하면 다시 미인식 이유로 돌아온다', () async {
      final vision = FakeVisionSource(
        visionUnknown,
        status: VisionSourceStatus.permissionDenied,
      );
      final c = withVision(vision);

      await c.tickOnce();
      expect(c.reason, DecisionReason.cameraDenied);

      vision.status = VisionSourceStatus.streaming;
      await c.tickOnce();
      expect(c.reason, DecisionReason.cameraUnavailable);
      c.dispose();
    });
  });

  // 진단 노출: 화면 진단 스트립(디버그 빌드)이 "API는 뭐라 했고 카메라는 뭐라
  // 했는지"를 그리기 위한 읽기 전용 값. 판정에는 관여하지 않는다.
  group('진단 노출', () {
    const apiGreen = SignalReading(
      SignalColor.green,
      12.3,
      SignalSource.api,
      freshMs: 0,
    );
    const visionGreen = SignalReading(
      SignalColor.green,
      11.0,
      SignalSource.vision,
      freshMs: 0,
    );
    const diag = VisionDiagnostics(
      lastReason: '',
      areaRatio: 0.024,
      brightness: 130,
      processMs: 31,
      framesProcessed: 42,
      lastFrameAgeMs: 120,
    );

    test('초기: 판독·상태 없음(카메라 미주입)', () {
      final c = make(apiGreen);
      expect(c.lastApiReading, isNull);
      expect(c.lastVisionReading, isNull);
      expect(c.visionStatus, isNull);
      expect(c.visionDiagnostics, isNull);
      expect(c.visionPreviewController, isNull);
      c.dispose();
    });

    test('tick 뒤 마지막 API·카메라 판독과 소스 상태·진단을 노출한다', () async {
      final vision = FakeVisionSource(
        visionGreen,
        status: VisionSourceStatus.streaming,
        diagnostics: diag,
      );
      final c = GuidanceController(
        feedback: feedback,
        itstId: '1850',
        direction: 'st',
        vision: vision,
        fetch: (itstId, direction, apiKey, {required nowMs}) async => apiGreen,
      );

      await c.tickOnce();

      expect(c.lastApiReading, same(apiGreen));
      expect(c.lastVisionReading, same(visionGreen));
      expect(c.visionStatus, VisionSourceStatus.streaming);
      expect(c.visionDiagnostics, same(diag));
      // Fake는 CameraController를 만들 수 없어 항상 null(프리뷰는 실기기 확인).
      expect(c.visionPreviewController, isNull);
      c.dispose();
    });

    test('fetch 실패 틱은 API 판독을 null로 남긴다', () async {
      final vision = FakeVisionSource(
        visionGreen,
        status: VisionSourceStatus.streaming,
      );
      final c = GuidanceController(
        feedback: feedback,
        itstId: '1850',
        direction: 'st',
        vision: vision,
        fetch: (itstId, direction, apiKey, {required nowMs}) async =>
            throw Exception('network'),
      );

      await c.tickOnce();

      expect(c.decision, Decision.unknown);
      expect(c.lastApiReading, isNull);
      c.dispose();
    });

    test('stop()은 마지막 판독을 지운다(정지 후 오래된 값 노출 금지)', () async {
      final vision = FakeVisionSource(
        visionGreen,
        status: VisionSourceStatus.streaming,
        diagnostics: diag,
      );
      final c = GuidanceController(
        feedback: feedback,
        itstId: '1850',
        direction: 'st',
        vision: vision,
        fetch: (itstId, direction, apiKey, {required nowMs}) async => apiGreen,
      );

      c.start();
      await c.tickOnce();
      expect(c.lastApiReading, isNotNull);
      expect(c.lastVisionReading, isNotNull);

      c.stop();

      expect(c.lastApiReading, isNull);
      expect(c.lastVisionReading, isNull);
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

  // API 응답 지연 재-aging: 컨트롤러는 요청 전 시각을 nowMs로 넘기고, 파서는 그
  // 시각 기준으로 신선도를 계산한다. fetch가 느리면(타임아웃 5초) 판정 시점에는
  // 이미 그만큼 더 오래된 값인데 "2초 이내"로 통과하고 잔여시간도 과대평가된다.
  // 판정 직전에 fetch 소요 시간만큼 다시 늙힌다(신선도 +, 잔여 −).
  group('API 응답 지연 재-aging', () {
    GuidanceController makeClocked(
      int Function() clock,
      Completer<SignalReading> release, {
      FakeVisionSource? vision,
    }) {
      return GuidanceController(
        feedback: feedback,
        itstId: '1850',
        direction: 'st',
        vision: vision,
        allowSingleSource: false,
        clock: clock,
        fetch: (itstId, direction, apiKey, {required nowMs}) => release.future,
      );
    }

    test('느린 fetch(1.5초)면 잔여시간을 지연만큼 줄인다: 8초 → 6.5초 → wait', () async {
      var now = 1000000;
      final release = Completer<SignalReading>();
      final vision = FakeVisionSource(
        const SignalReading(SignalColor.green, null, SignalSource.vision),
      );
      final c = makeClocked(() => now, release, vision: vision);
      final tick = c.tickOnce();
      now += 1500;
      release.complete(
        const SignalReading(SignalColor.green, 8.0, SignalSource.api),
      );
      await tick;
      expect(c.decision, Decision.wait);
      expect(c.reason, DecisionReason.remainingInsufficient);
      expect(c.remainSec, isNull);
      // 진단용 마지막 판독도 늙힌 값이다(화면이 8초라고 보여주면 안 된다).
      expect(c.lastApiReading?.remainSec, closeTo(6.5, 1e-9));
      expect(c.lastApiReading?.freshMs, 1500);
      c.dispose();
    });

    test('느린 fetch(1.5초)면 신선도에 지연을 더한다: 1000ms → 2500ms → API 불가', () async {
      var now = 5000;
      final release = Completer<SignalReading>();
      final vision = FakeVisionSource(
        const SignalReading(SignalColor.green, null, SignalSource.vision),
      );
      final c = makeClocked(() => now, release, vision: vision);
      final tick = c.tickOnce();
      now += 1500;
      release.complete(
        const SignalReading(
          SignalColor.green,
          15.0,
          SignalSource.api,
          freshMs: 1000,
        ),
      );
      await tick;
      expect(c.decision, Decision.wait);
      expect(c.reason, DecisionReason.apiUnavailable);
      c.dispose();
    });

    test('빠른 fetch는 그대로 walk(재-aging은 지연이 있을 때만)', () async {
      const now = 42;
      final release = Completer<SignalReading>();
      final vision = FakeVisionSource(
        const SignalReading(SignalColor.green, null, SignalSource.vision),
      );
      final c = makeClocked(() => now, release, vision: vision);
      final tick = c.tickOnce();
      release.complete(
        const SignalReading(SignalColor.green, 8.0, SignalSource.api),
      );
      await tick;
      expect(c.decision, Decision.walk);
      expect(c.remainSec, 8.0);
      c.dispose();
    });

    test('지연이 잔여시간보다 길어도 0 아래로 내려가지 않는다', () async {
      var now = 0;
      final release = Completer<SignalReading>();
      final vision = FakeVisionSource(
        const SignalReading(SignalColor.green, null, SignalSource.vision),
      );
      final c = makeClocked(() => now, release, vision: vision);
      final tick = c.tickOnce();
      now += 4000;
      release.complete(
        const SignalReading(SignalColor.green, 2.0, SignalSource.api),
      );
      await tick;
      // 4초 지연이면 신선도 4000ms > 2000ms라 API 불가가 먼저다(잔여 0은 음수가 아님).
      expect(c.decision, Decision.wait);
      expect(c.reason, DecisionReason.apiUnavailable);
      expect(c.lastApiReading?.remainSec, 0.0);
      c.dispose();
    });

    test('시계가 거꾸로 가도(음수 지연) 판독을 젊게 만들지 않는다', () async {
      var now = 10000;
      final release = Completer<SignalReading>();
      final vision = FakeVisionSource(
        const SignalReading(SignalColor.green, null, SignalSource.vision),
      );
      final c = makeClocked(() => now, release, vision: vision);
      final tick = c.tickOnce();
      now -= 500;
      release.complete(
        const SignalReading(
          SignalColor.green,
          8.0,
          SignalSource.api,
          freshMs: 1900,
        ),
      );
      await tick;
      expect(c.lastApiReading?.freshMs, 1900);
      expect(c.lastApiReading?.remainSec, 8.0);
      expect(c.decision, Decision.walk);
      c.dispose();
    });
  });

  test('stop→start 뒤의 새 tick은 옛 fetch가 남아 있어도 즉시 새 fetch를 시작한다', () async {
    var calls = 0;
    final first = Completer<SignalReading>();
    final second = Completer<SignalReading>();
    final c = GuidanceController(
      feedback: feedback,
      itstId: '1850',
      direction: 'st',
      allowSingleSource: true,
      fetch: (itstId, direction, apiKey, {required nowMs}) {
        calls++;
        return calls == 1 ? first.future : second.future;
      },
    );

    c.start();
    expect(calls, 1);
    c.stop(announce: false);
    c.start();
    // 옛 tick(첫 fetch)이 아직 안 끝났어도 새 세션의 첫 판정은 새 fetch로 한다.
    expect(calls, 2);

    // 옛 응답(빨강)이 먼저 와도 무시되고, 새 응답(초록)이 판정이 된다.
    first.complete(
      const SignalReading(SignalColor.red, null, SignalSource.api),
    );
    await Future<void>.delayed(Duration.zero);
    expect(c.decision, Decision.unknown);
    second.complete(
      const SignalReading(SignalColor.green, 15.0, SignalSource.api),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(c.decision, Decision.walk);
    c.dispose();
  });

  group('클립 카메라 연결 불가 이유 매핑', () {
    test(
      'status=failed + 진단 token_rejected → clipTokenRejected, 결정은 wait',
      () async {
        final vision = FakeVisionSource(
          const SignalReading(SignalColor.unknown, null, SignalSource.vision),
          status: VisionSourceStatus.failed,
          diagnostics: const VisionDiagnostics(lastReason: 'token_rejected'),
        );
        final c = GuidanceController(
          feedback: feedback,
          itstId: '1850',
          direction: 'st',
          vision: vision,
          allowSingleSource: false,
          clock: () => 0,
          fetch: (itstId, direction, apiKey, {required nowMs}) async =>
              const SignalReading(SignalColor.green, 20, SignalSource.api),
        );
        await c.tickOnce();
        expect(c.decision, Decision.wait);
        expect(c.reason, DecisionReason.clipTokenRejected);
        expect(speech.spoken.last, contains('기기 토큰 설정을 확인해 주세요'));
        c.dispose();
      },
    );

    test(
      'status=failed 인데 진단이 token_rejected 가 아니면(폰 카메라 일반 실패) cameraUnavailable 유지',
      () async {
        final vision = FakeVisionSource(
          const SignalReading(SignalColor.unknown, null, SignalSource.vision),
          status: VisionSourceStatus.failed,
          diagnostics: const VisionDiagnostics(lastReason: 'frame_error'),
        );
        final c = GuidanceController(
          feedback: feedback,
          itstId: '1850',
          direction: 'st',
          vision: vision,
          allowSingleSource: false,
          clock: () => 0,
          fetch: (itstId, direction, apiKey, {required nowMs}) async =>
              const SignalReading(SignalColor.green, 20, SignalSource.api),
        );
        await c.tickOnce();
        expect(c.reason, DecisionReason.cameraUnavailable);
        c.dispose();
      },
    );

    test('status=unreachable + 카메라 불가 → clipUnreachable, 결정은 wait', () async {
      final vision = FakeVisionSource(
        const SignalReading(SignalColor.unknown, null, SignalSource.vision),
        status: VisionSourceStatus.unreachable,
      );
      final c = GuidanceController(
        feedback: feedback,
        itstId: '1850',
        direction: 'st',
        vision: vision,
        allowSingleSource: false,
        clock: () => 0,
        fetch: (itstId, direction, apiKey, {required nowMs}) async =>
            const SignalReading(SignalColor.green, 20, SignalSource.api),
      );
      await c.tickOnce();
      expect(c.decision, Decision.wait);
      expect(c.reason, DecisionReason.clipUnreachable);
      expect(speech.spoken.last, contains('클립 카메라에 연결할 수 없습니다'));
      c.dispose();
    });

    test('status=unreachable 이어도 이유가 카메라 불가가 아니면 매핑하지 않는다', () async {
      final vision = FakeVisionSource(
        const SignalReading(SignalColor.red, null, SignalSource.vision),
        status: VisionSourceStatus.unreachable,
      );
      final c = GuidanceController(
        feedback: feedback,
        itstId: '1850',
        direction: 'st',
        vision: vision,
        allowSingleSource: false,
        clock: () => 0,
        fetch: (itstId, direction, apiKey, {required nowMs}) async =>
            const SignalReading(SignalColor.red, null, SignalSource.api),
      );
      await c.tickOnce();
      expect(c.reason, DecisionReason.redSignal);
      c.dispose();
    });
  });
}
