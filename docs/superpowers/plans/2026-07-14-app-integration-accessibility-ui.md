# 앱 통합 + 접근성 UI 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 완성된 엔진(실API→판단→음성/햅틱)을 1초 루프로 돌려 시각장애인이 켜고 끌 수 있는 접근성 앱으로 잇는다.

**Architecture:** 로직(GuidanceController: ChangeNotifier, 타이머·엔진 루프)과 화면(GuidanceScreen: 큰 버튼 토글·상태 표시·Semantics)을 분리한다. config는 고정 교차로·주기를 담고, main은 화면 하나만 띄운다. 컨트롤러는 fetch 함수·FeedbackController·타이머 팩토리를 주입받아 네트워크·하드웨어 없이 테스트 가능하게 한다.

**Tech Stack:** Flutter 3.35.6 / Dart 3.9.2, 기존 `signals`·`feedback` 모듈, flutter_test.

## Global Constraints

- **apiKey 하드코딩 금지.** `const String kApiKey = String.fromEnvironment('TDATA_KEY')` — `--dart-define=TDATA_KEY=...` 주입만. 개발용 키는 배포 전 재발급.
- **allowSingleSource=true는 임시.** 카메라 검출기 stub 동안만. config·컨트롤러 주석에 "카메라 완성 시 false로 복귀" 명시.
- **Fail-Safe 유지.** 오류/stale/미지 → unknown → "확인 불가, 대기하세요". 애매하면 절대 walk 아님.
- **컨트롤러는 Flutter 위젯에 의존 금지** — `ChangeNotifier`만 상속. 위젯은 화면 파일에만.
- **루프 주기 1초**, **needSec 7.0**, **고정 교차로 itstId '1620'·방향 'st'**(실측 확인, 실사용 시 교체).
- 실제 엔진 시그니처(그대로 사용):
  - `Future<SignalReading> fetchReading(String itstId, String direction, String apiKey, {required int nowMs, http.Client? client, String baseUrl, Duration timeout})`
  - `SignalReading visionStub()` (동기, 항상 unknown)
  - `Decision decide(SignalReading? api, SignalReading? vision, {double needSec = 7.0, int staleMs = 2000, bool allowSingleSource = false})`
  - `Future<void> FeedbackController.onDecision(Decision d, {double? remainSec})`
  - `enum Decision { walk, wait, unknown }`, `enum SignalColor { green, red, clearance, unknown }`
  - `class SignalReading { SignalColor color; double? remainSec; ... }`

---

## File Structure

- Create: `lib/app/config.dart` — 고정 설정 상수.
- Create: `lib/app/guidance_controller.dart` — ChangeNotifier, 1초 루프, start/stop/toggle.
- Create: `lib/app/guidance_screen.dart` — 큰 버튼 토글 UI, 상태 표시, Semantics.
- Modify: `lib/main.dart` — 카운터 템플릿 제거, GuidanceScreen 띄움.
- Test: `test/guidance_controller_test.dart`, `test/guidance_screen_test.dart`.

---

## Task 1: config.dart (고정 설정)

**Files:**
- Create: `app/lib/app/config.dart`

**Interfaces:**
- Produces: `kItstId`, `kDirection`, `kNeedSec`, `kLoopInterval`, `kApiKey`, `kAllowSingleSource`.

- [ ] **Step 1: 설정 파일 작성**

```dart
/// 앱 고정 설정. GPS 자동 교차로 선택은 별도 조각 — 지금은 고정 1개.
library;

/// 프로토타입 기본 교차로: 실측(2026-07-14)에서 st 방향 보행 초록 확인됨.
/// 실기기 사용 시 사용자 실제 위치 교차로로 교체(근본 해결은 GPS 자동선택).
const String kItstId = '1620';

/// 방위 접두사. nt/et/st/wt/ne/se/sw/nw 중 하나.
const String kDirection = 'st';

/// 건너기 시작에 필요한 최소 잔여 초. 이보다 짧으면 walk 안 함.
const double kNeedSec = 7.0;

/// 신호 확인 주기.
const Duration kLoopInterval = Duration(seconds: 1);

/// T-Data API 키. 하드코딩 금지 — --dart-define=TDATA_KEY=... 로 주입.
const String kApiKey = String.fromEnvironment('TDATA_KEY');

/// ⚠️ 임시: 카메라 검출기가 stub(항상 unknown)이라 엄격 AND면 영원히 wait이다.
/// API 단독 판단을 임시 허용한다. 카메라 검출기 완성 시 반드시 false로 복귀.
const bool kAllowSingleSource = true;
```

