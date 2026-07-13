# 출력 계층 (음성 + 햅틱) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** judge의 Decision(walk/wait/unknown)을 상태 전환 시에만 음성(TTS)과 상태별 진동으로 전달하는 출력 계층을 만든다.

**Architecture:** `app/lib/feedback/`에 3개 파일. FeedbackController(전환 감지·조율, onDecision은 Future<void>)가 SpeechOutput·HapticOutput 인터페이스에만 의존한다. 실제 백엔드(FlutterTtsSpeech, VibrationHaptic)는 인터페이스 뒤에 격리해, 전환 로직을 Fake 백엔드로 하드웨어 없이 테스트한다. 문구 생성(speechText)은 순수 함수라 테스트로 검증한다.

**Tech Stack:** Flutter 3.35.6 / Dart 3.9.2. 의존성: flutter_tts ^4.2.5(기기 내장 TTS), vibration ^3.2.0(패턴 진동). 테스트: `flutter test`.

## Global Constraints

- **전환 시에만 안내** — Decision이 이전과 다를 때만 speak·play. 같은 상태 지속 중 무음.
- **onDecision은 `Future<void>`** — 각 백엔드를 개별 `await` + try/catch. 동기 try/catch는 async 실패를 못 잡아 멀티채널 보장이 깨진다. Fake 백엔드도 **async로 throw**(동기 throw면 테스트 거짓 통과).
- **멀티채널 독립** — speech 실패해도 haptic은 반드시 시도. 두 호출을 각각 try/catch로 격리.
- **Fail-Safe** — TTS·진동 실패(권한/미지원/플랫폼 예외)는 삼켜 앱을 죽이지 않음.
- **안내 문구(정확히)** — walk: "지금 건너셔도 됩니다"(remainSec 있으면 ", N초 남았습니다" 덧붙임, N=반올림 정수), wait: "기다리세요", unknown: "신호를 확인할 수 없습니다. 대기하세요"(행동 지시 포함).
- **잔여시간은 전환 시 스냅샷 1회** — 카운트다운 재안내 없음(이번 조각).
- **진동 패턴** — walk: 짧게 두 번, wait: 길게 한 번, unknown: 짧게 세 번. vibration 패턴은 [wait, vibrate, wait, vibrate, ...] (0부터 wait로 시작).
- **Decision은 enum** — `enum Decision { walk, wait, unknown }`(app/lib/signals/judge.dart). `d == _last`는 카테고리 비교.
- **작업 디렉터리** — Dart 코드·테스트는 `app/` 안. import 경로 `package:clip_sense/...`.

---

## File Structure

- **Modify `app/pubspec.yaml`** — flutter_tts, vibration 의존성 추가(Task 1).
- **Create `app/lib/feedback/speech_output.dart`** — `SpeechOutput` 인터페이스 + `speechText` 순수 함수 + `FlutterTtsSpeech` 실제 구현(Task 2, 3).
- **Create `app/lib/feedback/haptic_output.dart`** — `HapticOutput` 인터페이스 + `VibrationHaptic` 실제 구현(Task 4).
- **Create `app/lib/feedback/feedback_controller.dart`** — `FeedbackController`(전환 감지·조율)(Task 5).
- **Create `app/test/feedback_controller_test.dart`** — Fake 백엔드 주입 테스트(Task 5).
- **Create `app/test/speech_text_test.dart`** — speechText 순수 함수 테스트(Task 2).

기존 참조: `app/lib/signals/judge.dart`의 `enum Decision { walk, wait, unknown }`.

---

## Task 1: 의존성 추가 (flutter_tts, vibration)

**Files:**
- Modify: `app/pubspec.yaml`

**Interfaces:**
- Consumes: (없음)
- Produces: `package:flutter_tts/flutter_tts.dart`, `package:vibration/vibration.dart` 사용 가능.

- [ ] **Step 1: pubspec.yaml에 의존성 추가**

`app/pubspec.yaml`의 `dependencies:` 섹션에서 `http: ^1.2.0` 아래에 두 줄 추가한다. 해당 섹션이 다음과 같이 되게 한다:

