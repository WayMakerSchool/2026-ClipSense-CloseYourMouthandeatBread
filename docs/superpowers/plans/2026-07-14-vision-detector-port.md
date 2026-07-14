# 카메라 검출기 알고리즘 이식 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Python detector.py/digits.py의 검출 알고리즘을 Dart 순수 로직으로 이식한다 — 픽셀 배열(RoiImage) → 신호 상태(RED/GREEN/GREEN_BLINK/UNKNOWN) + 잔여초.

**Architecture:** 의존성 바닥부터 이식한다 — config 값 → RoiImage(BGR→HSV) → image_ops(마스크·형태학) → contours(경계추적) → color_detector → signal_state_machine → digit_reader. 순수 로직과 stateful 검출기를 분리한다. 색은 OpenCV HSV 스케일(H 0–179, S/V 0–255)을 정확히 재현하고, Python 테스트를 Dart로 미러링해 동등성을 검증한다.

**Tech Stack:** Flutter 3.35.6 / Dart 3.9.2, dart:typed_data(Uint8List), dart:math. 새 런타임 의존성 없음(순수 Dart). flutter_test.

## Global Constraints

- **OpenCV HSV 스케일 정확 재현:** H∈[0,179], S∈[0,255], V∈[0,255]. config 값이 이 스케일로 튜닝됨. BGR→HSV는 OpenCV COLOR_BGR2HSV 공식 그대로.
- **불확실하면 UNKNOWN/None (Fail-Safe):** 애매한 세그먼트·blob → 판정 거부. DigitReader는 셀 하나라도 애매하면 전체 None(전부-아니면-무). 기존 안전정책과 일관.
- **config 값은 config.json 실제값 그대로.** 상수는 detector_config.dart에 값 타입으로. 주입 가능(테스트·튜닝).
- **Python 동등성:** scripts/test_detector.py·test_digits.py·test_state_machine.py의 케이스를 Dart로 미러링. 합성 프레임(회색 배경 + 컬러 원/7세그먼트 사각)으로 검증. 경계추적 등 미세차는 허용오차(closeTo) 사용.
- **stateful 클래스는 프레임 간 상태 유지** — ColorDetector(_brightnessEma,_lastRaw), SignalStateMachine(deque+counters), DigitReader(deque). t(시각)는 호출자 제공, 초 단위 일관.
- 실제 config 값(config.json):
  - HSV red: `[0,55,45]~[12,255,255]`, `[165,55,45]~[180,255,255]`; green: `[35,45,45]~[100,255,255]`
  - min_area_ratio 0.005, max_area_ratio 0.6, min_circularity 0.12, min_brightness 35, brightness_jump 60, brightness_ema_alpha 0.05, valid_exit_factor 0.6, morph_kernel 5
  - debounce_frames 8, blink_window_seconds 2.0, blink_min_toggles 3, blink_min_segment_seconds 0.15, unknown_after_seconds 1.5
  - digits.red_hsv `[0,100,80]~[10,255,255]`,`[170,100,80]~[180,255,255]`; seg_on_ratio 0.5, seg_off_ratio 0.2, min_cell_fill 0.08, max_cell_fill 0.65, max_cell_aspect 0.82, stable_window 5, stable_votes 3
- 상수 문자열: raw = 'RED'/'GREEN'/'NONE'; state = 'RED'/'GREEN'/'GREEN_BLINK'/'UNKNOWN'; reason = 'too_dark'/'brightness_jump'/'blob_too_large'/'no_blob'/'camera_fail'.

---

## File Structure

- Create: `lib/vision/detector_config.dart` — HsvRange, DetectorConfig 값 타입 + config.json 기본값.
- Create: `lib/vision/roi_image.dart` — RoiImage 값 타입 + bgrToHsv.
- Create: `lib/vision/image_ops.dart` — gaussianBlur, inRangeHsv(+OR), erode/dilate/open/close.
- Create: `lib/vision/contours.dart` — findContours(경계추적) + contourArea + arcLength + circularity.
- Create: `lib/vision/color_detector.dart` — ColorStat, FrameResult, ColorDetector.
- Create: `lib/vision/signal_state_machine.dart` — Transition, SignalStateMachine.
- Create: `lib/vision/digit_reader.dart` — DigitReader + 패턴/세그먼트 상수.
- Test: 각 파일별 `test/vision/*_test.dart`.

---

## Task 1: detector_config.dart (config 값 타입)

**Files:**
- Create: `app/lib/vision/detector_config.dart`
- Test: `app/test/vision/detector_config_test.dart`

**Interfaces:**
- Produces: `class HsvRange { final List<int> lower; final List<int> upper; }`, `class DetectorConfig { ... 모든 필드 ...; const DetectorConfig.defaults() }`.

- [ ] **Step 1: 실패 테스트 작성**

```dart
// test/vision/detector_config_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/vision/detector_config.dart';

void main() {
  test('기본값이 config.json과 일치', () {
    const c = DetectorConfig.defaults();
    expect(c.minAreaRatio, 0.005);
    expect(c.maxAreaRatio, 0.6);
    expect(c.minCircularity, 0.12);
    expect(c.minBrightness, 35);
    expect(c.brightnessJump, 60);
    expect(c.brightnessEmaAlpha, 0.05);
    expect(c.validExitFactor, 0.6);
    expect(c.morphKernel, 5);
    expect(c.debounceFrames, 8);
    expect(c.blinkWindowSeconds, 2.0);
    expect(c.blinkMinToggles, 3);
    expect(c.blinkMinSegmentSeconds, 0.15);
    expect(c.unknownAfterSeconds, 1.5);
    expect(c.segOnRatio, 0.5);
    expect(c.segOffRatio, 0.2);
    expect(c.minCellFill, 0.08);
    expect(c.maxCellFill, 0.65);
    expect(c.maxCellAspect, 0.82);
    expect(c.stableWindow, 5);
    expect(c.stableVotes, 3);
  });

  test('HSV red 범위 2개, green 1개', () {
    const c = DetectorConfig.defaults();
    expect(c.hsvRed.length, 2);
    expect(c.hsvRed[0].lower, [0, 55, 45]);
    expect(c.hsvRed[0].upper, [12, 255, 255]);
    expect(c.hsvRed[1].lower, [165, 55, 45]);
    expect(c.hsvGreen.length, 1);
    expect(c.hsvGreen[0].lower, [35, 45, 45]);
    expect(c.hsvGreen[0].upper, [100, 255, 255]);
  });

  test('digit red_hsv 별도 범위 2개', () {
    const c = DetectorConfig.defaults();
    expect(c.digitRedHsv.length, 2);
    expect(c.digitRedHsv[0].lower, [0, 100, 80]);
    expect(c.digitRedHsv[0].upper, [10, 255, 255]);
    expect(c.digitRedHsv[1].lower, [170, 100, 80]);
  });
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd app && flutter test test/vision/detector_config_test.dart`
Expected: FAIL — 타입 미정의.

