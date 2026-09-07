/// 카메라 원시 프레임의 중앙 ROI만 BGR로 변환한다.
///
/// camera 플러그인 타입을 받지 않는 순수 계층이라 stride와 픽셀 배치를 가짜
/// 바이트로 완전히 검증할 수 있다. 전체 프레임을 변환하지 않아 스트림 처리량도
/// 중앙 ROI 크기에 비례한다.
library;

import 'dart:typed_data';

import '../vision/roi_image.dart';

class YuvPlanes {
  final Uint8List y;
  final Uint8List u;
  final Uint8List v;
  final int width;
  final int height;
  final int yRowStride;
  final int uvRowStride;
  final int uvPixelStride;

  const YuvPlanes({
    required this.y,
    required this.u,
    required this.v,
    required this.width,
    required this.height,
    required this.yRowStride,
    required this.uvRowStride,
    required this.uvPixelStride,
  });
}

/// 프레임 안의 중앙 ROI 사각형(픽셀).
class CropRect {
  final int x;
  final int y;
  final int width;
  final int height;

  const CropRect(this.x, this.y, this.width, this.height);
}

/// [width]x[height] 프레임에서 가로·세로 [roiFrac] 비율의 중앙 사각형.
/// roiFrac 이 (0, 1] 밖이면 RangeError, 크기가 0 이하면 ArgumentError.
CropRect centerCrop(int width, int height, double roiFrac) {
  if (width <= 0 || height <= 0) {
    throw ArgumentError('frame width and height must be positive');
  }
  if (!roiFrac.isFinite || roiFrac <= 0 || roiFrac > 1) {
    throw RangeError.range(roiFrac, 0, 1, 'roiFrac');
  }

  final cropWidth = (width * roiFrac).round().clamp(1, width);
  final cropHeight = (height * roiFrac).round().clamp(1, height);
  return CropRect(
    (width - cropWidth) ~/ 2,
    (height - cropHeight) ~/ 2,
    cropWidth,
    cropHeight,
  );
}

int _byteAt(Uint8List bytes, int index, String plane) {
  if (index < 0 || index >= bytes.length) {
    throw FormatException('$plane plane is shorter than its stride metadata');
  }
  return bytes[index];
}

int _clampByte(int value) => value.clamp(0, 255);

/// Android YUV_420_888(video-range BT.601) 프레임의 중앙 ROI를 BGR로 변환한다.
/// U/V plane의 row stride와 pixel stride가 서로 다른 기기도 지원한다.
RoiImage yuv420ToRoiBgr(YuvPlanes planes, double roiFrac) {
  if (planes.yRowStride <= 0 ||
      planes.uvRowStride <= 0 ||
      planes.uvPixelStride <= 0) {
    throw ArgumentError('plane strides must be positive');
  }
  final crop = centerCrop(planes.width, planes.height, roiFrac);
  final out = Uint8List(crop.width * crop.height * 3);

  var dst = 0;
  for (var dy = 0; dy < crop.height; dy++) {
    final sy = crop.y + dy;
    for (var dx = 0; dx < crop.width; dx++) {
      final sx = crop.x + dx;
      final yIndex = sy * planes.yRowStride + sx;
      final uvIndex =
          (sy ~/ 2) * planes.uvRowStride + (sx ~/ 2) * planes.uvPixelStride;

      final y = _byteAt(planes.y, yIndex, 'Y');
      final u = _byteAt(planes.u, uvIndex, 'U') - 128;
      final v = _byteAt(planes.v, uvIndex, 'V') - 128;

      // ITU-R BT.601 limited/video range. Android 카메라의 YUV_420_888과
      // iOS bi-planar video range가 사용하는 표준 정수식이다.
      final c = (y - 16).clamp(0, 255);
      final r = (298 * c + 409 * v + 128) >> 8;
      final g = (298 * c - 100 * u - 208 * v + 128) >> 8;
      final b = (298 * c + 516 * u + 128) >> 8;

      out[dst++] = _clampByte(b);
      out[dst++] = _clampByte(g);
      out[dst++] = _clampByte(r);
    }
  }
  return RoiImage(crop.width, crop.height, out);
}

