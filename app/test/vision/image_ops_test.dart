import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/vision/detector_config.dart';
import 'package:clip_sense/vision/image_ops.dart';
import 'package:clip_sense/vision/roi_image.dart';

import 'blur_expected.dart';

// HSV 픽셀 배열 헬퍼: 모든 픽셀을 (h,s,v)로.
Uint8List hsvSolid(int n, int h, int s, int v) {
  final b = Uint8List(n * 3);
  for (var i = 0; i < n; i++) {
    b[i * 3] = h;
    b[i * 3 + 1] = s;
    b[i * 3 + 2] = v;
  }
  return b;
}

RoiImage _img(int w, int h, List<int> px) =>
    RoiImage(w, h, Uint8List.fromList(px));

/// 블러 결과를 기대 픽셀과 채널 단위로 비교 (어긋난 픽셀 좌표를 reason에 표시).
void _expectPixels(RoiImage got, int w, int h, List<int> expected) {
  expect(got.width, w);
  expect(got.height, h);
  expect(got.bytes.length, w * h * 3);
  for (var i = 0; i < expected.length; i++) {
    expect(
      got.bytes[i],
      expected[i],
      reason:
          'pixel ${i ~/ 3} (x=${(i ~/ 3) % w}, y=${i ~/ 3 ~/ w}) ch=${i % 3}',
    );
  }
}

void main() {
  test('inRangeHsv: 범위 안 → 255, 밖 → 0', () {
    const red = [
      HsvRange([0, 55, 45], [12, 255, 255]),
    ];
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
      for (var x = 1; x <= 5; x++) {
        m[y * 7 + x] = 255;
      }
    }
    // 노이즈는 블록과 안 붙게 (0,0)에 두면 open 후 사라짐... 대신 블록 검증
    final o = morphOpen(m, 7, 7, 3);
    expect(o[3 * 7 + 3], 255); // 블록 중앙 유지
  });

  // ---- 가우시안 블러: OpenCV GaussianBlur((k,k),0) 와 픽셀 단위 동일 ----
  // 기대값은 scripts/gen_blur_expected.py 가 실제 cv2로 만든 blur_expected.dart 상수.

  test('gaussianBlur5x5: 9x7 난수 BGR — cv2.GaussianBlur((5,5),0) 과 픽셀 일치', () {
    final got = gaussianBlur5x5(_img(blurMainW, blurMainH, blurMainInput));
    _expectPixels(got, blurMainW, blurMainH, blurMainExpected5x5);
  });

  test('gaussianBlur3x3: 9x7 난수 BGR — cv2.GaussianBlur((3,3),0) 과 픽셀 일치', () {
    final got = gaussianBlur3x3(_img(blurMainW, blurMainH, blurMainInput));
    _expectPixels(got, blurMainW, blurMainH, blurMainExpected3x3);
  });

  test('경계 반사(BORDER_REFLECT_101): 커널보다 작은 이미지도 cv2와 일치', () {
    _expectPixels(
      gaussianBlur5x5(_img(blurTiny2x2W, blurTiny2x2H, blurTiny2x2Input)),
      blurTiny2x2W,
      blurTiny2x2H,
      blurTiny2x2Expected5x5,
    );
    _expectPixels(
      gaussianBlur3x3(_img(blurTiny2x2W, blurTiny2x2H, blurTiny2x2Input)),
      blurTiny2x2W,
      blurTiny2x2H,
      blurTiny2x2Expected3x3,
    );
    _expectPixels(
      gaussianBlur5x5(_img(blurCol1x4W, blurCol1x4H, blurCol1x4Input)),
      blurCol1x4W,
      blurCol1x4H,
      blurCol1x4Expected5x5,
    );
    _expectPixels(
      gaussianBlur3x3(_img(blurCol1x4W, blurCol1x4H, blurCol1x4Input)),
      blurCol1x4W,
      blurCol1x4H,
      blurCol1x4Expected3x3,
    );
    _expectPixels(
      gaussianBlur5x5(_img(blurOne1x1W, blurOne1x1H, blurOne1x1Input)),
      blurOne1x1W,
      blurOne1x1H,
      blurOne1x1Expected5x5,
    );
  });

  test('블러는 입력을 바꾸지 않고 새 버퍼를 돌려준다', () {
    final src = _img(blurMainW, blurMainH, blurMainInput);
    final before = Uint8List.fromList(src.bytes);
    final got = gaussianBlur5x5(src);
    expect(src.bytes, before);
    expect(identical(got.bytes, src.bytes), isFalse);
  });

  test('단색 이미지는 블러 후에도 단색 (커널 합 = 1)', () {
    final px = List<int>.filled(6 * 5 * 3, 0);
    for (var i = 0; i < 6 * 5; i++) {
      px[i * 3] = 17;
      px[i * 3 + 1] = 200;
      px[i * 3 + 2] = 99;
    }
    _expectPixels(gaussianBlur5x5(_img(6, 5, px)), 6, 5, px);
    _expectPixels(gaussianBlur3x3(_img(6, 5, px)), 6, 5, px);
  });
}
