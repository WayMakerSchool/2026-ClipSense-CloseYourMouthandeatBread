/// 가우시안 블러 + HSV 마스크(inRange) + 형태학(erode/dilate/open/close). 순수 함수.
library;

import 'dart:typed_data';

import 'detector_config.dart';
import 'roi_image.dart';

/// OpenCV BORDER_REFLECT_101 인덱스 (gfedcb|abcdefgh|gfedcba). 경계 픽셀은 반복하지 않는다.
int _reflect101(int i, int n) {
  if (n == 1) return 0;
  while (i < 0 || i >= n) {
    if (i < 0) i = -i;
    if (i >= n) i = 2 * (n - 1) - i;
  }
  return i;
}

/// 분리형 정수 가우시안 블러 (BGR 3채널). cv2.GaussianBlur(img, (k,k), 0) 와 픽셀 단위 동일.
///
/// sigma=0이면 OpenCV는 고정 커널(5: [1,4,6,4,1]/16, 3: [1,2,1]/4)을 쓰고 8비트 입력은
/// 고정소수점 경로라 중간 반올림이 없다. 그래서 가로 합성곱 결과를 정수로 유지한 뒤
/// 세로 합성곱까지 끝내고 한 번만 (sum + S/2) ~/ S 로 반올림하면 값이 정확히 같다
/// (scripts/gen_blur_expected.py 가 cv2로 검증한 기대값을 image_ops_test.dart 가 고정).
RoiImage _gaussianBlur(RoiImage src, List<int> weights) {
  final w = src.width, h = src.height;
  final k = weights.length, r = k ~/ 2;
  var s = 0;
  for (final wt in weights) {
    s += wt;
  }
  final norm = s * s, half = norm ~/ 2;
  final bytes = src.bytes;

  // 축별 반사 인덱스를 미리 계산 (픽셀마다 while 루프를 돌지 않도록).
  final xs = Int32List(w * k);
  for (var x = 0; x < w; x++) {
    for (var t = 0; t < k; t++) {
      xs[x * k + t] = _reflect101(x + t - r, w);
    }
  }
  final ys = Int32List(h * k);
  for (var y = 0; y < h; y++) {
    for (var t = 0; t < k; t++) {
      ys[y * k + t] = _reflect101(y + t - r, h);
    }
  }

  // 1단계: 가로 합성곱 (정수, 반올림 없음). 최대 255*16 = 4080.
  final tmp = Int32List(w * h * 3);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      var b = 0, g = 0, rr = 0;
      for (var t = 0; t < k; t++) {
        final idx = (row + xs[x * k + t]) * 3;
        final wt = weights[t];
        b += bytes[idx] * wt;
        g += bytes[idx + 1] * wt;
        rr += bytes[idx + 2] * wt;
      }
      final o = (row + x) * 3;
      tmp[o] = b;
      tmp[o + 1] = g;
      tmp[o + 2] = rr;
    }
  }

  // 2단계: 세로 합성곱 + 한 번의 반올림. 최대 4080*16 = 65280.
  final out = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var b = 0, g = 0, rr = 0;
      for (var t = 0; t < k; t++) {
        final idx = (ys[y * k + t] * w + x) * 3;
        final wt = weights[t];
        b += tmp[idx] * wt;
        g += tmp[idx + 1] * wt;
        rr += tmp[idx + 2] * wt;
      }
      final o = (y * w + x) * 3;
      out[o] = (b + half) ~/ norm;
      out[o + 1] = (g + half) ~/ norm;
      out[o + 2] = (rr + half) ~/ norm;
    }
  }
  return RoiImage(w, h, out);
}

/// cv2.GaussianBlur(roi_bgr, (5,5), 0) — detector.py ColorDetector.detect 가 HSV 변환 직전에 쓴다.
RoiImage gaussianBlur5x5(RoiImage src) =>
    _gaussianBlur(src, const [1, 4, 6, 4, 1]);

/// cv2.GaussianBlur(roi_bgr, (3,3), 0) — digits.py DigitReader._mask 가 HSV 변환 직전에 쓴다.
RoiImage gaussianBlur3x3(RoiImage src) => _gaussianBlur(src, const [1, 2, 1]);

/// HSV 픽셀(길이 n*3)에서 범위 안 픽셀을 255로. 범위 여럿이면 OR.
Uint8List inRangeHsv(Uint8List hsv, int n, List<HsvRange> ranges) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    final h = hsv[i * 3], s = hsv[i * 3 + 1], v = hsv[i * 3 + 2];
    for (final r in ranges) {
      if (h >= r.lower[0] &&
          h <= r.upper[0] &&
          s >= r.lower[1] &&
          s <= r.upper[1] &&
          v >= r.lower[2] &&
          v <= r.upper[2]) {
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
            if (val == 255) {
              result = 255;
            }
          } else {
            if (val != 255) {
              result = 0;
            }
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
