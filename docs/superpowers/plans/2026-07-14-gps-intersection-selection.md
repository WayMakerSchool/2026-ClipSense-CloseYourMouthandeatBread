# GPS 교차로 자동선택 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** GPS로 최근접 교차로를 자동 선택하고, 방향을 사용자가 큰버튼 목록에서 골라 안내를 시작하는 흐름을 추가한다.

**Architecture:** 순수 로직(하버사인 거리·최근접 찾기)과 부수효과(GPS·화면)를 분리한다. `LocationService`는 인터페이스 뒤로 격리해 Fake로 테스트한다. GPS 실패는 예외가 아닌 sealed 결과 타입으로 표현한다. `GuidanceController`는 고정 상수 대신 선택된 itstId·방향을 생성자로 받는다. 앱 진입점이 `GuidanceScreen`에서 `SelectionScreen`으로 바뀐다.

**Tech Stack:** Flutter 3.35.6 / Dart 3.9.2, geolocator ^14.0.3(Dart ^3.5.0 요구 — 3.9.2 호환 확인), 기존 signals·feedback·app 모듈, flutter_test.

## Global Constraints

- **추측 금지 (Fail-Safe):** GPS 실패(권한 거부/위치 불가)·반경 내 교차로 없음 → 정직하게 "찾을 수 없음". 임의 교차로 절대 선택 안 함.
- **방향은 사용자 명시 선택** — GPS/나침반으로 방향 추정 금지(방향 오독 = 위험).
- **임시 좌표** — kIntersections의 lat/lng는 프로토타입 임시값. 코드·주석에 "실좌표 미확정, 실기기 전 교체" 명시. 실좌표는 T-Data `v2xCrossroadMapInformation`(data_id=10121, 활용신청 진행 중)에서 확보.
- **itstId·방향은 실측 확인값** — 실API에서 방향 여럿 확인된 교차로: itstId '1850'(nt/et/st), '1537'(ne/se/sw/nw), '4031'(nt/et/wt/se). 방향 코드: nt/et/st/wt/ne/se/sw/nw.
- **기존 안전정책 불변** — 선택 후 판단·음성/햅틱은 기존 엔진 그대로.
- 기존 시그니처(사용/수정):
  - `GuidanceController({required FeedbackController feedback, FetchReading? fetch, Duration interval, bool allowSingleSource})` → itstId·direction 추가.
  - `GuidanceScreen({required GuidanceController controller})` (StatelessWidget).
  - `FeedbackController(SpeechOutput, HapticOutput)`; `FlutterTtsSpeech()`, `VibrationHaptic()`.

---

## File Structure

- Create: `lib/app/intersection.dart` — `Direction`, `Intersection` 모델 + `kIntersections` 수동 매핑.
- Create: `lib/app/intersection_finder.dart` — `distanceMeters`, `nearest` (순수 함수).
- Create: `lib/app/location_service.dart` — `LocationResult`(sealed), `LocationService`(인터페이스), `GeolocatorLocationService`.
- Create: `lib/app/selection_screen.dart` — GPS→선택→방향목록→안내 진입 + 실패 안내.
- Modify: `lib/app/guidance_controller.dart` — itstId·direction 생성자 인자 추가, 상수 하드코딩 제거.
- Modify: `lib/main.dart` — 홈을 SelectionScreen으로.
- Modify: `pubspec.yaml` — geolocator 추가.
- Test: `test/intersection_finder_test.dart`, `test/location_service_test.dart`(sealed 타입 로직), `test/selection_screen_test.dart`, `test/guidance_controller_test.dart`(갱신).

---

## Task 1: Intersection 모델 + 수동 매핑

**Files:**
- Create: `app/lib/app/intersection.dart`

**Interfaces:**
- Produces: `class Direction { String code; String label; }`, `class Intersection { String itstId; String name; double lat; double lng; List<Direction> directions; }`, `const List<Intersection> kIntersections`.

- [ ] **Step 1: 모델 + 매핑 작성**

```dart
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
```

