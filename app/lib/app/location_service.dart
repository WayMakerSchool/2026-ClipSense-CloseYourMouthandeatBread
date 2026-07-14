/// GPS 위치 획득. 실패를 sealed 결과로 표현(예외 대신). 실제 구현은 geolocator.
library;

import 'package:geolocator/geolocator.dart';

/// 위치 획득 결과. 화면이 모든 경우를 명시 처리.
sealed class LocationResult {}

class LocationOk extends LocationResult {
  final double lat;
  final double lng;
  LocationOk(this.lat, this.lng);
}

class LocationDenied extends LocationResult {}      // 권한 거부

class LocationUnavailable extends LocationResult {} // 위치 못 잡음/서비스 꺼짐

abstract class LocationService {
  Future<LocationResult> current();
}

/// 서비스/권한 상태 → 결과 분류(순수). 실패 안내가 어느 것인지 결정하는 안전 로직.
LocationResult? classifyLocation({
  required bool serviceEnabled,
  required LocationPermission permission,
}) {
  if (!serviceEnabled) return LocationUnavailable();
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    return LocationDenied();
  }
  return null; // null = 진행 가능(위치 획득 시도)
}

/// geolocator 기반 실제 구현. 하드웨어·권한 의존이라 단위 테스트 안 함(분류 로직은
/// classifyLocation으로 분리해 순수 테스트).
/// 모든 예외를 삼켜 LocationUnavailable로 수렴(앱을 죽이지 않음).
class GeolocatorLocationService implements LocationService {
  @override
  Future<LocationResult> current() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return LocationUnavailable();
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      final classified = classifyLocation(
        serviceEnabled: serviceEnabled,
        permission: perm,
      );
      if (classified != null) return classified;
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          timeLimit: Duration(seconds: 10),
        ),
      );
      return LocationOk(pos.latitude, pos.longitude);
    } catch (_) {
      return LocationUnavailable();
    }
  }
}
