# GPS 교차로 자동선택 설계

**작성일:** 2026-07-14
**상태:** 사용자 승인 완료 (설계 방향)

## 1. 목적

지금 앱은 `config.dart`에 교차로 1개(itstId '1620'·방향 'st')를 고정으로 박아두고 그것만
읽는다. 그 교차로 앞이 아니면 의미가 없다. 이 조각은 **GPS로 "지금 내 앞 교차로"를
자동 선택**하고, 그 교차로의 방향을 **사용자가 골라** 안내를 시작하게 한다.

## 2. 이미 완성된 것 (이 조각의 전제)

- `lib/signals/` — `fetchReading(itstId, direction, apiKey, ...)`(실API), `decide`(판단+안전정책)
- `lib/feedback/` — 음성/햅틱
- `lib/app/` — `GuidanceController`(1초 루프, 현재 `kItstId`·`kDirection` 상수 하드코딩),
  `GuidanceScreen`(큰 버튼 토글 + 접근성). 89 테스트 통과, main 병합.

## 3. 범위

**포함:**
- 교차로 데이터 모델 + 서울 소규모 수동 매핑(좌표·itstId·방향)
- GPS 위치 획득(권한 요청 포함), 인터페이스 뒤 격리(테스트 주입)
- 최근접 교차로 찾기(반경 내, 하버사인 거리) — 순수 함수
- 선택 화면: GPS→교차로 자동선택 → 방향 큰버튼 세로 목록 → 안내 화면 진입
- GPS 실패/근처 없음 → 정직하게 "찾을 수 없음" 안내
- `GuidanceController`가 선택된 교차로·방향을 받도록 수정

**범위 밖 (다음 조각):**
- 전국 교차로 데이터셋(수동 매핑은 서울 몇 개만)
- 나침반 자동 방향 추정
- 매핑 안 된 지역 확장, 백그라운드 동작
- 카메라 검출기(별도 조각), allowSingleSource 복귀(카메라 조각에서)

## 4. 아키텍처

### 4.1 파일 구조 (책임 분리)

| 파일 | 책임 | 의존 |
|---|---|---|
| `lib/app/intersection.dart` | `Intersection` 모델 + 수동 매핑 목록 | 없음 |
| `lib/app/location_service.dart` | GPS 위치 획득(권한). 인터페이스 뒤 격리 | geolocator |
| `lib/app/intersection_finder.dart` | (위치, 목록) → 최근접 교차로(반경 내). 순수 함수 | intersection |
| `lib/app/selection_screen.dart` | 자동선택 → 방향 목록 → 안내 진입. 실패 안내 | 위 셋, guidance_* |
| 수정 `lib/app/guidance_controller.dart` | 선택된 itstId·방향을 받음(상수 하드코딩 제거) | — |

원칙: 순수 로직(거리 계산·최근접 찾기)과 부수효과(GPS, 화면)를 분리해 각각 독립 테스트.
`location_service`는 인터페이스로 격리해 실제 GPS 없이 Fake로 테스트.

### 4.2 Intersection 모델 + 수동 매핑

```dart
class Direction {
  final String code;   // 'nt'|'et'|'st'|'wt'|'ne'|'se'|'sw'|'nw'
  final String label;  // 스크린리더용 한국어, 예: '북쪽 횡단보도'
  const Direction(this.code, this.label);
}

class Intersection {
  final String itstId;      // T-Data 교차로 ID (실측 확인된 것)
  final String name;        // 사람이 읽을 이름, 예: '테스트교차로 A'
  final double lat;         // 위도
  final double lng;         // 경도
  final List<Direction> directions;  // 이 교차로의 사용 가능 방향들
  const Intersection(this.itstId, this.name, this.lat, this.lng, this.directions);
}

/// 서울 소규모 수동 매핑. itstId·방향은 실측(실API 호출)으로 존재·동작 확인.
/// ⚠️ 좌표(lat/lng)는 신호 API가 주지 않으므로 별도 조사로 채워야 함
/// (지도에서 해당 교차로 위경도 확인). 실측에서 방향 여럿 확인된 후보:
/// itstId 1850(북/동/남), 1537(북동/남동/남서/북서), 4031(북/동/서/남동) 등.
const List<Intersection> kIntersections = [ /* 실측 좌표로 채움 */ ];
```