- [ ] **Step 3: 구현**

```dart
// lib/vision/detector_config.dart
/// 검출기 설정 값 타입. 기본값은 저장소 config.json(2026-07-14)과 일치.
/// 실환경 HSV 튜닝은 카메라 조각에서 재조정(이 값은 시작점).
library;

/// HSV 범위(OpenCV 스케일: H 0-179, S/V 0-255). lower/upper 각 [H,S,V].
class HsvRange {
  final List<int> lower;
  final List<int> upper;
  const HsvRange(this.lower, this.upper);
}

class DetectorConfig {
  final List<HsvRange> hsvRed;
  final List<HsvRange> hsvGreen;
  final List<HsvRange> digitRedHsv;
  final double minAreaRatio;
  final double maxAreaRatio;
  final double minCircularity;
  final double minBrightness;
  final double brightnessJump;
  final double brightnessEmaAlpha;
  final double validExitFactor;
  final int morphKernel;
  final int debounceFrames;
  final double blinkWindowSeconds;
  final int blinkMinToggles;
  final double blinkMinSegmentSeconds;
  final double unknownAfterSeconds;
  final double segOnRatio;
  final double segOffRatio;
  final double minCellFill;
  final double maxCellFill;
  final double maxCellAspect;
  final int stableWindow;
  final int stableVotes;

  const DetectorConfig({
    required this.hsvRed,
    required this.hsvGreen,
    required this.digitRedHsv,
    required this.minAreaRatio,
    required this.maxAreaRatio,
    required this.minCircularity,
    required this.minBrightness,
    required this.brightnessJump,
    required this.brightnessEmaAlpha,
    required this.validExitFactor,
    required this.morphKernel,
    required this.debounceFrames,
    required this.blinkWindowSeconds,
    required this.blinkMinToggles,
    required this.blinkMinSegmentSeconds,
    required this.unknownAfterSeconds,
    required this.segOnRatio,
    required this.segOffRatio,
    required this.minCellFill,
    required this.maxCellFill,
    required this.maxCellAspect,
    required this.stableWindow,
    required this.stableVotes,
  });

  const DetectorConfig.defaults()
      : hsvRed = const [
          HsvRange([0, 55, 45], [12, 255, 255]),
          HsvRange([165, 55, 45], [180, 255, 255]),
        ],
        hsvGreen = const [HsvRange([35, 45, 45], [100, 255, 255])],
        digitRedHsv = const [
          HsvRange([0, 100, 80], [10, 255, 255]),
          HsvRange([170, 100, 80], [180, 255, 255]),
        ],
        minAreaRatio = 0.005,
        maxAreaRatio = 0.6,
        minCircularity = 0.12,
        minBrightness = 35,
        brightnessJump = 60,
        brightnessEmaAlpha = 0.05,
        validExitFactor = 0.6,
        morphKernel = 5,
        debounceFrames = 8,
        blinkWindowSeconds = 2.0,
        blinkMinToggles = 3,
        blinkMinSegmentSeconds = 0.15,
        unknownAfterSeconds = 1.5,
        segOnRatio = 0.5,
        segOffRatio = 0.2,
        minCellFill = 0.08,
        maxCellFill = 0.65,
        maxCellAspect = 0.82,
        stableWindow = 5,
        stableVotes = 3;
}
```

- [ ] **Step 4: 테스트 통과 + 분석**

Run: `cd app && flutter test test/vision/detector_config_test.dart && flutter analyze lib/vision/detector_config.dart test/vision/detector_config_test.dart`
Expected: PASS (3 tests), No issues found.

- [ ] **Step 5: 커밋**

```bash
git add app/lib/vision/detector_config.dart app/test/vision/detector_config_test.dart
git commit -m "feat(vision): add DetectorConfig value type (config.json defaults)"
```

---

## Task 2: roi_image.dart (픽셀 값 타입 + BGR→HSV)

**Files:**
- Create: `app/lib/vision/roi_image.dart`
- Test: `app/test/vision/roi_image_test.dart`

**Interfaces:**
- Produces: `class RoiImage { int width; int height; Uint8List bytes; }` (bytes = w*h*3, BGR 순서), `Uint8List bgrToHsv(RoiImage)` (반환 = w*h*3, HSV 순서, OpenCV 스케일).

**핵심:** OpenCV COLOR_BGR2HSV 공식. V=max(B,G,R). S = V==0?0:(V-min)/V*255. H는 6구간 공식 후 /2(0-179). 정수 반올림은 OpenCV 8-bit 경로와 맞추되, 미러링 테스트는 알려진 원색으로 검증(순수 빨강 BGR(0,0,255)→H≈0, 순수 초록 BGR(0,255,0)→H≈60).

- [ ] **Step 1: 실패 테스트 작성**

