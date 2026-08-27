// 실제 서울 보행등 근접 클립(data/real_signal_clip.mp4, 제3자 클립이라 단일 프레임의
// 중앙 ROI 크롭만 fixture로 보관)으로 Dart ColorDetector가 초록 보행등을 잡는지 고정한다.
//
// fixture 생성: scripts/dump_roi_fixture.py (같은 바이트를 Python detector.py로 판정한
// 결과가 real_signal_roi.json 의 python_reference 에 들어 있다).
//
// 배경(확정 블로커): 블러 없는 Dart 검출기는 이 클립의 초록 blob을 minAreaRatio(0.5%)
// 아래로 잘게 쪼개 no_blob을 냈다. Python 원본은 HSV 변환 전 5x5 가우시안 블러를 하고
// ROI를 25%로 좁히면 초록 면적이 2% 이상으로 안정된다.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/vision/color_detector.dart';
import 'package:clip_sense/vision/detector_config.dart';
import 'package:clip_sense/vision/roi_image.dart';

/// flutter test 는 패키지 루트(app/)에서 돈다. 저장소 루트에서 돌리는 경우도 허용.
File _fixture(String name) {
  for (final dir in ['test/fixtures', 'app/test/fixtures']) {
    final f = File('$dir/$name');
    if (f.existsSync()) return f;
  }
  throw StateError('fixture 없음: $name (cwd=${Directory.current.path})');
}

class _Fixture {
  final RoiImage roi;
  final Map<String, dynamic> meta;
  final Map<String, dynamic> pythonRef;
  _Fixture(this.roi, this.meta, this.pythonRef);
}

_Fixture _loadFixture() {
  final meta = jsonDecode(_fixture('real_signal_roi.json').readAsStringSync())
      as Map<String, dynamic>;
  final bytes = Uint8List.fromList(_fixture('real_signal_roi.bgr').readAsBytesSync());
  final w = meta['width'] as int, h = meta['height'] as int;
  return _Fixture(
    RoiImage(w, h, bytes),
    meta,
    meta['python_reference'] as Map<String, dynamic>,
  );
}

void main() {
  test('fixture 무결성: 320x180 BGR, 앱 kRoiFrac=0.25 중앙 크롭, 200KB 이하', () {
    final f = _loadFixture();
    expect(f.roi.width, 320);
    expect(f.roi.height, 180);
    expect(f.roi.bytes.length, 320 * 180 * 3);
    expect(f.roi.bytes.length, lessThanOrEqualTo(200 * 1024));
    expect((f.meta['crop'] as Map<String, dynamic>)['roi_frac'], 0.25);
    // Python 기준 판정 자체가 GREEN이어야 fixture로서 의미가 있다.
    expect(f.pythonRef['raw'], 'GREEN');
    expect(f.pythonRef['green_valid'], isTrue);
  });

  test('실제 보행등 초록 프레임 → raw GREEN, green.valid (Python detector.py와 같은 판정)', () {
    final f = _loadFixture();
    final d = ColorDetector(const DetectorConfig.defaults());
    final r = d.detect(f.roi);
    expect(r.raw, rawGreen, reason: 'reason=${r.reason} green=${r.green.areaRatio}');
    expect(r.green.valid, isTrue);
    expect(r.reason, '');
    expect(r.red.valid, isFalse);
  });

  test('초록 면적·밝기가 Python 기준값과 일치 (블러 5x5 포함한 경로 재현)', () {
    final f = _loadFixture();
    final r = ColorDetector(const DetectorConfig.defaults()).detect(f.roi);
    // 블러 없이는 초록 blob 면적이 Python의 절반 수준(1.5% vs 2.4%)으로 떨어진다.
    // 경계추적·형태학 미세차만 허용(±0.2%p).
    expect(r.green.areaRatio,
        closeTo(f.pythonRef['green_area_ratio'] as double, 0.002));
    // 블러가 OpenCV와 수치 동일하고 V=max(B,G,R)이므로 밝기 평균은 거의 정확히 같아야 한다.
    expect(r.brightness, closeTo(f.pythonRef['brightness'] as double, 0.05));
  });

  test('같은 프레임 반복 입력에도 GREEN 유지 (히스테리시스가 판정을 뒤집지 않음)', () {
    final f = _loadFixture();
    final d = ColorDetector(const DetectorConfig.defaults());
    for (var i = 0; i < 3; i++) {
      expect(d.detect(f.roi).raw, rawGreen);
    }
  });
}
