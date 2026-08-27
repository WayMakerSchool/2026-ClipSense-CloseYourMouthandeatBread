import 'dart:typed_data';

import 'package:clip_sense/camera/frame_converter.dart';
import 'package:clip_sense/vision/roi_image.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('yuv420ToRoiBgr', () {
    test('row/pixel stride를 따르며 중앙 ROI만 BT.601 BGR로 변환한다', () {
      // video-range BT.601의 순수 초록에 가까운 YUV: BGR ≈ [1, 255, 0].
      final y = Uint8List(6 * 4)..fillRange(0, 6 * 4, 145);
      final u = Uint8List(8)..fillRange(0, 8, 54);
      final v = Uint8List(8)..fillRange(0, 8, 34);

      final roi = yuv420ToRoiBgr(
        YuvPlanes(
          y: y,
          u: u,
          v: v,
          width: 4,
          height: 4,
          yRowStride: 6,
          uvRowStride: 5,
          uvPixelStride: 2,
        ),
        0.5,
      );

      expect(roi.width, 2);
      expect(roi.height, 2);
      expect(roi.bytes, [1, 255, 0, 1, 255, 0, 1, 255, 0, 1, 255, 0]);
    });

    test('잘못된 plane 메타데이터는 조용히 오염된 픽셀을 만들지 않고 실패한다', () {
      expect(
        () => yuv420ToRoiBgr(
          YuvPlanes(
            y: Uint8List(1),
            u: Uint8List(1),
            v: Uint8List(1),
            width: 4,
            height: 4,
            yRowStride: 4,
            uvRowStride: 2,
            uvPixelStride: 1,
          ),
          1,
        ),
        throwsFormatException,
      );
    });
  });

  group('bgra8888ToRoiBgr', () {
    test('행 padding과 alpha를 버리고 정확한 중앙 ROI를 자른다', () {
      const rowStride = 20; // 4 pixels * 4 bytes + 4 padding bytes
      final bytes = Uint8List(rowStride * 4);

      void pixel(int x, int y, int b, int g, int r) {
        final offset = y * rowStride + x * 4;
        bytes[offset] = b;
        bytes[offset + 1] = g;
        bytes[offset + 2] = r;
        bytes[offset + 3] = 255;
      }

      pixel(1, 1, 11, 12, 13);
      pixel(2, 1, 21, 22, 23);
      pixel(1, 2, 31, 32, 33);
      pixel(2, 2, 41, 42, 43);

      final roi = bgra8888ToRoiBgr(bytes, 4, 4, rowStride, 0.5);

      expect(roi.width, 2);
      expect(roi.height, 2);
      expect(roi.bytes, [11, 12, 13, 21, 22, 23, 31, 32, 33, 41, 42, 43]);
    });

    test('ROI 비율 범위를 검증한다', () {
      expect(
        () => bgra8888ToRoiBgr(Uint8List(16), 1, 1, 4, 0),
        throwsRangeError,
      );
      expect(
        () => bgra8888ToRoiBgr(Uint8List(16), 1, 1, 4, 1.1),
        throwsRangeError,
      );
    });
  });

  group('rotateBgr', () {
    RoiImage numberedImage() {
      // 3x2 픽셀의 B 채널을 행 우선 1..6으로 둔다.
      return RoiImage(
        3,
        2,
        Uint8List.fromList([
          1,
          0,
          0,
          2,
          0,
          0,
          3,
          0,
          0,
          4,
          0,
          0,
          5,
          0,
          0,
          6,
          0,
          0,
        ]),
      );
    }

    List<int> blue(RoiImage image) => [
      for (var i = 0; i < image.bytes.length; i += 3) image.bytes[i],
    ];

    test('90도 시계 방향 회전', () {
      final rotated = rotateBgr(numberedImage(), 90);
      expect((rotated.width, rotated.height), (2, 3));
      expect(blue(rotated), [4, 1, 5, 2, 6, 3]);
    });

    test('180도 회전', () {
      final rotated = rotateBgr(numberedImage(), 180);
      expect((rotated.width, rotated.height), (3, 2));
      expect(blue(rotated), [6, 5, 4, 3, 2, 1]);
    });

    test('270도 시계 방향 회전', () {
      final rotated = rotateBgr(numberedImage(), 270);
      expect((rotated.width, rotated.height), (2, 3));
      expect(blue(rotated), [3, 6, 2, 5, 1, 4]);
    });
  });
}
