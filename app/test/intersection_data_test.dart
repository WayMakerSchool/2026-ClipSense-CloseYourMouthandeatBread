import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/app/intersection.dart';

void main() {
  test('운영 교차로 매핑은 공식 T-Data 이름과 좌표를 사용한다', () {
    final byId = {
      for (final intersection in kIntersections)
        intersection.itstId: intersection,
    };

    expect(byId.keys, containsAll(<String>['1850', '1537', '1620']));
    expect(byId, isNot(contains('4031')));

    expect(byId['1850']!.name, '청계2가');
    expect(byId['1850']!.lat, closeTo(37.5682795, 0.0000001));
    expect(byId['1850']!.lng, closeTo(126.9876861, 0.0000001));

    expect(byId['1537']!.name, '정동');
    expect(byId['1537']!.lat, closeTo(37.5683276, 0.0000001));
    expect(byId['1537']!.lng, closeTo(126.9691612, 0.0000001));

    expect(byId['1620']!.name, '국일관');
    expect(byId['1620']!.lat, closeTo(37.5703027, 0.0000001));
    expect(byId['1620']!.lng, closeTo(126.9897302, 0.0000001));
  });

  test('모든 운영 교차로는 사용자에게 노출할 검증 방향이 하나 이상 있다', () {
    expect(kIntersections, isNotEmpty);
    for (final intersection in kIntersections) {
      expect(intersection.name, isNot(contains('테스트')));
      expect(intersection.directions, isNotEmpty, reason: intersection.itstId);
      expect(
        intersection.directions
            .map((direction) => direction.code)
            .toSet()
            .length,
        intersection.directions.length,
        reason: '${intersection.itstId}의 방향 코드가 중복되면 안 됩니다',
      );
    }
  });
}
