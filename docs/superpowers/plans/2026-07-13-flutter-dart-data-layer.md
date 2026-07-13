# Flutter Dart 데이터 계층 포팅 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Python 데이터 계층(signals/signal_api/vision_adapter/judge)을 Dart로 이식해 Flutter 앱이 온디바이스로 보행 신호를 판단할 수 있게 한다.

**Architecture:** `app/` 서브디렉터리에 Flutter 프로젝트를 만들고, `lib/signals/`에 4개 Dart 파일을 이식한다. 색은 Python의 문자열 상수 대신 Dart enum으로 승격한다. 안전 로직(AND 규칙, Fail-Safe, itstId 매칭, 미래시각 거부)은 Python과 동일하게 유지하고, Python 테스트를 Dart로 미러링해 동등성을 보장한다.

**Tech Stack:** Flutter/Dart(설치됨: /opt/homebrew/bin/flutter). 의존성: `http`(T-Data 호출), `test`/`flutter_test`(dev). 그 외 없음. 테스트 실행: `flutter test`.

## Global Constraints

- **온디바이스 독립** — 데이터 계층은 순수 로직. 무거운 의존성 금지(http만).
- **정직성/Fail-Safe** — 모르는 상태값/stale/미래시각/None/오류 → `SignalColor.unknown`. GREEN 추측 절대 금지. 불확실하면 wait/unknown.
- **안전 정책(사용자 확정)** — `decide`의 `allowSingleSource` 기본값 `false`. 카메라 unknown이면 API 초록이어도 wait.
- **API 키 하드코딩 금지** — `fetchReading`은 apiKey를 인자로 받음. 테스트는 `"dummy-key"`.
- **동등성** — Python 테스트(signal_reading, signal_api 27 assertion, vision_adapter, judge 20 케이스)의 같은 입력을 Dart 테스트로 미러링. 같은 입력→같은 출력.
- **실측 API 사실** — 엔드포인트 `https://t-data.seoul.go.kr/apig/apiman-gateway/tapi/v2xSignalPhaseTimingFusionInformation/1.0`, 파라미터 `apiKey`/`type=json`/`itstId`/`numOfRows=10`, 응답=레코드 배열, 잔여 단위 1/10초, 상태 enum: `protected-Movement-Allowed`/`permissive-Movement-Allowed`(green), `protected-clearance`/`permissive-clearance`(clearance), `stop-And-Remain`(red).
- **작업 디렉터리 주의** — Dart 코드·테스트는 `app/` 안. 원본 Python은 저장소 루트(참조용, 수정 금지).

---

## File Structure

- **Create `app/`** — `flutter create`로 생성하는 Flutter 프로젝트(Task 1).
- **Create `app/lib/signals/signal_reading.dart`** — `SignalColor`/`SignalSource` enum + `SignalReading` 클래스(Task 2).
- **Create `app/lib/signals/signal_api.dart`** — `statusMap`, `parseReading`, `fetchReading`(Task 3-4).
- **Create `app/lib/signals/vision_adapter.dart`** — `toReading`, `visionStub`(Task 5).
- **Create `app/lib/signals/judge.dart`** — `Decision` enum + `decide`(Task 6).
- **Create `app/test/*_test.dart`** — 각 모듈 미러 테스트(해당 태스크에 포함).
- **Modify 루트 `.gitignore`** — `app/build/` 등 Flutter 빌드물 제외(Task 1).

원본 참조: 루트의 `signals.py`, `signal_api.py`, `vision_adapter.py`, `judge.py`와 `scripts/test_*.py`. 이식 시 로직을 그대로 옮기되 Dart 관용구(enum, http.Client 주입)로 변환한다.

---

## Task 1: Flutter 프로젝트 생성 + gitignore

**Files:**
- Create: `app/` (flutter create 산출물)
- Modify: `app/pubspec.yaml` (http 의존성 추가)
- Modify: `.gitignore` (루트 — Flutter 빌드물 제외)

**Interfaces:**
- Consumes: (없음)
- Produces: `app/` Flutter 프로젝트, `package:http` 사용 가능, `flutter test` 실행 가능.

- [ ] **Step 1: Flutter 프로젝트 생성**

Run:
```bash
cd /Users/daniellim/Desktop/Clip_Sense
flutter create --project-name clip_sense --org com.clipsense app
```
Expected: `app/` 아래 pubspec.yaml, lib/, test/ 등 생성. "All done!" 메시지.

- [ ] **Step 2: http 의존성 추가**

`app/pubspec.yaml`의 `dependencies:` 섹션(이미 flutter가 있음)에 http를 추가한다. 해당 섹션을 다음과 같이 만든다:

```yaml
dependencies:
  flutter:
    sdk: flutter
  http: ^1.2.0
```

- [ ] **Step 3: 의존성 설치**

Run:
```bash
cd /Users/daniellim/Desktop/Clip_Sense/app && flutter pub get
```
Expected: "Got dependencies!" (http 및 하위 의존성 해결).

- [ ] **Step 4: 루트 .gitignore에 Flutter 빌드물 추가**

루트 `.gitignore` 끝에 다음 블록을 추가한다:

