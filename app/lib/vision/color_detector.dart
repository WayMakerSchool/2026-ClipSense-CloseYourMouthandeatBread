/// HSV 색상 마스킹 + blob 분석으로 프레임 단위 판정(RED/GREEN/NONE)을 낸다.
/// detector.py의 ColorDetector 이식.
///
/// 신뢰도 낮은 프레임은 정직하게 NONE 처리한다 (reason에 근거 기록):
/// - too_dark: ROI 평균 밝기가 임계 미만이면서 유효 blob도 없음 (렌즈/ROI 가림).
///   야간처럼 배경만 어둡고 램프가 또렷하면 정상 판정한다.
/// - brightness_jump: 평균 밝기가 이동평균 대비 급변 (가림/조명 급변 순간)
/// - blob_too_large: 검출 blob이 ROI 대부분을 덮음 (신호등이 아닌 물체)
/// - no_blob: 유효한 색상 blob 없음
///
/// 검출 히스테리시스: 직전 프레임에 검출된 색은 면적 임계를 완화해
/// (exit_factor 배) 경계값 부근에서 GREEN↔NONE이 튀는 것을 줄인다.
library;

import 'dart:typed_data';

import 'contours.dart';
import 'detector_config.dart';
import 'image_ops.dart';
import 'roi_image.dart';

// 프레임 단위 판정 값 (detector.py RAW_RED/RAW_GREEN/RAW_NONE).
const String rawRed = 'RED';
const String rawGreen = 'GREEN';
const String rawNone = 'NONE';

/// 한 색상 마스크의 분석 결과.
class ColorStat {
  final double areaRatio; // 최대 blob 면적 / ROI 면적
  final double circularity; // 4πA/P² (원=1.0, 보행자 아이콘은 낮음)
  final double aspectRatio; // bbox 가로/세로 (램프≈1, 7세그 숫자 획은 가늘고 김)
  final bool valid;

  const ColorStat({
    this.areaRatio = 0.0,
    this.circularity = 0.0,
    this.aspectRatio = 0.0,
    this.valid = false,
  });
}

/// 프레임 1장에 대한 판정 결과.
class FrameResult {
  final String raw;
  final ColorStat red;
  final ColorStat green;
  final double brightness; // ROI 평균 밝기 (HSV V)
  final String
  reason; // raw=NONE인 이유: too_dark / brightness_jump / blob_too_large / no_blob

  const FrameResult({
    this.raw = rawNone,
    this.red = const ColorStat(),
    this.green = const ColorStat(),
    this.brightness = 0.0,
    this.reason = '',
  });
}

class ColorDetector {
  final DetectorConfig _cfg;
  double? _brightnessEma;
  String _lastRaw = rawNone;

  ColorDetector(this._cfg);

  Uint8List _mask(Uint8List hsv, int w, int h, List<HsvRange> ranges) {
    final n = w * h;
    var mask = inRangeHsv(hsv, n, ranges);
    mask = morphOpen(mask, w, h, _cfg.morphKernel);
    mask = morphClose(mask, w, h, _cfg.morphKernel);
    return mask;
  }

  ColorStat _analyze(
    Uint8List mask,
    int w,
    int h,
    int roiArea,
    double minAreaRatio,
  ) {
    final contours = findContours(mask, w, h);
    if (contours.isEmpty) return const ColorStat();

    Contour? largest;
    var largestArea = -1.0;
    for (final c in contours) {
      final a = contourArea(c);
      if (a > largestArea) {
        largestArea = a;
        largest = c;
      }
    }
    final area = largestArea;
    final perimeter = arcLength(largest!);
    final circ = perimeter > 0
        ? (4 * 3.141592653589793 * area / (perimeter * perimeter))
        : 0.0;
    final areaRatio = area / roiArea;
    final (bw, bh) = largest.boundingSize;
    final aspectRatio = bh > 0 ? bw / bh : 0.0;
    // 신호등 램프는 bbox가 정사각형에 가깝다. 잔여시간 7세그 숫자의 획은
    // 가늘고 길어(실측 0.12~0.42) 면적·원형도만으로는 걸러지지 않는다.
    // ROI를 좁힐수록 숫자가 면적 기준을 넘기므로 형태로 배제한다.
    final shapeOk =
        _cfg.minAspectRatio <= aspectRatio &&
        aspectRatio <= _cfg.maxAspectRatio;
    final valid =
        minAreaRatio <= areaRatio &&
        areaRatio <= _cfg.maxAreaRatio &&
        circ >= _cfg.minCircularity &&
        shapeOk;
    return ColorStat(
      areaRatio: areaRatio,
      circularity: circ,
      aspectRatio: aspectRatio,
      valid: valid,
    );
  }

