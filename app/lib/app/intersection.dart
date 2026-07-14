/// 교차로·방향 모델과 서울 소규모 수동 매핑.
/// GPS→교차로 선택에 쓰인다. itstId·방향은 실API 검증값,
/// ⚠️ 좌표(lat/lng)는 프로토타입 임시값 — 실좌표는 T-Data v2xCrossroadMapInformation
/// (data_id=10121, 활용신청 진행 중)에서 확보 후 교체. 실기기 전 반드시 교체.
library;

/// 교차로의 한 방향(횡단보도). code는 T-Data 방위 접두사.
class Direction {
  final String code;   // nt/et/st/wt/ne/se/sw/nw
  final String label;  // 스크린리더용, 예: '북쪽 횡단보도'
  const Direction(this.code, this.label);
}

/// 한 교차로. itstId로 T-Data 신호를 조회한다.
class Intersection {
  final String itstId;
  final String name;
  final double lat;   // ⚠️ 임시 좌표
  final double lng;   // ⚠️ 임시 좌표
  final List<Direction> directions;
  const Intersection(this.itstId, this.name, this.lat, this.lng, this.directions);
}

/// 서울 소규모 수동 매핑. itstId·방향은 실측(실API) 확인, 좌표는 임시.
/// 좌표는 서울 시청 인근 임의값 — 실기기 전 실좌표로 교체(§Global Constraints).
const List<Intersection> kIntersections = [
  Intersection('1850', '테스트 교차로 A', 37.5665, 126.9780, [
    Direction('nt', '북쪽 횡단보도'),
    Direction('et', '동쪽 횡단보도'),
    Direction('st', '남쪽 횡단보도'),
  ]),
  Intersection('1537', '테스트 교차로 B', 37.5700, 126.9820, [
    Direction('ne', '북동쪽 횡단보도'),
    Direction('se', '남동쪽 횡단보도'),
    Direction('sw', '남서쪽 횡단보도'),
    Direction('nw', '북서쪽 횡단보도'),
  ]),
  Intersection('4031', '테스트 교차로 C', 37.5610, 126.9750, [
    Direction('nt', '북쪽 횡단보도'),
    Direction('et', '동쪽 횡단보도'),
    Direction('wt', '서쪽 횡단보도'),
    Direction('se', '남동쪽 횡단보도'),
  ]),
];
