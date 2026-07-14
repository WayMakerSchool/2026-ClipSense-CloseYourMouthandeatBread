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

/// geolocator 기반 실제 구현. 하드웨어·권한 의존이라 단위 테스트 안 함.
/// 모든 예외를 삼켜 LocationUnavailable로 수렴(앱을 죽이지 않음).
class GeolocatorLocationService implements LocationService {
  @override
  Future<LocationResult> current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return LocationUnavailable();
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return LocationDenied();
      }
      final pos = await Geolocator.getCurrentPosition();
      return LocationOk(pos.latitude, pos.longitude);
    } catch (_) {
      return LocationUnavailable();
    }
  }
}