- [ ] **Step 2: 분석 통과 확인**

Run: `cd app && flutter analyze lib/app/intersection.dart`
Expected: No issues found.

- [ ] **Step 3: 커밋**

```bash
git add app/lib/app/intersection.dart
git commit -m "feat(app): add Intersection model + manual Seoul mapping (temp coords)"
```

---

## Task 2: IntersectionFinder (하버사인 최근접, 순수 함수)

**Files:**
- Create: `app/lib/app/intersection_finder.dart`
- Test: `app/test/intersection_finder_test.dart`

**Interfaces:**
- Consumes: `Intersection`, `kIntersections`.
- Produces: `double distanceMeters(double, double, double, double)`, `Intersection? nearest(double lat, double lng, List<Intersection> list, {double radiusMeters})`.

- [ ] **Step 1: 실패 테스트 작성**

```dart
// test/intersection_finder_test.dart
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
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd app && flutter test test/intersection_finder_test.dart`
Expected: FAIL — 함수 미정의.

- [ ] **Step 3: 구현**

```dart
// lib/app/intersection_finder.dart
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
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd app && flutter test test/intersection_finder_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 5: 분석 통과 확인**

Run: `cd app && flutter analyze lib/app/intersection_finder.dart test/intersection_finder_test.dart`
Expected: No issues found.

- [ ] **Step 6: 커밋**

```bash
git add app/lib/app/intersection_finder.dart app/test/intersection_finder_test.dart
git commit -m "feat(app): add haversine nearest-intersection finder (pure)"
```

---

## Task 3: LocationService (GPS, sealed 결과)

**Files:**
- Modify: `app/pubspec.yaml` (geolocator 추가)
- Create: `app/lib/app/location_service.dart`
- Test: `app/test/location_service_test.dart`

**Interfaces:**
- Produces: `sealed class LocationResult`, `LocationOk(lat,lng)`, `LocationDenied`, `LocationUnavailable`, `abstract class LocationService { Future<LocationResult> current(); }`, `class GeolocatorLocationService implements LocationService`.

- [ ] **Step 1: geolocator 의존성 추가**

`app/pubspec.yaml`의 dependencies에 추가(vibration 아래):
```yaml
  geolocator: ^14.0.3
```

Run: `cd app && flutter pub get`
Expected: 성공(해결 충돌 없음). 실패 시 STOP — 버전 충돌 보고.

- [ ] **Step 2: 실패 테스트 작성 (sealed 타입 로직만)**

```dart
// test/location_service_test.dart
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
```

- [ ] **Step 3: 테스트 실패 확인**

Run: `cd app && flutter test test/location_service_test.dart`
Expected: FAIL — 타입 미정의.

- [ ] **Step 4: 구현**

```dart
// lib/app/location_service.dart
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
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `cd app && flutter test test/location_service_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 6: 분석 통과 확인**

Run: `cd app && flutter analyze lib/app/location_service.dart test/location_service_test.dart`
Expected: No issues found.

- [ ] **Step 7: 커밋**

```bash
git add app/pubspec.yaml app/pubspec.lock app/lib/app/location_service.dart app/test/location_service_test.dart
git commit -m "feat(app): add LocationService (geolocator, sealed result, fail-safe)"
```

---

## Task 4: GuidanceController — itstId·direction 주입

**Files:**
- Modify: `app/lib/app/guidance_controller.dart`
- Modify: `app/test/guidance_controller_test.dart`
- Modify: `app/test/guidance_screen_test.dart` (makeController 헬퍼가 GuidanceController 생성 — 새 required 인자로 깨짐)

**Interfaces:**
- Produces (변경): `GuidanceController({required FeedbackController feedback, required String itstId, required String direction, FetchReading? fetch, Duration interval, bool allowSingleSource})`.

**중요:** 이 생성자 변경은 `guidance_screen_test.dart`의 `makeController` 헬퍼(21~28행 부근)도
깨뜨린다. 그 헬퍼의 `GuidanceController(...)`에도 `itstId: '1850', direction: 'st'`를 추가해야
전체 테스트가 통과한다. 이 파일 갱신을 이 태스크에 포함한다.

- [ ] **Step 1: 컨트롤러에 필드·인자 추가**

`guidance_controller.dart`에서:
- 필드 추가: `final String _itstId; final String _direction;`
- 생성자에 `required String itstId, required String direction` 추가, `_itstId = itstId, _direction = direction` 초기화.
- `tickOnce()`의 `_fetch(kItstId, kDirection, kApiKey, nowMs: nowMs)`를 `_fetch(_itstId, _direction, kApiKey, nowMs: nowMs)`로 변경.
- `import 'config.dart';`는 유지(kApiKey·kNeedSec·kAllowSingleSource·kLoopInterval 여전히 사용). `kItstId`·`kDirection`은 더 이상 참조 안 함.

변경 후 생성자:
```dart
GuidanceController({
  required FeedbackController feedback,
  required String itstId,
  required String direction,
  FetchReading? fetch,
  Duration interval = kLoopInterval,
  bool allowSingleSource = kAllowSingleSource,
})  : _feedback = feedback,
      _itstId = itstId,
      _direction = direction,
      _fetch = fetch ?? _defaultFetch,
      _interval = interval,
      _allowSingleSource = allowSingleSource;
