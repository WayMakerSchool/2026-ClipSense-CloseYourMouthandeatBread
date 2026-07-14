import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/app/intersection.dart';
import 'package:clip_sense/app/intersection_finder.dart';

void main() {
  // 서울 시청(37.5665,126.9780) 주변 픽스처.
  const a = Intersection('1850', 'A', 37.5665, 126.9780, [Direction('st', '남')]);
  const b = Intersection('1537', 'B', 37.5700, 126.9820, [Direction('ne', '북동')]);
  const list = [a, b];

  test('distanceMeters: 같은 점은 0', () {
    expect(distanceMeters(37.5665, 126.9780, 37.5665, 126.9780), closeTo(0, 0.5));
  });

  test('distanceMeters: 위도 0.001도 ≈ 111m', () {
    final d = distanceMeters(37.5665, 126.9780, 37.5675, 126.9780);
    expect(d, closeTo(111, 5)); // 위도 1도≈111km → 0.001도≈111m
  });

  test('nearest: 정확히 A 위에 서면 A', () {
    final r = nearest(37.5665, 126.9780, list, radiusMeters: 100);
    expect(r?.itstId, '1850');
  });

  test('nearest: B에 더 가까우면 B', () {
    final r = nearest(37.5700, 126.9820, list, radiusMeters: 100);
    expect(r?.itstId, '1537');
  });

  test('nearest: 반경 밖이면 null', () {
    // A/B에서 멀리(부산 근처)
    final r = nearest(35.1796, 129.0756, list, radiusMeters: 100);
    expect(r, isNull);
  });

  test('nearest: 빈 목록이면 null', () {
    final r = nearest(37.5665, 126.9780, const [], radiusMeters: 100);
    expect(r, isNull);
  });

  test('nearest: 거리가 정확히 반경과 같으면 포함(경계 inclusive)', () {
    const it = Intersection('1850', 'A', 37.5665, 126.9780, [Direction('st', '남')]);
    const list = [it];
    final qLat = 37.5675, qLng = 126.9780; // A에서 북쪽으로 약간
    final d = distanceMeters(qLat, qLng, it.lat, it.lng);
    // 반경을 정확히 그 거리로 → 경계값. inclusive면 it 반환.
    final r = nearest(qLat, qLng, list, radiusMeters: d);
    expect(r?.itstId, '1850');
  });
}
