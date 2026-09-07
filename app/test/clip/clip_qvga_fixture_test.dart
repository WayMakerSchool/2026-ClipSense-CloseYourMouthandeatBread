// 클립 카메라가 보낼 법한 QVGA(320x240) 전체 프레임 fixture 의 기하 기록.
//
// 정직한 기록이 목적이다: 이 fixture 는 제3자 실클립을 4:3 으로 잘라 줄이고
// cv2 로 인코딩한 것(scripts/dump_clip_qvga_fixture.py)이지 OV2640 이 만든
// JPEG 이 아니다. 코덱·크롭 기하 회귀용이며 클립 카메라의 인식 거리를 말하지
// 않는다. 숫자는 fixture JSON 의 python_reference(detector.py)와 대조한다.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clip_sense/app/config.dart';
import 'package:clip_sense/clip/jpeg_frame.dart';
import 'package:clip_sense/vision/color_detector.dart';
import 'package:clip_sense/vision/detector_config.dart';
import 'package:flutter_test/flutter_test.dart';

File _fixture(String name) {
  for (final dir in ['test/fixtures', 'app/test/fixtures']) {
    final f = File('$dir/$name');
    if (f.existsSync()) return f;
  }
  throw StateError('fixture 없음: $name (cwd=${Directory.current.path})');
}

final Map<String, dynamic> meta =
    jsonDecode(_fixture('clip_qvga_fixture.json').readAsStringSync())
        as Map<String, dynamic>;

Map<String, dynamic> _frame(int index) => (meta['frames'] as List)
    .cast<Map<String, dynamic>>()
    .firstWhere((f) => f['frame_index'] == index);

Uint8List _jpeg(int index) => Uint8List.fromList(
  _fixture(_frame(index)['file'] as String).readAsBytesSync(),
);

FrameResult _detect(int index, double roiFrac) {
  final roi = decodeJpegToRoiBgr(_jpeg(index), roiFrac)!;
  return ColorDetector(const DetectorConfig.defaults()).detect(roi);
}

Map<String, dynamic> _ref(int index, double roiFrac) =>
    (_frame(index)['python_reference'] as Map<String, dynamic>)['$roiFrac']
        as Map<String, dynamic>;

void main() {
  test('fixture 무결성: 320x240, 10KB 미만, 크기 일치', () {
    for (final index in [20, 34]) {
      final bytes = _jpeg(index);
      expect(bytes.length, lessThan(10 * 1024));
      expect(bytes.length, _frame(index)['bytes']);
      final full = decodeJpegToRoiBgr(bytes, 1.0)!;
      expect((full.width, full.height), (320, 240));
    }
  });

  test('QVGA 전체 프레임(roiFrac 1.0)은 점등 프레임에서도 no_blob — 판정 근거로 못 쓴다', () {
    final r = _detect(20, 1.0);
    expect(r.raw, rawNone);
    expect(r.reason, 'no_blob');
    expect(r.green.areaRatio, lessThan(0.005));
    expect(
      r.green.areaRatio,
      closeTo(_ref(20, 1.0)['green_area_ratio'] as double, 0.003),
    );
  });

  test('roiFrac 0.5 는 점멸 소등 프레임(34)에서도 GREEN — 기본값으로 쓰지 않는 이유', () {
    final on = _detect(20, 0.5);
    final off = _detect(34, 0.5);
    expect(on.raw, rawGreen);
    expect(off.raw, rawGreen, reason: '소등인데 GREEN: 이 기하는 점멸을 놓친다');
    expect(
      off.green.areaRatio,
      closeTo(_ref(34, 0.5)['green_area_ratio'] as double, 0.004),
    );
  });

  test('roiFrac 0.25(기본): 점등 20 → GREEN, 소등 34 → NONE', () {
    expect(kClipRoiFrac, 0.25);
    final on = _detect(20, kClipRoiFrac);
    final off = _detect(34, kClipRoiFrac);
    expect(on.raw, rawGreen);
    expect(
      on.green.areaRatio,
      closeTo(_ref(20, 0.25)['green_area_ratio'] as double, 0.006),
    );
    expect(off.raw, rawNone);
    expect(
      off.green.areaRatio,
      closeTo(_ref(34, 0.25)['green_area_ratio'] as double, 0.003),
    );
  });
}
