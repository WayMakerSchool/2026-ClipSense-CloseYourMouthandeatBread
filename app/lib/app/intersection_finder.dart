/// GPS 위치 → 최근접 교차로. 순수 함수(하드웨어·네트워크 없음).
library;

import 'dart:math' as math;

import 'intersection.dart';

/// 두 위경도 간 대원거리(m). 하버사인.
double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  const earthRadius = 6371000.0; // m
  final dLat = _rad(lat2 - lat1);
  final dLng = _rad(lng2 - lng1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_rad(lat1)) *
          math.cos(_rad(lat2)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return earthRadius * c;
}

double _rad(double deg) => deg * math.pi / 180.0;

/// 반경 내 최근접 교차로. 반경 밖이거나 목록이 비면 null.
Intersection? nearest(double lat, double lng, List<Intersection> list,
    {double radiusMeters = 100}) {
  Intersection? best;
  double bestDist = double.infinity;
  for (final it in list) {
    final d = distanceMeters(lat, lng, it.lat, it.lng);
    if (d < bestDist) {
      bestDist = d;
      best = it;
    }
  }
  if (best == null || bestDist > radiusMeters) return null;
  return best;
}