```
# Flutter (app/)
app/build/
app/.dart_tool/
app/.flutter-plugins
app/.flutter-plugins-dependencies
app/.packages
app/ios/Pods/
app/android/.gradle/
```

- [ ] **Step 5: 기본 템플릿 위젯 테스트 제거**

`flutter create`는 기본 `app/test/widget_test.dart`를 만드는데, 이는 기본 앱 UI(카운터)를 테스트한다. 이 조각은 데이터 계층만 다루고 그 UI를 유지하지 않으므로, 이후 전체 `flutter test` 실행 시 이 템플릿 테스트가 실패한다. 삭제한다:

Run:
```bash
rm -f /Users/daniellim/Desktop/Clip_Sense/app/test/widget_test.dart
```

- [ ] **Step 6: 러너가 도는지 확인**

Run:
```bash
cd /Users/daniellim/Desktop/Clip_Sense/app && flutter test
```
Expected: "No tests found." 또는 테스트 0개 통과(위젯 테스트 삭제됨, 아직 우리 테스트 없음). 러너 자체가 정상 동작함을 확인 — 오류(컴파일 실패 등)가 없어야 함.

- [ ] **Step 7: Commit**

```bash
cd /Users/daniellim/Desktop/Clip_Sense
git add app .gitignore
git commit -m "chore: scaffold Flutter app project with http dependency"
```

---

## Task 2: signal_reading.dart (공유 타입)

원본: 루트 `signals.py`. 색·출처를 enum으로 승격.

**Files:**
- Create: `app/lib/signals/signal_reading.dart`
- Test: `app/test/signal_reading_test.dart`

**Interfaces:**
- Consumes: (없음)
- Produces:
  - `enum SignalColor { green, red, clearance, unknown }`
  - `enum SignalSource { api, vision }`
  - `class SignalReading` — 생성자 `SignalReading(this.color, this.remainSec, this.source, {this.freshMs = 0, this.raw})`, 필드 `SignalColor color`, `double? remainSec`, `SignalSource source`, `int freshMs`, `String? raw`; getter `bool get isGo => color == SignalColor.green`.

- [ ] **Step 1: Write the failing test**

Create `app/test/signal_reading_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/signals/signal_reading.dart';

void main() {
  test('필드 보존', () {
    final r = SignalReading(SignalColor.green, 24.1, SignalSource.api,
        freshMs: 120);
    expect(r.color, SignalColor.green);
    expect(r.remainSec, 24.1);
    expect(r.source, SignalSource.api);
    expect(r.freshMs, 120);
  });

  test('raw 기본값 null', () {
    final r = SignalReading(SignalColor.green, 24.1, SignalSource.api);
    expect(r.raw, isNull);
  });

  test('isGo: green이면 true', () {
    final r = SignalReading(SignalColor.green, null, SignalSource.api);
    expect(r.isGo, isTrue);
  });

  test('isGo: red이면 false', () {
    final r = SignalReading(SignalColor.red, null, SignalSource.vision);
    expect(r.isGo, isFalse);
  });

  test('isGo: unknown이면 false', () {
    final r = SignalReading(SignalColor.unknown, null, SignalSource.api);
    expect(r.isGo, isFalse);
  });

  test('remainSec null 허용', () {
    final r = SignalReading(SignalColor.red, null, SignalSource.vision);
    expect(r.remainSec, isNull);
  });

  test('4색 구분', () {
    expect({
      SignalColor.green,
      SignalColor.red,
      SignalColor.clearance,
      SignalColor.unknown
    }.length, 4);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/daniellim/Desktop/Clip_Sense/app && flutter test test/signal_reading_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'clip_sense'` 또는 `signal_reading.dart` 없음.

- [ ] **Step 3: Write minimal implementation**

Create `app/lib/signals/signal_reading.dart`:

```dart
/// 보행 신호 판정의 공유 표준 타입 (Python signals.py 이식).
///
/// signal_api / vision_adapter / judge 세 모듈이 이 표현으로만 대화한다.
/// 색은 4-값 enum이며, unknown은 "모른다"는 1급 상태다 (추측 금지).

/// 신호 색 (4-값 고정).
enum SignalColor {
  green, // 건널 수 있음 (보행 초록)
  red, // 멈춤 (보행 빨강)
  clearance, // 초록 점멸 (곧 끝남 — 새로 건너기 시작 금지)
  unknown, // 확인 불가 (모르는 값/오래된 데이터/오류/신호 없음)
}

/// 판정 출처.
enum SignalSource { api, vision }

/// 한 소스(API 또는 비전)의 보행 신호 판정 한 건. 불변.
class SignalReading {
  final SignalColor color; // 4색 중 하나
  final double? remainSec; // 남은 초. 모르면 null (색과 독립)
  final SignalSource source; // api | vision
  final int freshMs; // 이 값이 몇 ms 전 것인지 (신선도)
  final String? raw; // 디버그용 원문 (예: 'protected-Movement-Allowed')

  const SignalReading(this.color, this.remainSec, this.source,
      {this.freshMs = 0, this.raw});

  /// 이 판정 하나만 볼 때 '초록'인가. (최종 결정은 judge가 함)
  bool get isGo => color == SignalColor.green;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/daniellim/Desktop/Clip_Sense/app && flutter test test/signal_reading_test.dart`
