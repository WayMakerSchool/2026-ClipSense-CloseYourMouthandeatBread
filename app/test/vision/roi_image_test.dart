import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/vision/roi_image.dart';

RoiImage solid(int w, int h, int b, int g, int r) {
  final bytes = Uint8List(w * h * 3);
  for (var i = 0; i < w * h; i++) {
    bytes[i * 3] = b;
    bytes[i * 3 + 1] = g;
    bytes[i * 3 + 2] = r;
  }
  return RoiImage(w, h, bytes);
}

void main() {
  test('순수 빨강 BGR(0,0,255) → H≈0, S=255, V=255', () {
    final hsv = bgrToHsv(solid(2, 2, 0, 0, 255));
    expect(hsv[0], closeTo(0, 1));   // H
    expect(hsv[1], 255);             // S
    expect(hsv[2], 255);             // V
  });

  test('순수 초록 BGR(0,255,0) → H≈60', () {
    final hsv = bgrToHsv(solid(2, 2, 0, 255, 0));
    expect(hsv[0], closeTo(60, 1));
  });

  test('순수 파랑 BGR(255,0,0) → H≈120', () {
    final hsv = bgrToHsv(solid(1, 1, 255, 0, 0));
    expect(hsv[0], closeTo(120, 1));
  });

  test('검정 → V=0, S=0', () {
    final hsv = bgrToHsv(solid(1, 1, 0, 0, 0));
    expect(hsv[2], 0);
    expect(hsv[1], 0);
  });

  test('회색 BGR(128,128,128) → S=0, V=128', () {
    final hsv = bgrToHsv(solid(1, 1, 128, 128, 128));
    expect(hsv[1], 0);
    expect(hsv[2], 128);
  });
}