```dart
// test/vision/roi_image_test.dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/vision/roi_image.dart';

RoiImage solid(int w, int h, int b, int g, int r) {
  final bytes = Uint8List(w * h * 3);
  for (var i = 0; i < w * h; i++) {
    bytes[i * 3] = b;
    bytes[i * 3 + 1] = g;
    bytes[i * 3 + 2] = r;
  }
  return RoiImage(w, h, bytes);
}

void main() {
  test('순수 빨강 BGR(0,0,255) → H≈0, S=255, V=255', () {
    final hsv = bgrToHsv(solid(2, 2, 0, 0, 255));
    expect(hsv[0], closeTo(0, 1));   // H
    expect(hsv[1], 255);             // S
    expect(hsv[2], 255);             // V
  });

  test('순수 초록 BGR(0,255,0) → H≈60', () {
    final hsv = bgrToHsv(solid(2, 2, 0, 255, 0));
    expect(hsv[0], closeTo(60, 1));
  });

  test('순수 파랑 BGR(255,0,0) → H≈120', () {
    final hsv = bgrToHsv(solid(1, 1, 255, 0, 0));
    expect(hsv[0], closeTo(120, 1));
  });

  test('검정 → V=0, S=0', () {
    final hsv = bgrToHsv(solid(1, 1, 0, 0, 0));
    expect(hsv[2], 0);
    expect(hsv[1], 0);
  });

  test('회색 BGR(128,128,128) → S=0, V=128', () {
    final hsv = bgrToHsv(solid(1, 1, 128, 128, 128));
    expect(hsv[1], 0);
    expect(hsv[2], 128);
  });
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd app && flutter test test/vision/roi_image_test.dart`
Expected: FAIL.

- [ ] **Step 3: 구현**

```dart
// lib/vision/roi_image.dart
/// 프레임워크·카메라 무관 픽셀 값 타입 + BGR→HSV(OpenCV 스케일).
library;

import 'dart:typed_data';

/// BGR 3채널, 행 우선. bytes.length == width*height*3, [B,G,R, B,G,R, ...].
class RoiImage {
  final int width;
  final int height;
  final Uint8List bytes;
  const RoiImage(this.width, this.height, this.bytes);
}

/// BGR → HSV (OpenCV COLOR_BGR2HSV: H 0-179, S/V 0-255).
/// 반환 bytes = width*height*3, [H,S,V, ...].
Uint8List bgrToHsv(RoiImage img) {
  final n = img.width * img.height;
  final out = Uint8List(n * 3);
  final src = img.bytes;
  for (var i = 0; i < n; i++) {
    final b = src[i * 3];
    final g = src[i * 3 + 1];
    final r = src[i * 3 + 2];
    final maxc = b > g ? (b > r ? b : r) : (g > r ? g : r);
    final minc = b < g ? (b < r ? b : r) : (g < r ? g : r);
    final v = maxc;
    final delta = maxc - minc;
    int s = 0;
    if (v != 0) s = (delta * 255 / v).round();
    double h = 0;
    if (delta != 0) {
      if (maxc == r) {
        h = 60 * (((g - b) / delta) % 6);
      } else if (maxc == g) {
        h = 60 * (((b - r) / delta) + 2);
      } else {
        h = 60 * (((r - g) / delta) + 4);
      }
    }
    if (h < 0) h += 360;
    // OpenCV는 H를 절반으로(0-179).
    var hh = (h / 2).round();
    if (hh >= 180) hh -= 180;
    out[i * 3] = hh;
    out[i * 3 + 1] = s;
    out[i * 3 + 2] = v;
  }
  return out;
}
```

주: OpenCV의 정확한 8-bit H 반올림과 미세차가 있을 수 있어 테스트는 closeTo(±1). 색 판정은 범위 기반이라 ±1은 무해.

- [ ] **Step 4: 테스트 통과 + 분석**

Run: `cd app && flutter test test/vision/roi_image_test.dart && flutter analyze lib/vision/roi_image.dart test/vision/roi_image_test.dart`
Expected: PASS (5), No issues.

- [ ] **Step 5: 커밋**

```bash
git add app/lib/vision/roi_image.dart app/test/vision/roi_image_test.dart
git commit -m "feat(vision): add RoiImage + BGR→HSV (OpenCV scale)"
```

---

## Task 3: image_ops.dart (블러·마스크·형태학)

**Files:**
- Create: `app/lib/vision/image_ops.dart`
- Test: `app/test/vision/image_ops_test.dart`

**Interfaces:**
- Consumes: HsvRange, RoiImage(HSV bytes).
- Produces:
  - `Uint8List inRangeHsv(Uint8List hsv, int n, List<HsvRange> ranges)` — 이진 마스크(0/255), 길이 n=w*h. 범위 여럿 OR.
  - `Uint8List erode(Uint8List mask, int w, int h, int k)`, `dilate(...)`, `morphOpen(...)`=erode→dilate, `morphClose(...)`=dilate→erode. 커널=타원 k×k.
  - `Uint8List gaussianBlurBgr(RoiImage img, int k)` — BGR 블러(선택: 미러링 필요시). *주: OpenCV 블러 정확 재현은 어려우니, 미러링 테스트는 블러 없는 경로(단색/큰 블록)로 색·형태학을 검증하고, 블러는 통합 단계에서 근사 허용.*

**형태학 커널(타원):** OpenCV getStructuringElement(MORPH_ELLIPSE,(k,k)) 재현. 중심 기준 타원 마스크. 경계는 0 패딩(OpenCV 기본 BORDER_CONSTANT는 morphology에서 erode는 값 유지 경향 — 미러링 테스트로 확인, 필요시 조정).

- [ ] **Step 1: 실패 테스트 작성**