Expected: PASS — All tests passed! (7 tests)

- [ ] **Step 5: Commit**

```bash
cd /Users/daniellim/Desktop/Clip_Sense
git add app/lib/signals/signal_reading.dart app/test/signal_reading_test.dart
git commit -m "feat(dart): port SignalReading shared type with color enum"
```

---

## Task 3: signal_api.dart 파싱 (parseReading)

원본: 루트 `signal_api.py`의 `STATUS_MAP`, `_to_remain_sec`, `parse_reading`. 네트워크 없이 순수 파싱만. HTTP는 Task 4.

**Files:**
- Create: `app/lib/signals/signal_api.dart`
- Test: `app/test/signal_api_test.dart`

**Interfaces:**
- Consumes: `signal_reading.dart` (SignalColor, SignalSource, SignalReading)
- Produces:
  - `const Map<String, SignalColor> statusMap`
  - `SignalReading parseReading(List records, String direction, int nowMs, {int staleMs = 2000, String? itstId})`

- [ ] **Step 1: Write the failing test**

Create `app/test/signal_api_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/signals/signal_reading.dart';
import 'package:clip_sense/signals/signal_api.dart';

const now = 1783943330618;

// 실측 응답을 본뜬 레코드 (Python test_signal_api.py의 rec() 대응).
Map<String, dynamic> rec({Map<String, dynamic> over = const {}}) {
  final base = <String, dynamic>{
    'itstId': '1537',
    'trsmUtcTime': now,
    'ntPdsgStatNm': null,
    'ntPdsgRmdrCs': null,
    'nePdsgStatNm': 'protected-Movement-Allowed',
    'nePdsgRmdrCs': 241,
    'nwPdsgStatNm': 'stop-And-Remain',
    'nwPdsgRmdrCs': 281,
    'stPdsgStatNm': 'protected-clearance',
    'stPdsgRmdrCs': 33,
  };
  base.addAll(over);
  return base;
}

void main() {
  test('초록 매핑 + 잔여 241→24.1', () {
    final r = parseReading([rec()], 'ne', now);
    expect(r.color, SignalColor.green);
    expect(r.remainSec, 24.1);
    expect(r.source, SignalSource.api);
    expect(r.raw, 'protected-Movement-Allowed');
  });

  test('빨강 매핑', () {
    expect(parseReading([rec()], 'nw', now).color, SignalColor.red);
  });

  test('clearance 매핑', () {
    expect(parseReading([rec()], 'st', now).color, SignalColor.clearance);
  });

  test('None 방위 → unknown', () {
    final r = parseReading([rec()], 'nt', now);
    expect(r.color, SignalColor.unknown);
    expect(r.remainSec, isNull);
  });

  test('미지 상태 → unknown, raw 보존', () {
    final r = parseReading([
      rec(over: {'nePdsgStatNm': 'some-New-Phase'})
    ], 'ne', now);
    expect(r.color, SignalColor.unknown);
    expect(r.raw, 'some-New-Phase');
  });

  test('stale → unknown', () {
    final r = parseReading([rec()], 'ne', now + 5000, staleMs: 2000);
    expect(r.color, SignalColor.unknown);
  });

  test('fresh_ms 계산', () {
    final r = parseReading([rec()], 'ne', now + 500, staleMs: 2000);
    expect(r.color, SignalColor.green);
    expect(r.freshMs, 500);
  });

  test('빈 배열 → unknown', () {
    expect(parseReading([], 'ne', now).color, SignalColor.unknown);
  });

  test('문자열 잔여 처리', () {
    final r = parseReading([
      rec(over: {'nePdsgRmdrCs': '241'})
    ], 'ne', now);
    expect(r.remainSec, 24.1);
  });

  test('statusMap 알려진 값만', () {
    expect(statusMap.keys.toSet(), {
      'protected-Movement-Allowed',
      'permissive-Movement-Allowed',
      'protected-clearance',
      'permissive-clearance',
      'stop-And-Remain',
    });
  });

  test('trsmUtcTime null → unknown', () {
    final r = parseReading([
      rec(over: {'trsmUtcTime': null})
    ], 'ne', now);
    expect(r.color, SignalColor.unknown);
    expect(r.raw, 'protected-Movement-Allowed');
  });

  test('trsmUtcTime 파싱불가 → unknown', () {
    final r = parseReading([
      rec(over: {'trsmUtcTime': 'not-a-number'})
    ], 'ne', now);
    expect(r.color, SignalColor.unknown);
  });

  test('여러 레코드 중 itstId 매칭 선택', () {
    final multi = [
      rec(over: {
        'itstId': '9999',
        'nePdsgStatNm': 'stop-And-Remain',
        'nePdsgRmdrCs': 50
      }),
      rec(over: {
        'itstId': '1537',
        'nePdsgStatNm': 'protected-Movement-Allowed',
        'nePdsgRmdrCs': 241
      }),
    ];
    final r = parseReading(multi, 'ne', now, itstId: '1537');
    expect(r.color, SignalColor.green);
    expect(r.remainSec, 24.1);
  });

  test('매칭 itstId 없으면 unknown', () {
    final multi = [
      rec(over: {'itstId': '9999'}),
      rec(over: {'itstId': '1537'}),
    ];
    expect(parseReading(multi, 'ne', now, itstId: '0000').color,
        SignalColor.unknown);
  });

  test('itstId 미지정 시 첫 레코드(하위호환)', () {
    final multi = [
      rec(over: {'itstId': '9999', 'nePdsgStatNm': 'stop-And-Remain'}),
      rec(over: {'itstId': '1537'}),
    ];
    expect(parseReading(multi, 'ne', now).color, SignalColor.red);
  });

  test('미래 시각(큰 음수 fresh) → unknown', () {
    final r = parseReading([
      rec(over: {'trsmUtcTime': now + 10000})
    ], 'ne', now, staleMs: 2000);
    expect(r.color, SignalColor.unknown);
  });

  test('작은 시계오차는 허용(초록 통과)', () {
    final r = parseReading([
      rec(over: {'trsmUtcTime': now + 100})
    ], 'ne', now, staleMs: 2000);
    expect(r.color, SignalColor.green);
  });

  test('정확히 stale_ms 경계는 fresh(초록 통과)', () {
    final r = parseReading([rec()], 'ne', now + 2000, staleMs: 2000);
    expect(r.color, SignalColor.green);
  });

  test('stale_ms 초과는 unknown', () {
    final r = parseReading([rec()], 'ne', now + 2001, staleMs: 2000);
    expect(r.color, SignalColor.unknown);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/daniellim/Desktop/Clip_Sense/app && flutter test test/signal_api_test.dart`
