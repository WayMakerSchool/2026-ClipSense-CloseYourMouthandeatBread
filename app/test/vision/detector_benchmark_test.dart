// 프레임 처리 시간 측정. 실기기가 아니라 Dart VM(JIT) 기준이라 절대값은 실기기와
// 다르지만, 파이프라인 단계별 비중과 회귀(예: 새 필터가 몇 배 느리게 만들었는지)를
// 잡는 데 쓴다. 실기기 값은 진단 스트립(--dart-define=CLIP_DEBUG=true)의 ms 표시로 본다.
//
// 실행: flutter test test/vision/detector_benchmark_test.dart --plain-name 벤치마크
// (기본 테스트 실행에도 포함되지만, 상한만 확인하고 수치는 print로 남긴다.)
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/vision/color_detector.dart';
import 'package:clip_sense/vision/detector_config.dart';
import 'package:clip_sense/vision/digit_reader.dart';
import 'package:clip_sense/vision/image_ops.dart';
import 'package:clip_sense/vision/roi_image.dart';

File _fixture(String name) {
  for (final dir in ['test/fixtures', 'app/test/fixtures']) {
    final f = File('$dir/$name');
    if (f.existsSync()) return f;
  }
  throw StateError('fixture 없음: $name (cwd=${Directory.current.path})');
}

/// [rounds]회 실행 후 1회당 평균 마이크로초.
double _benchUs(int rounds, void Function() body) {
  // 워밍업(JIT 최적화가 붙은 뒤 측정).
  for (var i = 0; i < 3; i++) {
    body();
  }
  final sw = Stopwatch()..start();
  for (var i = 0; i < rounds; i++) {
    body();
  }
  sw.stop();
  return sw.elapsedMicroseconds / rounds;
}

void main() {
  test('벤치마크: 실클립 ROI 320x180 프레임 처리 단계별 시간', () {
    final meta =
        jsonDecode(_fixture('real_signal_sequence.json').readAsStringSync())
            as Map<String, dynamic>;
    final width = meta['width'] as int;
    final height = meta['height'] as int;
    final bytes = Uint8List.fromList(
      _fixture('real_signal_sequence.bgr').readAsBytesSync(),
    );
    final roi = RoiImage(
      width,
      height,
      Uint8List.sublistView(bytes, 0, width * height * 3),
    );

    const cfg = DetectorConfig.defaults();
    final detector = ColorDetector(cfg);
    final digits = DigitReader(cfg);

    final blurUs = _benchUs(20, () => gaussianBlur5x5(roi));
    final detectUs = _benchUs(20, () => detector.detect(roi));
    final digitUs = _benchUs(20, () => digits.read(roi));
    final totalUs = detectUs + digitUs;

    // ignore: avoid_print
    print(
      '[벤치] ROI ${width}x$height — 블러 ${(blurUs / 1000).toStringAsFixed(1)}ms · '
      'detect ${(detectUs / 1000).toStringAsFixed(1)}ms · '
      '숫자판독 ${(digitUs / 1000).toStringAsFixed(1)}ms · '
      '합계 ${(totalUs / 1000).toStringAsFixed(1)}ms '
      '(Dart VM JIT 기준, 실기기 AOT는 더 빠름)',
    );

    // 상한: 카메라가 3프레임당 1회 처리하므로 30fps에서 100ms 예산.
    // JIT에서 이 상한을 넘으면 실기기에서도 위험 신호다.
    expect(
      totalUs / 1000,
      lessThan(100),
      reason:
          '프레임 처리가 100ms를 넘으면 판정이 stale(2초) 쪽으로 밀린다. '
          'kCameraProcessEveryN 상향이나 ROI 축소를 검토할 것.',
    );
  });
}
