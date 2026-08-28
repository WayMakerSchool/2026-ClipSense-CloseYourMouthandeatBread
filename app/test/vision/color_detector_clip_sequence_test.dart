// 실제 서울 보행등 클립(data/real_signal_clip.mp4)의 대표 프레임 3개로 Dart 검출기·
// 상태머신이 Python 원본과 같은 판정을 내는지 고정한다.
//
// fixture 생성(제3자 클립이라 프레임 3개의 중앙 ROI만 보관):
//   .venv/bin/python scripts/dump_clip_sequence.py --video data/real_signal_clip.mp4 \
//       --roi-frac 0.25 --pixel-frames 20,34,54 --out app/test/fixtures/real_signal_sequence
//
// 배경(실측으로 찾은 오판): ROI를 25%로 좁히자 잔여시간 7세그 숫자의 빨간 획이
// 면적 기준(0.5%)을 넘겨, 초록이 점멸로 꺼진 구간(프레임 30~41, 54~59)이 RED로
// 판정됐다. 상태머신이 GREEN_BLINK 대신 RED로 넘어가 현장에서는 초록 점멸에
// "빨간불입니다"가 나왔을 상황이다. 램프 bbox 종횡비(램프 0.48~0.92 vs 숫자 획
// 0.12~0.42)로 걸러 raw RED를 0으로 만들었고, 이 테스트가 그 회귀를 막는다.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/vision/color_detector.dart';
import 'package:clip_sense/vision/detector_config.dart';
import 'package:clip_sense/vision/roi_image.dart';
import 'package:clip_sense/vision/signal_state_machine.dart';

/// flutter test 는 패키지 루트(app/)에서 돈다. 저장소 루트에서 돌리는 경우도 허용.
File _fixture(String name) {
  for (final dir in ['test/fixtures', 'app/test/fixtures']) {
    final f = File('$dir/$name');
    if (f.existsSync()) return f;
  }
  throw StateError('fixture 없음: $name (cwd=${Directory.current.path})');
}

void main() {
  final meta =
      jsonDecode(_fixture('real_signal_sequence.json').readAsStringSync())
          as Map<String, dynamic>;
  final width = meta['width'] as int;
  final height = meta['height'] as int;
  final frameBytes = width * height * 3;
  final pixels = Uint8List.fromList(
    _fixture('real_signal_sequence.bgr').readAsBytesSync(),
  );
  final frames = (meta['frames'] as List).cast<Map<String, dynamic>>();
  final keptIndices = (meta['pixel_frame_indices'] as List).cast<int>();

  /// 픽셀이 담긴 i번째 프레임의 ROI.
  RoiImage roiAt(int slot) => RoiImage(
    width,
    height,
    Uint8List.sublistView(pixels, slot * frameBytes, (slot + 1) * frameBytes),
  );

  Map<String, dynamic> expectedFor(int frameIndex) =>
      frames.firstWhere((f) => f['index'] == frameIndex);

  test('fixture 무결성: 프레임 수·크기·ROI 비율', () {
    expect(pixels.length, keptIndices.length * frameBytes);
    expect(keptIndices, [20, 34, 54]);
    expect((meta['crop'] as Map)['roi_frac'], 0.25);
    // 제3자 클립이므로 저장소에 담는 픽셀을 제한한다.
    expect(pixels.length, lessThanOrEqualTo(600 * 1024));
  });

  group('Python 원본과 같은 프레임 판정', () {
    for (var slot = 0; slot < 3; slot++) {
      final frameIndex = [20, 34, 54][slot];
      final expected = expectedFor(frameIndex);
      test('프레임 $frameIndex → raw ${expected['raw']}', () {
        // 각 프레임을 새 검출기로 판정한다(EMA·히스테리시스 이력 없음 —
        // Python dump 스크립트는 연속 처리지만, 담긴 프레임은 밝기가
        // 안정 구간이라 EMA 영향이 없음을 아래 수치 비교가 확인한다).
        final d = ColorDetector(const DetectorConfig.defaults());
        final r = d.detect(roiAt(slot));
        expect(r.raw, expected['raw']);
        expect(r.reason, expected['reason']);
        expect(
          r.green.areaRatio,
          closeTo(expected['green_area_ratio'] as double, 0.002),
        );
        expect(
          r.red.areaRatio,
          closeTo(expected['red_area_ratio'] as double, 0.002),
        );
        expect(r.brightness, closeTo(expected['brightness'] as double, 0.05));
      });
    }
  });

  test('점멸로 꺼진 구간의 빨간 7세그 숫자를 빨간불로 읽지 않는다', () {
    // 프레임 34·54는 초록이 꺼져 있고 빨간 숫자만 남은 프레임이다.
    // 종횡비 필터가 없으면 red.valid=true → raw RED가 됐다.
    for (final frameIndex in [34, 54]) {
      final slot = keptIndices.indexOf(frameIndex);
      final d = ColorDetector(const DetectorConfig.defaults());
      final r = d.detect(roiAt(slot));
      expect(r.raw, isNot(rawRed), reason: '프레임 $frameIndex');
      expect(
        r.red.valid,
        isFalse,
        reason:
            '프레임 $frameIndex: 빨강 면적 ${r.red.areaRatio}, '
            '종횡비 ${r.red.aspectRatio} — 숫자 획은 램프가 아니다',
      );
      expect(r.red.aspectRatio, lessThan(0.45), reason: '프레임 $frameIndex');
    }
  });

  test('전체 시퀀스에 빨간불 판정이 없다 (초록·점멸 클립)', () {
    final raws = frames.map((f) => f['raw'] as String).toList();
    expect(raws.where((r) => r == rawRed), isEmpty);
    expect(raws.where((r) => r == rawGreen).length, greaterThan(30));
    // 상태머신도 RED로 넘어가지 않고 초록/점멸로 수렴한다.
    final states = frames.map((f) => f['state'] as String).toSet();
    expect(states.contains('RED'), isFalse);
    expect(states.contains('GREEN_BLINK'), isTrue);
  });

  test('담긴 프레임을 순서대로 넣으면 상태머신이 초록을 유지한다', () {
    final cfg = const DetectorConfig.defaults();
    final d = ColorDetector(cfg);
    final machine = SignalStateMachine(cfg);
    // 프레임 20(초록)을 디바운스 이상 반복 → GREEN 진입.
    for (var i = 0; i < cfg.debounceFrames + 2; i++) {
      final r = d.detect(roiAt(0));
      machine.update(i / 30.0, r.raw, reason: r.reason);
    }
    expect(machine.state, stateGreen);

    // 이어서 프레임 34(초록 꺼짐 + 빨간 숫자)를 넣어도 RED로 넘어가지 않는다.
    var t = (cfg.debounceFrames + 2) / 30.0;
    for (var i = 0; i < cfg.debounceFrames + 2; i++) {
      final r = d.detect(roiAt(1));
      machine.update(t, r.raw, reason: r.reason);
      t += 1 / 30.0;
    }
    expect(machine.state, isNot(stateRed));
  });
}
