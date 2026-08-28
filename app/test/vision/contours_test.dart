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

  // --- 퇴화(degenerate)/경계(border) 케이스: circularity가 NaN/Infinity를
  // downstream(>= minCircularity 비교)으로 흘려보내지 않는지 고정한다.
  // NaN >= threshold는 항상 false이므로, NaN이 새면 신호가 "조용히" 오검출된다.

  test('단일 픽셀 blob → contour 1개, circularity 0.0(NaN 아님), throw 없음', () {
    final m = Uint8List(100 * 100);
    m[50 * 100 + 50] = 255; // 고립 픽셀 1개.
    final cs = findContours(m, 100, 100);
    expect(cs.length, 1);
    expect(cs.first.length, 1);
    final c = circularity(cs.first);
    expect(c, 0.0);
    expect(c.isFinite, isTrue);
    expect(c.isNaN, isFalse);
  });

  test('1픽셀 폭 가로선(5픽셀, 높이1) → 면적 0, circularity 0.0, isFinite', () {
    final m = Uint8List(100 * 100);
    for (var x = 40; x < 45; x++) {
      m[50 * 100 + x] = 255; // y=50 행에 5픽셀 연속.
    }
    final cs = findContours(m, 100, 100);
    expect(cs.length, 1);
    final area = contourArea(cs.first);
    expect(area, 0.0);
    final c = circularity(cs.first);
    expect(c, 0.0);
    expect(c.isFinite, isTrue);
  });

  test('빈 마스크 → findContours 빈 리스트(중복 확인, 명시적 계약)', () {
    final m = Uint8List(50 * 50);
    expect(findContours(m, 50, 50), isEmpty);
  });

  test(
    '이미지 좌측 경계에 붙은 사각 blob → contour 1개, 닫힘(면적>0), circularity isFinite',
    () {
      // x=0 경계에 flush로 붙은 채운 사각형: ROI 경계에 걸친 신호 blob 근사.
      final m = filledRect(100, 100, 0, 30, 20, 70);
      final cs = findContours(m, 100, 100);
      expect(cs.length, 1);
      final area = contourArea(cs.first);
      expect(area, greaterThan(0.0));
      final c = circularity(cs.first);
      expect(c.isFinite, isTrue);
      expect(c.isNaN, isFalse);
    },
  );

  test(
    '상단 행 중앙에 걸친 반원형 blob(top border) → contour 1개, 닫힘, circularity isFinite',
    () {
      // y=0 행에서 잘린 반원: 위쪽 경계에 걸친 blob 근사.
      final w = 100, h = 100;
      final m = filledCircle(w, h, 50, 0, 20);
      final cs = findContours(m, w, h);
      expect(cs.length, 1);
      final area = contourArea(cs.first);
      expect(area, greaterThan(0.0));
      final c = circularity(cs.first);
      expect(c.isFinite, isTrue);
    },
  );

  test('NaN 가드: 1px 선의 circularity는 항상 isFinite(>= minCircularity 비교를 보호)', () {
    // perimeter는 >0일 수 있으나 area=0인 케이스에서도 circularity가
    // NaN/Infinity로 새지 않아야 한다 — 이것이 findContours 결과를
    // `circularity(c) >= minCircularity`로 판정하는 downstream 로직의
    // 안전을 지키는 핵심 불변조건이다.
    final m = Uint8List(100 * 100);
    for (var x = 10; x < 15; x++) {
      m[10 * 100 + x] = 255;
    }
    final cs = findContours(m, 100, 100);
    expect(cs.length, 1);
    final c = circularity(cs.first);
    expect(
      c.isFinite,
      isTrue,
      reason: 'circularity must never be NaN/Infinity',
    );
    // NaN 비교는 항상 false이므로, 안전 쪽으로도 확인: 임계값 비교가
    // 정상적으로 false로 판정되는지(오검출 없이 "원이 아님"으로 거부됨).
    expect(c >= 0.7, isFalse);
  });
}
