# 카메라 검출기 — 알고리즘 이식 설계

**작성일:** 2026-07-14
**상태:** 사용자 승인 완료 (설계 방향)

## 1. 목적

Python `detector.py`(277줄)·`digits.py`(209줄)의 검출 알고리즘을 Dart 순수 로직으로 이식한다.
"픽셀 배열 → 신호 상태(RED/GREEN/GREEN_BLINK/UNKNOWN) + 잔여초"를 만든다. 이게 완성되면
`visionStub()`(항상 unknown)을 실제 카메라 판정으로 대체할 수 있는 알맹이가 준비된다.

**범위 밖(다음 조각):** Flutter camera 플러그인 실시간 프레임·YUV→RGB·ROI 크롭(카메라 배관),
실환경 HSV 튜닝, GuidanceController 배선 + `kAllowSingleSource=false` 복귀.

## 2. 확보된 사실 (2026-07-14 확인)

- **config.json이 저장소에 존재** — 실제 HSV 값·모든 임계값이 있다(아래 §4.7). 그대로 이식.
- **Python 테스트 존재** — `scripts/test_detector.py`(97줄)·`test_digits.py`(164줄)·
  `test_state_machine.py`(143줄). 합성 프레임(회색 배경 + `cv2.circle` 컬러 원)으로 검증.
  → **Dart로 미러링해 동등성 검증**(데이터 계층 때와 같은 관행).
- Python은 `roi_bgr`(BGR np.ndarray)를 입력으로 받는다. Dart는 프레임워크-무관 값 타입으로.

## 3. 범위

**포함:** 색검출·형태학·경계추적(contour)·색 판정·상태머신·7세그먼트 디코딩을 Dart 순수 로직으로.
**범위 밖:** 카메라 실시간 배관, 실환경 튜닝, 앱 배선(위 §1).

## 4. 아키텍처

### 4.1 파일 구조 (책임 분리)

| 파일 | 책임 | 대응 Python |
|---|---|---|
| `lib/vision/roi_image.dart` | `RoiImage(width,height,bytes)` 값 타입 + BGR→HSV 변환 | 입력 경계 |
| `lib/vision/image_ops.dart` | 블러·inRange 마스크·형태학(erode/dilate/open/close) | cv2 연산 |
| `lib/vision/contours.dart` | 경계추적 → 면적·둘레·원형도 | findContours+contourArea+arcLength |
| `lib/vision/color_detector.dart` | HSV 색검출 → raw 판정(밝기·EMA·히스테리시스) | ColorDetector |
| `lib/vision/signal_state_machine.dart` | 시간축 디바운스·점멸 감지 → 상태 | SignalStateMachine |
| `lib/vision/digit_reader.dart` | 7세그먼트 셀 분할·디코딩·다수결 | DigitReader |
| `lib/vision/detector_config.dart` | cfg 값 타입 + config.json 값 상수 | cfg dict |

원칙: 순수 로직(픽셀 연산·경계추적)과 stateful 검출기(프레임 간 상태)를 분리해 각각 독립 테스트.
색은 OpenCV HSV 스케일(H 0–179, S/V 0–255) 정확히 재현 — config 값이 그 스케일로 튜닝됨.

### 4.2 RoiImage (입력 경계)

```dart
/// 프레임워크·카메라 무관 픽셀 값 타입. BGR 3채널, 행 우선(row-major).
class RoiImage {
  final int width;
  final int height;
  final Uint8List bytes; // length = width*height*3, [B,G,R, B,G,R, ...]
  const RoiImage(this.width, this.height, this.bytes);
}
```
BGR→HSV 변환은 OpenCV `COLOR_BGR2HSV` 공식 정확 재현(H 0–179). 카메라 조각이 나중에
YUV→RGB→BGR 결과를 이 타입으로 채워 넘긴다. 알고리즘은 카메라를 전혀 모른다.

### 4.3 image_ops (픽셀 연산)