```dart
// test/vision/image_ops_test.dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/vision/detector_config.dart';
import 'package:clip_sense/vision/image_ops.dart';

// HSV 픽셀 배열 헬퍼: 모든 픽셀을 (h,s,v)로.
Uint8List hsvSolid(int n, int h, int s, int v) {
  final b = Uint8List(n * 3);
  for (var i = 0; i < n; i++) {
    b[i * 3] = h; b[i * 3 + 1] = s; b[i * 3 + 2] = v;
  }
  return b;
}

void main() {
  test('inRangeHsv: 범위 안 → 255, 밖 → 0', () {
    const red = [HsvRange([0, 55, 45], [12, 255, 255])];
    // H=5,S=200,V=200 → 범위 안
    expect(inRangeHsv(hsvSolid(1, 5, 200, 200), 1, red)[0], 255);
    // H=100 → 밖
    expect(inRangeHsv(hsvSolid(1, 100, 200, 200), 1, red)[0], 0);
    // S=10 → 밖(채도 부족)
    expect(inRangeHsv(hsvSolid(1, 5, 10, 200), 1, red)[0], 0);
  });

  test('inRangeHsv: 여러 범위 OR (빨강 wraparound)', () {
    const red = [
      HsvRange([0, 55, 45], [12, 255, 255]),
      HsvRange([165, 55, 45], [180, 255, 255]),
    ];
    expect(inRangeHsv(hsvSolid(1, 170, 200, 200), 1, red)[0], 255); // 둘째 범위
  });

  test('erode: 3x3 단일 점 제거', () {
    // 5x5 마스크 중앙 1점만 255 → erode 후 전부 0
    final m = Uint8List(25);
    m[12] = 255; // 중앙(2,2)
    final e = erode(m, 5, 5, 3);
    expect(e.every((v) => v == 0), isTrue);
  });

  test('dilate: 3x3 단일 점 확장', () {
    final m = Uint8List(25);
    m[12] = 255;
    final d = dilate(m, 5, 5, 3);
    // 중앙 주변 십자+대각(타원 3x3은 십자 또는 3x3 꽉참) 확장됨
    expect(d[12], 255);
    expect(d[7], 255); // 위
    expect(d[11], 255); // 왼
  });

  test('morphOpen: 작은 노이즈 제거, 큰 블록 유지', () {
    // 7x7: 큰 5x5 블록 + 떨어진 1점 노이즈
    final m = Uint8List(49);
    for (var y = 1; y <= 5; y++) {
      for (var x = 1; x <= 5; x++) m[y * 7 + x] = 255;
    }
    // 노이즈는 블록과 안 붙게 (0,0)에 두면 open 후 사라짐... 대신 블록 검증
    final o = morphOpen(m, 7, 7, 3);
    expect(o[3 * 7 + 3], 255); // 블록 중앙 유지
  });
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd app && flutter test test/vision/image_ops_test.dart`
Expected: FAIL.

- [ ] **Step 3: 구현**

```dart
// lib/vision/image_ops.dart
/// HSV 마스크(inRange) + 형태학(erode/dilate/open/close). 순수 함수.
library;

import 'dart:typed_data';

import 'detector_config.dart';

/// HSV 픽셀(길이 n*3)에서 범위 안 픽셀을 255로. 범위 여럿이면 OR.
Uint8List inRangeHsv(Uint8List hsv, int n, List<HsvRange> ranges) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    final h = hsv[i * 3], s = hsv[i * 3 + 1], v = hsv[i * 3 + 2];
    for (final r in ranges) {
      if (h >= r.lower[0] && h <= r.upper[0] &&
          s >= r.lower[1] && s <= r.upper[1] &&
          v >= r.lower[2] && v <= r.upper[2]) {
        out[i] = 255;
        break;
      }
    }
  }
  return out;
}

/// 타원 구조요소(k×k) — 불리언 커널. OpenCV MORPH_ELLIPSE 근사.
List<bool> _ellipseKernel(int k) {
  final kernel = List<bool>.filled(k * k, false);
  final c = (k - 1) / 2.0;
  final rr = c <= 0 ? 0.0 : c;
  for (var y = 0; y < k; y++) {
    for (var x = 0; x < k; x++) {
      final dx = (x - c) / (rr == 0 ? 1 : rr);
      final dy = (y - c) / (rr == 0 ? 1 : rr);
      if (dx * dx + dy * dy <= 1.0 + 1e-9) kernel[y * k + x] = true;
    }
  }
  return kernel;
}

Uint8List _morph(Uint8List mask, int w, int h, int k, bool dilateOp) {
  final kernel = _ellipseKernel(k);
  final half = k ~/ 2;
  final out = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      // dilate: 커널 내 하나라도 255 → 255. erode: 커널 전부 255 → 255.
      var result = dilateOp ? 0 : 255;
      for (var ky = 0; ky < k; ky++) {
        for (var kx = 0; kx < k; kx++) {
          if (!kernel[ky * k + kx]) continue;
          final ny = y + ky - half;
          final nx = x + kx - half;
          final inside = ny >= 0 && ny < h && nx >= 0 && nx < w;
          final val = inside ? mask[ny * w + nx] : 0;
          if (dilateOp) {
            if (val == 255) { result = 255; }
          } else {
            if (val != 255) { result = 0; }
          }
        }
      }
      out[y * w + x] = result;
    }
  }
  return out;
}

Uint8List dilate(Uint8List mask, int w, int h, int k) =>
    _morph(mask, w, h, k, true);
Uint8List erode(Uint8List mask, int w, int h, int k) =>
    _morph(mask, w, h, k, false);
Uint8List morphOpen(Uint8List mask, int w, int h, int k) =>
    dilate(erode(mask, w, h, k), w, h, k);
Uint8List morphClose(Uint8List mask, int w, int h, int k) =>
    erode(dilate(mask, w, h, k), w, h, k);
```

주: OpenCV erode의 경계 처리는 BORDER_CONSTANT(0)이라 위 inside=false→0과 일치(erode에서 경계 밖을 0으로 보면 경계 픽셀이 깎임 — OpenCV 기본과 동일 방향). 미러링에서 미세차 나면 테스트 허용오차로 흡수.

- [ ] **Step 4: 테스트 통과 + 분석**

Run: `cd app && flutter test test/vision/image_ops_test.dart && flutter analyze lib/vision/image_ops.dart test/vision/image_ops_test.dart`
Expected: PASS (5), No issues.

- [ ] **Step 5: 커밋**

```bash
git add app/lib/vision/image_ops.dart app/test/vision/image_ops_test.dart
git commit -m "feat(vision): add HSV inRange mask + morphology (open/close, ellipse)"
```

---

## Task 4: contours.dart (경계추적 → 면적·둘레·원형도)