```

tickOnce 내부:
```dart
final apiReading = await _fetch(_itstId, _direction, kApiKey, nowMs: nowMs);
```

- [ ] **Step 2: 기존 테스트 갱신**

`test/guidance_controller_test.dart`의 모든 `GuidanceController(...)`/`make(...)` 생성에
`itstId: '1850', direction: 'st'`를 추가한다. 예: `make` 헬퍼가 있으면 그 안에서:
```dart
GuidanceController make(SignalReading apiReading, {bool allowSingleSource = true}) {
  return GuidanceController(
    feedback: feedback,
    itstId: '1850',
    direction: 'st',
    allowSingleSource: allowSingleSource,
    fetch: (itstId, direction, apiKey, {required nowMs}) async => apiReading,
  );
}
```
`fetch가 throw` 테스트처럼 make를 안 쓰고 직접 생성하는 곳도 `itstId`·`direction` 추가.
추가로 검증 테스트 1개:
```dart
test('tick은 생성자의 itstId·direction을 fetch에 전달한다', () async {
  String? gotItst, gotDir;
  final c = GuidanceController(
    feedback: feedback,
    itstId: '4031',
    direction: 'et',
    fetch: (itstId, direction, apiKey, {required nowMs}) async {
      gotItst = itstId; gotDir = direction;
      return const SignalReading(SignalColor.red, null, SignalSource.api, freshMs: 0);
    },
  );
  await c.tickOnce();
  expect(gotItst, '4031');
  expect(gotDir, 'et');
  c.dispose();
});
```

- [ ] **Step 3: guidance_screen_test.dart의 makeController 갱신**

`test/guidance_screen_test.dart`의 `makeController` 헬퍼(GuidanceController 생성)에도
`itstId: '1850', direction: 'st'`를 추가한다:
```dart
GuidanceController makeController(SignalReading reading) {
  return GuidanceController(
    feedback: FeedbackController(FakeSpeech(), FakeHaptic()),
    itstId: '1850',
    direction: 'st',
    fetch: (itstId, direction, apiKey, {required nowMs}) async => reading,
  );
}
```

- [ ] **Step 4: 관련 테스트 통과 확인**

Run: `cd app && flutter test test/guidance_controller_test.dart test/guidance_screen_test.dart`
Expected: PASS (controller 기존 10 + 신규 1 = 11, screen 9 = 총 20). 회귀 없어야.

- [ ] **Step 5: 분석 통과 확인**

Run: `cd app && flutter analyze lib/app/guidance_controller.dart test/guidance_controller_test.dart test/guidance_screen_test.dart`
Expected: No issues found.

- [ ] **Step 6: 커밋**

```bash
git add app/lib/app/guidance_controller.dart app/test/guidance_controller_test.dart app/test/guidance_screen_test.dart
git commit -m "feat(app): GuidanceController takes selected itstId/direction (was fixed const)"
```

---

## Task 5: SelectionScreen (접근성 선택 화면) + main 배선

**Files:**
- Create: `app/lib/app/selection_screen.dart`
- Modify: `app/lib/main.dart`
- Test: `app/test/selection_screen_test.dart`

**Interfaces:**
- Consumes: `LocationService`, `LocationResult`, `nearest`, `kIntersections`, `Intersection`, `Direction`, `GuidanceController`, `GuidanceScreen`, `FeedbackController`.
- Produces: `class SelectionScreen extends StatefulWidget` — 생성자 `SelectionScreen({required LocationService location, required FeedbackController Function() feedbackFactory, List<Intersection> intersections = kIntersections})`.

설계: StatefulWidget. initState에서 `_locate()` 호출 → `location.current()` → 결과에 따라 상태.
상태 enum: `_Phase { locating, chooseDirection, denied, unavailable, notFound }`.
- locating: "위치 확인 중" 표시.
- chooseDirection: 교차로 이름 + 방향들 큰버튼 세로 목록(각 `Semantics(button, label)`). 탭 → GuidanceScreen push.
- denied: "위치 권한이 필요합니다" + 재시도 버튼(다시 `_locate()`).
- unavailable: "위치를 확인할 수 없습니다" + 재시도.
- notFound: "근처 교차로를 찾을 수 없습니다" + 재시도.

방향 탭 시:
```dart
final controller = GuidanceController(
  feedback: widget.feedbackFactory(),
  itstId: intersection.itstId,
  direction: dir.code,
);
Navigator.of(context).push(MaterialPageRoute(
  builder: (_) => GuidanceScreen(controller: controller)));