- [ ] **Step 2: 분석 통과 확인**

Run: `cd app && flutter analyze lib/app/config.dart`
Expected: No issues found.

- [ ] **Step 3: 커밋**

```bash
git add app/lib/app/config.dart
git commit -m "feat(app): add fixed config (intersection, loop, key injection)"
```

---

## Task 2: GuidanceController (엔진 루프)

**Files:**
- Create: `app/lib/app/guidance_controller.dart`
- Test: `app/test/guidance_controller_test.dart`

**Interfaces:**
- Consumes: `fetchReading`, `visionStub`, `decide`, `FeedbackController.onDecision`, config 상수.
- Produces:
  - `typedef FetchReading = Future<SignalReading> Function(String itstId, String direction, String apiKey, {required int nowMs});`
  - `class GuidanceController extends ChangeNotifier`
    - 생성자: `GuidanceController({required FeedbackController feedback, FetchReading? fetch, Duration interval = kLoopInterval, bool allowSingleSource = kAllowSingleSource})`
    - `bool get running`, `Decision get decision`, `double? get remainSec`
    - `void start()`, `void stop()`, `void toggle()`, `Future<void> tickOnce()`(테스트용 1틱 노출), `@override void dispose()`

주입 설계: 타이머는 `Timer.periodic`을 쓰되, 각 틱은 `tickOnce()`를 호출한다. 테스트는 `start()` 대신 `tickOnce()`를 직접 await 해 타이머 없이 검증한다. `fetch`가 null이면 실제 `fetchReading`을 래핑해 기본 사용.

- [ ] **Step 1: 실패 테스트 작성**

```dart
// test/guidance_controller_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/signals/signal_reading.dart';
import 'package:clip_sense/signals/judge.dart';
import 'package:clip_sense/feedback/speech_output.dart';
import 'package:clip_sense/feedback/haptic_output.dart';
import 'package:clip_sense/feedback/feedback_controller.dart';
import 'package:clip_sense/app/guidance_controller.dart';

class FakeSpeech implements SpeechOutput {
  final List<String> spoken = [];
  @override
  Future<void> speak(String text) async => spoken.add(text);
}

class FakeHaptic implements HapticOutput {
  final List<Decision> played = [];
  @override
  Future<void> play(Decision d) async => played.add(d);
}

void main() {
  late FakeSpeech speech;
  late FakeHaptic haptic;
  late FeedbackController feedback;

  setUp(() {
    speech = FakeSpeech();
    haptic = FakeHaptic();
    feedback = FeedbackController(speech, haptic);
  });

  // 주입할 fetch: 지정한 SignalReading을 반환.
  GuidanceController make(SignalReading apiReading,
      {bool allowSingleSource = true}) {
    return GuidanceController(
      feedback: feedback,
      allowSingleSource: allowSingleSource,
      fetch: (itstId, direction, apiKey, {required nowMs}) async => apiReading,
    );
  }

  test('초기 상태: 정지·unknown', () {
    final c = make(const SignalReading(SignalColor.red, null, SignalSource.api));
    expect(c.running, isFalse);
    expect(c.decision, Decision.unknown);
    c.dispose();
  });

  test('API 초록·충분 → tick 후 walk + 잔여시간 + 음성', () async {
    final c = make(const SignalReading(
        SignalColor.green, 15.0, SignalSource.api, freshMs: 0));
    await c.tickOnce();
    expect(c.decision, Decision.walk);
    expect(c.remainSec, 15.0);
    expect(speech.spoken.single, contains('건너'));
    expect(haptic.played.single, Decision.walk);
    c.dispose();
  });

  test('API 초록이지만 4초(부족) → wait', () async {
    final c = make(const SignalReading(
        SignalColor.green, 4.0, SignalSource.api, freshMs: 0));
    await c.tickOnce();
    expect(c.decision, Decision.wait);
    c.dispose();
  });

  test('API 빨강 → wait', () async {
    final c = make(const SignalReading(
        SignalColor.red, null, SignalSource.api, freshMs: 0));
    await c.tickOnce();
    expect(c.decision, Decision.wait);
    c.dispose();
  });

  test('fetch가 throw해도 tick은 unknown으로 수렴(타이머 안 죽음)', () async {
    final c = GuidanceController(
      feedback: feedback,
      fetch: (itstId, direction, apiKey, {required nowMs}) async =>
          throw Exception('network'),
    );
    await c.tickOnce();
    expect(c.decision, Decision.unknown);
    c.dispose();
  });

  test('toggle: 정지→시작→정지', () {
    final c = make(const SignalReading(SignalColor.red, null, SignalSource.api));
    expect(c.running, isFalse);
    c.toggle();
    expect(c.running, isTrue);
    c.toggle();
    expect(c.running, isFalse);
    c.dispose();
  });

  test('stop 후 running=false, 상태 알림', () {
    final c = make(const SignalReading(SignalColor.red, null, SignalSource.api));
    c.start();
    expect(c.running, isTrue);
    c.stop();
    expect(c.running, isFalse);
    c.dispose();
  });

  test('notifyListeners: tick이 리스너를 부른다', () async {
    final c = make(const SignalReading(
        SignalColor.green, 15.0, SignalSource.api, freshMs: 0));
    var notified = 0;
    c.addListener(() => notified++);
    await c.tickOnce();
    expect(notified, greaterThan(0));
    c.dispose();
  });
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd app && flutter test test/guidance_controller_test.dart`
Expected: FAIL — `guidance_controller.dart` 없음/타입 미정의.

