import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/signals/signal_reading.dart';
import 'package:clip_sense/signals/judge.dart';
import 'package:clip_sense/feedback/speech_output.dart';
import 'package:clip_sense/feedback/haptic_output.dart';
import 'package:clip_sense/feedback/feedback_controller.dart';
import 'package:clip_sense/app/guidance_controller.dart';
import 'package:clip_sense/app/guidance_screen.dart';

class FakeSpeech implements SpeechOutput {
  final List<String> spoken = [];
  @override
  Future<void> speak(String text) async => spoken.add(text);
}

class FakeHaptic implements HapticOutput {
  @override
  Future<void> play(Decision d) async {}
}

GuidanceController makeController(
  SignalReading reading, {
  FakeSpeech? speech,
  bool allowSingleSource = true,
}) {
  return GuidanceController(
    feedback: FeedbackController(speech ?? FakeSpeech(), FakeHaptic()),
    itstId: '1850',
    direction: 'st',
    // 이 파일은 화면 표현만 검증한다. 엄격 AND 배선은 controller 테스트에서
    // FakeVisionSource로 별도 검증한다(카메라 미인식 문구 테스트만 엄격 모드).
    allowSingleSource: allowSingleSource,
    fetch: (itstId, direction, apiKey, {required nowMs}) async => reading,
  );
}

