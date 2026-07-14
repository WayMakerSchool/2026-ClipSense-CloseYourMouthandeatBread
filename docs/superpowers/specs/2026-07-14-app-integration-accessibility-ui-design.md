# 앱 통합 + 접근성 UI 설계

**작성일:** 2026-07-14
**상태:** 사용자 승인 완료 (설계 방향)

## 1. 목적

완성된 엔진(실API → 판단 → 음성/햅틱)을 **실제로 켜고 끌 수 있는 앱**으로 잇는다.
`main.dart`는 아직 Flutter 기본 카운터 템플릿이라 엔진이 화면에 연결돼 있지 않다.
이 조각은 그 "몸통"을 만든다:

1. 엔진을 1초마다 돌려 `FeedbackController`에 먹이는 루프/앱 골격
2. 시각장애인 접근성 UI — 스크린리더(TalkBack/VoiceOver) 호환, 큰 고대비 화면,
   시작/정지 조작, 음성 라벨

## 2. 이미 완성된 것 (이 조각의 전제)

실API(서울 T-Data)로 실측 검증 완료(2026-07-14):

- `lib/signals/` — `fetchReading()`(실API 호출), `parseReading()`(색·잔여시간 파싱),
  `decide()`(판단 + 안전정책), `visionStub()`(항상 unknown)
- `lib/feedback/` — `FeedbackController.onDecision()`(전환 감지 → 음성/햅틱),
  `speechText()`, `hapticPatterns`, `FlutterTtsSpeech`, `VibrationHaptic`
- 안전정책 실증: 초록이어도 `needSec`(7초) 미만이면 wait, 오류/stale → unknown

## 3. 범위

**포함:**
- 앱 진입점 교체(카운터 템플릿 제거)
- 1초 주기 엔진 루프 컨트롤러
- 고정 교차로 1개(itstId·방향) 설정
- 화면 전체가 큰 버튼 하나 = 시작/정지 토글
- 상태별 접근성 화면(A안: 색 꽉 채움 + 초대형 글자 + 아이콘) + 스크린리더 라벨

**범위 밖 (별도 조각, 나중):**
- GPS 자동 교차로 선택
- 실제 카메라 검출기(지금은 stub)
- 백그라운드 동작
- 실기기 음성/햅틱 수동 검증(기기 필요)

## 4. 아키텍처

### 4.1 파일 구조 (책임 분리)

| 파일 | 책임 | 의존 |
|---|---|---|
| `lib/main.dart` | 앱 진입점. `GuidanceScreen` 하나만 띄움 | guidance_screen |
| `lib/app/config.dart` | 고정 설정(itstId, 방향, needSec, 루프주기, apiKey 주입) | 없음 |
| `lib/app/guidance_controller.dart` | 엔진 루프 + 시작/정지 상태. 화면이 구독 | signals, feedback, config |
| `lib/app/guidance_screen.dart` | 접근성 UI(큰 버튼 토글, 상태 표시, Semantics) | guidance_controller |

원칙: 컨트롤러(로직·타이머)와 화면(위젯)을 분리해 각각 독립적으로 이해·테스트 가능하게.
컨트롤러는 Flutter 위젯에 의존하지 않고 `ChangeNotifier`만 상속(테스트에서 타이머·엔진 주입 가능).

### 4.2 GuidanceController

`ChangeNotifier`를 상속. 화면이 `notifyListeners()`로 갱신을 받는다.

**상태:**
- `bool running` — 안내 중인지
- `Decision decision` — 현재 판단(초기 unknown)
- `double? remainSec` — 현재 잔여시간(walk일 때만 의미)

**동작:**
- `start()` — 1초 타이머 시작. 매 틱마다 `_tick()`.
- `stop()` — 타이머 취소. `running=false`. 화면 "정지됨".
- `toggle()` — running이면 stop, 아니면 start.
- `_tick()` (매 1초):
  1. `fetchReading(itstId, direction, apiKey, nowMs: now)` → api 판정
  2. `visionStub()` → vision 판정(항상 unknown)
  3. `decide(api, vision, needSec: 7, allowSingleSource: true)` → Decision
     (⚠️ 아래 §6 안전 조건 — allowSingleSource는 임시)
  4. walk면 잔여시간 계산(api.remainSec)
  5. `feedbackController.onDecision(d, remainSec: ...)` — 음성/햅틱(전환 시에만)
  6. 상태 갱신 후 `notifyListeners()`

**주입:** 테스트를 위해 `fetchReading` 함수, `FeedbackController`, 타이머 팩토리를
생성자로 주입 가능하게 한다(실제 네트워크·하드웨어 없이 로직 검증).

### 4.3 GuidanceScreen

**화면 전체가 하나의 큰 버튼.** `GestureDetector`(또는 전체를 덮는 버튼)로
어디를 눌러도 `controller.toggle()`.

