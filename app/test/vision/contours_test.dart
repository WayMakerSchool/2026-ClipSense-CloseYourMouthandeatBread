import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/vision/contours.dart';

// 마스크에 채운 원 그리기.
Uint8List filledCircle(int w, int h, int cx, int cy, int r) {
  final m = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final dx = x - cx, dy = y - cy;
      if (dx * dx + dy * dy <= r * r) m[y * w + x] = 255;
    }
  }
  return m;
}

Uint8List filledRect(int w, int h, int x1, int y1, int x2, int y2) {
  final m = Uint8List(w * h);
  for (var y = y1; y < y2; y++) {
    for (var x = x1; x < x2; x++) {
      m[y * w + x] = 255;
    }
  }
  return m;
}

void main() {
  test('빈 마스크 → contour 없음', () {
    expect(findContours(Uint8List(100), 10, 10), isEmpty);
  });

  test('채운 원 → 면적 ≈ πr², 원형도 ≈ 1.0', () {
    final m = filledCircle(100, 100, 50, 50, 20);
    final cs = findContours(m, 100, 100);
    expect(cs.length, 1);
    final area = contourArea(cs.first);
    expect(area, closeTo(math.pi * 20 * 20, math.pi * 20 * 20 * 0.15));
    expect(circularity(cs.first), closeTo(1.0, 0.2));
  });

  test('채운 사각 → 원형도가 원보다 낮음(< 0.85)', () {
    final m = filledRect(100, 100, 30, 30, 70, 70);
    final cs = findContours(m, 100, 100);
    expect(cs.length, 1);
    expect(circularity(cs.first), lessThan(0.85));
  });

  test('blob 2개 → contour 2개', () {
    final m = filledCircle(100, 100, 25, 25, 8);
    final m2 = filledCircle(100, 100, 75, 75, 8);
    for (var i = 0; i < m.length; i++) {
      if (m2[i] == 255) m[i] = 255;
    }
    expect(findContours(m, 100, 100).length, 2);
  });
}
