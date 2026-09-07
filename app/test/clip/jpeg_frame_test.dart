// 클립 카메라 JPEG → 중앙 ROI BGR. 순수 Dart(image 패키지 decodeJpg)라
// 실기기 없이 flutter test 로 검증한다.
//
// 이 파일의 실클립 테스트는 "JPEG 코덱을 거쳐도 검출이 유지되는가"(코덱 회귀)
// 만 본다. 320x180 크롭 fixture 를 그대로 인코딩한 것이므로 클립 카메라의
// 실제 QVGA 전체 프레임 검출 거리를 말해 주지 않는다 —
// scripts/measure_clip_frame_size.py 참고.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clip_sense/clip/jpeg_frame.dart';
import 'package:clip_sense/vision/color_detector.dart';
import 'package:clip_sense/vision/detector_config.dart';
import 'package:clip_sense/vision/roi_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

File _fixture(String name) {
  for (final dir in ['test/fixtures', 'app/test/fixtures']) {
    final f = File('$dir/$name');
    if (f.existsSync()) return f;
  }
  throw StateError('fixture 없음: $name (cwd=${Directory.current.path})');
}

RoiImage _loadRoi() {
  final meta =
      jsonDecode(_fixture('real_signal_roi.json').readAsStringSync())
          as Map<String, dynamic>;
  return RoiImage(
    meta['width'] as int,
    meta['height'] as int,
    Uint8List.fromList(_fixture('real_signal_roi.bgr').readAsBytesSync()),
  );
}

/// BGR RoiImage → JPEG 바이트(테스트 전용 인코더).
Uint8List _encodeJpeg(RoiImage roi, {int quality = 90}) {
  final image = img.Image.fromBytes(
    width: roi.width,
    height: roi.height,
    bytes: roi.bytes.buffer,
    bytesOffset: roi.bytes.offsetInBytes,
    numChannels: 3,
    order: img.ChannelOrder.bgr,
  );
  return img.encodeJpg(image, quality: quality);
}

/// 단색 사각형 안에 다른 단색 블록을 그린 합성 프레임(크롭 위치 검증용).
RoiImage _synthetic(int w, int h) {
  final bytes = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 3;
      final center =
          x >= w ~/ 4 && x < 3 * w ~/ 4 && y >= h ~/ 4 && y < 3 * h ~/ 4;
      bytes[i] = center ? 200 : 20; // B
      bytes[i + 1] = center ? 30 : 220; // G
      bytes[i + 2] = center ? 40 : 60; // R
    }
  }
  return RoiImage(w, h, bytes);
}

void main() {
  group('decodeJpegToRoiBgr', () {
    test('실클립 ROI를 JPEG(q90)로 왕복해도 검출기는 GREEN을 유지한다', () {
      final original = _loadRoi();
      final jpeg = _encodeJpeg(original);
      final decoded = decodeJpegToRoiBgr(jpeg, 1.0)!;
      expect(decoded.width, original.width);
      expect(decoded.height, original.height);

      // 코덱 손실은 평균 절대 오차 몇 단계 이내.
      var sum = 0;
      for (var i = 0; i < original.bytes.length; i++) {
        sum += (original.bytes[i] - decoded.bytes[i]).abs();
      }
      expect(sum / original.bytes.length, lessThan(4.0));

      final frame = ColorDetector(
        const DetectorConfig.defaults(),
      ).detect(decoded);
      expect(frame.raw, rawGreen);
      expect(frame.green.areaRatio, greaterThan(0.02));
    });

    test('roiFrac 0.5는 중앙 절반(가로·세로)만 돌려준다 — 320x240 → 160x120', () {
      final full = _synthetic(320, 240);
      final jpeg = _encodeJpeg(full, quality: 100);
      final roi = decodeJpegToRoiBgr(jpeg, 0.5)!;
      expect(roi.width, 160);
      expect(roi.height, 120);
      // 중앙 블록(파랑 계열)만 남고 바깥 초록 배경은 없다.
      var blueish = 0;
      for (var i = 0; i < roi.width * roi.height; i++) {
        if (roi.bytes[i * 3] > 150 && roi.bytes[i * 3 + 1] < 90) blueish++;
      }
      expect(blueish / (roi.width * roi.height), greaterThan(0.97));
    });

    test('roiFrac 1.0은 전체 프레임', () {
      final roi = decodeJpegToRoiBgr(_encodeJpeg(_synthetic(64, 48)), 1.0)!;
      expect((roi.width, roi.height), (64, 48));
      expect(roi.bytes.length, 64 * 48 * 3);
    });

    test('JPEG이 아니거나 잘린 바이트는 null(던지지 않음)', () {
      expect(decodeJpegToRoiBgr(Uint8List(0), 0.5), isNull);
      expect(
        decodeJpegToRoiBgr(Uint8List.fromList([1, 2, 3, 4, 5]), 0.5),
        isNull,
      );
      final jpeg = _encodeJpeg(_synthetic(64, 48));
      final truncated = Uint8List.sublistView(jpeg, 0, jpeg.length ~/ 3);
      // 잘린 JPEG 은 디코더가 부분 이미지를 내거나 실패한다 — 어느 쪽이든 던지지 않는다.
      expect(() => decodeJpegToRoiBgr(truncated, 0.5), returnsNormally);
    });

    test('roiFrac 범위 밖은 ArgumentError', () {
      final jpeg = _encodeJpeg(_synthetic(64, 48));
      expect(() => decodeJpegToRoiBgr(jpeg, 0), throwsA(isA<ArgumentError>()));
      expect(
        () => decodeJpegToRoiBgr(jpeg, 1.5),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('bgrCenterCrop', () {
    test('BGR 프레임의 중앙 ROI만 복사한다', () {
      final full = _synthetic(80, 60);
      final roi = bgrCenterCrop(full, 0.25);
      expect((roi.width, roi.height), (20, 15));
      // 중앙은 파랑 계열 블록.
      expect(roi.bytes[0], 200);
      expect(roi.bytes[1], 30);
    });

    test('roiFrac 1.0은 같은 객체', () {
      final full = _synthetic(8, 6);
      expect(identical(bgrCenterCrop(full, 1.0), full), isTrue);
    });
  });
}