```
feedbackFactory로 넘기는 이유: 실제 백엔드(FlutterTtsSpeech/VibrationHaptic)를 화면이 직접
import하지 않고 main이 주입 → 테스트에서 Fake 주입 가능.

- [ ] **Step 1: 실패 위젯 테스트 작성**

```dart
// test/selection_screen_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/signals/judge.dart';
import 'package:clip_sense/feedback/speech_output.dart';
import 'package:clip_sense/feedback/haptic_output.dart';
import 'package:clip_sense/feedback/feedback_controller.dart';
import 'package:clip_sense/app/intersection.dart';
import 'package:clip_sense/app/location_service.dart';
import 'package:clip_sense/app/selection_screen.dart';

class FakeLocationService implements LocationService {
  final LocationResult result;
  FakeLocationService(this.result);
  @override
  Future<LocationResult> current() async => result;
}

class FakeSpeech implements SpeechOutput {
  @override
  Future<void> speak(String text) async {}
}

class FakeHaptic implements HapticOutput {
  @override
  Future<void> play(Decision d) async {}
}

FeedbackController fakeFeedback() => FeedbackController(FakeSpeech(), FakeHaptic());

const _testList = [
  Intersection('1850', '테스트 교차로 A', 37.5665, 126.9780, [
    Direction('nt', '북쪽 횡단보도'),
    Direction('st', '남쪽 횡단보도'),
  ]),
];

Widget wrap(LocationResult result) => MaterialApp(
      home: SelectionScreen(
        location: FakeLocationService(result),
        feedbackFactory: fakeFeedback,
        intersections: _testList,
      ),
    );