Expected: FAIL — `signal_api.dart` 없음 / `parseReading` 미정의.

- [ ] **Step 3: Write minimal implementation**

Create `app/lib/signals/signal_api.dart` (parseReading까지만; fetchReading은 Task 4에서 추가):

```dart
/// 서울 T-Data 실시간 보행신호 API 번역기 (Python signal_api.py 이식).
///
/// 책임: (교차로 레코드, 방위) → SignalReading(source: api). 판단하지 않는다.
/// 정직성: 모르는 상태값·stale·미래시각·null·오류는 전부 unknown (green 추측 금지).

import 'signal_reading.dart';

/// API 상태 enum(SAE J2735) → 색. 화이트리스트: 여기 없는 값은 unknown.
const Map<String, SignalColor> statusMap = {
  'protected-Movement-Allowed': SignalColor.green,
  'permissive-Movement-Allowed': SignalColor.green,
  'protected-clearance': SignalColor.clearance,
  'permissive-clearance': SignalColor.clearance,
  'stop-And-Remain': SignalColor.red,
};

/// 1/10초 단위 잔여값 → 초. 파싱 불가/null이면 null.
double? _toRemainSec(dynamic rawCs) {
  if (rawCs == null || rawCs == '') return null;
  final v = double.tryParse(rawCs.toString());
  if (v == null) return null;
  return double.parse((v / 10.0).toStringAsFixed(1));
}

/// 레코드 배열 + 방위 접두사(예 'ne') → SignalReading(source: api).
///
/// itstId가 주어지면 records 중 itstId 일치 첫 레코드만 사용(다른 교차로 신호
/// 오독 방지). 일치 없으면 unknown. itstId가 null이면 records[0](하위호환).
/// 미지 상태/stale/미래시각/신호 없음/빈 배열/itstId 불일치 → 전부 unknown.
SignalReading parseReading(List records, String direction, int nowMs,
    {int staleMs = 2000, String? itstId}) {
  if (records.isEmpty) {
    return const SignalReading(SignalColor.unknown, null, SignalSource.api);
  }

  Map rec;
  if (itstId == null) {
    rec = records[0] as Map;
  } else {
    final match = records.cast<Map>().where(
        (r) => r['itstId']?.toString() == itstId.toString());
    if (match.isEmpty) {
      return const SignalReading(SignalColor.unknown, null, SignalSource.api);
    }
    rec = match.first;
  }

  final stat = rec['${direction}PdsgStatNm'];
  final rmdr = rec['${direction}PdsgRmdrCs'];
  final raw = stat?.toString();

  // 신선도 — 전송시각 없거나 파싱 불가면 신선도 불명 → unknown (raw 보존).
  final trsm = rec['trsmUtcTime'];
  if (trsm == null) {
    return SignalReading(SignalColor.unknown, null, SignalSource.api, raw: raw);
  }
  final trsmMs = double.tryParse(trsm.toString());
  if (trsmMs == null) {
    return SignalReading(SignalColor.unknown, null, SignalSource.api, raw: raw);
  }
  final freshMs = (nowMs - trsmMs).toInt();

  // 미래 시각(시계 오차) — 작은 음수는 허용, 큰 음수만 거부.
  if (freshMs < -staleMs) {
    return SignalReading(SignalColor.unknown, null, SignalSource.api, raw: raw);
  }
  // stale → unknown (원문 보존)
  if (freshMs > staleMs) {
    return SignalReading(SignalColor.unknown, null, SignalSource.api,
        freshMs: freshMs, raw: raw);
  }

  final color = statusMap[stat] ?? SignalColor.unknown;
  final remain = color != SignalColor.unknown ? _toRemainSec(rmdr) : null;
  return SignalReading(color, remain, SignalSource.api,
      freshMs: freshMs < 0 ? 0 : freshMs, raw: raw);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/daniellim/Desktop/Clip_Sense/app && flutter test test/signal_api_test.dart`