**Files:**
- Create: `app/lib/vision/contours.dart`
- Test: `app/test/vision/contours_test.dart`

**Interfaces:**
- Produces: `class Contour { final List<int> xs; final List<int> ys; }`, `List<Contour> findContours(Uint8List mask, int w, int h)` (연결요소별 외곽 경계, RETR_EXTERNAL 근사), `double contourArea(Contour)` (shoelace), `double arcLength(Contour)` (닫힌 둘레), `double circularity(Contour)` (4π·area/perimeter², perimeter 0이면 0).

**핵심:** 정확 이식이지만 OpenCV와 100% 일치는 목표가 아니고 **판정에 쓰는 값(면적비·원형도)이 임계값과 정합**하면 된다. 접근:
- 연결요소(4-이웃 또는 8-이웃 flood fill)로 blob 분리(외부 blob만).
- 각 blob의 **외곽 경계**를 Moore-neighbor tracing으로 시계방향 추출 → 경계 점 리스트.
- contourArea = shoelace(경계 다각형). arcLength = 인접 경계점 유클리드 거리 합(닫힘).
- circularity = 4π·area/perimeter². 원(반지름 r)이면 ≈1.0에 근접해야 함(테스트로 확인).

미러링 테스트: 합성 마스크에 채운 원 → 면적 closeTo(πr², 상대오차), 원형도 closeTo(1.0, 0.15). 채운 사각 → 면적=넓이, 원형도<원. 빈 마스크 → 빈 리스트.

- [ ] **Step 1: 실패 테스트 작성**

```dart
// test/vision/contours_test.dart
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/vision/contours.dart';

// 마스크에 채운 원 그리기.
Uint8List filledCircle(int w, int h, int cx, int cy, int r) {
  final m = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final dx = x - cx, dy = y - cy;
      if (dx * dx + dy * dy <= r * r) m[y * w + x] = 255;
    }
  }
  return m;
}

Uint8List filledRect(int w, int h, int x1, int y1, int x2, int y2) {
  final m = Uint8List(w * h);
  for (var y = y1; y < y2; y++) {
    for (var x = x1; x < x2; x++) m[y * w + x] = 255;
  }
  return m;
}

void main() {
  test('빈 마스크 → contour 없음', () {
    expect(findContours(Uint8List(100), 10, 10), isEmpty);
  });

  test('채운 원 → 면적 ≈ πr², 원형도 ≈ 1.0', () {
    final m = filledCircle(100, 100, 50, 50, 20);
    final cs = findContours(m, 100, 100);
    expect(cs.length, 1);
    final area = contourArea(cs.first);
    expect(area, closeTo(math.pi * 20 * 20, math.pi * 20 * 20 * 0.15));
    expect(circularity(cs.first), closeTo(1.0, 0.2));
  });

  test('채운 사각 → 원형도가 원보다 낮음(< 0.85)', () {
    final m = filledRect(100, 100, 30, 30, 70, 70);
    final cs = findContours(m, 100, 100);
    expect(cs.length, 1);
    expect(circularity(cs.first), lessThan(0.85));
  });

  test('blob 2개 → contour 2개', () {
    final m = filledCircle(100, 100, 25, 25, 8);
    final m2 = filledCircle(100, 100, 75, 75, 8);
    for (var i = 0; i < m.length; i++) if (m2[i] == 255) m[i] = 255;
    expect(findContours(m, 100, 100).length, 2);
  });
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd app && flutter test test/vision/contours_test.dart`
Expected: FAIL.

- [ ] **Step 3: 구현**

구현자에게: 다음을 구현하라(정확한 코드는 구현자가 작성하되 아래 알고리즘·시그니처를 지킬 것).
- `findContours(mask, w, h)`: 8-이웃 연결요소 라벨링으로 255 blob들을 분리. 각 blob에 대해 Moore-neighbor boundary tracing(시작=blob의 최상단-최좌측 픽셀, 시계방향)으로 외곽 경계 점열 추출. 각 경계를 `Contour(xs, ys)`로. 반환은 blob별 1개(외부 경계만; 구멍 무시 = RETR_EXTERNAL).
- `contourArea(c)`: shoelace 공식 `0.5*|Σ(x_i*y_{i+1} - x_{i+1}*y_i)|`.
- `arcLength(c)`: 인접 경계점(마지막→처음 닫음) 유클리드 거리 합.
- `circularity(c)`: `perimeter>0 ? 4*pi*area/(perimeter*perimeter) : 0`.

구현 시 주의:
- 경계 추적은 단일 픽셀 blob·1D 선(면적 0) 등 degenerate에 안전해야 함(perimeter 0 → circularity 0).
- 성능: ROI는 작음(수백×수백). O(픽셀) 라벨링 + O(경계) 추적으로 충분.
- OpenCV contourArea/arcLength와 미세차는 허용(테스트 closeTo). circularity가 원≈1, 사각<원이면 판정에 충분.

- [ ] **Step 4: 테스트 통과 + 분석**

Run: `cd app && flutter test test/vision/contours_test.dart && flutter analyze lib/vision/contours.dart test/vision/contours_test.dart`
Expected: PASS (4), No issues.

- [ ] **Step 5: 커밋**

```bash
git add app/lib/vision/contours.dart app/test/vision/contours_test.dart
git commit -m "feat(vision): add contour tracing (area/perimeter/circularity)"
```

---

## Task 5: color_detector.dart (프레임 단위 색 판정)

**Files:**
- Create: `app/lib/vision/color_detector.dart`
- Test: `app/test/vision/color_detector_test.dart`

**Interfaces:**
- Consumes: RoiImage, bgrToHsv, inRangeHsv, morphOpen/Close, findContours+contourArea+arcLength+circularity, DetectorConfig.
- Produces: `class ColorStat { double areaRatio; double circularity; bool valid; }`, `class FrameResult { String raw; ColorStat red; ColorStat green; double brightness; String reason; }`, `class ColorDetector { ColorDetector(DetectorConfig); FrameResult detect(RoiImage); }`. 상수: `rawRed='RED'`, `rawGreen='GREEN'`, `rawNone='NONE'`.

