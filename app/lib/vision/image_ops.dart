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
