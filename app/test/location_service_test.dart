// GeolocatorLocationService는 하드웨어 의존이라 테스트 안 함(인터페이스 뒤 격리).
// 여기선 sealed 결과 타입과 Fake로 소비자 계약만 검증.
import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/app/location_service.dart';

class FakeLocationService implements LocationService {
  final LocationResult result;
  FakeLocationService(this.result);
  @override
  Future<LocationResult> current() async => result;
}

void main() {
  test('LocationOk는 좌표를 담는다', () async {
    final s = FakeLocationService(LocationOk(37.5, 127.0));
    final r = await s.current();
    expect(r, isA<LocationOk>());
    expect((r as LocationOk).lat, 37.5);
    expect(r.lng, 127.0);
  });

  test('LocationDenied / LocationUnavailable 구분', () async {
    expect(await FakeLocationService(LocationDenied()).current(),
        isA<LocationDenied>());
    expect(await FakeLocationService(LocationUnavailable()).current(),
        isA<LocationUnavailable>());
  });

  test('sealed switch는 모든 경우를 강제한다', () {
    String describe(LocationResult r) => switch (r) {
          LocationOk() => 'ok',
          LocationDenied() => 'denied',
          LocationUnavailable() => 'unavailable',
        };
    expect(describe(LocationOk(1, 2)), 'ok');
    expect(describe(LocationDenied()), 'denied');
    expect(describe(LocationUnavailable()), 'unavailable');
  });
}