**로직 (detector.py 그대로):**
- `detect`: (블러 생략 또는 근사 — 아래 주 참조) → hsv → brightness=V 평균.
- brightnessEma: 첫 프레임=brightness. jumped = |brightness-ema|>brightnessJump (**EMA 갱신 전** 판정). ema += alpha*(brightness-ema).
- red/green 마스크: inRange(+OR) → morphOpen → morphClose (morphKernel).
- thr(color): _lastRaw==color면 minAreaRatio*validExitFactor, 아니면 minAreaRatio.
- _analyze(mask): findContours → 없으면 ColorStat(). 최대 면적 contour → area,perimeter,circularity, areaRatio=area/roiArea. valid = minAreaRatio≤areaRatio≤maxAreaRatio ∧ circularity≥minCircularity. (min_area_ratio는 thr()의 완화값 사용.)
- 결정 우선순위: brightness<minBrightness→NONE/too_dark; jumped→NONE/brightness_jump; red.valid∧green.valid→면적 큰 쪽(red 우선 `>=`); red.valid→RED; green.valid→GREEN; else NONE(oversized=max(area_ratio)>maxAreaRatio ? blob_too_large : no_blob).
- _lastRaw 갱신.

**주(블러):** OpenCV GaussianBlur 정확 재현은 어렵다. 미러링 테스트가 통과하도록: 블러를 (a) 생략하거나 (b) 간단한 3x3/5x5 박스 근사로 구현. Python 테스트의 원은 크고(반지름 25/200) 색이 뚜렷해 블러 유무로 판정이 안 바뀐다 — 블러 생략으로 시작하고, 미러링 테스트가 다 통과하면 유지. (통합·실환경에서 블러 필요하면 카메라 조각에서 추가.) 이 결정을 코드 주석에 명시.

- [ ] **Step 1: 실패 테스트 작성 (test_detector.py 미러링)**

```dart
// test/vision/color_detector_test.dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/vision/detector_config.dart';
import 'package:clip_sense/vision/roi_image.dart';
import 'package:clip_sense/vision/color_detector.dart';

const size = 200;

// 회색 배경 + 중앙 채운 원(BGR). Python test_detector.py의 frame() 재현.
RoiImage frame({int bg = 80, List<int>? circleBgr, int r = 0}) {
  final bytes = Uint8List(size * size * 3);
  for (var i = 0; i < size * size; i++) {
    bytes[i * 3] = bg; bytes[i * 3 + 1] = bg; bytes[i * 3 + 2] = bg;
  }
  if (circleBgr != null) {
    const cx = size ~/ 2, cy = size ~/ 2;
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final dx = x - cx, dy = y - cy;
        if (dx * dx + dy * dy <= r * r) {
          final idx = (y * size + x) * 3;
          bytes[idx] = circleBgr[0];
          bytes[idx + 1] = circleBgr[1];
          bytes[idx + 2] = circleBgr[2];
        }
      }
    }
  }
  return RoiImage(size, size, bytes);
}

const red = [40, 40, 235];    // BGR
const green = [70, 210, 80];

void main() {
  test('빈 회색 프레임 → NONE/no_blob', () {
    final d = ColorDetector(const DetectorConfig.defaults());
    final r = d.detect(frame());
    expect(r.raw, rawNone);
    expect(r.reason, 'no_blob');
  });

  test('빨간 원 → RED', () {
    final d = ColorDetector(const DetectorConfig.defaults());
    final r = d.detect(frame(circleBgr: red, r: 25));
    expect(r.raw, rawRed);
  });

  test('초록 원 → GREEN', () {
    final d = ColorDetector(const DetectorConfig.defaults());
    final r = d.detect(frame(circleBgr: green, r: 25));
    expect(r.raw, rawGreen);
  });

  test('어두운 프레임 → too_dark', () {
    final d = ColorDetector(const DetectorConfig.defaults());
    final r = d.detect(frame(bg: 10));
    expect(r.raw, rawNone);
    expect(r.reason, 'too_dark');
  });

  test('밝기 급변 → brightness_jump', () {
    final d = ColorDetector(const DetectorConfig.defaults());
    d.detect(frame(bg: 80));       // ema 초기화
    final r = d.detect(frame(bg: 200));
    expect(r.raw, rawNone);
    expect(r.reason, 'brightness_jump');
  });
}
```

주: test_detector.py의 나머지 케이스(6~)도 원본을 보고 미러링에 포함하라(히스테리시스·blob_too_large 등). 위는 대표 5개.

- [ ] **Step 2: 테스트 실패 확인** — Run: `cd app && flutter test test/vision/color_detector_test.dart` → FAIL.

- [ ] **Step 3: 구현** — detector.py의 ColorDetector를 위 로직대로 이식. 블러는 주석과 함께 생략.

- [ ] **Step 4: 테스트 통과 + 분석** — Run: `cd app && flutter test test/vision/color_detector_test.dart && flutter analyze lib/vision/color_detector.dart test/vision/color_detector_test.dart` → PASS, No issues.

- [ ] **Step 5: 커밋**

```bash
git add app/lib/vision/color_detector.dart app/test/vision/color_detector_test.dart
git commit -m "feat(vision): add ColorDetector (frame-level RED/GREEN/NONE)"
```

---

## Task 6: signal_state_machine.dart (시간축 상태머신)

**Files:**
- Create: `app/lib/vision/signal_state_machine.dart`
- Test: `app/test/vision/signal_state_machine_test.dart`

**Interfaces:**
- Consumes: DetectorConfig, raw 상수('RED'/'GREEN'/'NONE').
- Produces: `class Transition { double t; String oldState; String newState; }`, `class SignalStateMachine { SignalStateMachine(DetectorConfig); String state; Transition? update(double t, String raw, {String reason}); void resume(); }`. 상수: `stateRed`,`stateGreen`,`stateGreenBlink`,`stateUnknown`.