```yaml
dependencies:
  flutter:
    sdk: flutter

  # The following adds the Cupertino Icons font to your application.
  # Use with the CupertinoIcons class for iOS style icons.
  cupertino_icons: ^1.0.8

  http: ^1.2.0
  flutter_tts: ^4.2.5
  vibration: ^3.2.0
```

- [ ] **Step 2: 의존성 설치**

Run: `cd /Users/daniellim/Desktop/Clip_Sense/app && flutter pub get`
Expected: "Got dependencies!" (flutter_tts, vibration 및 하위 의존성 해결). 오류 없이 완료.

- [ ] **Step 3: analyze로 프로젝트 무결성 확인**

Run: `cd /Users/daniellim/Desktop/Clip_Sense/app && flutter analyze`
Expected: "No issues found!" (새 의존성이 기존 코드를 깨지 않음).

- [ ] **Step 4: Commit**

```bash
cd /Users/daniellim/Desktop/Clip_Sense
git add app/pubspec.yaml app/pubspec.lock
git commit -m "chore(dart): add flutter_tts and vibration dependencies"
```

---

## Task 2: speechText 순수 함수 + SpeechOutput 인터페이스

원본 설계 §4.2. 문구 생성(순수 함수)과 인터페이스만. 실제 TTS 구현은 Task 3.

**Files:**
- Create: `app/lib/feedback/speech_output.dart`
- Test: `app/test/speech_text_test.dart`

**Interfaces:**
- Consumes: `app/lib/signals/judge.dart`의 `enum Decision { walk, wait, unknown }`
- Produces:
  - `abstract class SpeechOutput { Future<void> speak(String text); }`
  - `String speechText(Decision d, {double? remainSec})`

- [ ] **Step 1: Write the failing test**

Create `app/test/speech_text_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/signals/judge.dart';
import 'package:clip_sense/feedback/speech_output.dart';

void main() {
  test('walk 문구', () {
    expect(speechText(Decision.walk), '지금 건너셔도 됩니다');
  });

  test('walk + 잔여시간(반올림 정수 초)', () {
    expect(speechText(Decision.walk, remainSec: 15.0),
        '지금 건너셔도 됩니다, 15초 남았습니다');
  });

  test('walk 잔여시간 반올림', () {
    expect(speechText(Decision.walk, remainSec: 14.6),
        '지금 건너셔도 됩니다, 15초 남았습니다');
  });

  test('wait 문구', () {
    expect(speechText(Decision.wait), '기다리세요');
  });

  test('unknown 문구에 행동 지시(대기) 포함', () {
    final text = speechText(Decision.unknown);
    expect(text, '신호를 확인할 수 없습니다. 대기하세요');
    expect(text.contains('대기'), isTrue);
  });

  test('walk가 아니면 remainSec 무시', () {
    expect(speechText(Decision.wait, remainSec: 15.0), '기다리세요');
    expect(speechText(Decision.unknown, remainSec: 15.0),
        '신호를 확인할 수 없습니다. 대기하세요');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/daniellim/Desktop/Clip_Sense/app && flutter test test/speech_text_test.dart`
Expected: FAIL — `speech_output.dart` 없음 / `speechText` 미정의.

- [ ] **Step 3: Write minimal implementation**

Create `app/lib/feedback/speech_output.dart` (인터페이스 + 순수 함수만; FlutterTtsSpeech는 Task 3):

```dart
/// 판단 결과를 음성으로 안내하는 출력.
///
/// SpeechOutput은 인터페이스(테스트 시 Fake 주입). speechText는 Decision을
/// 안내 문구로 바꾸는 순수 함수라 하드웨어 없이 검증된다.
library;

import '../signals/judge.dart';

/// 음성 출력 인터페이스. 실제 구현은 FlutterTtsSpeech(Task 3).
abstract class SpeechOutput {
  Future<void> speak(String text);
}

/// Decision → 안내 문구(순수 함수).
///
/// walk에만 remainSec을 붙인다(전환 시 스냅샷 1회, 반올림 정수 초).
/// unknown은 상태 서술에 그치지 않고 행동 지시(대기)를 포함한다 — Fail-Safe.
String speechText(Decision d, {double? remainSec}) {
  switch (d) {
    case Decision.walk:
      if (remainSec != null) {
        return '지금 건너셔도 됩니다, ${remainSec.round()}초 남았습니다';
      }
      return '지금 건너셔도 됩니다';
    case Decision.wait:
      return '기다리세요';
    case Decision.unknown:
      return '신호를 확인할 수 없습니다. 대기하세요';
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/daniellim/Desktop/Clip_Sense/app && flutter test test/speech_text_test.dart`
Expected: PASS — All tests passed! (6 tests)