  double _thr(String colorRaw) => _lastRaw == colorRaw
      ? _cfg.minAreaRatio * _cfg.validExitFactor
      : _cfg.minAreaRatio;

  FrameResult detect(RoiImage roi) {
    // detector.py와 같은 위치: HSV 변환 직전 5x5 가우시안 블러(OpenCV와 수치 동일).
    // 실제 카메라 프레임은 LED 램프 안의 픽셀 노이즈로 마스크가 잘게 쪼개져 초록 blob이
    // minAreaRatio 아래로 떨어진다 — 실측(서울 보행등 근접 클립, 중앙 ROI 50%):
    // 블러 없이 0.39% → no_blob, 블러 후 0.62% → GREEN. test/vision/color_detector_real_clip_test 참조.
    final hsv = bgrToHsv(gaussianBlur5x5(roi));
    final w = roi.width, h = roi.height;
    final roiArea = w * h;

    var vSum = 0;
    for (var i = 0; i < roiArea; i++) {
      vSum += hsv[i * 3 + 2];
    }
    final brightness = vSum / roiArea;

    _brightnessEma ??= brightness;
    final jumped = (brightness - _brightnessEma!).abs() > _cfg.brightnessJump;
    _brightnessEma =
        _brightnessEma! +
        _cfg.brightnessEmaAlpha * (brightness - _brightnessEma!);

    // 마스크는 신뢰도와 무관하게 계산 (디버그 뷰 표시용과 동일한 순서 유지).
    final redMask = _mask(hsv, w, h, _cfg.hsvRed);
    final greenMask = _mask(hsv, w, h, _cfg.hsvGreen);

    final red = _analyze(redMask, w, h, roiArea, _thr(rawRed));
    final green = _analyze(greenMask, w, h, roiArea, _thr(rawGreen));

    String raw;
    var reason = '';
    // 밝기 게이트는 "볼 것이 없어서 어두운" 경우에만 건다. 야간에는 배경이
    // 어두운 것이 정상이고, LED 램프는 그 속에서 오히려 또렷하다. 유효한
    // blob이 이미 잡혔는데 평균 밝기만으로 판정을 포기하면 야간에는 늘
    // "확인할 수 없습니다"가 된다.
    final hasLamp = red.valid || green.valid;
    if (brightness < _cfg.minBrightness && !hasLamp) {
      raw = rawNone;
      reason = 'too_dark';
    } else if (jumped) {
      raw = rawNone;
      reason = 'brightness_jump';
    } else if (red.valid && green.valid) {
      raw = red.areaRatio >= green.areaRatio ? rawRed : rawGreen;
    } else if (red.valid) {
      raw = rawRed;
    } else if (green.valid) {
      raw = rawGreen;
    } else {
      raw = rawNone;
      final oversized = red.areaRatio > green.areaRatio
          ? red.areaRatio
          : green.areaRatio;
      reason = oversized > _cfg.maxAreaRatio ? 'blob_too_large' : 'no_blob';
    }

    _lastRaw = raw;
    return FrameResult(
      raw: raw,
      red: red,
      green: green,
      brightness: brightness,
      reason: reason,
    );
  }
}
