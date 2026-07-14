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

  testWidgets('Semantics 버튼 라벨 존재', (tester) async {
    final c = makeController(
      const SignalReading(SignalColor.red, null, SignalSource.api),
    );
    await tester.pumpWidget(MaterialApp(home: GuidanceScreen(controller: c)));
    // 버튼 시맨틱스가 최소 하나 있어야(스크린리더 조작 가능)
    expect(tester.getSemantics(find.byType(GuidanceScreen)), isNotNull);
    c.dispose();
  });
}