- [ ] **Step 5: Commit**

```bash
cd /Users/daniellim/Desktop/Clip_Sense
git add app/lib/feedback/speech_output.dart app/test/speech_text_test.dart
git commit -m "feat(dart): add speechText pure function and SpeechOutput interface"
```

---

## Task 3: FlutterTtsSpeech 실제 구현

원본 설계 §4.2. flutter_tts 감싸기. 하드웨어 의존이라 단위 테스트 없음(인터페이스 뒤 격리, 실기기 수동).

**Files:**
- Modify: `app/lib/feedback/speech_output.dart` (FlutterTtsSpeech 추가)

**Interfaces:**
- Consumes: `SpeechOutput`(Task 2), `package:flutter_tts`
- Produces: `class FlutterTtsSpeech implements SpeechOutput` — 생성자에서 ko-KR 설정, `speak`은 이전 안내를 끊고 재생.

- [ ] **Step 1: FlutterTtsSpeech 구현 추가**

`app/lib/feedback/speech_output.dart` 상단 import에 추가:

```dart
import 'package:flutter_tts/flutter_tts.dart';
```

파일 끝에 추가:

```dart
/// flutter_tts 기반 실제 음성 출력. 기기 내장 한국어 TTS(오프라인).
///
/// 하드웨어·OS 의존이라 단위 테스트하지 않는다(인터페이스 뒤 격리, 실기기 수동).
/// speak 실패(권한/미지원/플랫폼 예외)는 삼켜 앱을 죽이지 않는다(Fail-Safe).
class FlutterTtsSpeech implements SpeechOutput {
  final FlutterTts _tts;

  FlutterTtsSpeech([FlutterTts? tts]) : _tts = tts ?? FlutterTts() {
    // 한국어 로케일. 실패해도 무시(기기가 지원 안 하면 기본 로케일로 동작).
    _tts.setLanguage('ko-KR').catchError((_) {});
  }

  @override
  Future<void> speak(String text) async {
    // 새 안내가 오면 이전 것을 끊고 재생. 각 단계 실패는 삼킨다.
    try {
      await _tts.stop();
    } catch (_) {}
    await _tts.speak(text);
  }
}
```

주의: `speak`의 `_tts.speak(text)`는 try/catch로 감싸지 않는다 — 실패 시 Future가 에러로 완료되어야 FeedbackController(Task 5)의 개별 await+catch가 잡고 멀티채널 독립을 보장한다. `stop()` 실패만 국소적으로 삼킨다(이전 안내 중단은 부가 작업이라 실패해도 새 안내는 진행).

- [ ] **Step 2: analyze로 컴파일 확인**

Run: `cd /Users/daniellim/Desktop/Clip_Sense/app && flutter analyze`
Expected: "No issues found!" (flutter_tts API 사용이 올바름).

- [ ] **Step 3: 기존 speechText 테스트 회귀 확인**

Run: `cd /Users/daniellim/Desktop/Clip_Sense/app && flutter test test/speech_text_test.dart`
Expected: PASS — 6 tests(FlutterTtsSpeech 추가가 순수 함수·인터페이스를 안 깸).

- [ ] **Step 4: Commit**

```bash
cd /Users/daniellim/Desktop/Clip_Sense
git add app/lib/feedback/speech_output.dart
git commit -m "feat(dart): add FlutterTtsSpeech backend (ko-KR, interrupt-on-new)"
```

---

## Task 4: HapticOutput 인터페이스 + VibrationHaptic

원본 설계 §4.3. 진동 패턴. 하드웨어 의존이라 단위 테스트 없음(인터페이스 뒤 격리).

