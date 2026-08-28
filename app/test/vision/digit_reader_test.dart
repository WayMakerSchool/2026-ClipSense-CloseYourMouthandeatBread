// digits.py DigitReader 이식 검증 + scripts/test_digits.py 케이스 미러링.
// draw_seven_segment(digits.py 187~209)를 Dart로 이식한 drawSevenSegment로
// 합성 7-세그먼트 숫자 셀을 그려 판독기를 검증한다.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/vision/detector_config.dart';
import 'package:clip_sense/vision/roi_image.dart';
import 'package:clip_sense/vision/digit_reader.dart';

// test_digits.py DIGIT_RED = (35, 35, 220) (BGR).
const digitRed = [35, 35, 220];

/// digits.py draw_seven_segment 이식 (테스트 전용, 판독 대상 아님).
/// img: RoiImage와 동일한 BGR bytes를 in-place로 채운다.
void drawSevenSegment(
  Uint8List bytes,
  int imgW,
  int imgH,
  int number,
  int x,
  int y,
  int digitW,
  int digitH,
  List<int> colorBgr, {
  int gap = 6,
}) {
  final text = number.toString();
  final th = digitH ~/ 8 < 2 ? 2 : digitH ~/ 8; // max(2, digit_h // 8)
  for (var i = 0; i < text.length; i++) {
    final d = int.parse(text[i]);
    // DIGIT_PATTERNS에서 값이 d인 첫 키를 찾아 그 문자 집합을 켠다.
    final patternKey = kDigitPatterns.entries
        .firstWhere((e) => e.value == d)
        .key;
    final on = patternKey.split('').toSet();
    final ox = x + i * (digitW + gap);
    final segRects = <String, List<int>>{
      'a': [ox + th, y, ox + digitW - th, y + th],
      'b': [ox + digitW - th, y + th, ox + digitW, y + digitH ~/ 2 - th ~/ 2],
      'c': [
        ox + digitW - th,
        y + digitH ~/ 2 + th ~/ 2,
        ox + digitW,
        y + digitH - th,
      ],
      'd': [ox + th, y + digitH - th, ox + digitW - th, y + digitH],
      'e': [ox, y + digitH ~/ 2 + th ~/ 2, ox + th, y + digitH - th],
      'f': [ox, y + th, ox + th, y + digitH ~/ 2 - th ~/ 2],
      'g': [
        ox + th,
        y + digitH ~/ 2 - th ~/ 2,
        ox + digitW - th,
        y + digitH ~/ 2 + th ~/ 2,
      ],
    };
    for (final name in on) {
      final r = segRects[name]!;
      _fillRect(bytes, imgW, imgH, r[0], r[1], r[2], r[3], colorBgr);
    }
  }
}

// cv2.rectangle(img, (x1,y1), (x2,y2), color, -1) 이식: [x1,x2) x [y1,y2) 채움
// (OpenCV -1 두께 채우기는 우/하단 경계를 포함하나, 세그먼트끼리 두께(th)만큼
// 간격이 있어 실제 코드에선 포함 여부가 결과에 영향 없음. 반개구간으로 이식).
void _fillRect(
  Uint8List bytes,
  int imgW,
  int imgH,
  int x1,
  int y1,
  int x2,
  int y2,
  List<int> colorBgr,
) {
  final xs = x1 < 0 ? 0 : x1;
  final ys = y1 < 0 ? 0 : y1;
  final xe = x2 > imgW ? imgW : x2;
  final ye = y2 > imgH ? imgH : y2;
  for (var yy = ys; yy < ye; yy++) {
    for (var xx = xs; xx < xe; xx++) {
      final idx = (yy * imgW + xx) * 3;
      bytes[idx] = colorBgr[0];
      bytes[idx + 1] = colorBgr[1];
      bytes[idx + 2] = colorBgr[2];
    }
  }
}