- [ ] **Step 3: 컨트롤러 구현**

```dart
// lib/app/guidance_controller.dart
/// 엔진 루프 컨트롤러. 1초마다 실API→판단→음성/햅틱, 화면에 상태 통지.
///
/// Flutter 위젯에 의존하지 않는다(ChangeNotifier만). fetch·interval을 주입해
/// 네트워크·타이머 없이 테스트한다. tickOnce()는 한 틱을 노출(테스트·수동 호출).
library;

import 'dart:async';

import 'package:http/http.dart' as http;

import '../signals/signal_reading.dart';
import '../signals/signal_api.dart' as api;
import '../signals/vision_adapter.dart';
import '../signals/judge.dart';
import '../feedback/feedback_controller.dart';
import 'config.dart';

/// 주입 가능한 fetch 시그니처(실제 fetchReading의 축약형).
typedef FetchReading = Future<SignalReading> Function(
    String itstId, String direction, String apiKey,
    {required int nowMs});

class GuidanceController extends ChangeNotifier {
  final FeedbackController _feedback;
  final FetchReading _fetch;
  final Duration _interval;
  final bool _allowSingleSource;

  Timer? _timer;
  bool _running = false;
  Decision _decision = Decision.unknown;
  double? _remainSec;

  GuidanceController({
    required FeedbackController feedback,
    FetchReading? fetch,
    Duration interval = kLoopInterval,
    bool allowSingleSource = kAllowSingleSource,
  })  : _feedback = feedback,
        _fetch = fetch ?? _defaultFetch,
        _interval = interval,
        _allowSingleSource = allowSingleSource;

  static Future<SignalReading> _defaultFetch(
      String itstId, String direction, String apiKey,
      {required int nowMs}) {
    return api.fetchReading(itstId, direction, apiKey, nowMs: nowMs);
  }

  bool get running => _running;
  Decision get decision => _decision;
  double? get remainSec => _remainSec;

  void start() {
    if (_running) return;
    _running = true;
    _timer = Timer.periodic(_interval, (_) => tickOnce());
    notifyListeners();
    tickOnce(); // 시작 즉시 첫 확인(1초 기다리지 않음)
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
    notifyListeners();
  }

  void toggle() => _running ? stop() : start();

  /// 한 틱: 실API→판단→음성/햅틱→상태통지. 예외는 삼켜 unknown으로 수렴
  /// (타이머가 죽지 않게 — 1초 뒤 재시도).
  Future<void> tickOnce() async {
    Decision d;
    double? remain;
    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final apiReading = await _fetch(kItstId, kDirection, kApiKey, nowMs: nowMs);
      final visionReading = visionStub();
      d = decide(apiReading, visionReading,
          needSec: kNeedSec, allowSingleSource: _allowSingleSource);
      remain = d == Decision.walk ? apiReading.remainSec : null;
    } catch (_) {
      d = Decision.unknown;
      remain = null;
    }
    _decision = d;
    _remainSec = remain;
    await _feedback.onDecision(d, remainSec: remain);
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
```