/// iOS BGRA8888 프레임의 중앙 ROI를 BGR로 변환한다. 행 끝 padding은
/// [bytesPerRow]로 건너뛰고 alpha 채널은 버린다.
RoiImage bgra8888ToRoiBgr(
  Uint8List bytes,
  int width,
  int height,
  int bytesPerRow,
  double roiFrac,
) {
  if (bytesPerRow < width * 4) {
    throw ArgumentError('bytesPerRow is too small for BGRA8888 width');
  }
  final crop = centerCrop(width, height, roiFrac);
  final out = Uint8List(crop.width * crop.height * 3);

  var dst = 0;
  for (var dy = 0; dy < crop.height; dy++) {
    final sy = crop.y + dy;
    for (var dx = 0; dx < crop.width; dx++) {
      final sx = crop.x + dx;
      final src = sy * bytesPerRow + sx * 4;
      out[dst++] = _byteAt(bytes, src, 'BGRA');
      out[dst++] = _byteAt(bytes, src + 1, 'BGRA');
      out[dst++] = _byteAt(bytes, src + 2, 'BGRA');
    }
  }
  return RoiImage(crop.width, crop.height, out);
}

/// BGR ROI를 시계 방향 0/90/180/270도로 회전한다. 카메라 센서 방향을
/// 정규화해 세로형 7-세그먼트 숫자가 옆으로 눕지 않게 하는 순수 함수다.
RoiImage rotateBgr(RoiImage source, int clockwiseDegrees) {
  final degrees = ((clockwiseDegrees % 360) + 360) % 360;
  if (degrees == 0) return source;
  if (degrees != 90 && degrees != 180 && degrees != 270) {
    throw ArgumentError.value(
      clockwiseDegrees,
      'clockwiseDegrees',
      'must be a multiple of 90 degrees',
    );
  }

  final srcW = source.width;
  final srcH = source.height;
  final dstW = degrees == 180 ? srcW : srcH;
  final dstH = degrees == 180 ? srcH : srcW;
  final out = Uint8List(dstW * dstH * 3);

  for (var sy = 0; sy < srcH; sy++) {
    for (var sx = 0; sx < srcW; sx++) {
      late final int dx;
      late final int dy;
      switch (degrees) {
        case 90:
          dx = srcH - 1 - sy;
          dy = sx;
          break;
        case 180:
          dx = srcW - 1 - sx;
          dy = srcH - 1 - sy;
          break;
        case 270:
          dx = sy;
          dy = srcW - 1 - sx;
          break;
      }
      final src = (sy * srcW + sx) * 3;
      final dst = (dy * dstW + dx) * 3;
      out[dst] = source.bytes[src];
      out[dst + 1] = source.bytes[src + 1];
      out[dst + 2] = source.bytes[src + 2];
    }
  }
  return RoiImage(dstW, dstH, out);
}

/// 이미 BGR 인 전체 프레임(예: 디코드된 JPEG)의 중앙 ROI 만 복사한다.
/// roiFrac 1.0 이면 복사 없이 같은 객체를 돌려준다.
RoiImage bgrCenterCrop(RoiImage full, double roiFrac) {
  final crop = centerCrop(full.width, full.height, roiFrac);
  if (crop.width == full.width && crop.height == full.height) return full;
  if (full.bytes.length < full.width * full.height * 3) {
    throw ArgumentError('BGR frame bytes are shorter than width*height*3');
  }
  final out = Uint8List(crop.width * crop.height * 3);
  final rowBytes = crop.width * 3;
  for (var dy = 0; dy < crop.height; dy++) {
    final src = ((crop.y + dy) * full.width + crop.x) * 3;
    out.setRange(dy * rowBytes, (dy + 1) * rowBytes, full.bytes, src);
  }
  return RoiImage(crop.width, crop.height, out);
}