**Files:**
- Create: `app/lib/feedback/haptic_output.dart`

**Interfaces:**
- Consumes: `enum Decision`(judge.dart), `package:vibration`
- Produces:
  - `abstract class HapticOutput { Future<void> play(Decision d); }`
  - `class VibrationHaptic implements HapticOutput`

- [ ] **Step 1: HapticOutput 인터페이스 + VibrationHaptic 구현**

Create `app/lib/feedback/haptic_output.dart`:

```dart
/// 판단 결과를 상태별 진동 패턴으로 안내하는 출력.
///
/// HapticOutput은 인터페이스(테스트 시 Fake). VibrationHaptic은 하드웨어 의존이라
/// 단위 테스트하지 않는다(인터페이스 뒤 격리, 실기기 수동). 진동 실패(미지원/권한)는
/// 삼켜 앱을 죽이지 않는다(Fail-Safe).
library;

import 'package:vibration/vibration.dart';

import '../signals/judge.dart';

/// 진동 출력 인터페이스. 실제 구현은 VibrationHaptic.
abstract class HapticOutput {
  Future<void> play(Decision d);
}

/// Decision별 진동 패턴. vibration 패턴은 [wait, vibrate, wait, vibrate, ...]
/// (밀리초, 0부터 wait로 시작). 상태를 소리 없이 촉각으로 구분한다.
/// - walk: 짧게 두 번 (가도 됨)
/// - wait: 길게 한 번 (멈춤)
/// - unknown: 짧게 세 번 (주의)
const Map<Decision, List<int>> hapticPatterns = {
  Decision.walk: [0, 120, 100, 120],
  Decision.wait: [0, 600],
  Decision.unknown: [0, 80, 80, 80, 80, 80],
};

class VibrationHaptic implements HapticOutput {
  @override
  Future<void> play(Decision d) async {
    final pattern = hapticPatterns[d];
    if (pattern == null) return;
    // 진동 지원 안 하는 기기면 조용히 넘어감.
    // vibration 3.x의 hasVibrator()는 Future<bool>(non-nullable).
    final hasVibrator = await Vibration.hasVibrator();
    if (!hasVibrator) return;
    await Vibration.vibrate(pattern: pattern);
  }
}
```

주의: `Vibration.vibrate(pattern:)` 호출은 try/catch로 감싸지 않는다 — 실패 시 Future 에러가 FeedbackController(Task 5)의 개별 await+catch로 잡히게 한다. `hasVibrator` 가드로 미지원 기기는 사전 차단한다.

- [ ] **Step 2: analyze로 컴파일 확인**

Run: `cd /Users/daniellim/Desktop/Clip_Sense/app && flutter analyze`
Expected: "No issues found!" (vibration API 사용이 올바름).

- [ ] **Step 3: Commit**

```bash
cd /Users/daniellim/Desktop/Clip_Sense
git add app/lib/feedback/haptic_output.dart
git commit -m "feat(dart): add HapticOutput interface and VibrationHaptic patterns"
```

---

## Task 5: FeedbackController (전환 감지·조율) + 테스트

원본 설계 §4.1. 안전 핵심. onDecision은 Future<void>, 각 백엔드 개별 await+catch.

**Files:**
- Create: `app/lib/feedback/feedback_controller.dart`
- Test: `app/test/feedback_controller_test.dart`

**Interfaces:**
- Consumes: `SpeechOutput`(Task 2), `HapticOutput`(Task 4), `speechText`(Task 2), `enum Decision`(judge.dart)
- Produces:
  - `class FeedbackController` — 생성자 `FeedbackController(this._speech, this._haptic)`, `Future<void> onDecision(Decision d, {double? remainSec})`.

- [ ] **Step 1: Write the failing test**

