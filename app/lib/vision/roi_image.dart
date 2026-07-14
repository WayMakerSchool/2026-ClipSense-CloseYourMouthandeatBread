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
