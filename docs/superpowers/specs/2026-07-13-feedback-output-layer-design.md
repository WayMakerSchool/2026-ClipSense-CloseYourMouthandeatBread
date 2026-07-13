# 설계: Flutter 앱 출력 계층 (음성 + 햅틱)

**작성일:** 2026-07-13
**대상:** Clip sense 실제 제품의 Flutter 앱, 출력 계층 조각.
**범위:** 이번 설계는 judge의 판단 결과(`Decision`)를 사용자에게 **음성(TTS)과
햅틱(진동)으로 전달**하는 출력 계층까지다. UI 화면, judge를 돌리는 루프,
GPS, 카메라, 백그라운드 동작은 이 문서의 범위가 아니다(후속 조각).

---

## 1. 배경과 결정

Dart 데이터 계층(app/lib/signals/)이 완성돼 `judge.decide(...)`가 `Decision`
(walk/wait/unknown)을 낸다. 그러나 그 결정을 사용자에게 전달하는 수단이 없다.
시각장애인 사용자에게는 화면이 아니라 **음성과 진동**이 유일한 출력 채널이다.

**결정 1 — 음성은 기기 내장 TTS(flutter_tts).** 기존 Python 데모는 사전 생성 wav를
재생했지만, Flutter에서는 OS 내장 한국어 TTS를 쓴다. 오프라인 동작(음영지역 OK)을
유지하면서도 "15초 남았습니다" 같은 동적 잔여시간 안내가 가능하다. 시각장애인용
안내의 표준 방식이다.

**결정 2 — 햅틱은 상태별 진동 패턴.** 단순 전환 알림이 아니라 walk/wait/unknown마다
다른 진동 패턴을 낸다. 시끄러운 도로에서 음성을 못 들어도 진동만으로 상태를 구분할
수 있다(브리프의 멀티채널 피드백).

**결정 3 — 안내는 상태 전환 시에만.** judge는 초당 여러 번 Decision을 낸다. 매번
안내하면 "대기... 대기..."가 반복된다. Decision이 **바뀔 때만** 음성·햅틱을 내고,
같은 상태 지속 중에는 조용히 한다(Python voice.py의 전환 감지 철학과 동일).

**결정 5 — 잔여시간은 전환 시점 스냅샷 1회, 카운트다운 없음(이번 조각).** 결정 1의
"동적 잔여시간"과 결정 3의 "전환 시에만"이 walk에서 만나는 지점을 명확히 한다:
walk로 바뀌는 순간 "…N초 남았습니다"를 **한 번** 말하고, 그 뒤 같은 walk가 지속되는
동안은 조용하다. remainSec은 전환 시점의 스냅샷일 뿐이며, "10초… 5초…" 같은 주기적
카운트다운 재안내는 이번 조각의 범위가 아니다. (주기 재안내가 필요하면 후속 조각에서
FeedbackController에 타이머를 더하되, 그건 judge 루프·타이밍 정책과 얽히므로 별도로
설계한다.)

**결정 4 — 백엔드를 인터페이스 뒤로 격리.** 실제 TTS·진동은 폰 하드웨어·OS에
의존해 단위 테스트로 목킹할 수 없다. SpeechOutput/HapticOutput을 abstract로 두고
FeedbackController가 그 인터페이스에만 의존하게 해서, 전환 감지 로직을 Fake 백엔드로
네트워크·오디오 없이 테스트한다. 실기기 확인은 수동(다음 앱 통합 조각).

---

## 2. 아키텍처

```
judge.decide() → Decision ─▶ FeedbackController.onDecision(d, remainSec)
                                   │ (이전 Decision과 다를 때만)
                                   ├─▶ SpeechOutput.speak(문구)
                                   └─▶ HapticOutput.play(d)
```

각 유닛은 하나의 책임만 진다:
- **FeedbackController** — "언제 낼지"(전환 감지). 판단하지 않고, 출력하지도 않고,
  두 백엔드를 조율만 한다.
- **SpeechOutput / HapticOutput** — "어떻게 낼지"(음성/진동). 언제 낼지는 모른다.

이 경계 덕분에 FeedbackController는 순수 로직으로 테스트되고, 백엔드는 독립적으로
교체·확장된다.

---

## 3. 파일 구조 (`app/lib/feedback/`)

- **`feedback_controller.dart`** — 전환 감지 + 조율. `FeedbackController`.
- **`speech_output.dart`** — `abstract class SpeechOutput` + `FlutterTtsSpeech`(실제),
  안내 문구 매핑.
- **`haptic_output.dart`** — `abstract class HapticOutput` + `VibrationHaptic`(실제),
  진동 패턴 매핑.

테스트: `app/test/feedback_controller_test.dart`(Fake 백엔드 주입).

---

## 4. 모듈별 상세

### 4.1 `feedback_controller.dart`
- `class FeedbackController`:
  - 생성자 `FeedbackController(this._speech, this._haptic)` — SpeechOutput·HapticOutput 주입.
  - 필드 `Decision? _last` — 직전에 안내한 Decision(초기 null).
  - `Future<void> onDecision(Decision d, {double? remainSec})` — **반드시 `Future<void>`
    (void 아님).** 백엔드는 Future를 반환하는 async 작업이므로, void에서 await 없이
    호출하면 비동기 실패를 동기 try/catch가 못 잡아 멀티채널 보장이 깨지고
    unhandled exception이 된다.
    - `Decision`은 enum(`enum Decision { walk, wait, unknown }`)이라 `d == _last`는
      카테고리 비교다. remainSec은 별도 인자라 값이 달라도 전환으로 오인되지 않는다.
    - `d == _last`이면 아무것도 안 함(같은 상태 지속 → 조용).
    - 다르면 `_last = d` 갱신 후, 두 백엔드를 **각각 개별 await + try/catch**로 호출:
      ```dart
      try { await _speech.speak(speechText(d, remainSec: remainSec)); }
      catch (_) { /* 삼킴 — 음성 실패가 진동을 막지 않음 */ }
      try { await _haptic.play(d); }
      catch (_) { /* 삼킴 */ }
      ```
      speech가 async로 실패해도 haptic await는 반드시 실행된다(멀티채널 독립, §5).
    - 첫 호출(`_last == null`)은 항상 안내.
  - **판단하지 않음. 출력 자체를 하지 않음(백엔드에 위임). 조율만.**