**핵심 리스크 & 좌표 출처 (2026-07-14 조사 확정):**
itstId·방향은 실API로 검증됨. 좌표는 신호 API가 안 주지만, **T-Data에 짝 API가 존재**:
- **교차로 Map 정보** — 서비스 `v2xCrossroadMapInformation/1.0`, 파라미터 `apiKey`(대문자 K),
  응답 필드 `itstId`·`itstNm`·`mapCtptIntLat`(위도)·`mapCtptIntLot`(경도). data_id=10121.
- T-Data는 **데이터셋별 활용신청**이라, 신호(10120)만 신청한 키로는 이 API가 404다
  (같은 키로 신호=200, 좌표=404 실측 확인). 같은 계정에서 data_id=10121을 추가 신청하면
  같은 키로 열린다(무료, 개발계정 보통 자동승인).
- itstId가 두 API에서 일치하는지는 LIKELY(같은 부서·필드명·네이밍) — 승인 후 실호출로 검증.

**진행 방식(사용자 결정):** 임시 좌표로 구현 완성 + 활용신청 병행. 승인·검증 후 좌표만
실API 값으로 교체(코드 구조는 안 바뀜 — kIntersections 리스트의 lat/lng만 교체).
**임시 좌표 경고:** 프로토타입 좌표는 실제와 다를 수 있어 GPS 선택이 부정확할 수 있음 —
코드·주석에 "실좌표 미확정" 명시, 실기기 전 반드시 교체.

### 4.3 LocationService

```dart
/// GPS 위치 결과. 실패를 1급 값으로.
sealed class LocationResult {}
class LocationOk extends LocationResult { final double lat, lng; LocationOk(this.lat, this.lng); }
class LocationDenied extends LocationResult {}     // 권한 거부
class LocationUnavailable extends LocationResult {} // 위치 못 잡음/서비스 꺼짐

abstract class LocationService {
  Future<LocationResult> current();
}

/// 실제 구현(geolocator). 권한 요청 → 위치 획득. 하드웨어 의존이라 단위테스트 안 함.
class GeolocatorLocationService implements LocationService { ... }
```

실패를 예외가 아닌 `sealed` 결과 타입으로 표현해 호출자가 모든 경우를 명시적으로 처리하게 한다.

### 4.4 IntersectionFinder (순수 함수)

```dart
/// 두 위경도 간 거리(m). 하버사인.
double distanceMeters(double lat1, double lng1, double lat2, double lng2) { ... }

/// 반경 내 최근접 교차로. 없으면 null.
Intersection? nearest(double lat, double lng, List<Intersection> list,
    {double radiusMeters = 100}) { ... }
```

순수 함수라 하드웨어·네트워크 없이 완전 테스트. 반경(기본 100m)은 GPS 오차 감안한 값.

### 4.5 SelectionScreen (접근성)

흐름:
1. 화면 진입 → `LocationService.current()` 호출(권한 요청 포함).
2. `LocationOk` + `nearest(...)` 성공 → 교차로 이름 음성 안내 + 그 교차로의 방향들을
   **화면 가득 큰버튼 세로 목록**(각 버튼 스크린리더 라벨, 예: "북쪽 횡단보도").
3. 방향 버튼 탭 → `GuidanceScreen`으로 이동(선택된 itstId·방향 전달) → 기존 안내 시작.
4. `LocationDenied` → "위치 권한이 필요합니다" 음성 + 재요청 버튼.
5. `LocationUnavailable` 또는 `nearest`가 null → "근처 교차로를 찾을 수 없습니다" 음성.

접근성: 큰버튼 세로 목록, 각 버튼 `Semantics(button, label)`, 고대비. 상태 전환 음성 안내.
기존 "화면 전체가 큰 버튼" 철학을 방향 선택엔 "큰버튼 목록"으로 확장(각 항목이 큰 버튼).

