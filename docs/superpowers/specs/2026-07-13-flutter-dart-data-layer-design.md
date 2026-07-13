# 설계: Flutter 앱 골격 (1) — Dart 데이터 계층 포팅

**작성일:** 2026-07-13
**대상:** Clip sense 실제 제품의 Flutter 네이티브 앱, 첫 조각.
**범위:** 이번 설계는 **Python 데이터 계층(signals/signal_api/vision_adapter/judge)을
Dart로 이식**하고 Flutter 프로젝트를 생성하는 것까지다. UI·TTS/햅틱·백그라운드
동작·실제 카메라 검출기·GPS는 이 문서의 범위가 아니다(후속 조각).

---

## 1. 배경과 결정

Clip sense의 데이터 계층은 이미 Python으로 완성·검증됐다(2026-07-13, main 병합).
그러나 Flutter 앱은 Dart로 동작하고 Python은 폰에서 네이티브로 실행되지 않는다.

**결정 1 — Dart로 포팅 (온디바이스 독립).** Python을 서버에 두는 대신 Dart로 이식해
폰에서 완전 독립 동작하게 한다. 시각장애인 보행 안전은 음영지역(인터넷 없는 곳)에서도
동작해야 하므로, 서버 상시 의존은 부적합하다. 포팅 대상은 총 246줄(signals 31 +
signal_api 122 + vision_adapter 22 + judge 71)로 작고, Python 테스트가 사양서 역할을
하므로 이식 방향이 명확하다.

**결정 2 — 첫 조각 = 데이터 계층.** UI·음성·햅틱·백그라운드는 판단 결과가 있어야
얹힌다. 데이터 계층이 토대이므로 먼저 이식한다.

**결정 3 — 동등성은 Python 테스트 미러링으로 보장.** 기존 Python 테스트의 같은 입력을
Dart 테스트로 똑같이 작성한다. 같은 입력→같은 출력이면 안전 로직이 이식 과정에서
바뀌지 않았음을 보장한다.

**결정 4 — vision은 순수 번역 함수만 포팅 + UNKNOWN 스텁.** vision_adapter의 순수
번역(상태문자열→SignalReading)은 이식하되, 그것을 먹여줄 실제 카메라 검출기(Python
detector.py의 OpenCV HSV)는 이번 범위 밖이다. 대신 항상 UNKNOWN을 반환하는 스텁
소스를 두어, judge가 "카메라 신호 없음" 상황(단일소스 경로)을 제대로 다루는지 검증한다.

---

## 2. 프로젝트 구조

Flutter 프로젝트를 기존 저장소 안 `app/` 서브디렉터리에 둔다. Python 원본과 Dart
이식본을 한 저장소에서 대조할 수 있다.

```
Clip_Sense/
├── signal_api.py, judge.py, ...     (기존 Python — 원본, 유지)
├── app/                             (신규 Flutter 프로젝트)
│   ├── pubspec.yaml
│   ├── lib/signals/
│   │   ├── signal_reading.dart      (공유 타입)
│   │   ├── signal_api.dart          (서울 T-Data 파싱 + HTTP)
│   │   ├── vision_adapter.dart      (상태→SignalReading + 스텁)
│   │   └── judge.dart               (AND 판단 엔진)
│   └── test/
│       ├── signal_reading_test.dart
│       ├── signal_api_test.dart
│       ├── vision_adapter_test.dart
│       └── judge_test.dart
```

`.gitignore`에 Flutter 빌드 산출물 추가: `app/build/`, `app/.dart_tool/`,
`app/.flutter-plugins*`. `pubspec.lock` 커밋 여부는 오픈이슈(§8-1)에서 확정한다.
플랫폼 생성물(ios/android)은 데이터 계층 조각엔 불필요하나 다음 조각(UI)에서 쓰이므로,
`flutter create` 범위는 오픈이슈(§8-2)에서 판단한다.

**의존성 (pubspec.yaml):**
- `http` — 서울 T-Data 호출
- `test` (dev) — 단위 테스트
- 그 외 없음. 데이터 계층은 순수 로직이라 TTS·햅틱·상태관리 패키지는 다음 조각에서.