void main() {
  testWidgets('위치 성공 + 근처 교차로 → 방향 목록 표시', (tester) async {
    await tester.pumpWidget(wrap(LocationOk(37.5665, 126.9780)));
    await tester.pumpAndSettle();
    expect(find.textContaining('북쪽 횡단보도'), findsOneWidget);
    expect(find.textContaining('남쪽 횡단보도'), findsOneWidget);
  });

  testWidgets('권한 거부 → "권한" 안내', (tester) async {
    await tester.pumpWidget(wrap(LocationDenied()));
    await tester.pumpAndSettle();
    expect(find.textContaining('권한'), findsOneWidget);
  });

  testWidgets('위치 불가 → "확인할 수 없" 안내', (tester) async {
    await tester.pumpWidget(wrap(LocationUnavailable()));
    await tester.pumpAndSettle();
    expect(find.textContaining('확인할 수 없'), findsOneWidget);
  });

  testWidgets('근처 교차로 없음 → "찾을 수 없" 안내', (tester) async {
    // 부산 좌표 → _testList(서울)에서 반경 밖
    await tester.pumpWidget(wrap(LocationOk(35.1796, 129.0756)));
    await tester.pumpAndSettle();
    expect(find.textContaining('찾을 수 없'), findsOneWidget);
  });

  testWidgets('방향 버튼에 Semantics 라벨', (tester) async {
    await tester.pumpWidget(wrap(LocationOk(37.5665, 126.9780)));
    await tester.pumpAndSettle();
    // 방향 버튼 하나의 Semantics 라벨에 방향 텍스트 포함
    final sem = tester.getSemantics(find.textContaining('북쪽 횡단보도').first);
    expect(sem.label, contains('북쪽'));
  });
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd app && flutter test test/selection_screen_test.dart`
Expected: FAIL — SelectionScreen 없음.

- [ ] **Step 3: SelectionScreen 구현**

```dart
// lib/app/selection_screen.dart
/// GPS로 최근접 교차로를 자동 선택하고, 방향을 사용자가 큰버튼 목록에서 고른다.
/// GPS 실패·근처 없음은 정직하게 안내(추측 금지). 방향 선택 후 GuidanceScreen으로.
library;

import 'package:flutter/material.dart';

import '../feedback/feedback_controller.dart';
import 'guidance_controller.dart';
import 'guidance_screen.dart';
import 'intersection.dart';
import 'intersection_finder.dart';
import 'location_service.dart';

enum _Phase { locating, chooseDirection, denied, unavailable, notFound }

class SelectionScreen extends StatefulWidget {
  final LocationService location;
  final FeedbackController Function() feedbackFactory;
  final List<Intersection> intersections;
  const SelectionScreen({
    super.key,
    required this.location,
    required this.feedbackFactory,
    this.intersections = kIntersections,
  });

  @override
  State<SelectionScreen> createState() => _SelectionScreenState();
}

class _SelectionScreenState extends State<SelectionScreen> {
  _Phase _phase = _Phase.locating;
  Intersection? _found;

  @override
  void initState() {
    super.initState();
    _locate();
  }

  Future<void> _locate() async {
    setState(() => _phase = _Phase.locating);
    final r = await widget.location.current();
    if (!mounted) return;
    switch (r) {
      case LocationOk(:final lat, :final lng):
        final it = nearest(lat, lng, widget.intersections);
        setState(() {
          if (it == null) {
            _phase = _Phase.notFound;
          } else {
            _found = it;
            _phase = _Phase.chooseDirection;
          }
        });
      case LocationDenied():
        setState(() => _phase = _Phase.denied);
      case LocationUnavailable():
        setState(() => _phase = _Phase.unavailable);
    }
  }

  void _choose(Intersection it, Direction dir) {
    final controller = GuidanceController(
      feedback: widget.feedbackFactory(),
      itstId: it.itstId,
      direction: dir.code,
    );
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => GuidanceScreen(controller: controller),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF222222),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    switch (_phase) {
      case _Phase.locating:
        return _message('위치를 확인하는 중입니다');
      case _Phase.denied:
        return _messageWithRetry('위치 권한이 필요합니다');
      case _Phase.unavailable:
        return _messageWithRetry('위치를 확인할 수 없습니다');
      case _Phase.notFound:
        return _messageWithRetry('근처 교차로를 찾을 수 없습니다');
      case _Phase.chooseDirection:
        return _directionList(_found!);
    }
  }

  Widget _message(String text) => Center(
        child: Semantics(
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w800,
                    color: Colors.white)),
          ),
        ),
      );

  Widget _messageWithRetry(String text) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Expanded(child: _message(text)),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Semantics(
              button: true,
              label: '다시 시도',
              excludeSemantics: true,
              child: GestureDetector(
                onTap: _locate,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  color: const Color(0xFF3A3A3A),
                  child: const Text('다시 시도',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          color: Colors.white)),
                ),
              ),
            ),
          ),
        ],
      );

  Widget _directionList(Intersection it) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Semantics(
              liveRegion: true,
              child: Text('${it.name}\n건널 방향을 선택하세요',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: Colors.white)),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final dir in it.directions)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    child: Semantics(
                      button: true,
                      label: dir.label,
                      excludeSemantics: true,
                      child: GestureDetector(
                        onTap: () => _choose(it, dir),
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 32),
                          color: const Color(0xFF0A5FA8),
                          child: Text(dir.label,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 34,
                                  fontWeight: FontWeight.w900,
                                  color: Colors.white)),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd app && flutter test test/selection_screen_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: main.dart 배선 변경**