### 4.2 `speech_output.dart`
- `abstract class SpeechOutput { Future<void> speak(String text); }`
- `String speechText(Decision d, {double? remainSec})` — Decision → 문구:
  | Decision | 문구 |
  |---|---|
  | walk | "지금 건너셔도 됩니다" (remainSec 있으면 ", N초 남았습니다" 덧붙임) |
  | wait | "기다리세요" |
  | unknown | "신호를 확인할 수 없습니다. 대기하세요" |
  (문구 생성은 순수 함수라 컨트롤러 테스트에서 검증. remainSec는 반올림한 정수 초.)
  unknown 문구는 상태 서술에 그치지 않고 **행동 지시(대기)**를 포함한다 — Fail-Safe
  원칙상 불확실하면 무조건 대기여야 하는데, 사용자에게 대기하라고 말하지 않으면
  위험하다. wait와 unknown 둘 다 "행동=대기"로 안전하게 수렴한다.
- `class FlutterTtsSpeech implements SpeechOutput`:
  - flutter_tts 인스턴스. 한국어 로케일 `ko-KR` 설정.
  - `speak(text)`: 새 안내가 오면 이전 것을 끊고(`stop()`) 재생(`speak()`).
  - TTS 실패(권한/미지원)는 try/catch로 삼킴 — 앱을 죽이지 않음.

### 4.3 `haptic_output.dart`
- `abstract class HapticOutput { Future<void> play(Decision d); }`
- `class VibrationHaptic implements HapticOutput`:
  - Decision별 진동 패턴:
    | Decision | 패턴 (의미) |
    |---|---|
    | walk | 짧게 두 번 ●● (가도 됨) |
    | wait | 길게 한 번 ▬ (멈춤) |
    | unknown | 짧게 세 번 ●·●·● (주의) |
  - `vibration` 패키지의 패턴 진동 사용. 진동 미지원 기기·실패는 try/catch로 삼킴.

---

## 5. 에러 처리 (Fail-Safe, 데이터 계층과 동일 철학)

- TTS·진동 실패(권한 없음, 미지원 기기, 플랫폼 예외)는 예외를 삼켜 앱을 죽이지 않는다.
- 음성과 햅틱은 서로 독립 — 하나가 실패해도 다른 하나는 시도한다(멀티채널 백업).
- 출력 실패가 판단(judge)이나 컨트롤러 상태를 오염시키지 않는다.

---

## 6. 테스트 전략

- **`feedback_controller_test.dart`** — Fake SpeechOutput/HapticOutput(호출 기록만)
  주입. 컨트롤러 `onDecision`이 `Future<void>`이므로 테스트도 `await onDecision(...)`.
  검증:
  1. 첫 Decision은 안내됨(speak·play 각 1회).
  2. 같은 Decision 반복 시 무음(추가 호출 0회).
  3. 전환(wait→walk 등) 시 안내됨.
  4. walk에 remainSec 주면 문구에 "N초 남았습니다" 포함.
  5. 각 Decision이 올바른 문구를 만든다(speechText 순수 함수 검증. unknown 문구에
     "대기" 포함).
  6. speech가 **async로 실패**(Fake의 speak가 `Future.error`/async throw)해도 haptic은
     호출된다(멀티채널 독립). **Fake는 반드시 async로 throw** — 실기기 TTS/진동 실패는
     Future 에러 완료 형태이므로, Fake가 동기로 throw하면 테스트가 거짓 통과한다.
- **실제 FlutterTtsSpeech/VibrationHaptic은 단위 테스트하지 않음** — 폰 하드웨어·OS
  의존이라 목킹 불가. 인터페이스 뒤로 격리하고 실기기 확인은 수동(후속 앱 통합 조각).
- 실행: `cd app && flutter test test/feedback_controller_test.dart`. analyze 클린 유지.

---

## 7. 의존성

pubspec.yaml에 추가:
- `flutter_tts` — 기기 내장 TTS
- `vibration` — 패턴 진동

---

## 8. 오픈 이슈 (구현 시 확인)

1. **flutter_tts/vibration 최신 안정 버전** — 구현 시 pub.dev에서 확인해 고정.
2. **진동 패턴의 정확한 밀리초 값** — 구현 시 실기기 체감으로 조정 가능하게 상수화.

(잔여시간 스냅샷 vs 카운트다운, unknown 행동 지시, onDecision async 처리는 각각
§1 결정 5, §4.2 문구표, §4.1에서 확정됨 — 더 이상 오픈 이슈 아님.)

---

## 9. 이번 설계에 포함하지 않는 것 (후속 조각)

- UI 화면(고대비 접근성)
- judge를 주기적으로 돌리는 루프(앱 통합/백그라운드)
- GPS/교차로·방위 선택
- 실제 카메라 검출기(Dart)
- 백그라운드 동작

각각 별도 설계·계획 사이클로 진행한다.