---

## 3. Python → Dart 언어 매핑

| Python | Dart | 근거 |
|---|---|---|
| 색 상수 `GREEN="GREEN"` (str) | `enum SignalColor { green, red, clearance, unknown }` | Dart enum이 관용·타입안전. Python 최종 리뷰 Minor "str이라 오타 무검증"을 언어 차원에서 차단 |
| 출처 `SRC_API="API"` | `enum SignalSource { api, vision }` | 동일 |
| `SignalReading` dataclass | `class SignalReading` (immutable, `final` 필드) | Dart 관용 |
| `is_go()` | `bool get isGo => color == SignalColor.green` | getter |
| `parse_reading(...)` 함수 | 최상위 함수 (순수) | 순수 함수는 그대로 |
| `fetch_reading(..., opener=None)` | `fetchReading(..., {http.Client? client})` | http.Client 주입으로 테스트 시 mock |
| `except Exception` (Fail-Safe) | `try/catch` → `SignalReading(unknown)` | 동일 의미 |
| `str(rec.get("itstId")) == str(itst_id)` | `rec['itstId']?.toString() == itstId.toString()` | JSON에서 int/String 무관 비교 |

`raw` 필드(API 원문, 예 `"protected-Movement-Allowed"`)는 디버깅용이라 `String?`로
유지한다(enum 아님).

---

## 4. 데이터 흐름

```
서울 T-Data ─http─▶ fetchReading() ─▶ SignalReading(source: api)  ┐
                                                                    ├─▶ decide() ─▶ Decision
visionStub() (항상 unknown) ────────▶ SignalReading(source: vision)┘   (walk|wait|unknown)
```

Python과 동일하다(이식이므로). 각 모듈은 하나의 책임만 지고 SignalReading으로만 대화한다.

---

## 5. 모듈별 상세

### 5.1 `signal_reading.dart`
- `enum SignalColor { green, red, clearance, unknown }`
- `enum SignalSource { api, vision }`
- `class SignalReading`: `final SignalColor color; final double? remainSec;
  final SignalSource source; final int freshMs; final String? raw;`
  immutable(const 생성자), `bool get isGo => color == SignalColor.green`.

### 5.2 `signal_api.dart` (Python signal_api.py 전체 이식 — 안전 수정 포함)
- `statusMap` — API enum 문자열 → SignalColor (화이트리스트, 아는 5개만):
  `protected-Movement-Allowed`/`permissive-Movement-Allowed`→green,
  `protected-clearance`/`permissive-clearance`→clearance, `stop-And-Remain`→red.
- `parseReading(List records, String direction, int nowMs,
  {int staleMs = 2000, String? itstId})`:
  - itstId 주어지면 매칭 레코드 선택(`toString()` 비교), 없으면 unknown. itstId=null이면
    records[0](하위호환).
  - 미지 상태값/None/빈배열 → unknown(추측 금지).
  - 신선도: trsmUtcTime None/파싱불가 → unknown. `freshMs > staleMs`(stale) → unknown.
    **미래시각 `freshMs < -staleMs` → unknown**(시계오차 정직성).
  - 잔여(`{direction}PdsgRmdrCs`): 1/10초 → 초(예 241→24.1). 파싱 불가면 null.
  - raw 원문 보존.
- `fetchReading(String itstId, String direction, String apiKey,
  {required int nowMs, http.Client? client, Duration timeout, String baseUrl})`:
  - 요청 파라미터 `apiKey`, `type=json`, `itstId`, `numOfRows=10`.
  - 응답이 List 아니면 unknown. parseReading에 itstId 넘김.
  - 네트워크/HTTP/JSON/기타 예외 전부 catch → `SignalReading(unknown, source: api)`.
  - **apiKey 하드코딩 금지** — 호출자가 주입.

### 5.3 `vision_adapter.dart`
- `SignalReading toReading(String state, {double? remainSec, int freshMs = 0})`:
  기존 detector 상태(`RED`/`GREEN`/`GREEN_BLINK`/`UNKNOWN`)→SignalReading(source: vision).
  GREEN_BLINK→clearance. 미지 상태→unknown.