주: `ChangeNotifier`는 `package:flutter/foundation.dart`에 있다. import 추가 필요:
`import 'package:flutter/foundation.dart';` — 위 import 목록 맨 위에 넣는다.

- [ ] **Step 4: import 보정 후 테스트 통과 확인**

`guidance_controller.dart` 상단에 `import 'package:flutter/foundation.dart';` 추가.

Run: `cd app && flutter test test/guidance_controller_test.dart`
Expected: PASS (8 tests).

- [ ] **Step 5: 분석 통과 확인**

Run: `cd app && flutter analyze lib/app/guidance_controller.dart test/guidance_controller_test.dart`
Expected: No issues found.

- [ ] **Step 6: 커밋**

```bash
git add app/lib/app/guidance_controller.dart app/test/guidance_controller_test.dart
git commit -m "feat(app): add GuidanceController (1s engine loop, injectable, fail-safe)"
```

---

## Task 3: GuidanceScreen (접근성 UI)

**Files:**
- Create: `app/lib/app/guidance_screen.dart`
- Test: `app/test/guidance_screen_test.dart`

**Interfaces:**
- Consumes: `GuidanceController`(running/decision/remainSec/toggle), `Decision`.
- Produces: `class GuidanceScreen extends StatefulWidget { final GuidanceController controller; ... }`.

설계: 화면 전체가 탭 타깃 → `controller.toggle()`. 상태에 따라 배경색·아이콘·텍스트.
`Semantics`로 스크린리더 라벨(현재 상태 + 조작 안내), 상태 텍스트는 `liveRegion: true`.
`AnimatedBuilder(animation: controller)`로 갱신 구독.

색·문구(스펙 §4.3):
- 정지: 배경 `Color(0xFF222222)`, 문구 "화면을 눌러 안내를 시작하세요", 아이콘 없음.
- walk: 배경 `Color(0xFF0A8F3C)`, 🚶(아이콘 대신 텍스트 이모지 가능), "건너세요", "N초"(remainSec 정수).
- wait: 배경 `Color(0xFFC31414)`, ✋, "기다리세요".
- unknown: 배경 `Color(0xFF5A5A5A)`, ❓, "확인 불가", "대기하세요".

- [ ] **Step 1: 실패 위젯 테스트 작성**