RoiImage _blankImage(int w, int h, {int bg = 0}) {
  final bytes = Uint8List(w * h * 3);
  if (bg != 0) {
    for (var i = 0; i < w * h; i++) {
      bytes[i * 3] = bg;
      bytes[i * 3 + 1] = bg;
      bytes[i * 3 + 2] = bg;
    }
  }
  return RoiImage(w, h, bytes);
}

/// _cell(number, cell_w, cell_h) 이식: 단일 숫자 셀을 pad=4로 딱 맞게 렌더링.
RoiImage cellImage(
  int number,
  int cellW,
  int cellH, {
  List<int> color = digitRed,
}) {
  const pad = 4;
  final w = cellW + 2 * pad;
  final h = cellH + 2 * pad;
  final img = _blankImage(w, h);
  drawSevenSegment(img.bytes, w, h, number, pad, pad, cellW, cellH, color);
  return img;
}

/// 여러 숫자를 gap 간격으로 이어 그린 다자리 ROI (draw_seven_segment 자체가
/// 다자리 문자열을 지원하므로 이를 그대로 이용).
RoiImage multiDigitImage(
  int number, {
  int digitW = 30,
  int digitH = 56,
  int pad = 6,
  int gap = 10,
}) {
  final text = number.toString();
  final w = text.length * digitW + (text.length - 1) * gap + 2 * pad;
  final h = digitH + 2 * pad;
  final img = _blankImage(w, h);
  drawSevenSegment(
    img.bytes,
    w,
    h,
    number,
    pad,
    pad,
    digitW,
    digitH,
    digitRed,
    gap: gap,
  );
  return img;
}