void main() {
  testWidgets('정지 상태: 시작 안내 문구 표시', (tester) async {
    final c = makeController(
      const SignalReading(SignalColor.red, null, SignalSource.api),
    );
    await tester.pumpWidget(MaterialApp(home: GuidanceScreen(controller: c)));
    expect(find.textContaining('시작'), findsOneWidget);
    c.dispose();
  });

  testWidgets('walk 상태: "건너세요" + 잔여시간 표시', (tester) async {
    final c = makeController(
      const SignalReading(
        SignalColor.green,
        15.0,
        SignalSource.api,
        freshMs: 0,
      ),
    );
    await tester.pumpWidget(MaterialApp(home: GuidanceScreen(controller: c)));
    await c.tickOnce();
    await tester.pump();
    expect(find.textContaining('건너세요'), findsOneWidget);
    expect(find.textContaining('15'), findsOneWidget);
    c.dispose();
  });

  testWidgets('wait 상태: "기다리세요" 표시', (tester) async {
    final c = makeController(
      const SignalReading(SignalColor.red, null, SignalSource.api, freshMs: 0),
    );
    await tester.pumpWidget(MaterialApp(home: GuidanceScreen(controller: c)));
    await c.tickOnce();
    await tester.pump();
    expect(find.textContaining('기다리세요'), findsOneWidget);
    expect(find.textContaining('빨간불'), findsOneWidget);
    c.dispose();
  });

  testWidgets('화면 탭 → 안내 시작(running=true)', (tester) async {
    final c = makeController(
      const SignalReading(SignalColor.red, null, SignalSource.api),
    );
    await tester.pumpWidget(MaterialApp(home: GuidanceScreen(controller: c)));
    expect(c.running, isFalse);
    await tester.tap(find.byType(GuidanceScreen));
    await tester.pump();
    expect(c.running, isTrue);
    c.stop();
    c.dispose();
  });

  // 아래 Semantics 라벨 테스트들은 노드 존재 여부만이 아니라 실제 라벨
  // "내용"을 검증한다(라벨이 비어있거나 엉뚱해도 존재만으로는 통과했던
  // 이전 테스트의 구멍을 메움). 버튼 노드(Key('guidanceButtonSemantics'))는
  // 상태+조작 안내 전체를, 라이브 리전 노드(Key('guidanceLiveRegionSemantics'))는
  // 상태만 담는다 — guidance_screen.dart의 두 형제 Semantics 노드 구조 참고.
  final buttonSemantics = find.byKey(const Key('guidanceButtonSemantics'));
  final liveRegionSemantics = find.byKey(
    const Key('guidanceLiveRegionSemantics'),
  );

  testWidgets('Semantics 버튼 라벨: 정지 상태(시작 전) → "정지" 또는 "시작" 포함', (tester) async {
    final c = makeController(
      const SignalReading(SignalColor.red, null, SignalSource.api),
    );
    await tester.pumpWidget(MaterialApp(home: GuidanceScreen(controller: c)));

    final label = tester.getSemantics(buttonSemantics).label;
    expect(
      label.contains('정지') || label.contains('시작'),
      isTrue,
      reason: '실제 라벨: "$label"',
    );
    c.dispose();
  });

  testWidgets('Semantics 버튼 라벨: walk 상태 → "건너세요"+잔여시간(15) 포함', (tester) async {
    final c = makeController(
      const SignalReading(
        SignalColor.green,
        15.0,
        SignalSource.api,
        freshMs: 0,
      ),
    );
    await tester.pumpWidget(MaterialApp(home: GuidanceScreen(controller: c)));
    await c.tickOnce();
    await tester.pump();

    final label = tester.getSemantics(buttonSemantics).label;
    expect(label, contains('건너세요'));
    expect(label, contains('15'));

    final liveLabel = tester.getSemantics(liveRegionSemantics).label;
    expect(liveLabel, contains('건너세요'));
    expect(liveLabel, contains('15'));
    c.dispose();
  });

  testWidgets('Semantics 버튼 라벨: wait 상태 → "기다리세요" 포함', (tester) async {
    final c = makeController(
      const SignalReading(SignalColor.red, null, SignalSource.api, freshMs: 0),
    );
    await tester.pumpWidget(MaterialApp(home: GuidanceScreen(controller: c)));
    await c.tickOnce();
    await tester.pump();

    final label = tester.getSemantics(buttonSemantics).label;
    expect(label, contains('기다리세요'));

    final liveLabel = tester.getSemantics(liveRegionSemantics).label;
    expect(liveLabel, contains('기다리세요'));
    c.dispose();
  });

  // 실기기의 가장 흔한 wait: API는 오는데 카메라가 신호등을 못 찾음. 화면·라이브
  // 리전·음성 모두에 지정 문구 "카메라가 신호등을 찾지 못했습니다. 신호등을 향해
  // 주세요."가 글자 그대로(마침표 포함, ".." 없이) 들어가야 한다.
  testWidgets('엄격 모드·카메라 판독 없음 → "신호등을 향해 주세요" 이유 표시+음성', (tester) async {
    final speech = FakeSpeech();
    final c = makeController(
      const SignalReading(
        SignalColor.green,
        15.0,
        SignalSource.api,
        freshMs: 0,
      ),
      speech: speech,
      allowSingleSource:
          false, // 카메라 미주입(visionStub=unknown) → cameraUnavailable
    );
    await tester.pumpWidget(MaterialApp(home: GuidanceScreen(controller: c)));
    await c.tickOnce();
    await tester.pump();

    expect(c.decision, Decision.wait);
    expect(c.reason, DecisionReason.cameraUnavailable);
    expect(find.textContaining('건너세요'), findsNothing);
    expect(find.text('카메라가 신호등을 찾지 못했습니다. 신호등을 향해 주세요'), findsOneWidget);
    expect(
      tester.getSemantics(liveRegionSemantics).label,
      '기다리세요. 카메라가 신호등을 찾지 못했습니다. 신호등을 향해 주세요.',
    );
    expect(speech.spoken, ['카메라가 신호등을 찾지 못했습니다. 신호등을 향해 주세요. 기다리세요']);
    c.dispose();
  });

  testWidgets('Semantics 버튼 라벨: unknown 상태 → "확인" 포함', (tester) async {
    final c = makeController(
      const SignalReading(
        SignalColor.red,
        null,
        SignalSource.api,
        freshMs: 999999, // stale → unknown
      ),
    );
    await tester.pumpWidget(MaterialApp(home: GuidanceScreen(controller: c)));
    // running=false && decision==unknown은 "정지됨" 화면으로 보이므로(코드 주석
    // 참고), 진짜 "확인 불가" 화면을 보려면 running=true 상태에서 stale 판정을
    // 받아야 한다. start()는 즉시 한 번 tickOnce()를 돌리므로 별도 tick 불필요.
    c.start();
    await c.tickOnce();
    await tester.pump();

    final label = tester.getSemantics(buttonSemantics).label;
    expect(label, contains('확인'));

    final liveLabel = tester.getSemantics(liveRegionSemantics).label;
    expect(liveLabel, contains('확인'));
    c.dispose();
  });

  testWidgets('start→walk→stop 실제 경로: 정지 후 "건너세요"가 아니라 시작 안내가 보인다(안전)', (
    tester,
  ) async {
    final c = makeController(
      const SignalReading(
        SignalColor.green,
        15.0,
        SignalSource.api,
        freshMs: 0,
      ),
    );
    await tester.pumpWidget(MaterialApp(home: GuidanceScreen(controller: c)));

    c.start();
    await c.tickOnce();
    await tester.pump();
    expect(find.textContaining('건너세요'), findsOneWidget);

    c.stop();
    await tester.pump();
    expect(find.textContaining('시작'), findsOneWidget);
    expect(find.textContaining('건너세요'), findsNothing);

    c.dispose();
  });

  // 앱 생명주기. 정지는 화면이 실제로 가려지는 paused/hidden/detached에서만.
  // inactive는 카메라 권한 다이얼로그·알림창·제어센터 같은 잠깐의 포커스 이탈이라
  // 여기서 정지하면 첫 탭의 권한 요청만으로 안내가 취소된다(실기기 재현).
  //
  // 테스트 바인딩은 생명주기 상태를 테스트 사이에 초기화하지 않고, 같은 상태로의
  // 전이는 무시되므로(SchedulerBinding) 각 테스트가 resumed로 정규화하고 끝에
  // 되돌린다 — 실행 순서와 무관하게 통과해야 한다.
  group('앱 생명주기', () {
    const red = SignalReading(SignalColor.red, null, SignalSource.api);

    Future<void> setLifecycle(WidgetTester tester, AppLifecycleState s) async {
      tester.binding.handleAppLifecycleStateChanged(s);
      await tester.pump();
    }

    Future<void> normalize(WidgetTester tester) async {
      await setLifecycle(tester, AppLifecycleState.resumed);
      addTearDown(() {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      });
    }

    testWidgets('inactive(권한 다이얼로그 등)에서는 계속 실행된다', (tester) async {
      final speech = FakeSpeech();
      final c = makeController(red, speech: speech);
      await tester.pumpWidget(MaterialApp(home: GuidanceScreen(controller: c)));
      await normalize(tester);
      c.start();
      expect(c.running, isTrue);

      await setLifecycle(tester, AppLifecycleState.inactive);
      expect(c.running, isTrue);
      expect(speech.spoken, isNot(contains(kStoppedSpeechText)));

      await setLifecycle(tester, AppLifecycleState.resumed);
      expect(c.running, isTrue);
      c.dispose();
    });

    testWidgets('paused(백그라운드)면 정지하고 정지 음성을 낸다', (tester) async {
      final speech = FakeSpeech();
      final c = makeController(red, speech: speech);
      await tester.pumpWidget(MaterialApp(home: GuidanceScreen(controller: c)));
      await normalize(tester);
      c.start();
      expect(c.running, isTrue);

      await setLifecycle(tester, AppLifecycleState.paused);

      expect(c.running, isFalse);
      expect(c.decision, Decision.unknown);
      expect(speech.spoken, [kStoppedSpeechText]);
      expect(find.textContaining('시작'), findsOneWidget);
      c.dispose();
    });

    testWidgets('hidden·detached도 정지한다(정지 음성 포함)', (tester) async {
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.detached,
      ]) {
        final speech = FakeSpeech();
        final c = makeController(red, speech: speech);
        await tester.pumpWidget(
          MaterialApp(home: GuidanceScreen(controller: c)),
        );
        await normalize(tester);
        c.start();
        expect(c.running, isTrue, reason: '$state');

        await setLifecycle(tester, state);

        expect(c.running, isFalse, reason: '$state');
        expect(speech.spoken, [kStoppedSpeechText], reason: '$state');
        c.dispose();
      }
    });

    testWidgets('정지 상태에서 paused가 와도 정지 음성은 없다(중복 안내 방지)', (tester) async {
      final speech = FakeSpeech();
      final c = makeController(red, speech: speech);
      await tester.pumpWidget(MaterialApp(home: GuidanceScreen(controller: c)));
      await normalize(tester);
      expect(c.running, isFalse);

      await setLifecycle(tester, AppLifecycleState.paused);

      expect(c.running, isFalse);
      expect(speech.spoken, isEmpty);
      c.dispose();
    });
  });
}
