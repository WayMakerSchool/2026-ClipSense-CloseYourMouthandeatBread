# 카메라 배관 + 검출기 배선 설계

**작성일:** 2026-07-14
**상태:** 사용자 승인 완료 (설계 방향)

## 1. 목적

Flutter 카메라의 실시간 프레임을 이미 완성된 vision 파이프라인(ColorDetector →
SignalStateMachine, DigitReader)에 연결하고, 그 결과를 judge에 합쳐 **API + 카메라
이중 검증**을 완성한다. `visionStub()`(항상 unknown)을 실제 카메라 판정으로 대체하고,
임시 `kAllowSingleSource=true`를 끄고 원래 안전 설계(엄격 AND)로 복귀한다.

## 2. 확보된 사실 (2026-07-14 확인)

- **camera 0.11.2+1이 우리 환경(Dart 3.9.2 / Flutter 3.35.6)과 호환** — `pub get` 성공,
  geolocator·vibration과 충돌 없음(에러 0, 8개 의존성 추가). 0.11.3+는 Flutter ≥3.35를
  요구하나 실제 빌드가 3.32.2일 수 있어 0.11.2+1로 고정.
- **프레임 형식:** camera는 `ImageFormatGroup`으로 `yuv420`(안드로이드 기본),
  `bgra8888`(iOS), `nv21`을 준다. 안드로이드=YUV420, iOS=BGRA8888 → 둘 다 변환 필요.
- **vision 입력:** `RoiImage(width, height, Uint8List bytes)` — BGR 3채널. `ColorDetector.detect`,
  `DigitReader.read/readFrame`가 이걸 받음. `SignalStateMachine.update(t, raw, {reason})`.
  `toReading(state, {remainSec, freshMs})` → SignalReading(source: vision).

## 3. 범위

**포함:**
- 카메라 프레임(YUV420/BGRA8888) → 중앙 ROI 크롭 → RoiImage(BGR) 변환
- camera 플러그인 제어 + 프레임 스트림 → vision 파이프라인 → SignalReading 노출
- GuidanceController가 visionStub 대신 카메라 판정을 judge에 전달
- `kAllowSingleSource=false` 복귀(엄격 AND)
- 카메라 권한 선언(Android/iOS)

**범위 밖 (다음 조각):**
- 신호등 자동 찾기(ROI 자동 — 지금은 화면 중앙 고정)
- 실환경 HSV 튜닝, 블러 정밀 재현
- 백그라운드 동작, ESP32 하드웨어

## 4. 아키텍처

### 4.1 파일 구조 (책임 분리)

| 파일 | 책임 | 테스트 |
|---|---|---|
| `lib/camera/frame_converter.dart` | 프레임(YUV420/BGRA) + 중앙 ROI 사각 → RoiImage(BGR). 순수 함수 | 가짜 프레임으로 단위 테스트 |
| `lib/camera/camera_vision_source.dart` | camera 제어 + 프레임 스트림 → converter → vision 파이프라인 → 최신 SignalReading | 인터페이스 뒤 격리, 실기기 수동 |
| 수정 `lib/app/guidance_controller.dart` | visionStub 대신 주입된 vision source의 latestReading을 judge에 | Fake source 주입 테스트 |
| 수정 `lib/app/config.dart` | `kAllowSingleSource=false`, ROI 비율·카메라 해상도 상수 | 값 테스트 |
| 수정 `pubspec.yaml` + 플랫폼 매니페스트 | camera 0.11.2+1, 카메라 권한 | pub get·빌드 |

원칙: **순수 변환(frame_converter)과 하드웨어 제어(camera_vision_source)를 분리**한다.
변환은 가짜 YUV/BGRA 바이트로 완전 테스트하고, 실제 camera 스트림 제어는 인터페이스
뒤로 격리해 실기기 수동 검증한다(데이터·위치 계층과 같은 패턴).

### 4.2 frame_converter (순수 변환)

```dart
/// 카메라 프레임 → 중앙 ROI 크롭 → RoiImage(BGR). 프레임워크 타입에 의존하지 않게
/// plane 바이트·stride·width/height를 인자로 받는다(camera CameraImage에서 뽑아 전달).
class YuvPlanes {
  final Uint8List y, u, v;
  final int width, height, yRowStride, uvRowStride, uvPixelStride;
  ...
}

/// YUV420 → 중앙 ROI만 BGR로. roiFrac=중앙에서 취할 비율(예 0.5).
RoiImage yuv420ToRoiBgr(YuvPlanes p, double roiFrac);

/// BGRA8888 → 중앙 ROI만 BGR로.
RoiImage bgra8888ToRoiBgr(Uint8List bytes, int width, int height,
    int bytesPerRow, double roiFrac);
```

핵심: 성능을 위해 **전체 프레임을 변환하지 않고 중앙 ROI 영역만** 순회해 BGR로 만든다
(전체 프레임 변환은 실시간에 무겁다). YUV→RGB는 표준 BT.601 공식. ROI는 중앙에서
roiFrac(예 0.5) 비율의 정사각/직사각 영역.

### 4.3 camera_vision_source (하드웨어 + 파이프라인)

```dart
/// 카메라 판정을 노출하는 인터페이스. GuidanceController가 이걸 구독.
abstract class VisionSource {
  SignalReading get latestReading; // 최신 카메라 판정(없으면 unknown)
  Future<void> start();
  Future<void> stop();
}

/// 실제 구현: camera 플러그인 스트림 → frame_converter → vision 파이프라인.
class CameraVisionSource implements VisionSource {
  // ColorDetector, SignalStateMachine, DigitReader 보유(프레임 간 상태).
  // startImageStream 콜백마다:
  //   CameraImage → YuvPlanes/BGRA bytes → frame_converter → RoiImage
  //   → detector.detect → sm.update(t, raw, reason) → state
  //   → digitReader.read(roi) → remainSec
  //   → _latest = toReading(state, remainSec: ..., freshMs: 0)
  // t는 단조 경과 초(스트림 시작 기준).
}
```