- `SignalReading visionStub()`: 항상 `SignalReading(color: unknown, source: vision,
  remainSec: null, freshMs: 0)`. 실제 카메라 검출기 자리의 스텁.

### 5.4 `judge.dart` (Python judge.py 전체 이식 — 안전 정책 포함)
- `enum Decision { walk, wait, unknown }`
- `Decision decide(SignalReading? api, SignalReading? vision,
  {double needSec = 7.0, int staleMs = 2000, bool allowSingleSource = false})`:
  - **엄격 AND 기본값 `false`**(사용자 확정): 카메라 UNKNOWN/stale이면 API 초록이어도 wait.
  - `_usable(r)`: 존재 + color != unknown + freshMs <= staleMs.
  - 둘 다 가용: 둘 다 green + 잔여충분(min remain >= needSec) → walk, 아니면 wait.
  - 둘 다 못 씀 → unknown. 단일 소스: allowSingleSource면 green+충분 시 walk, 아니면 wait.
  - 잔여 정보 전부 없으면 wait(보수적).

---

## 6. 에러 처리 (Python과 동일한 Fail-Safe)

- 불확실하면 항상 안전한 쪽: wait 또는 unknown.
- HTTP/JSON/파싱 오류 → try/catch로 잡아 unknown 반환, 앱을 죽이지 않음.
- 모르는 상태값·stale·미래시각·None → unknown(GREEN 추측 절대 금지).

---

## 7. 테스트 전략 (동등성 — Python 미러링)

각 Python 테스트의 케이스를 그대로 Dart로 옮긴다. Dart `test` 패키지, `flutter test` 실행.

- `signal_reading_test.dart` ← test_signals.py: 필드 보존, isGo(green만 true), 4색 구분.
- `signal_api_test.dart` ← test_signal_api.py(27 assertion): 색 매핑, 1/10초 변환,
  None/미지/stale→unknown, 빈배열, 문자열 잔여, **itstId 매칭 3종, 미래시각 2종,
  stale 경계 2종, non-list 1종**, fetch 오류경로(client 주입: 네트워크오류/JSON실패/정상).
- `vision_adapter_test.dart` ← test_vision_adapter.py: 4상태 매핑(GREEN_BLINK→clearance),
  미지→unknown, 잔여·신선도 보존, source=vision, **visionStub은 항상 unknown**.
- `judge_test.dart` ← test_judge.py(20 케이스): 둘다초록→walk, 불일치 4종→wait,
  둘다빨강→wait, 잔여부족→wait, 잔여없음→wait, 한쪽stale→wait, 둘다unknown→unknown,
  단일소스 허용·비허용, **기본 엄격(카메라unknown이면 API초록도 wait) 안전 케이스**.

**핵심 성공 기준:** 같은 입력에 Python과 Dart가 같은 색/결정을 낸다. 특히 judge 안전
속성(둘 다 초록일 때만 walk, 불일치→wait)과 signal_api 정직성(모르면 unknown, itstId
매칭, 미래시각 거부)이 Dart에서도 동일해야 한다.

---

## 8. 오픈 이슈

1. **pubspec.lock 커밋 여부** — 앱이므로 커밋이 정석이나, 프로토타입 단계라 잠정 제외 가능.
   구현 시 확정.
2. **flutter create 범위** — 데이터 계층만이면 플랫폼 폴더(ios/android)가 불필요하지만,
   다음 조각(UI)에서 필요하다. 지금 전체 생성 후 빌드물만 무시하는 게 나을지 구현 시 판단.
3. **API 키 주입 방식** — 다음 조각(앱 통합)에서 확정. 이번엔 fetchReading 인자로만 받음.

---

## 9. 이번 설계에 포함하지 않는 것 (후속 조각)

- Flutter UI 화면(고대비 접근성 UI)
- 상태관리(판단 결과 → 화면/출력 연결)
- TTS 음성 안내, 상황별 햅틱
- 백그라운드 동작(앱 꺼져도 감시)
- 실제 카메라 검출기(OpenCV HSV의 Dart 이식 — 별도 큰 작업)
- GPS/교차로·방위 선택

각각 별도 설계·계획 사이클로 진행한다.