Expected: PASS — All tests passed! (20 tests)

- [ ] **Step 5: Commit**

```bash
cd /Users/daniellim/Desktop/Clip_Sense
git add app/lib/signals/signal_api.dart app/test/signal_api_test.dart
git commit -m "feat(dart): port Seoul T-Data parseReading with safety fixes"
```

---

## Task 4: signal_api.dart HTTP (fetchReading)

원본: 루트 `signal_api.py`의 `fetch_reading`, `DEFAULT_BASE_URL`. http.Client 주입으로 테스트.

**Files:**
- Modify: `app/lib/signals/signal_api.dart` (fetchReading, defaultBaseUrl 추가)
- Test: `app/test/signal_api_test.dart` (fetch 오류 경로 케이스 추가)

**Interfaces:**
- Consumes: `parseReading` (Task 3), `package:http`
- Produces:
  - `const String defaultBaseUrl`
  - `Future<SignalReading> fetchReading(String itstId, String direction, String apiKey, {required int nowMs, http.Client? client, String baseUrl = defaultBaseUrl, Duration timeout = const Duration(seconds: 5)})`

- [ ] **Step 1: Write the failing test (fetch 케이스 추가)**

`app/test/signal_api_test.dart`의 import에 추가:

```dart
import 'dart:convert';
import 'package:http/http.dart' as http;
```

그리고 `main()` 안 마지막 `}` 앞에 다음 그룹을 추가:

```dart
  group('fetchReading (http.Client 주입)', () {
    test('네트워크 오류 → unknown', () async {
      final client = MockClient((req) async => throw Exception('network down'));
      final r = await fetchReading('1537', 'ne', 'dummy-key',
          nowMs: now, client: client);
      expect(r.color, SignalColor.unknown);
      expect(r.source, SignalSource.api);
    });

    test('JSON 파싱 실패 → unknown', () async {
      final client = MockClient((req) async => http.Response('<html>err</html>', 200));
      final r = await fetchReading('1537', 'ne', 'dummy-key',
          nowMs: now, client: client);
      expect(r.color, SignalColor.unknown);
    });

    test('list 아닌 응답(dict) → unknown', () async {
      final client = MockClient(
          (req) async => http.Response(jsonEncode({'error': 'x'}), 200));
      final r = await fetchReading('1537', 'ne', 'dummy-key',
          nowMs: now, client: client);
      expect(r.color, SignalColor.unknown);
    });

    test('정상 응답 → 파싱 위임(green)', () async {
      final body = jsonEncode([
        {
          'itstId': '1537',
          'trsmUtcTime': now,
          'nePdsgStatNm': 'protected-Movement-Allowed',
          'nePdsgRmdrCs': 241,
        }
      ]);
      final client = MockClient((req) async => http.Response(body, 200));
      final r = await fetchReading('1537', 'ne', 'dummy-key',
          nowMs: now, client: client);
      expect(r.color, SignalColor.green);
      expect(r.remainSec, 24.1);
    });
  });
```

`MockClient`는 `package:http/testing.dart`가 제공한다. import에 추가:

```dart
import 'package:http/testing.dart';
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/daniellim/Desktop/Clip_Sense/app && flutter test test/signal_api_test.dart`
Expected: FAIL — `fetchReading` 미정의.

- [ ] **Step 3: Write minimal implementation (signal_api.dart에 추가)**

`app/lib/signals/signal_api.dart` 상단 import에 추가:

```dart
import 'dart:convert';
import 'package:http/http.dart' as http;
```

파일 끝에 추가:

```dart
const String defaultBaseUrl =
    'https://t-data.seoul.go.kr/apig/apiman-gateway/tapi/'
    'v2xSignalPhaseTimingFusionInformation/1.0';

/// 서울 T-Data를 호출해 해당 교차로·방위 보행신호를 SignalReading으로.
///
/// 네트워크·HTTP·JSON 오류는 전부 삼켜 unknown 반환(앱을 죽이지 않음).
/// client를 주입하면 네트워크 없이 테스트 가능. apiKey는 호출자가 주입
/// (여기서 하드코딩 안 함).
Future<SignalReading> fetchReading(
    String itstId, String direction, String apiKey,
    {required int nowMs,
    http.Client? client,
    String baseUrl = defaultBaseUrl,
    Duration timeout = const Duration(seconds: 5)}) async {
  final c = client ?? http.Client();
  try {
    final uri = Uri.parse(baseUrl).replace(queryParameters: {
      'apiKey': apiKey,
      'type': 'json',
      'itstId': itstId,
      'numOfRows': '10',
    });
    final resp = await c.get(uri).timeout(timeout);
    final decoded = jsonDecode(resp.body);
    if (decoded is! List) {
      return const SignalReading(SignalColor.unknown, null, SignalSource.api);
    }
    return parseReading(decoded, direction, nowMs, itstId: itstId);
  } catch (_) {
    // 네트워크/HTTP/JSON/기타 — 정직하게 unknown (조용히 실패)
    return const SignalReading(SignalColor.unknown, null, SignalSource.api);
  } finally {
    if (client == null) c.close();
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/daniellim/Desktop/Clip_Sense/app && flutter test test/signal_api_test.dart`
Expected: PASS — All tests passed! (24 tests)