프레임 처리는 무거우니 **프레임 스킵**(예 N프레임당 1회 처리) 또는 처리 중 프레임 드롭으로
UI·배터리를 보호한다. 실패(카메라 오류/변환 예외)는 삼켜 latestReading을 unknown 유지
(Fail-Safe). camera 플러그인 직접 의존은 이 파일에만.

### 4.4 GuidanceController 수정

현재 tickOnce가 `visionStub()`을 부른다. 이를 주입된 VisionSource의 latestReading으로:

```dart
GuidanceController({
  required FeedbackController feedback,
  required String itstId,
  required String direction,
  VisionSource? vision,        // ← 추가: 없으면 stub(하위호환·테스트)
  FetchReading? fetch,
  ...
});
// tickOnce에서:
//   final visionReading = _vision?.latestReading ?? visionStub();
//   d = decide(apiReading, visionReading, needSec: kNeedSec,
//              allowSingleSource: kAllowSingleSource);  // 이제 false
```

`allowSingleSource`는 config의 `kAllowSingleSource`(=false)를 그대로 쓴다. 카메라가
붙었으니 엄격 AND — API·카메라 둘 다 green일 때만 walk.

### 4.5 config 수정

- `kAllowSingleSource = false` (⚠️ true→false: 엄격 AND 복귀. 카메라 배선 완료로 임시 종료).
- `kRoiFrac = 0.5` (중앙 ROI 비율), `kCameraProcessEveryN = 3` (프레임 스킵), 카메라 해상도 프리셋.

## 5. 데이터 흐름

```
[카메라 스트림] → CameraImage(YUV420/BGRA) → frame_converter(중앙 ROI 크롭+BGR) → RoiImage
   → ColorDetector.detect → raw+reason → SignalStateMachine.update(t) → state
   → DigitReader.read(roi) → remainSec → toReading → SignalReading(vision) → CameraVisionSource._latest
                                                                                    │
[1초 루프] tickOnce: fetchReading(API) + vision.latestReading                        │
   → judge.decide(allowSingleSource:false) ←────────────────────────────────────────┘
   → 둘 다 green일 때만 walk → FeedbackController(음성/햅틱) + 화면
```

카메라는 자체 스트림(수십 fps, N스킵)으로 latestReading을 갱신하고, judge 루프는 1초마다
그 최신값을 API와 합쳐 판단한다. 두 속도가 분리돼 있어 서로 안 막는다.

## 6. 안전 원칙 (강화됨 + 기존 유지)

- **엄격 AND 복귀:** API·카메라 둘 다 green + 잔여충분일 때만 walk. 원래 안전 설계 완성.
- **⚠️ 트레이드오프(명시):** 엄격 AND면 카메라가 신호등을 확실히 못 볼 때(방향·조명·거리)
  API가 green이어도 unknown/wait이 나온다. 안전하지만 "기다리세요"가 자주 나올 수 있음.
  **실기기에서 카메라 인식률을 측정**하고, 지나치게 답답하면 이후 조각에서 정책 조정
  (예: 카메라 신뢰도 기반 가중, 또는 특정 조건서 단일소스 허용) — 지금은 안전 최우선.
- **Fail-Safe 유지:** 카메라 프레임 없음/변환 실패/파이프라인 예외 → vision unknown →
  judge가 walk 안 냄. 애매하면 대기.
- **stale 방지:** 카메라 스트림 끊기면 latestReading이 오래되지 않게(freshMs 또는 마지막
  갱신 시각 기반) — 오래되면 unknown 취급.

## 7. 테스트 전략

- **frame_converter 단위 테스트:** 가짜 YUV420/BGRA 바이트(알려진 색 블록)를 만들어 중앙
  ROI가 올바른 BGR로 나오는지. 예: 전체 초록 YUV → ROI가 초록 BGR. 순수 함수라 완전 검증.
- **GuidanceController 테스트:** Fake VisionSource(원하는 SignalReading 반환) 주입 → judge가
  엄격 AND로 동작하는지(API green+vision green→walk, 한쪽 unknown→wait). 기존 테스트도
  vision 인자 추가로 갱신.
- **CameraVisionSource:** camera 플러그인·실시간 프레임은 실기기 수동 검증(범위 밖 자동화).
  프레임 처리 로직(변환→파이프라인)은 frame_converter·vision 테스트로 이미 커버.
- **실기기 체크리스트(문서화):** 권한 요청, 실제 신호등 인식률, 프레임 처리 성능·배터리,
  YUV/BGRA 변환 정확성, 엄격 AND 체감(답답함 정도).

## 8. 미해결/후속

- ROI 자동(신호등 찾기) — 지금 중앙 고정. 다음 조각.
- 실환경 HSV 튜닝(config.json 값은 시작점) — 실기기 촬영으로.
- 블러 재활성화(gaussianBlur) — vision 조각에서 생략했으니 여기서 추가 검토(실프레임은
  노이즈 있어 블러 필요할 수 있음).
- 엄격 AND 체감 조정 — 실기기 인식률 측정 후.
- 프레임 처리를 UI isolate 밖으로(성능) — 필요시.
- 카메라 해상도·처리 주기(N) 튜닝 — 실기기 성능 보고.