**로직 (detector.py SignalStateMachine 그대로):** §설계 4.6과 detector.py 195~277 라인 정확 이식. HOLD_REASONS={'too_dark','brightness_jump','blob_too_large','camera_fail'}. _countBlinkToggles, resume, update의 우선순위 전부 동일.

- [ ] **Step 1: 실패 테스트 작성 (test_state_machine.py 13케이스 미러링)**

test_state_machine.py의 `run(fps, segments)`·`blink_segments`·`states_of` 헬퍼를 Dart로 옮기고, 13개 check를 그대로 미러링한다. 핵심 케이스:

```dart
// test/vision/signal_state_machine_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/vision/detector_config.dart';
import 'package:clip_sense/vision/signal_state_machine.dart';

const rawRed = 'RED', rawGreen = 'GREEN', rawNone = 'NONE';

// (지속초, raw[, reason]) 시퀀스를 fps로 주입 → 전환 리스트.
(List<Transition>, SignalStateMachine) run(
    double fps, List<List<dynamic>> segments) {
  final sm = SignalStateMachine(const DetectorConfig.defaults());
  final trs = <Transition>[];
  var frame = 0;
  for (final seg in segments) {
    final duration = (seg[0] as num).toDouble();
    final raw = seg[1] as String;
    final reason = seg.length > 2 ? seg[2] as String : '';
    final count = (duration * fps).round();
    for (var i = 0; i < count; i++) {
      final tr = sm.update(frame / fps, raw, reason: reason);
      if (tr != null) trs.add(tr);
      frame++;
    }
  }
  return (trs, sm);
}

List<List<dynamic>> blinkSegments(double seconds, {double period = 1.0}) {
  final segs = <List<dynamic>>[];
  var t = 0.0;
  while (t < seconds - 1e-9) {
    segs.add([period / 2, rawGreen]);
    segs.add([period / 2, rawNone]);
    t += period;
  }
  return segs;
}

List<String> statesOf(List<Transition> trs) => trs.map((t) => t.newState).toList();

void main() {
  test('기본 사이클 30fps: RED→GREEN→BLINK→RED', () {
    final (trs, _) = run(30, [
      [5, rawRed], [4, rawGreen], ...blinkSegments(3), [4, rawRed],
    ]);
    expect(statesOf(trs),
        [stateRed, stateGreen, stateGreenBlink, stateRed]);
  });

  test('15fps / 60fps에서도 같은 사이클', () {
    for (final fps in [15.0, 60.0]) {
      final (trs, _) = run(fps, [
        [5, rawRed], [4, rawGreen], ...blinkSegments(3), [4, rawRed],
      ]);
      expect(statesOf(trs),
          [stateRed, stateGreen, stateGreenBlink, stateRed]);
    }
  });

  test('1프레임 글리치 무시', () {
    final (trs, _) = run(30, [[3, rawRed], [1 / 30, rawGreen], [3, rawRed]]);
    expect(statesOf(trs), [stateRed]);
  });

  test('점멸 후 안정 초록 복귀', () {
    final (trs, _) = run(30, [[4, rawGreen], ...blinkSegments(3), [5, rawGreen]]);
    expect(statesOf(trs), [stateGreen, stateGreenBlink, stateGreen]);
  });

  test('점멸 중 UNKNOWN 없음', () {
    final (trs, _) = run(30, [[4, rawGreen], ...blinkSegments(6)]);
    expect(statesOf(trs).contains(stateUnknown), isFalse);
  });

  test('소등 1.5초 후 UNKNOWN', () {
    final (trs, _) = run(30, [[3, rawRed], [3, rawNone]]);
    final u = trs.where((t) => t.newState == stateUnknown).toList();
    expect(u.length, 1);
    expect(u.first.t, inInclusiveRange(3.0 + 1.4, 3.0 + 1.8));
  });

  test('긴 안정 구간 전환 1회', () {
    final (trs, _) = run(30, [[30, rawRed]]);
    expect(statesOf(trs), [stateRed]);
  });

  test('느린 점멸 플래핑 없음', () {
    final (trs, _) = run(30, [[4, rawGreen], ...blinkSegments(6, period: 1.5)]);
    expect(statesOf(trs), [stateGreen, stateGreenBlink]);
  });

  test('주기적 플리커에 전환 없음', () {
    final flicker = <List<dynamic>>[];
    for (var i = 0; i < 100; i++) {
      flicker.addAll([[1 / 30, rawRed], [1 / 30, rawRed], [1 / 30, rawNone]]);
    }
    final (trs, _) = run(30, flicker);
    expect(statesOf(trs), isEmpty);
  });

  test('짧은 dropout이 가짜 점멸 안 만듦', () {
    final (trs, _) = run(30, [
      [3, rawGreen], [2 / 30, rawNone], [0.7, rawGreen],
      [2 / 30, rawNone], [3, rawGreen],
    ]);
    expect(statesOf(trs), [stateGreen]);
  });

  test('판정 보류 NONE은 점멸로 안 잡힘', () {
    final banding = <List<dynamic>>[[3, rawGreen]];
    for (var i = 0; i < 6; i++) {
      banding.addAll([[0.6, rawGreen], [0.4, rawNone, 'brightness_jump']]);
    }
    final (trs, _) = run(30, banding);
    expect(statesOf(trs), [stateGreen]);
  });

  test('실제 소등 패턴은 여전히 점멸 감지', () {
    final realBlink = <List<dynamic>>[[3, rawGreen]];
    for (var i = 0; i < 6; i++) {
      realBlink.addAll([[0.6, rawGreen], [0.4, rawNone]]);
    }
    final (trs, _) = run(30, realBlink);
    expect(statesOf(trs), [stateGreen, stateGreenBlink]);
  });

  test('판정 보류 지속 → UNKNOWN 정상 전환', () {
    final (trs, _) = run(30, [[3, rawRed], [2.5, rawNone, 'camera_fail']]);
    expect(statesOf(trs), [stateRed, stateUnknown]);
  });
}
```

- [ ] **Step 2: 테스트 실패 확인** — Run: `cd app && flutter test test/vision/signal_state_machine_test.dart` → FAIL.