- [ ] **Step 5: Commit**

```bash
cd /Users/daniellim/Desktop/Clip_Sense
git add app/lib/signals/signal_api.dart app/test/signal_api_test.dart
git commit -m "feat(dart): add HTTP fetchReading with fail-safe unknown"
```

---

## Task 5: vision_adapter.dart

원본: 루트 `vision_adapter.py`. 순수 번역 + UNKNOWN 스텁.

**Files:**
- Create: `app/lib/signals/vision_adapter.dart`
- Test: `app/test/vision_adapter_test.dart`

**Interfaces:**
- Consumes: `signal_reading.dart`
- Produces:
  - `SignalReading toReading(String state, {double? remainSec, int freshMs = 0})`
  - `SignalReading visionStub()`

- [ ] **Step 1: Write the failing test**

Create `app/test/vision_adapter_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/signals/signal_reading.dart';
import 'package:clip_sense/signals/vision_adapter.dart';

void main() {
  test('RED 매핑', () => expect(toReading('RED').color, SignalColor.red));
  test('GREEN 매핑', () => expect(toReading('GREEN').color, SignalColor.green));
  test('GREEN_BLINK → clearance',
      () => expect(toReading('GREEN_BLINK').color, SignalColor.clearance));
  test('UNKNOWN 매핑',
      () => expect(toReading('UNKNOWN').color, SignalColor.unknown));

  test('source=vision', () {
    expect(toReading('GREEN').source, SignalSource.vision);
  });

  test('잔여·신선도 보존', () {
    final r = toReading('GREEN', remainSec: 12.0, freshMs: 100);
    expect(r.remainSec, 12.0);
    expect(r.freshMs, 100);
  });

  test('잔여 기본 null', () {
    expect(toReading('RED').remainSec, isNull);
  });

  test('미지 상태 → unknown', () {
    expect(toReading('SOMETHING_ELSE').color, SignalColor.unknown);
  });

  test('visionStub은 항상 unknown', () {
    final r = visionStub();
    expect(r.color, SignalColor.unknown);
    expect(r.source, SignalSource.vision);
    expect(r.remainSec, isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/daniellim/Desktop/Clip_Sense/app && flutter test test/vision_adapter_test.dart`
Expected: FAIL — `vision_adapter.dart` 없음.

- [ ] **Step 3: Write minimal implementation**

Create `app/lib/signals/vision_adapter.dart`:

```dart
/// 기존 카메라 검출기 상태 → 표준 SignalReading 번역 (Python vision_adapter.py 이식).
///
/// 검출 알고리즘은 여기 없다. 상태 문자열 표현만 표준화한다.
/// GREEN_BLINK(초록 점멸)는 clearance로 매핑한다. 실제 카메라 검출기(Dart)는
/// 아직 없으므로 visionStub()이 그 자리를 대신해 항상 unknown을 반환한다.

import 'signal_reading.dart';

const Map<String, SignalColor> _stateMap = {
  'RED': SignalColor.red,
  'GREEN': SignalColor.green,
  'GREEN_BLINK': SignalColor.clearance,
  'UNKNOWN': SignalColor.unknown,
};

/// 검출기 상태 문자열 → SignalReading(source: vision). 미지 상태는 unknown.
SignalReading toReading(String state, {double? remainSec, int freshMs = 0}) {
  final color = _stateMap[state] ?? SignalColor.unknown;
  return SignalReading(color, remainSec, SignalSource.vision, freshMs: freshMs);
}

/// 실제 카메라 검출기 자리의 스텁. 항상 unknown (신호 없음).
/// judge가 "카메라 신호 없음" 상황(단일소스 경로)을 겪게 한다.
SignalReading visionStub() {
  return const SignalReading(SignalColor.unknown, null, SignalSource.vision);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/daniellim/Desktop/Clip_Sense/app && flutter test test/vision_adapter_test.dart`
Expected: PASS — All tests passed! (9 tests)

- [ ] **Step 5: Commit**

```bash
cd /Users/daniellim/Desktop/Clip_Sense
git add app/lib/signals/vision_adapter.dart app/test/vision_adapter_test.dart
git commit -m "feat(dart): port vision adapter with UNKNOWN stub source"
```

---

## Task 6: judge.dart (AND 판단 엔진)

원본: 루트 `judge.py`. 안전 핵심. `allowSingleSource` 기본 `false`.

