// test_detector.py 미러링: ColorDetector 신뢰도 로직 단위 테스트
// (합성 프레임: 회색 배경 + 중앙 채운 원, cv2.circle 재현).
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/vision/detector_config.dart';
import 'package:clip_sense/vision/roi_image.dart';
import 'package:clip_sense/vision/color_detector.dart';

const size = 200; // ROI 200x200 (test_detector.py SIZE)

// 회색 배경 + 중앙 채운 원(BGR). Python test_detector.py의 frame()/cv2.circle 재현.
RoiImage frame({int bg = 80, List<int>? circleBgr, int r = 0}) {
  final bytes = Uint8List(size * size * 3);
  for (var i = 0; i < size * size; i++) {
    bytes[i * 3] = bg;
    bytes[i * 3 + 1] = bg;
    bytes[i * 3 + 2] = bg;
  }
  if (circleBgr != null) {
    const cx = size ~/ 2, cy = size ~/ 2;
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final dx = x - cx, dy = y - cy;
        if (dx * dx + dy * dy <= r * r) {
          final idx = (y * size + x) * 3;
          bytes[idx] = circleBgr[0];
          bytes[idx + 1] = circleBgr[1];
          bytes[idx + 2] = circleBgr[2];
        }
      }
    }
  }
  return RoiImage(size, size, bytes);
}

// BGR 색상(test_detector.py 상수 그대로).
const red = [40, 40, 235];
const redDim = [30, 30, 120]; // 어두운 빨강(밝기 급변 없이 blob_too_large 테스트용)
const green = [70, 210, 80];

void main() {
  test('1. 빈 회색 프레임 → NONE/no_blob (EMA 초기화)', () {
    final d = ColorDetector(const DetectorConfig.defaults());
    final r = d.detect(frame());
    expect(r.raw, rawNone);
    expect(r.reason, 'no_blob');
  });

  test('2. 빨간 원 → RED', () {
    final d = ColorDetector(const DetectorConfig.defaults());
    final r = d.detect(frame(circleBgr: red, r: 25));
    expect(r.raw, rawRed);
  });

  test('3. 초록 원 → GREEN', () {
    final d = ColorDetector(const DetectorConfig.defaults());
    final r = d.detect(frame(circleBgr: green, r: 25));
    expect(r.raw, rawGreen);
  });

  test('4. 아주 어두운 프레임(렌즈 가림) → too_dark', () {
    final d = ColorDetector(const DetectorConfig.defaults());
    final r = d.detect(frame(bg: 10));
    expect(r.raw, rawNone);
    expect(r.reason, 'too_dark');
  });

  test('5. 밝기 급변(밝은 회색으로 가림) → brightness_jump', () {
    final d = ColorDetector(const DetectorConfig.defaults());
    d.detect(frame(bg: 80)); // ema 초기화
    final r = d.detect(frame(bg: 200));
    expect(r.raw, rawNone);
    expect(r.reason, 'brightness_jump');
  });

  test('6. ROI 대부분을 덮는 빨간 물체 → blob_too_large (신호등이 아님)', () {
    final d = ColorDetector(const DetectorConfig.defaults());
    d.detect(frame()); // EMA 초기화
    final r = d.detect(frame(circleBgr: redDim, r: 94)); // 면적 ≈ 70% > max 60%
    expect(r.raw, rawNone);
    expect(r.reason, 'blob_too_large');
  });

  group('7. 검출 히스테리시스', () {
    test(
        '진입 임계(0.5%) 미달이지만 이탈 임계(0.3%) 이상인 작은 초록 blob은 '
        '직전에 GREEN이었을 때만 유지된다', () {
      final d = ColorDetector(const DetectorConfig.defaults());
      d.detect(frame()); // EMA 초기화, last=NONE
      final rSmallFirst =
          d.detect(frame(circleBgr: green, r: 7)); // 0.38% < 0.5% → NONE
      final rBig = d.detect(frame(circleBgr: green, r: 25)); // 확실한 GREEN
      final rSmallAfter =
          d.detect(frame(circleBgr: green, r: 7)); // 0.38% ≥ 0.3% → 유지

      expect(rSmallFirst.raw, rawNone,
          reason: '진입 전 작은 blob 거부 (실제: ${rSmallFirst.raw}, '
              'area_ratio=${rSmallFirst.green.areaRatio})');
      expect(rBig.raw, rawGreen);
      expect(rSmallAfter.raw, rawGreen,
          reason: '검출 중 작은 blob 유지 (실제: ${rBig.raw} -> ${rSmallAfter.raw})');
    });
  });
}