void main() {
  group('drawSevenSegment 기반 단일 숫자 판독 (0~9)', () {
    for (var d = 0; d <= 9; d++) {
      test('숫자 $d → readFrame == $d', () {
        final reader = DigitReader(const DetectorConfig.defaults());
        final img = cellImage(d, 30, 56); // ratio ~0.54, 표준 폭
        expect(reader.readFrame(img), d, reason: '숫자 $d 판독 실패');
      });
    }
  });

  test('두 자리 숫자(12) → readFrame == 12', () {
    final reader = DigitReader(const DetectorConfig.defaults());
    final img = multiDigitImage(12);
    expect(reader.readFrame(img), 12);
  });

  test('두 자리 숫자(9) 단일 자릿수도 정상', () {
    final reader = DigitReader(const DetectorConfig.defaults());
    final img = multiDigitImage(9);
    expect(reader.readFrame(img), 9);
  });

  test('빈 회색 프레임 → null (셀 없음)', () {
    final reader = DigitReader(const DetectorConfig.defaults());
    final img = _blankImage(100, 70, bg: 80);
    expect(reader.readFrame(img), isNull);
  });

  test('완전히 검은 프레임 → null', () {
    final reader = DigitReader(const DetectorConfig.defaults());
    final img = _blankImage(100, 70);
    expect(reader.readFrame(img), isNull);
  });

  group('부정 케이스 (test_digits.py negative_tests 미러링)', () {
    test('1) 단색 빨강 원 blob → null (숫자 아님)', () {
      final reader = DigitReader(const DetectorConfig.defaults());
      final img = _blankImage(45, 70);
      _drawFilledCircle(img.bytes, 45, 70, 22, 35, 20, digitRed);
      expect(reader.readFrame(img), isNull);
    });

    test('1) 단색 빨강 사각형 blob → null (숫자 아님)', () {
      final reader = DigitReader(const DetectorConfig.defaults());
      final img = _blankImage(45, 70);
      _fillRect(img.bytes, 45, 70, 6, 6, 39, 64, digitRed);
      expect(reader.readFrame(img), isNull);
    });

    test('2) 좁은 종횡비의 3이 1로 오판되면 안 됨', () {
      final reader = DigitReader(const DetectorConfig.defaults());
      for (final ratio in [0.44, 0.50, 0.55, 0.60]) {
        const cellH = 60;
        final cellW = (cellH * ratio).toInt();
        final img = cellImage(3, cellW, cellH);
        final v = reader.readFrame(img);
        expect(v, isNot(1), reason: '종횡비 $ratio의 3이 1로 오판');
        expect(v == 3 || v == null, isTrue, reason: '종횡비 $ratio의 3이 $v로 오판');
      }
    });

    test('3) 진짜 1은 여전히 1로 읽혀야 함', () {
      final reader = DigitReader(const DetectorConfig.defaults());
      var gotOne = false;
      for (final ratio in [0.16, 0.20, 0.25]) {
        const cellH = 60;
        final cellW = (cellH * ratio).toInt() < 6 ? 6 : (cellH * ratio).toInt();
        final img = cellImage(1, cellW, cellH);
        if (reader.readFrame(img) == 1) gotOne = true;
      }
      expect(gotOne, isTrue, reason: '진짜 1을 어떤 종횡비에서도 읽지 못함');
    });

    test('4) 표준 폭의 한 자리 4는 4 또는 null이어야 함 (다른 숫자면 오판)', () {
      final reader = DigitReader(const DetectorConfig.defaults());
      final img = cellImage(4, (56 * 0.60).toInt(), 56);
      final v = reader.readFrame(img);
      expect(v == 4 || v == null, isTrue, reason: '4가 $v로 오판');
    });

    test('5) 두 자리가 뭉친 넓은 셀은 null이어야 함', () {
      final reader = DigitReader(const DetectorConfig.defaults());
      final img = cellImage(8, (56 * 0.95).toInt(), 56); // 폭만 넓힌 셀 = 뭉침 모사
      expect(reader.readFrame(img), isNull);
    });
  });

  group('read() 시간 안정화(다수결)', () {
    test('같은 값이 stable_votes(3) 이상 → 그 값', () {
      final reader = DigitReader(const DetectorConfig.defaults());
      final img = cellImage(5, 30, 56);
      reader.read(img);
      reader.read(img);
      final r = reader.read(img);
      expect(r, 5);
    });

    test('표가 흔들리면(다수 미달) → null', () {
      final reader = DigitReader(const DetectorConfig.defaults());
      final img5 = cellImage(5, 30, 56);
      final img7 = cellImage(7, 30, 56);
      reader.read(img5);
      reader.read(img7);
      final r = reader.read(img5); // 5:2, 7:1, votes(2) < stable_votes(3)
      expect(r, isNull);
    });

    test('roi=null은 None 투표로 취급 (공백 동안 stale 값 방지)', () {
      final reader = DigitReader(const DetectorConfig.defaults());
      final img = cellImage(5, 30, 56);
      reader.read(img);
      reader.read(img);
      final r1 = reader.read(img);
      expect(r1, 5, reason: '3표 확보 후 stable');
      reader.read(null);
      reader.read(null);
      final r2 = reader.read(null);
      // maxlen=5 윈도우에 [5,5,5,null,null,null] 중 최근 5개 [5,5,null,null,null]
      // → 5표=2, votes(2) < stable_votes(3) → null.
      expect(r2, isNull);
    });

    test('read(null) 단독 반복 → null', () {
      final reader = DigitReader(const DetectorConfig.defaults());
      reader.read(null);
      reader.read(null);
      final r = reader.read(null);
      expect(r, isNull);
    });
  });
}

void _drawFilledCircle(
  Uint8List bytes,
  int imgW,
  int imgH,
  int cx,
  int cy,
  int r,
  List<int> colorBgr,
) {
  for (var y = 0; y < imgH; y++) {
    for (var x = 0; x < imgW; x++) {
      final dx = x - cx, dy = y - cy;
      if (dx * dx + dy * dy <= r * r) {
        final idx = (y * imgW + x) * 3;
        bytes[idx] = colorBgr[0];
        bytes[idx + 1] = colorBgr[1];
        bytes[idx + 2] = colorBgr[2];
      }
    }
  }
}