```dart
// test/guidance_screen_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/signals/signal_reading.dart';
import 'package:clip_sense/signals/judge.dart';
import 'package:clip_sense/feedback/speech_output.dart';
import 'package:clip_sense/feedback/haptic_output.dart';
import 'package:clip_sense/feedback/feedback_controller.dart';
import 'package:clip_sense/app/guidance_controller.dart';
import 'package:clip_sense/app/guidance_screen.dart';

class FakeSpeech implements SpeechOutput {
  @override
  Future<void> speak(String text) async {}
}

class FakeHaptic implements HapticOutput {
  @override
  Future<void> play(Decision d) async {}
}

GuidanceController makeController(SignalReading reading) {
  return GuidanceController(
    feedback: FeedbackController(FakeSpeech(), FakeHaptic()),
    fetch: (itstId, direction, apiKey, {required nowMs}) async => reading,
  );
}

void main() {
  testWidgets('정지 상태: 시작 안내 문구 표시', (tester) async {
    final c = makeController(
        const SignalReading(SignalColor.red, null, SignalSource.api));
    await tester.pumpWidget(MaterialApp(home: GuidanceScreen(controller: c)));
    expect(find.textContaining('시작'), findsOneWidget);
    c.dispose();
  });

  testWidgets('walk 상태: "건너세요" + 잔여시간 표시', (tester) async {
    final c = makeController(const SignalReading(
        SignalColor.green, 15.0, SignalSource.api, freshMs: 0));
    await tester.pumpWidget(MaterialApp(home: GuidanceScreen(controller: c)));
    await c.tickOnce();
    await tester.pump();
    expect(find.textContaining('건너세요'), findsOneWidget);
    expect(find.textContaining('15'), findsOneWidget);
    c.dispose();
  });

  testWidgets('wait 상태: "기다리세요" 표시', (tester) async {
    final c = makeController(const SignalReading(
        SignalColor.red, null, SignalSource.api, freshMs: 0));
    await tester.pumpWidget(MaterialApp(home: GuidanceScreen(controller: c)));
    await c.tickOnce();
    await tester.pump();
    expect(find.textContaining('기다리세요'), findsOneWidget);
    c.dispose();
  });

  testWidgets('화면 탭 → 안내 시작(running=true)', (tester) async {
    final c = makeController(
        const SignalReading(SignalColor.red, null, SignalSource.api));
    await tester.pumpWidget(MaterialApp(home: GuidanceScreen(controller: c)));
    expect(c.running, isFalse);
    await tester.tap(find.byType(GuidanceScreen));
    await tester.pump();
    expect(c.running, isTrue);
    c.stop();
    c.dispose();
  });

  testWidgets('Semantics 버튼 라벨 존재', (tester) async {
    final c = makeController(
        const SignalReading(SignalColor.red, null, SignalSource.api));
    await tester.pumpWidget(MaterialApp(home: GuidanceScreen(controller: c)));
    // 버튼 시맨틱스가 최소 하나 있어야(스크린리더 조작 가능)
    expect(
      tester.getSemantics(find.byType(GuidanceScreen)),
      isNotNull,
    );
    c.dispose();
  });
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd app && flutter test test/guidance_screen_test.dart`
Expected: FAIL — `guidance_screen.dart` 없음.

- [ ] **Step 3: 화면 구현**

```dart
// lib/app/guidance_screen.dart
/// 접근성 안내 화면. 화면 전체가 큰 버튼(탭 → 시작/정지 토글).
/// 상태별 고대비 색·초대형 글자·아이콘(A안) + 스크린리더 Semantics.
///
/// 전맹 사용자에겐 엔진 음성/햅틱이 이미 전달된다. 이 시각 표시는 저시력·도우미용,
/// Semantics 라벨은 전맹 사용자의 화면 조작(시작/정지 확인)용.
library;

import 'package:flutter/material.dart';

import '../signals/judge.dart';
import 'guidance_controller.dart';

class GuidanceScreen extends StatelessWidget {
  final GuidanceController controller;
  const GuidanceScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final v = _view(controller);
        return Scaffold(
          body: Semantics(
            button: true,
            label: v.semanticLabel,
            excludeSemantics: true,
            child: GestureDetector(
              onTap: controller.toggle,
              behavior: HitTestBehavior.opaque,
              child: Container(
                color: v.bg,
                width: double.infinity,
                height: double.infinity,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (v.icon != null)
                      Text(v.icon!, style: const TextStyle(fontSize: 96)),
                    const SizedBox(height: 16),
                    Text(v.title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 56,
                            fontWeight: FontWeight.w900,
                            color: Colors.white)),
                    if (v.sub != null) ...[
                      const SizedBox(height: 12),
                      Text(v.sub!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.w800,
                              color: Colors.white)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _View {
  final Color bg;
  final String? icon;
  final String title;
  final String? sub;
  final String semanticLabel;
  _View(this.bg, this.icon, this.title, this.sub, this.semanticLabel);
}

_View _view(GuidanceController c) {
  const tapStart = ' 두 번 탭하면 안내를 시작합니다.';
  const tapStop = ' 두 번 탭하면 안내를 정지합니다.';
  if (!c.running) {
    return _View(const Color(0xFF222222), null, '화면을 눌러\n안내를 시작하세요',
        null, '정지됨.$tapStart');
  }
  switch (c.decision) {
    case Decision.walk:
      final sub = c.remainSec != null ? '${c.remainSec!.round()}초' : null;
      return _View(const Color(0xFF0A8F3C), '🚶', '건너세요', sub,
          '건너세요.${sub != null ? " $sub 남음." : ""}$tapStop');
    case Decision.wait:
      return _View(const Color(0xFFC31414), '✋', '기다리세요', null,
          '기다리세요.$tapStop');
    case Decision.unknown:
      return _View(const Color(0xFF5A5A5A), '❓', '확인 불가', '대기하세요',
          '신호를 확인할 수 없습니다. 대기하세요.$tapStop');
  }
}
```

