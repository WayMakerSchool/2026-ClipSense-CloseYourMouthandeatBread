import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/signals/judge.dart';
import 'package:clip_sense/feedback/speech_output.dart';
import 'package:clip_sense/feedback/haptic_output.dart';
import 'package:clip_sense/feedback/feedback_controller.dart';
import 'package:clip_sense/app/intersection.dart';
import 'package:clip_sense/app/location_service.dart';
import 'package:clip_sense/app/selection_screen.dart';
import 'package:clip_sense/app/guidance_screen.dart';
import 'package:clip_sense/camera/camera_vision_source.dart';
import 'package:clip_sense/signals/signal_reading.dart';

class FakeLocationService implements LocationService {
  final LocationResult result;
  FakeLocationService(this.result);
  @override
  Future<LocationResult> current() async => result;
}

/// current() 호출 횟수를 세는 위치 서비스(다시 시도 검증용).
class CountingLocationService implements LocationService {
  final LocationResult result;
  int calls = 0;
  CountingLocationService(this.result);
  @override
  Future<LocationResult> current() async {
    calls++;
    return result;
  }
}

class FakeSpeech implements SpeechOutput {
  @override
  Future<void> speak(String text) async {}
}

class FakeHaptic implements HapticOutput {
  @override
  Future<void> play(Decision d) async {}
}

class FakeVisionSource implements VisionSource {
  int stopCalls = 0;

  @override
  SignalReading get latestReading =>
      const SignalReading(SignalColor.unknown, null, SignalSource.vision);

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}

FeedbackController fakeFeedback() =>
    FeedbackController(FakeSpeech(), FakeHaptic());

const _testList = [
  Intersection('1850', '테스트 교차로 A', 37.5665, 126.9780, [
    Direction('nt', '북쪽 횡단보도'),
    Direction('st', '남쪽 횡단보도'),
  ]),
];

Widget wrap(LocationResult result) => MaterialApp(
  home: SelectionScreen(
    location: FakeLocationService(result),
    feedbackFactory: fakeFeedback,
    intersections: _testList,
  ),
);