**표시(A안):**
- 정지 중: 안내 문구 "화면을 눌러 안내를 시작하세요" + 중립 색
- running 중, 상태별 전체화면:
  - walk: 초록(#0a8f3c) 배경 + 🚶 + "건너세요" + "N초"
  - wait: 빨강(#c31414) 배경 + ✋ + "기다리세요"
  - unknown: 회색(#5a5a5a) 배경 + ❓ + "확인 불가" + "대기하세요"

**접근성:**
- 전체 버튼에 `Semantics(button: true, label: ...)` — 현재 상태 + 조작 안내를
  스크린리더가 읽음(예: "건너세요, 15초 남음. 두 번 탭하면 안내를 정지합니다").
- 상태 텍스트는 `Semantics(liveRegion: true)`로 상태 전환 시 스크린리더가 자동 낭독.
- 색에만 의존하지 않음 — 글자·아이콘 병행(색약 대비).
- 초대형 글자, 고대비.

주: 전맹 사용자에겐 엔진의 음성/햅틱이 이미 전달된다. 이 화면의 시각 표시는
곁의 저시력·잔존시력 사용자와 도우미를 위한 것이고, 스크린리더 라벨은 전맹
사용자의 화면 조작(시작/정지 확인)을 위한 것이다.

### 4.4 config.dart

```
// 프로토타입 기본값: 실측(2026-07-14)에서 존재·동작 확인된 교차로.
// 실기기 사용 시 사용자의 실제 위치 교차로로 교체해야 함(GPS 자동선택은 다음 조각).
const String kItstId = '1620';                // 실측에서 st 방향 보행 초록 확인됨
const String kDirection = 'st';               // nt/et/st/wt/ne/se/sw/nw 중 하나
const double kNeedSec = 7.0;
const Duration kLoopInterval = Duration(seconds: 1);
// apiKey는 하드코딩 금지 — String.fromEnvironment('TDATA_KEY')로 --dart-define 주입.
const String kApiKey = String.fromEnvironment('TDATA_KEY');
```

## 5. 데이터 흐름

```
[화면 탭] → controller.toggle()
   running=true → 1초 타이머
      매 1초 _tick():
        fetchReading(고정 itstId·방향) ─┐
        visionStub() (unknown) ─────────┤→ decide(allowSingleSource) → Decision
                                          ↓
             feedbackController.onDecision → 음성/햅틱(전환 시)
                                          ↓
             상태 갱신 → notifyListeners → 화면 재그림(색·글자·아이콘·Semantics)
[화면 탭] → controller.toggle() → stop → 타이머 취소 → "정지됨" 화면
```

## 6. 안전 조건 (⚠️ 반드시 지킬 것)

- **`allowSingleSource=true`는 카메라 검출기 stub 동안의 임시 모드.**
  카메라가 항상 unknown이라 엄격 AND면 앱이 영원히 "기다리세요"만 말한다.
  임시로 API 단독 판단을 허용해 통합을 검증한다.
  **카메라 검출기 조각이 완성되면 반드시 엄격 AND(allowSingleSource=false)로 복귀.**
  이 사실을 코드 주석과 config에 눈에 띄게 남긴다.
- **Fail-Safe 유지:** 오류/stale/미지 → unknown → "확인 불가, 대기하세요".
  API가 애매하면 절대 "건너세요"를 말하지 않는다.
- **apiKey 하드코딩 금지.** `--dart-define=TDATA_KEY=...`로만 주입. 개발용 키는
  배포 전 재발급([[tdata-api-live-verified]]).

## 7. 에러 처리

- `fetchReading`은 이미 모든 네트워크/HTTP/JSON 오류를 삼켜 unknown 반환.
  컨트롤러 `_tick`은 추가로 예외를 감싸 타이머가 죽지 않게 한다(1초 뒤 재시도).
- 음성/햅틱 실패는 `FeedbackController`가 이미 개별 삼킴(멀티채널 독립).
- 앱은 어떤 경우에도 크래시하지 않고, 불확실하면 대기 안내로 수렴.

## 8. 테스트 전략

- `GuidanceController` 단위 테스트: `fetchReading`·`FeedbackController`·타이머를 Fake로
  주입. 검증: start→틱마다 decide 호출, toggle 동작, 각 Decision에서 상태·잔여시간
  갱신, `_tick` 예외 시 타이머 유지, allowSingleSource 전달 확인.
- `GuidanceScreen` 위젯 테스트: 상태별 표시(색·글자·아이콘), 탭 시 toggle 호출,
  Semantics 라벨 존재(walk/wait/unknown 각각), liveRegion 갱신.
- 실기기 검증(음성 발음, 진동 체감, 스크린리더 실제 낭독)은 기기 필요 — 범위 밖,
  체크리스트로 문서화.

## 9. 미해결/후속

- 프로토타입 기본 교차로는 itstId '1620'·st(실측 확인). 실사용 시 사용자 실제 위치
  교차로로 교체 필요 — 근본 해결은 GPS 자동선택(다음 조각).
- 실기기 스크린리더(TalkBack/VoiceOver) 실제 낭독 순서·타이밍 검증.
- 음성(엔진)과 스크린리더 라벨이 동시에 울릴 때 중복/충돌 여부 — 실기기 확인 후 조정.
