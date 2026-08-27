/// 교차로·방향 모델과 서울 소규모 수동 매핑.
/// GPS→교차로 선택에 쓰인다. itstId·방향은 실API 검증값이며 좌표·이름은
/// 서울 T-Data `교차로 MAP 정보` CSV(2024-11-14 배포본, data_id=10144)로
/// 대조했다. 원본 Open API는 data_id=10121이다.
library;

/// 교차로의 한 방향(횡단보도). code는 T-Data 방위 접두사.
class Direction {
  final String code; // nt/et/st/wt/ne/se/sw/nw
  final String label; // 스크린리더용, 예: '북쪽 횡단보도'
  const Direction(this.code, this.label);
}

/// 한 교차로. itstId로 T-Data 신호를 조회한다.
class Intersection {
  final String itstId;
  final String name;
  final double lat;
  final double lng;
  final List<Direction> directions;
  const Intersection(
    this.itstId,
    this.name,
    this.lat,
    this.lng,
    this.directions,
  );
}

/// 서울 소규모 수동 매핑. 좌표·교차로명은 위 공식 CSV 값 그대로다.
/// 방향은 신호 API에서 실제 응답 필드가 확인된 횡단보도만 노출한다.
const List<Intersection> kIntersections = [
  Intersection('1850', '청계2가', 37.5682795, 126.9876861, [
    Direction('nt', '북쪽 횡단보도'),
    Direction('et', '동쪽 횡단보도'),
    Direction('st', '남쪽 횡단보도'),
  ]),
  Intersection('1537', '정동', 37.5683276, 126.9691612, [
    Direction('ne', '북동쪽 횡단보도'),
    Direction('se', '남동쪽 횡단보도'),
    Direction('sw', '남서쪽 횡단보도'),
    Direction('nw', '북서쪽 횡단보도'),
  ]),
  Intersection('1620', '국일관', 37.5703027, 126.9897302, [
    Direction('st', '남쪽 횡단보도'),
  ]),
];