void main() {
  testWidgets('위치 성공 + 근처 교차로 → 방향 목록 표시', (tester) async {
    await tester.pumpWidget(wrap(LocationOk(37.5665, 126.9780)));
    await tester.pumpAndSettle();
    expect(find.textContaining('북쪽 횡단보도'), findsOneWidget);
    expect(find.textContaining('남쪽 횡단보도'), findsOneWidget);
  });

  testWidgets('권한 거부 → "권한" 안내', (tester) async {
    await tester.pumpWidget(wrap(LocationDenied()));
    await tester.pumpAndSettle();
    expect(find.textContaining('권한'), findsOneWidget);
  });

  testWidgets('위치 불가 → "확인할 수 없" 안내', (tester) async {
    await tester.pumpWidget(wrap(LocationUnavailable()));
    await tester.pumpAndSettle();
    expect(find.textContaining('확인할 수 없'), findsOneWidget);
  });

  testWidgets('근처 교차로 없음 → "찾을 수 없" 안내', (tester) async {
    // 부산 좌표 → _testList(서울)에서 반경 밖
    await tester.pumpWidget(wrap(LocationOk(35.1796, 129.0756)));
    await tester.pumpAndSettle();
    expect(find.textContaining('찾을 수 없'), findsOneWidget);
  });

  testWidgets('방향 버튼에 Semantics 라벨', (tester) async {
    await tester.pumpWidget(wrap(LocationOk(37.5665, 126.9780)));
    await tester.pumpAndSettle();
    // 방향 버튼 하나의 Semantics 라벨에 방향 텍스트 포함
    final sem = tester.getSemantics(find.textContaining('북쪽 횡단보도').first);
    expect(sem.label, contains('북쪽'));
  });

  testWidgets('방향 버튼 빠른 연속 탭 → GuidanceScreen·컨트롤러는 한 번만 생성', (tester) async {
    var feedbackBuildCount = 0;
    FeedbackController countingFeedback() {
      feedbackBuildCount++;
      return fakeFeedback();
    }

    await tester.pumpWidget(
      MaterialApp(
        home: SelectionScreen(
          location: FakeLocationService(LocationOk(37.5665, 126.9780)),
          feedbackFactory: countingFeedback,
          intersections: _testList,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final directionButton = find.byWidgetPredicate(
      (w) => w is GestureDetector && w.onTap != null,
      description: 'direction button GestureDetector',
    );
    expect(directionButton, findsWidgets);
    final onTap = tester.widget<GestureDetector>(directionButton.first).onTap!;

    // 두 번째 탭이 첫 push의 렌더/애니메이션 완료 전에 들어오는 "더블탭"을
    // 재현하기 위해, 실제 히트테스트 대신 콜백을 연속 호출해 레이스를 보장한다.
    onTap();
    onTap();
    await tester.pumpAndSettle();

    // 가드가 없다면 feedbackFactory()가 두 번 호출되어 GuidanceController(및
    // TTS/햅틱 엔진)가 중복 생성된다. 가드가 있으면 첫 탭만 통과한다.
    expect(feedbackBuildCount, 1);
    expect(find.byType(GuidanceScreen), findsOneWidget);
  });

  testWidgets('선택 화면이 만든 GuidanceController는 route pop 때 카메라를 정리한다', (
    tester,
  ) async {
    final vision = FakeVisionSource();
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionScreen(
          location: FakeLocationService(LocationOk(37.5665, 126.9780)),
          feedbackFactory: fakeFeedback,
          visionFactory: () => vision,
          intersections: _testList,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('북쪽 횡단보도'));
    await tester.pumpAndSettle();
    expect(find.byType(GuidanceScreen), findsOneWidget);

    Navigator.of(tester.element(find.byType(GuidanceScreen))).pop();
    await tester.pumpAndSettle();

    expect(vision.stopCalls, 1);
  });

  // ─── 스크린리더(TalkBack/VoiceOver) 두 번 탭 = SemanticsAction.tap ────
  // Semantics(excludeSemantics: true) 아래의 GestureDetector는 접근성 트리에서
  // 빠지므로, Semantics 노드 자체에 onTap이 없으면 두 번 탭이 아무 일도 안 한다.

  testWidgets('다시 시도 Semantics tap 액션 → 위치 재시도', (tester) async {
    final location = CountingLocationService(LocationUnavailable());
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionScreen(
          location: location,
          feedbackFactory: fakeFeedback,
          intersections: _testList,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(location.calls, 1);

    final retry = find.semantics.byLabel('다시 시도');
    expect(retry, findsOne);
    expect(retry.evaluate().single.flagsCollection.isButton, isTrue);
    tester.semantics.performAction(retry, SemanticsAction.tap);
    await tester.pumpAndSettle();
    expect(location.calls, 2);
  });

  testWidgets('방향 버튼 Semantics tap 액션 → GuidanceScreen push', (tester) async {
    final vision = FakeVisionSource();
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionScreen(
          location: FakeLocationService(LocationOk(37.5665, 126.9780)),
          feedbackFactory: fakeFeedback,
          visionFactory: () => vision,
          intersections: _testList,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final dir = find.semantics.byLabel('북쪽 횡단보도');
    expect(dir, findsOne);
    expect(dir.evaluate().single.flagsCollection.isButton, isTrue);
    tester.semantics.performAction(dir, SemanticsAction.tap);
    await tester.pumpAndSettle();
    expect(find.byType(GuidanceScreen), findsOneWidget);
  });

  testWidgets('방향 버튼 Semantics tap 연속 두 번 → 컨트롤러는 한 번만 생성(가드 유지)', (
    tester,
  ) async {
    var feedbackBuildCount = 0;
    FeedbackController countingFeedback() {
      feedbackBuildCount++;
      return fakeFeedback();
    }

    final vision = FakeVisionSource();
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionScreen(
          location: FakeLocationService(LocationOk(37.5665, 126.9780)),
          feedbackFactory: countingFeedback,
          visionFactory: () => vision,
          intersections: _testList,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final dir = find.semantics.byLabel('북쪽 횡단보도');
    // 첫 push의 프레임이 돌기 전에 두 번째 액션이 들어오는 더블탭 재현.
    tester.semantics.performAction(dir, SemanticsAction.tap);
    tester.semantics.performAction(dir, SemanticsAction.tap);
    await tester.pumpAndSettle();

    expect(feedbackBuildCount, 1);
    expect(find.byType(GuidanceScreen), findsOneWidget);
  });
}