- `gaussianBlur(roi, k)` — OpenCV `(k,k),0` 등가. sigma 자동공식 재현(OpenCV: σ=0.3·((k-1)·0.5-1)+0.8).
- `inRangeHsv(hsv, lower, upper)` → 이진 마스크(Uint8List). 범위 여럿이면 OR.
- 형태학: `erode`/`dilate`/`open`/`close`. 커널=타원(ellipse) k×k. detector는 OPEN→CLOSE,
  digit은 CLOSE만(원본과 동일).
순수 함수. OpenCV 결과와 픽셀 단위 비교로 검증(합성 마스크).

### 4.4 contours (경계추적 — 정확 이식)

```dart
class Contour { final List<Point> points; }
List<Contour> findContours(Uint8List mask, int w, int h); // RETR_EXTERNAL 등가
double contourArea(Contour c);   // Green 정리(shoelace)
double arcLength(Contour c);     // 둘레(닫힌 경로)
double circularity(Contour c);   // 4π·area/perimeter²
```
가장 어려운 부분. Moore-neighbor 또는 Suzuki-Abe 경계추적으로 blob 외곽선 추출 → OpenCV의
다각형 기반 면적·둘레와 거의 일치. `min_circularity`가 이 값에 튜닝돼 있어 정확 이식 필요.
Python 테스트(원 → 알려진 원형도)로 검증.

### 4.5 color_detector (stateful)

`ColorDetector` — Python과 동일. 상태: `_brightnessEma`, `_lastRaw`.
`FrameResult detect(RoiImage roi)`:
1. 블러 → HSV → V채널 평균(brightness).
2. brightness EMA + jump 감지(brightness_jump).
3. red/green 마스크(inRange+OR) → open→close.
4. 각 마스크: findContours → 최대 blob → 면적비·원형도 → valid 판정(면적비 범위 ∧ 원형도).
5. 히스테리시스: `_lastRaw`면 min_area_ratio·valid_exit_factor로 완화.
6. 우선순위 결정: too_dark → brightness_jump → 둘다valid(면적 큰 쪽, red 우선) → red → green → NONE(reason).
7. `_lastRaw` 갱신, `FrameResult(raw, red/green stat, brightness, reason)` 반환.
raw: `RED`/`GREEN`/`NONE`. reason: `too_dark`/`brightness_jump`/`no_blob`/`blob_too_large`.

### 4.6 signal_state_machine (stateful, 시간축)

`SignalStateMachine` — Python과 동일. 상태: RED/GREEN/GREEN_BLINK/UNKNOWN(초기 UNKNOWN).
내부: `_consecRaw`/`_consecCount`(연속 run), `_history: deque[(t,raw)]`(blink_window 초 창,
HOLD_REASONS의 NONE 제외), `_lastActiveT`.
`Transition? update(double t, String raw, {String reason})`:
1. 연속 run 갱신, history 추가(hold NONE 제외)·prune(t-blink_window 밖), `_lastActiveT` 갱신.
2. `debounced = _consecCount >= debounce_frames`. `noneDuration = t - _lastActiveT`.
3. `toggles = _countBlinkToggles(t)`: history를 run으로 접고, 인접 {GREEN,NONE} 쌍 중
   두 구간 다 ≥ blink_min_segment면 토글로 카운트.
4. `blinkExitOk = state != GREEN_BLINK || toggles == 0`(점멸 이탈 히스테리시스).
5. 우선순위: RED&debounced→RED / toggles≥blink_min_toggles→GREEN_BLINK /
   GREEN&debounced&blinkExitOk→GREEN / NONE&noneDuration≥unknown_after→UNKNOWN / else 유지.
6. 상태 바뀌면 Transition 반환. `resume()`은 history·counter만 초기화(state 유지).
`t`는 호출자 제공(초 단위 일관성만 지키면 됨) — Dart는 단조시계 델타.

### 4.7 detector_config (config 값)