Create `app/test/feedback_controller_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/signals/judge.dart';
import 'package:clip_sense/feedback/speech_output.dart';
import 'package:clip_sense/feedback/haptic_output.dart';
import 'package:clip_sense/feedback/feedback_controller.dart';

/// 호출을 기록하는 Fake 음성 출력. throwAsync=true면 speak가 async로 실패한다
/// (실기기 TTS 실패가 Future 에러 완료인 것을 흉내 — 동기 throw면 거짓 통과).
class FakeSpeech implements SpeechOutput {
  final List<String> spoken = [];
  bool throwAsync = false;
  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    if (throwAsync) throw Exception('tts failed');
  }
}

/// 호출을 기록하는 Fake 진동 출력.
class FakeHaptic implements HapticOutput {
  final List<Decision> played = [];
  @override
  Future<void> play(Decision d) async {
    played.add(d);
  }
}

void main() {
  test('첫 Decision은 안내됨 (speak·play 각 1회)', () async {
    final s = FakeSpeech();
    final h = FakeHaptic();
    final c = FeedbackController(s, h);
    await c.onDecision(Decision.wait);
    expect(s.spoken, ['기다리세요']);
    expect(h.played, [Decision.wait]);
  });

  test('같은 Decision 반복 시 무음', () async {
    final s = FakeSpeech();
    final h = FakeHaptic();
    final c = FeedbackController(s, h);
    await c.onDecision(Decision.wait);
    await c.onDecision(Decision.wait);
    await c.onDecision(Decision.wait);
    expect(s.spoken.length, 1);
    expect(h.played.length, 1);
  });

  test('전환 시 안내됨 (wait→walk)', () async {
    final s = FakeSpeech();
    final h = FakeHaptic();
    final c = FeedbackController(s, h);
    await c.onDecision(Decision.wait);
    await c.onDecision(Decision.walk);
    expect(s.spoken, ['기다리세요', '지금 건너셔도 됩니다']);
    expect(h.played, [Decision.wait, Decision.walk]);
  });

  test('walk 전환에 remainSec 주면 문구에 잔여시간 포함', () async {
    final s = FakeSpeech();
    final h = FakeHaptic();
    final c = FeedbackController(s, h);
    await c.onDecision(Decision.walk, remainSec: 12.0);
    expect(s.spoken, ['지금 건너셔도 됩니다, 12초 남았습니다']);
  });

  test('speech가 async로 실패해도 haptic은 호출됨 (멀티채널 독립)', () async {
    final s = FakeSpeech()..throwAsync = true;
    final h = FakeHaptic();
    final c = FeedbackController(s, h);
    // onDecision은 예외를 밖으로 던지지 않아야 한다(삼킴).
    await c.onDecision(Decision.walk);
    expect(s.spoken.length, 1); // speak는 시도됨(그리고 실패)
    expect(h.played, [Decision.walk]); // speech 실패에도 haptic 실행됨
  });

  test('unknown 전환 안내', () async {
    final s = FakeSpeech();
    final h = FakeHaptic();
    final c = FeedbackController(s, h);
    await c.onDecision(Decision.unknown);
    expect(s.spoken, ['신호를 확인할 수 없습니다. 대기하세요']);
    expect(h.played, [Decision.unknown]);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/daniellim/Desktop/Clip_Sense/app && flutter test test/feedback_controller_test.dart`
Expected: FAIL — `feedback_controller.dart` 없음 / `FeedbackController` 미정의.

- [ ] **Step 3: Write minimal implementation**

Create `app/lib/feedback/feedback_controller.dart`:

```dart
/// 판단 결과(Decision)를 음성·진동으로 조율하는 컨트롤러 (설계 §4.1).
///
/// 판단하지 않고, 출력 자체도 하지 않는다(백엔드에 위임). Decision이 이전과
/// 다를 때만(전환 시에만) 안내하고, 같은 상태 지속 중에는 조용하다.
library;

import '../signals/judge.dart';
import 'speech_output.dart';
import 'haptic_output.dart';

class FeedbackController {
  final SpeechOutput _speech;
  final HapticOutput _haptic;
  Decision? _last; // 직전에 안내한 Decision(초기 null → 첫 Decision은 항상 안내)

  FeedbackController(this._speech, this._haptic);

  /// Decision을 받아 전환 시에만 안내한다. Future<void>여야 각 백엔드의 async
  /// 실패를 개별 await+catch로 잡을 수 있다(void면 못 잡아 멀티채널 보장 깨짐).
  Future<void> onDecision(Decision d, {double? remainSec}) async {
    if (d == _last) return; // 같은 상태 지속 → 조용
    _last = d;

    // 두 백엔드를 각각 개별 await + try/catch. speech가 async로 실패해도
    // haptic await는 반드시 실행된다(멀티채널 독립, 설계 §5).
    try {
      await _speech.speak(speechText(d, remainSec: remainSec));
    } catch (_) {
      // 음성 실패는 삼킴 — 진동을 막지 않는다.
    }
    try {
      await _haptic.play(d);
    } catch (_) {
      // 진동 실패도 삼킴 — 앱을 죽이지 않는다.
    }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/daniellim/Desktop/Clip_Sense/app && flutter test test/feedback_controller_test.dart`
