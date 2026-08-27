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
  @override
  Future<void> speak(String text) async {}
}

class FakeHaptic implements HapticOutput {
  @override
  Future<void> play(Decision d) async {}
}

GuidanceController makeController(SignalReading reading) {
  return GuidanceController(
    feedback: FeedbackController(FakeSpeech(), FakeHaptic()),
    itstId: '1850',
    direction: 'st',
    // 이 파일은 화면 표현만 검증한다. 엄격 AND 배선은 controller 테스트에서
    // FakeVisionSource로 별도 검증한다.
    allowSingleSource: true,
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

  testWidgets('앱이 백그라운드로 가면 안내·카메라 루프를 안전하게 정지한다', (tester) async {
    final c = makeController(
      const SignalReading(SignalColor.red, null, SignalSource.api),
    );
    await tester.pumpWidget(MaterialApp(home: GuidanceScreen(controller: c)));
    c.start();
    expect(c.running, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    expect(c.running, isFalse);
    expect(c.decision, Decision.unknown);
    expect(find.textContaining('시작'), findsOneWidget);
    c.dispose();
  });
}
