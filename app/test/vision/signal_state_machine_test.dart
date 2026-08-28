// SignalStateMachine 단위 테스트. scripts/test_state_machine.py 13케이스 미러링
// (영상 없이 판정 시퀀스를 직접 주입).
import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/vision/detector_config.dart';
import 'package:clip_sense/vision/signal_state_machine.dart';

const rawRed = 'RED', rawGreen = 'GREEN', rawNone = 'NONE';

// (지속초, raw[, reason]) 시퀀스를 fps로 주입 → 전환 리스트.
(List<Transition>, SignalStateMachine) run(
  double fps,
  List<List<dynamic>> segments,
) {
  final sm = SignalStateMachine(const DetectorConfig.defaults());
  final trs = <Transition>[];
  var frame = 0;
  for (final seg in segments) {
    final duration = (seg[0] as num).toDouble();
    final raw = seg[1] as String;
    final reason = seg.length > 2 ? seg[2] as String : '';
    final count = (duration * fps).round();
    for (var i = 0; i < count; i++) {
      final tr = sm.update(frame / fps, raw, reason: reason);
      if (tr != null) trs.add(tr);
      frame++;
    }
  }
  return (trs, sm);
}

List<List<dynamic>> blinkSegments(double seconds, {double period = 1.0}) {
  final segs = <List<dynamic>>[];
  var t = 0.0;
  while (t < seconds - 1e-9) {
    segs.add([period / 2, rawGreen]);
    segs.add([period / 2, rawNone]);
    t += period;
  }
  return segs;
}

List<String> statesOf(List<Transition> trs) =>
    trs.map((t) => t.newState).toList();

void main() {
  test('기본 사이클 30fps: RED→GREEN→BLINK→RED', () {
    final (trs, _) = run(30, [
      [5, rawRed],
      [4, rawGreen],
      ...blinkSegments(3),
      [4, rawRed],
    ]);
    expect(statesOf(trs), [stateRed, stateGreen, stateGreenBlink, stateRed]);
  });

  test('15fps / 60fps에서도 같은 사이클', () {
    for (final fps in [15.0, 60.0]) {
      final (trs, _) = run(fps, [
        [5, rawRed],
        [4, rawGreen],
        ...blinkSegments(3),
        [4, rawRed],
      ]);
      expect(statesOf(trs), [stateRed, stateGreen, stateGreenBlink, stateRed]);
    }
  });

  test('1프레임 글리치 무시', () {
    final (trs, _) = run(30, [
      [3, rawRed],
      [1 / 30, rawGreen],
      [3, rawRed],
    ]);
    expect(statesOf(trs), [stateRed]);
  });

  test('점멸 후 안정 초록 복귀', () {
    final (trs, _) = run(30, [
      [4, rawGreen],
      ...blinkSegments(3),
      [5, rawGreen],
    ]);
    expect(statesOf(trs), [stateGreen, stateGreenBlink, stateGreen]);
  });

  test('점멸 중 UNKNOWN 없음', () {
    final (trs, _) = run(30, [
      [4, rawGreen],
      ...blinkSegments(6),
    ]);
    expect(statesOf(trs).contains(stateUnknown), isFalse);
  });

  test('소등 1.5초 후 UNKNOWN', () {
    final (trs, _) = run(30, [
      [3, rawRed],
      [3, rawNone],
    ]);
    final u = trs.where((t) => t.newState == stateUnknown).toList();
    expect(u.length, 1);
    expect(u.first.t, inInclusiveRange(3.0 + 1.4, 3.0 + 1.8));
  });

  test('긴 안정 구간 전환 1회', () {
    final (trs, _) = run(30, [
      [30, rawRed],
    ]);
    expect(statesOf(trs), [stateRed]);
  });

  test('느린 점멸 플래핑 없음', () {
    final (trs, _) = run(30, [
      [4, rawGreen],
      ...blinkSegments(6, period: 1.5),
    ]);
    expect(statesOf(trs), [stateGreen, stateGreenBlink]);
  });

  test('주기적 플리커에 전환 없음', () {
    final flicker = <List<dynamic>>[];
    for (var i = 0; i < 100; i++) {
      flicker.addAll([
        [1 / 30, rawRed],
        [1 / 30, rawRed],
        [1 / 30, rawNone],
      ]);
    }
    final (trs, _) = run(30, flicker);
    expect(statesOf(trs), isEmpty);
  });

  test('짧은 dropout이 가짜 점멸 안 만듦', () {
    final (trs, _) = run(30, [
      [3, rawGreen],
      [2 / 30, rawNone],
      [0.7, rawGreen],
      [2 / 30, rawNone],
      [3, rawGreen],
    ]);
    expect(statesOf(trs), [stateGreen]);
  });

  test('판정 보류 NONE은 점멸로 안 잡힘', () {
    final banding = <List<dynamic>>[
      [3, rawGreen],
    ];
    for (var i = 0; i < 6; i++) {
      banding.addAll([
        [0.6, rawGreen],
        [0.4, rawNone, 'brightness_jump'],
      ]);
    }
    final (trs, _) = run(30, banding);
    expect(statesOf(trs), [stateGreen]);
  });

  test('실제 소등 패턴은 여전히 점멸 감지', () {
    final realBlink = <List<dynamic>>[
      [3, rawGreen],
    ];
    for (var i = 0; i < 6; i++) {
      realBlink.addAll([
        [0.6, rawGreen],
        [0.4, rawNone],
      ]);
    }
    final (trs, _) = run(30, realBlink);
    expect(statesOf(trs), [stateGreen, stateGreenBlink]);
  });

  test('판정 보류 지속 → UNKNOWN 정상 전환', () {
    final (trs, _) = run(30, [
      [3, rawRed],
      [2.5, rawNone, 'camera_fail'],
    ]);
    expect(statesOf(trs), [stateRed, stateUnknown]);
  });
}