- [ ] **Step 3: 구현** — detector.py 195~277을 정확 이식. deque는 `dart:collection`의 Queue 또는 List. 시간 기반 prune, run 접기, 토글 카운트, 우선순위 전부 동일.

- [ ] **Step 4: 테스트 통과 + 분석** — Run: `cd app && flutter test test/vision/signal_state_machine_test.dart && flutter analyze lib/vision/signal_state_machine.dart test/vision/signal_state_machine_test.dart` → PASS (13+), No issues.

- [ ] **Step 5: 커밋**

```bash
git add app/lib/vision/signal_state_machine.dart app/test/vision/signal_state_machine_test.dart
git commit -m "feat(vision): add SignalStateMachine (debounce + blink detection)"
```

---

## Task 7: digit_reader.dart (7세그먼트 잔여시간 판독)

**Files:**
- Create: `app/lib/vision/digit_reader.dart`
- Test: `app/test/vision/digit_reader_test.dart`

**Interfaces:**
- Consumes: RoiImage, bgrToHsv, inRangeHsv, morphClose, DetectorConfig.
- Produces: `class DigitReader { DigitReader(DetectorConfig); int? readFrame(RoiImage); int? read(RoiImage?); }`. 상수: `kDigitPatterns`(Map), `kSegmentRegions`(Map).

**로직 (digits.py 그대로):** §설계 4.8과 digits.py 42~184 정확 이식. red_hsv는 digitRedHsv 사용. _mask(블러+inRange+OR+CLOSE), _splitCells(열 투영·노이즈 필터), _segRatio, _decodeCell(크기·fill·좁은"1"·aspect·max_fill·이중임계·패턴룩업), readFrame(셀 1~2, 35% 높이 필터, 전부-아니면-무), read(다수결 stable_votes).

**테스트:** digits.py의 `draw_seven_segment`를 Dart 테스트 헬퍼로 이식해 합성 숫자 이미지를 만들어 검증. test_digits.py 케이스 미러링(각 숫자 0~9 그려 판독, 모호/과대 셀 → None, roi=null → None 투표, 다수결).

- [ ] **Step 1: 실패 테스트 작성 (test_digits.py 미러링)**

test_digits.py를 읽고 그 케이스를 미러링한다. `draw_seven_segment`(digits.py 187~209)를 Dart 헬퍼 `drawSevenSegment(bytes, w, h, number, x, y, digitW, digitH, colorBgr)`로 이식(빨강 세그먼트 사각 그리기). 대표 케이스:

```dart
// test/vision/digit_reader_test.dart (골격)
// - 각 숫자 d in 0..9: 빨강(BGR 0,0,235)으로 draw → readFrame == d
// - 두 자리(예 12) draw → readFrame == 12
// - 빈/회색 프레임 → null
// - 과대 단색 블롭 → null
// - read(): 같은 값 3프레임 → 그 값; 흔들리면 null; read(null) → None 투표
```
(구현자는 test_digits.py의 실제 케이스·허용오차를 그대로 옮긴다. 세그먼트 그리기 좌표는 digits.py draw_seven_segment와 동일해야 패턴이 맞다.)

- [ ] **Step 2: 테스트 실패 확인** — Run: `cd app && flutter test test/vision/digit_reader_test.dart` → FAIL.

- [ ] **Step 3: 구현** — digits.py DigitReader 정확 이식. Counter는 `Map<int,int>`. deque는 고정길이 List/Queue.

- [ ] **Step 4: 테스트 통과 + 분석** — Run: `cd app && flutter test test/vision/digit_reader_test.dart && flutter analyze lib/vision/digit_reader.dart test/vision/digit_reader_test.dart` → PASS, No issues.

- [ ] **Step 5: 전체 스위트 확인**

Run: `cd app && flutter test`
Expected: All tests passed (기존 111 + vision 신규 ≈ 111+40). 회귀 없어야.

- [ ] **Step 6: 커밋**

```bash
git add app/lib/vision/digit_reader.dart app/test/vision/digit_reader_test.dart
git commit -m "feat(vision): add DigitReader (7-segment countdown decode)"
```

---

## Self-Review (계획 작성자 수행 완료)

- **스펙 커버리지:** config(T1)·roi_image/HSV(T2)·image_ops(T3)·contours(T4)·color_detector(T5)·state_machine(T6)·digit_reader(T7) — 설계 §4.1의 7파일 전부 ✅. Python 미러링(test_detector/state_machine/digits) ✅. 안전(불확실→NONE/UNKNOWN, 전부-아니면-무) ✅. config.json 실제값 ✅.
- **플레이스홀더:** T4(contours)·T5(color_detector 나머지 케이스)·T7(digit_reader 케이스)는 알고리즘·시그니처를 명시하되 전체 코드 대신 "정확 이식" 지시 — 원본 Python이 이미 저장소에 있어 구현자가 참조 가능(파일 경로 명시). 순수 전사가 아닌 알고리즘 이식이라 이 방식이 맞음. 단 구현자 dispatch 시 원본 Python 파일 경로를 반드시 전달할 것.
- **타입 일관성:** RoiImage(T2) ↔ 모든 검출기 입력. inRangeHsv/morph(T3) ↔ color_detector·digit_reader. findContours+contourArea+circularity(T4) ↔ color_detector._analyze. DetectorConfig(T1) ↔ 모든 생성자. raw/state/reason 문자열 상수 통일.
- **주의(구현자):** 각 구현자에게 대응 Python 원본 경로를 전달(detector.py, digits.py, scripts/test_*.py). 블러는 T5에서 생략(주석). 경계추적·형태학 미세차는 테스트 허용오차(closeTo)로 흡수. 이 조각은 앱에 배선 안 함(toReading 연결·카메라·allowSingleSource 복귀는 다음 조각).

---

## Execution Handoff

계획은 subagent-driven-development로 실행한다(Task별 fresh 구현자 + 리뷰). 각 구현자에게 대응 Python 원본 파일 경로를 반드시 전달한다(정확 이식이므로).