`lib/main.dart`를 SelectionScreen이 홈이 되도록 교체:
```dart
/// Clip sense 앱 진입점. GPS 교차로 선택 → 안내로 배선.
library;

import 'package:flutter/material.dart';

import 'feedback/speech_output.dart';
import 'feedback/haptic_output.dart';
import 'feedback/feedback_controller.dart';
import 'app/location_service.dart';
import 'app/selection_screen.dart';

void main() {
  runApp(const ClipSenseApp());
}

class ClipSenseApp extends StatelessWidget {
  const ClipSenseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Clip sense',
      debugShowCheckedModeBanner: false,
      home: SelectionScreen(
        location: GeolocatorLocationService(),
        feedbackFactory: () =>
            FeedbackController(FlutterTtsSpeech(), VibrationHaptic()),
      ),
    );
  }
}
```

- [ ] **Step 6: 전체 분석·테스트 통과 확인**

Run: `cd app && flutter analyze`
Expected: No issues found.

Run: `cd app && flutter test`
Expected: All tests passed (기존 89 - 대체분 + 신규 = 약 103; 정확한 수는 실행으로 확인, 회귀 없어야).

- [ ] **Step 7: 커밋**

```bash
git add app/lib/app/selection_screen.dart app/lib/main.dart app/test/selection_screen_test.dart
git commit -m "feat(app): add SelectionScreen (GPS→intersection→direction), wire as home"
```

---

## Self-Review (계획 작성자 수행 완료)

- **스펙 커버리지:** 모델+매핑(T1) ✅, 하버사인 최근접(T2) ✅, LocationService sealed(T3) ✅, 컨트롤러 itstId/direction 주입(T4) ✅, SelectionScreen+실패 안내+방향목록+main(T5) ✅. 안전(추측 금지 → notFound/denied/unavailable) ✅, 방향 사용자 선택 ✅, 임시 좌표 주석 ✅.
- **플레이스홀더:** 없음. 좌표는 의도적 임시값(주석 명시).
- **타입 일관성:** `LocationResult` sealed ↔ SelectionScreen switch 3-case + nearest null → notFound. `GuidanceController` 새 생성자(itstId·direction required) ↔ T4 갱신 + T5 호출부 일치. `nearest(lat,lng,list,{radiusMeters})` ↔ T2 정의·T5 호출 일치. `SelectionScreen(location, feedbackFactory, intersections)` ↔ 테스트·main 일치.
- **주의(구현자):** geolocator pub get 실패 시 STOP(SDK 충돌 보고). 기존 guidance_controller_test·guidance_screen_test가 GuidanceController 생성자 변경으로 깨지면 itstId·direction 추가해 갱신(T4에서 controller test는 갱신하나, guidance_screen_test도 controller를 만들면 거기도 추가 필요 — T5 Step 6 전체 테스트에서 확인).

---

## Execution Handoff

계획은 subagent-driven-development로 실행한다(Task별 fresh 구현자 + 리뷰).