Expected: PASS — All tests passed! (6 tests). 특히 "speech async 실패해도 haptic 호출됨" 통과.

- [ ] **Step 5: 전체 테스트 + analyze 확인**

Run: `cd /Users/daniellim/Desktop/Clip_Sense/app && flutter test && flutter analyze`
Expected: 전체 스위트 통과(기존 62 + speech_text 6 + feedback_controller 6 = 74), "No issues found!".

- [ ] **Step 6: Commit**

```bash
cd /Users/daniellim/Desktop/Clip_Sense
git add app/lib/feedback/feedback_controller.dart app/test/feedback_controller_test.dart
git commit -m "feat(dart): add FeedbackController with transition detection

전환 시에만 안내. onDecision은 Future<void>로 각 백엔드 개별 await+catch —
speech가 async로 실패해도 haptic은 실행(멀티채널 독립). Fake는 async throw."
```

---

## Self-Review

**1. Spec coverage (설계 대비):**
- §2 아키텍처(FeedbackController + SpeechOutput/HapticOutput) → Task 2/4/5 ✅
- §4.1 FeedbackController(전환 감지, Future<void>, 개별 await+catch, enum 비교) → Task 5 ✅
- §4.2 speechText 순수함수 + 문구(walk/wait/unknown, unknown에 대기, remainSec 반올림) + FlutterTtsSpeech(ko-KR, interrupt) → Task 2/3 ✅
- §4.3 HapticOutput + VibrationHaptic(walk/wait/unknown 패턴) → Task 4 ✅
- §5 Fail-Safe(실패 삼킴, 멀티채널 독립) → Task 3/4/5 ✅
- §6 테스트(Fake 주입, 6검증, async throw로 거짓통과 방지) → Task 2/5 테스트 ✅
- §1 결정 5(잔여시간 스냅샷 1회) → Task 2 문구(전환 시 1회, 카운트다운 로직 없음) ✅
- §7 의존성(flutter_tts, vibration) → Task 1 ✅
- 범위 밖(UI/judge 루프/GPS/카메라/백그라운드) → 계획에 없음 ✅

**2. Placeholder scan:** "TBD/TODO/적절히" 없음. 모든 코드 스텝에 완전한 Dart 코드. 진동 패턴 밀리초는 상수(hapticPatterns)로 구체값 명시. FlutterTtsSpeech/VibrationHaptic은 하드웨어 의존이라 단위 테스트 없음을 명시(analyze로만 컴파일 검증) — 이는 플레이스홀더가 아니라 설계 §6의 명시적 결정. ✅

**3. Type consistency:**
- `SpeechOutput.speak(String) -> Future<void>` — Task 2 정의 = Task 3 구현 = Task 5 사용 일치 ✅
- `HapticOutput.play(Decision) -> Future<void>` — Task 4 정의 = Task 5 사용 일치 ✅
- `speechText(Decision, {double? remainSec}) -> String` — Task 2 정의 = Task 5 호출 일치 ✅
- `FeedbackController(SpeechOutput, HapticOutput)`, `onDecision(Decision, {double? remainSec}) -> Future<void>` — Task 5 정의 = test 일치 ✅
- `enum Decision { walk, wait, unknown }` — 기존 judge.dart, 전 태스크 동일 참조 ✅
- import 경로 `package:clip_sense/feedback/*.dart`, `package:clip_sense/signals/judge.dart` — 일관 ✅

이상 없음.