주: 위젯 테스트에서 `find.byType(GuidanceScreen)`을 탭하려면 GuidanceScreen이
탭 영역을 채워야 한다(위 Container가 화면을 채움 — OK). `StatelessWidget`이지만
`AnimatedBuilder`가 controller를 구독하므로 상태 갱신은 정상 반영된다.

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd app && flutter test test/guidance_screen_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: 분석 통과 확인**

Run: `cd app && flutter analyze lib/app/guidance_screen.dart test/guidance_screen_test.dart`
Expected: No issues found.

- [ ] **Step 6: 커밋**

```bash
git add app/lib/app/guidance_screen.dart app/test/guidance_screen_test.dart
git commit -m "feat(app): add accessible GuidanceScreen (full-screen toggle, Semantics)"
```

---

## Task 4: main.dart 교체 (엔진 배선)

**Files:**
- Modify: `app/lib/main.dart` (전체 교체)

**Interfaces:**
- Consumes: `GuidanceController`, `GuidanceScreen`, `FeedbackController`, `FlutterTtsSpeech`, `VibrationHaptic`.

- [ ] **Step 1: main.dart 전체 교체**

```dart
/// Clip sense 앱 진입점. 엔진(실API→판단→음성/햅틱)을 접근성 화면에 배선한다.
library;

import 'package:flutter/material.dart';

import 'feedback/speech_output.dart';
import 'feedback/haptic_output.dart';
import 'feedback/feedback_controller.dart';
import 'app/guidance_controller.dart';
import 'app/guidance_screen.dart';

void main() {
  final feedback = FeedbackController(FlutterTtsSpeech(), VibrationHaptic());
  final controller = GuidanceController(feedback: feedback);
  runApp(ClipSenseApp(controller: controller));
}

class ClipSenseApp extends StatelessWidget {
  final GuidanceController controller;
  const ClipSenseApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Clip sense',
      debugShowCheckedModeBanner: false,
      home: GuidanceScreen(controller: controller),
    );
  }
}
```

- [ ] **Step 2: 전체 분석 통과 확인**

Run: `cd app && flutter analyze`
Expected: No issues found.

- [ ] **Step 3: 전체 테스트 통과 확인**

Run: `cd app && flutter test`
Expected: All tests passed (기존 70 + 신규 13 = 83).

주: 기존 `test/widget_test.dart`(flutter 기본 카운터 테스트)가 있으면 삭제한다 —
MyApp을 지웠으므로 컴파일 실패한다. Step 1에서 함께 제거.

- [ ] **Step 4: 커밋**

```bash
git add app/lib/main.dart
git rm app/test/widget_test.dart  # 기본 카운터 테스트 제거(있는 경우)
git commit -m "feat(app): wire engine into accessible app (replace counter template)"
```

---

## Self-Review (계획 작성자 수행 완료)

- **스펙 커버리지:** 파일 4개(config/controller/screen/main) ✅, 1초 루프 ✅, 고정 교차로 ✅, 큰 버튼 토글 ✅, A안 표시 ✅, Semantics ✅, allowSingleSource 임시+주석 ✅, Fail-Safe(tick try/catch) ✅, apiKey 주입 ✅.
- **플레이스홀더:** 없음. 모든 코드 블록 완전.
- **타입 일관성:** `fetch` 주입 시그니처가 Task 2 typedef와 Task 3 테스트에서 동일(`(itstId, direction, apiKey, {required nowMs})`). `decide`·`onDecision`·`SignalReading` 실제 시그니처와 일치.
- **주의(구현자에게):** `ChangeNotifier` import는 `package:flutter/foundation.dart`. `find.byType(GuidanceScreen)` 탭 가능하도록 Container가 화면을 채움.

---

## Execution Handoff

계획은 subagent-driven-development로 실행한다(Task별 fresh 구현자 + 리뷰).