config.json의 실제 값을 Dart 상수/값 타입으로. 확보된 값:
```
HSV red:   [0,55,45]~[12,255,255], [165,55,45]~[180,255,255]
HSV green: [35,45,45]~[100,255,255]
min_area_ratio 0.005, max_area_ratio 0.6, min_circularity 0.12
min_brightness 35, brightness_jump 60, brightness_ema_alpha 0.05
valid_exit_factor 0.6, morph_kernel 5
debounce_frames 8, blink_window_seconds 2.0, blink_min_toggles 3
blink_min_segment_seconds 0.15, unknown_after_seconds 1.5
digits: red_hsv [0,100,80]~[10,255,255],[170,100,80]~[180,255,255]
  seg_on_ratio 0.5, seg_off_ratio 0.2, min_cell_fill 0.08, max_cell_fill 0.65
  max_cell_aspect 0.82, stable_window 5, stable_votes 3
```
값 타입으로 감싸 주입 가능하게(테스트·튜닝 조각). 기본값은 위 config.json 값.

### 4.8 digit_reader (stateful, 7세그먼트)

`DigitReader` — Python과 동일. `SEGMENT_REGIONS`(7개 정규화 박스), `DIGIT_PATTERNS`(0–9),
`_recent: deque(maxlen=stable_window)`.
- `_mask`(digit red HSV, 블러+CLOSE) → `_splitCells`(열 투영으로 셀 분할, 노이즈 필터).
- `_decodeCell`: 크기·fill·aspect 체크, 좁은"1" 특수처리, 7세그먼트 샘플→ON/OFF(중간값이면 셀 거부),
  패턴 룩업. `readFrame`: 셀 1–2개, 하나라도 None이면 전체 None(전부-아니면-무).
- `read(roi)`: roi=null이면 None 투표(카메라 공백 시 stale 방지), 최근 stable_window 중
  최빈값을 stable_votes 이상일 때만 반환.

## 5. 데이터 흐름 (이번 조각 = 카메라 이전까지)

```
RoiImage(픽셀) ─ColorDetector.detect→ raw+reason ─StateMachine.update(t)→ 상태/Transition
                                                          │
digitRoi(RoiImage?) ─DigitReader.read→ 잔여초                │
                                                          ↓
        (다음 조각) → toReading(state, remainSec, freshMs) → SignalReading(source: vision)
```
이번 조각은 위 파이프라인의 각 부품 + 조립까지. `toReading` 연결·카메라·배선은 다음 조각.

## 6. 안전 원칙 (기존 유지)

- **불확실하면 UNKNOWN** — 애매한 세그먼트·blob → 판정 거부(추측 금지). 기존 Fail-Safe와 일관.
- **전부-아니면-무** — DigitReader는 셀 하나라도 애매하면 전체 None(부분 추측 안 함).
- **stale 방지** — 프레임 공백 시 None 투표로 오래된 값 미유지.
- 이 검출기가 완성돼도 이번 조각에선 아직 안 쓴다(배선은 다음). allowSingleSource는 카메라 조각에서 복귀.

## 7. 테스트 전략

- **Python 테스트 미러링** — `test_detector.py`·`test_digits.py`·`test_state_machine.py`를
  Dart로. 합성 프레임: `RoiImage`에 회색 배경 + 컬러 원/사각을 그리는 헬퍼(원본 `cv2.circle` 재현).
  같은 config 값, 같은 케이스(빨간원→RED, 초록원→GREEN, 어두움→too_dark, 밝기급변→jump 등).
- **단계별 순수 검증** — BGR→HSV(알려진 색), inRange 마스크, 형태학, 경계추적(원→면적·원형도),
  상태머신(시퀀스 주입 → 상태 전이), 7세그먼트(합성 숫자 → 디코딩).
- 실환경 정확도(실제 신호등 인식률)는 범위 밖 — 카메라·튜닝 조각에서.

## 8. 미해결/후속

- 경계추적이 OpenCV 면적·둘레와 얼마나 일치하는지 — 미러링 테스트 허용오차로 확인, 필요시 조정.
- Gaussian 블러 sigma·형태학 경계 처리 등 라이브러리별 미세차 — 픽셀 비교로 확인.
- 실환경 HSV 재튜닝(config.json 값은 시작점) — 카메라 조각.
- toReading 연결·GuidanceController 배선·allowSingleSource 복귀 — 다음 조각들.