### 4.6 GuidanceController 수정

현재 `tickOnce()`가 `kItstId`·`kDirection` 상수를 직접 참조(하드코딩). 이를 선택된 값으로:

```dart
GuidanceController({
  required FeedbackController feedback,
  required String itstId,      // ← 추가: 선택된 교차로
  required String direction,   // ← 추가: 선택된 방향
  FetchReading? fetch,
  Duration interval = kLoopInterval,
  bool allowSingleSource = kAllowSingleSource,
});
// tickOnce에서 kItstId/kDirection 대신 _itstId/_direction 사용.
```

`kApiKey`·`kNeedSec`·`kAllowSingleSource`는 그대로 config에서. 기존 컨트롤러 테스트는
생성자에 itstId·direction을 넘기도록 갱신(로직 변화 없음, 값 출처만 바뀜).

## 5. 데이터 흐름

```
앱 시작 → SelectionScreen
   LocationService.current()  (권한 요청)
     LocationOk(lat,lng) → nearest(lat,lng, kIntersections)
        교차로 있음 → 이름 음성 + 방향 큰버튼 목록
           [방향 탭] → GuidanceScreen(itstId, direction) → 기존 1초 루프 안내
        교차로 없음(null) → "근처 교차로를 찾을 수 없습니다"
     LocationDenied → "위치 권한이 필요합니다" + 재요청
     LocationUnavailable → "위치를 확인할 수 없습니다"
```

## 6. 안전 원칙 (기존 유지)

- **추측 금지:** GPS 실패·근처 교차로 없음 → 정직하게 "찾을 수 없음". 임의 교차로 선택 절대 안 함.
- **방향은 사용자 명시 선택:** GPS/나침반으로 방향 추정 안 함(방향 오독 = 엉뚱한 신호 = 위험).
- **선택 후 판단은 기존 엔진 그대로:** Fail-Safe(불확실 → "확인 불가, 대기하세요") 유지.
- **좌표 정확성:** 수동 매핑 좌표는 실제 지도에서 확인. 틀리면 엉뚱한 교차로.

## 7. 에러 처리

- `LocationService`는 예외 대신 `sealed` 결과. 화면이 모든 경우 처리.
- geolocator 내부 예외는 서비스 구현에서 삼켜 `LocationUnavailable`로 수렴.
- 권한 거부는 앱을 죽이지 않고 재요청 경로 제공.

## 8. 테스트 전략

- `intersection_finder_test.dart`: `distanceMeters`(알려진 두 점 거리), `nearest`(반경 내/밖,
  여러 교차로 중 최근접, 빈 목록 → null). 순수 함수라 하드웨어 없이 완전 검증.
- `selection_screen_test.dart`: FakeLocationService 주입 → 각 결과(Ok+교차로 있음/없음,
  Denied, Unavailable)에서 올바른 화면·음성·방향 목록. 방향 탭 → GuidanceScreen 전달 값 확인.
- `guidance_controller_test.dart` 갱신: 생성자 itstId·direction 주입, tickOnce가 그 값을 fetch에 전달.
- 실기기 검증(실제 GPS 권한·정확도)은 범위 밖, 체크리스트로 문서화.

## 9. 미해결/후속

- **좌표 API 활용신청(진행 중)** — 사용자가 data_id=10121 신청. 승인되면 같은 키로
  `v2xCrossroadMapInformation/1.0` 호출해 우리 신호 itstId(1850·1537·4031 등)가 좌표와 함께
  나오는지 검증. 나오면 kIntersections의 임시 좌표를 실값으로 교체(로직 불변).
- 프로토타입 임시 좌표는 실제와 다를 수 있음 — 실기기 전 반드시 실좌표로 교체.
- 실기기 GPS 정확도·권한 UX 실측.
- 반경 100m가 적절한지 실측 조정.
- (확장) 좌표 API가 열리면 수동 매핑 대신 서울 전체 교차로를 그 API로 자동 구성 가능
  — 별도 조각(전국/서울 전체 데이터셋 로딩·캐싱).