**Files:**
- Create: `app/lib/signals/judge.dart`
- Test: `app/test/judge_test.dart`

**Interfaces:**
- Consumes: `signal_reading.dart`
- Produces:
  - `enum Decision { walk, wait, unknown }`
  - `Decision decide(SignalReading? api, SignalReading? vision, {double needSec = 7.0, int staleMs = 2000, bool allowSingleSource = false})`

- [ ] **Step 1: Write the failing test**

Create `app/test/judge_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/signals/signal_reading.dart';
import 'package:clip_sense/signals/judge.dart';

SignalReading api(SignalColor color, {double? remain = 30.0, int fresh = 100}) =>
    SignalReading(color, remain, SignalSource.api, freshMs: fresh);
SignalReading vis(SignalColor color, {double? remain, int fresh = 100}) =>
    SignalReading(color, remain, SignalSource.vision, freshMs: fresh);

void main() {
  test('둘 다 초록 → walk', () {
    expect(decide(api(SignalColor.green, remain: 30), vis(SignalColor.green)),
        Decision.walk);
  });

  test('API초록·비전빨강 → wait', () {
    expect(decide(api(SignalColor.green), vis(SignalColor.red)), Decision.wait);
  });
  test('API빨강·비전초록 → wait', () {
    expect(decide(api(SignalColor.red), vis(SignalColor.green)), Decision.wait);
  });
  test('API초록·비전점멸 → wait', () {
    expect(decide(api(SignalColor.green), vis(SignalColor.clearance)),
        Decision.wait);
  });
  test('API점멸·비전초록 → wait', () {
    expect(decide(api(SignalColor.clearance), vis(SignalColor.green)),
        Decision.wait);
  });

  test('둘 다 빨강 → wait', () {
    expect(decide(api(SignalColor.red), vis(SignalColor.red)), Decision.wait);
  });

  test('잔여 부족 → wait', () {
    expect(
        decide(api(SignalColor.green, remain: 3.0), vis(SignalColor.green),
            needSec: 7.0),
        Decision.wait);
  });

  test('잔여 정보 없음 → wait', () {
    expect(
        decide(api(SignalColor.green, remain: null),
            vis(SignalColor.green, remain: null),
            needSec: 7.0),
        Decision.wait);
  });

  test('한쪽 stale → wait', () {
    expect(
        decide(api(SignalColor.green, remain: 30, fresh: 5000),
            vis(SignalColor.green),
            staleMs: 2000),
        Decision.wait);
  });

  test('둘 다 unknown → unknown', () {
    expect(
        decide(api(SignalColor.unknown, remain: null),
            vis(SignalColor.unknown, remain: null)),
        Decision.unknown);
  });

  test('비전 단독 초록 → walk (allowSingleSource)', () {
    expect(
        decide(null, vis(SignalColor.green, remain: 30),
            allowSingleSource: true),
        Decision.walk);
  });

  test('단일 소스 비허용 → wait', () {
    expect(
        decide(null, vis(SignalColor.green, remain: 30),
            allowSingleSource: false),
        Decision.wait);
  });

  test('비전 단독 빨강 → wait', () {
    expect(decide(null, vis(SignalColor.red), allowSingleSource: true),
        Decision.wait);
  });

  test('둘 다 null → unknown', () {
    expect(decide(null, null), Decision.unknown);
  });

  test('단일 소스 초록·잔여없음 → wait', () {
    expect(
        decide(null, vis(SignalColor.green, remain: null),
            allowSingleSource: true),
        Decision.wait);
  });

  // 안전 정책(사용자 확정): 기본 엄격 — 카메라 unknown이면 API 초록도 wait
  test('기본: 비전 unknown이면 API 초록이어도 wait', () {
    expect(
        decide(api(SignalColor.green, remain: 30),
            vis(SignalColor.unknown, remain: null)),
        Decision.wait);
  });
  test('기본: API unknown이면 비전 초록이어도 wait', () {
    expect(
        decide(api(SignalColor.unknown, remain: null),
            vis(SignalColor.green, remain: 30)),
        Decision.wait);
  });
  test('기본: 비전 stale이면 API 초록이어도 wait', () {
    expect(
        decide(api(SignalColor.green, remain: 30),
            vis(SignalColor.green, remain: 30, fresh: 5000)),
        Decision.wait);
  });
  test('기본: API null이면 비전 초록이어도 wait', () {
    expect(decide(null, vis(SignalColor.green, remain: 30)), Decision.wait);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/daniellim/Desktop/Clip_Sense/app && flutter test test/judge_test.dart`
Expected: FAIL — `judge.dart` 없음.

- [ ] **Step 3: Write minimal implementation**

Create `app/lib/signals/judge.dart`:

```dart
/// 이중 판단 엔진: API + 비전 → walk / wait / unknown (Python judge.py 이식).
///
/// 안전 핵심 (Fail-Safe):
/// - walk는 두 소스가 모두 green + 잔여시간 충분 + 둘 다 fresh일 때만.
/// - 하나라도 불일치/부족/stale → wait.
/// - 두 소스 모두 unknown 또는 입력 없음 → Decision.unknown.
/// - 기본(allowSingleSource=false)은 엄격: 두 소스 모두 green일 때만 walk.
///   한쪽이 unknown/stale/없음이라 단일 소스만 가용하면 무조건 wait
///   — 카메라가 조용히 실패해도 API 단독으로 walk가 나가지 않는다.
/// - 서울 밖 카메라 단독 운용은 호출자가 allowSingleSource=true로 opt-in.

import 'signal_reading.dart';

enum Decision { walk, wait, unknown }

/// 이 판정을 판단에 쓸 수 있는가 (존재 + unknown 아님 + fresh).
bool _usable(SignalReading? r, int staleMs) =>
    r != null && r.color != SignalColor.unknown && r.freshMs <= staleMs;

/// 가용한 잔여시간 중 가장 짧은 것이 needSec 이상인가.
/// 잔여 정보가 하나도 없으면 보수적으로 false.
bool _remainOk(List<SignalReading> readings, double needSec) {
  final remains = readings
      .map((r) => r.remainSec)
      .where((s) => s != null)
      .cast<double>()
      .toList();
  if (remains.isEmpty) return false;
  return remains.reduce((a, b) => a < b ? a : b) >= needSec;
}

/// 최종 보행 결정. 기본은 엄격 — 두 소스 모두 green일 때만 walk.
Decision decide(SignalReading? api, SignalReading? vision,
    {double needSec = 7.0,
    int staleMs = 2000,
    bool allowSingleSource = false}) {
  final apiOk = _usable(api, staleMs);
  final visOk = _usable(vision, staleMs);

  // 둘 다 못 씀 → 확인 불가
  if (!apiOk && !visOk) return Decision.unknown;

  // 두 소스 다 가용: AND 규칙
  if (apiOk && visOk) {
    final bothGreen =
        api!.color == SignalColor.green && vision!.color == SignalColor.green;
    if (bothGreen && _remainOk([api, vision], needSec)) return Decision.walk;
    return Decision.wait;
  }

  // 단일 소스만 가용
  if (!allowSingleSource) return Decision.wait;
  final single = apiOk ? api! : vision!;
  if (single.color == SignalColor.green && _remainOk([single], needSec)) {
    return Decision.walk;
  }
  return Decision.wait;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/daniellim/Desktop/Clip_Sense/app && flutter test test/judge_test.dart`
Expected: PASS — All tests passed! (20 tests)

- [ ] **Step 5: 전체 테스트 확인 + Commit**

Run: `cd /Users/daniellim/Desktop/Clip_Sense/app && flutter test`
Expected: PASS — 전체 스위트 통과(signal_reading 7 + signal_api 24 + vision_adapter 9 + judge 20 = 60 tests). widget_test.dart는 Task 1에서 삭제됐으므로 우리 4개 테스트 파일만 실행된다.

```bash
cd /Users/daniellim/Desktop/Clip_Sense
git add app/lib/signals/judge.dart app/test/judge_test.dart
git commit -m "feat(dart): port dual-source AND judge with strict default"
```

---

## Self-Review

**1. Spec coverage (설계 대비):**
- §2 프로젝트 구조(app/ 서브디렉터리, lib/signals/) → Task 1-6 ✅
- §3 언어 매핑(색 enum 승격, http.Client 주입, itstId toString 비교) → Task 2(enum), Task 4(client), Task 3(toString) ✅
- §5.1 signal_reading(SignalColor/Source enum, SignalReading, isGo) → Task 2 ✅
- §5.2 signal_api(statusMap, parseReading 안전수정 전부, fetchReading Fail-Safe) → Task 3(파싱+itstId+미래시각), Task 4(HTTP) ✅
- §5.3 vision_adapter(toReading, visionStub 항상 unknown) → Task 5 ✅
- §5.4 judge(Decision enum, decide, 엄격 기본 false) → Task 6 ✅
- §7 테스트 전략(Python 미러링, 각 케이스) → 각 태스크 테스트 ✅
- 범위 밖(UI/음성/햅틱/백그라운드/실제카메라/GPS) → 계획에 없음 ✅

**2. Placeholder scan:** "TBD/TODO/적절히" 없음. 모든 코드 스텝에 완전한 Dart 코드. 오픈이슈(pubspec.lock, flutter create 범위)는 Task 1에서 구체 처리(gitignore 블록 명시)로 해소 ✅

**3. Type consistency:**
- `SignalReading(color, remainSec, source, {freshMs, raw})` — Task 2 정의 = Task 3/4/5/6 사용 일치 ✅
- `SignalColor.{green,red,clearance,unknown}` — 전 태스크 동일 ✅
- `parseReading(records, direction, nowMs, {staleMs, itstId})` — Task 3 정의 = Task 4 호출 일치 ✅
- `decide(api, vision, {needSec, staleMs, allowSingleSource})` — Task 6 정의 = test 호출 일치 ✅
- 패키지 import 경로 `package:clip_sense/signals/*.dart` — Task 1의 `--project-name clip_sense`와 일치 ✅
- Decision enum: `Decision.{walk,wait,unknown}` — judge.dart 정의 = test 일치 ✅

이상 없음.
