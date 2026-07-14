/// 잔여 시간 숫자 읽기 — 7-세그먼트 디코딩, 딥러닝 없음. digits.py DigitReader 이식.
///
/// 보행 신호 잔여시간 표시기는 붉은 LED 7-세그먼트 형태가 표준적이다.
/// 숫자 ROI → 빨강 마스크 → 열 투영으로 자릿수 분리 → 자릿수별 7개
/// 세그먼트 영역 샘플링 → 패턴 테이블 디코딩.
///
/// 정직성 원칙: 모든 자릿수가 유효 패턴으로 디코딩될 때만 값을 내고,
/// 아니면 null("판독 불가"). 시간 안정화(최근 stable_window 프레임 다수결)까지
/// 통과해야 stable 값이 된다. 어설픈 추측은 하지 않는다.
library;

import 'dart:typed_data';

import 'detector_config.dart';
import 'image_ops.dart';
import 'roi_image.dart';

/// 세그먼트 이름: a=상단, b=우상, c=우하, d=하단, e=좌하, f=좌상, g=중앙
const Map<String, int> kDigitPatterns = {
  'abcdef': 0,
  'bc': 1,
  'abged': 2,
  'abgcd': 3,
  'fgbc': 4,
  'afgcd': 5,
  'afgedc': 6,
  'abc': 7,
  'abcdefg': 8,
  'abcdfg': 9,
};

/// 정규화 좌표 (x1, y1, x2, y2) — 자릿수 셀 안에서 각 세그먼트를 샘플링할 영역.
const Map<String, List<double>> kSegmentRegions = {
  'a': [0.25, 0.00, 0.75, 0.18],
  'b': [0.70, 0.12, 1.00, 0.44],
  'c': [0.70, 0.56, 1.00, 0.88],
  'd': [0.25, 0.82, 0.75, 1.00],
  'e': [0.00, 0.56, 0.30, 0.88],
  'f': [0.00, 0.12, 0.30, 0.44],
  'g': [0.25, 0.41, 0.75, 0.59],
};

String _normalizePattern(Set<String> segs) {
  final sorted = segs.toList()..sort();
  return sorted.join();
}

// 패턴 테이블을 정렬 키로 재색인 (digits.py _PATTERNS_SORTED).
final Map<String, int> _patternsSorted = {
  for (final e in kDigitPatterns.entries) _normalizePattern(e.key.split('').toSet()): e.value,
};

/// 1채널 마스크(값 0 또는 255) — width*height, 행 우선. cv2 단일채널 Mat 대응.
class _Mask {
  final int width;
  final int height;
  final Uint8List data;
  const _Mask(this.width, this.height, this.data);

  int at(int x, int y) => data[y * width + x];
}

/// 셀(마스크 서브영역): shape (h, w) — digits.py의 numpy 슬라이스 결과 대응.
class _Cell {
  final int width;
  final int height;
  final Uint8List data; // height*width, 행 우선, 값 0/255
  const _Cell(this.width, this.height, this.data);

  double get fill {
    if (data.isEmpty) return 0.0;
    var sum = 0;
    for (final v in data) {
      sum += v;
    }
    return (sum / data.length) / 255.0;
  }
}

class DigitReader {
  final DetectorConfig _cfg;
  final List<int?> _recent = []; // maxlen=stableWindow deque 대응

  DigitReader(this._cfg);

  _Mask _mask(RoiImage roi) {
    // 블러 생략 — digits.py는 cv2.GaussianBlur(roi,(3,3),0)를 HSV 변환 전에
    // 적용하지만, image_ops.dart에 gaussianBlur가 없어 color_detector.dart와
    // 동일하게 이 조각에서는 생략한다(카메라/통합 조각에서 다룰 항목).
    // 합성 테스트 숫자는 선명해 블러 없이도 세그먼트가 정확히 갈린다.
    final hsv = bgrToHsv(roi);
    final n = roi.width * roi.height;
    final mask = inRangeHsv(hsv, n, _cfg.digitRedHsv);
    final closed = morphClose(mask, roi.width, roi.height, 3);
    return _Mask(roi.width, roi.height, closed);
  }

  /// 열 투영의 공백으로 자릿수 셀을 분리한다 (digits.py _split_cells).
  List<_Cell> _splitCells(_Mask mask) {
    final w = mask.width, h = mask.height;
    // 열별로 하나라도 점등되어 있는지.
    final colLit = List<bool>.filled(w, false);
    var anyLit = false;
    for (var x = 0; x < w; x++) {
      for (var y = 0; y < h; y++) {
        if (mask.at(x, y) == 255) {
          colLit[x] = true;
          anyLit = true;
          break;
        }
      }
    }
    if (!anyLit) return [];

    // 점등 구간(run)들을 [start, end) 로 수집.
    final runs = <(int, int)>[];
    var inRun = false;
    var start = 0;
    for (var x = 0; x <= w; x++) {
      final lit = x < w ? colLit[x] : false;
      if (lit && !inRun) {
        inRun = true;
        start = x;
      } else if (!lit && inRun) {
        inRun = false;
        runs.add((start, x));
      }
    }

    final boxes = <_Cell>[];
    for (final (x1, x2) in runs) {
      final subW = x2 - x1;
      // 이 구간에서 점등된 행 범위(rows.min..rows.max)를 찾아 세로로 tight-crop.
      var rowMin = -1;
      var rowMax = -1;
      for (var y = 0; y < h; y++) {
        var lit = false;
        for (var x = x1; x < x2; x++) {
          if (mask.at(x, y) == 255) {
            lit = true;
            break;
          }
        }
        if (lit) {
          if (rowMin == -1) rowMin = y;
          rowMax = y;
        }
      }
      if (rowMin == -1) continue; // rows.size == 0
      final subH = rowMax - rowMin + 1;
      final data = Uint8List(subW * subH);
      for (var yy = 0; yy < subH; yy++) {
        for (var xx = 0; xx < subW; xx++) {
          data[yy * subW + xx] = mask.at(x1 + xx, rowMin + yy);
        }
      }
      boxes.add(_Cell(subW, subH, data));
    }
    if (boxes.isEmpty) return [];

    // 노이즈 셀 제거: 가장 큰 셀 높이의 60% 미만은 버림.
    final maxH = boxes.map((b) => b.height).reduce((a, b) => a > b ? a : b);
    return boxes.where((b) => b.height >= 0.6 * maxH).toList();
  }

  double _segRatio(_Cell cell, String regionKey) {
    final h = cell.height, w = cell.width;
    final region = kSegmentRegions[regionKey]!;
    final nx1 = region[0], ny1 = region[1], nx2 = region[2], ny2 = region[3];
    final x1 = (nx1 * w).toInt();
    final x2Raw = (nx1 * w).toInt() + 1;
    final x2b = (nx2 * w).toInt();
    final x2 = x2Raw > x2b ? x2Raw : x2b;
    final y1 = (ny1 * h).toInt();
    final y2Raw = (ny1 * h).toInt() + 1;
    final y2b = (ny2 * h).toInt();
    final y2 = y2Raw > y2b ? y2Raw : y2b;

    final rx1 = x1.clamp(0, w);
    final rx2 = x2.clamp(0, w);
    final ry1 = y1.clamp(0, h);
    final ry2 = y2.clamp(0, h);
    if (rx2 <= rx1 || ry2 <= ry1) return 0.0;

    var sum = 0;
    var count = 0;
    for (var yy = ry1; yy < ry2; yy++) {
      for (var xx = rx1; xx < rx2; xx++) {
        sum += cell.data[yy * cell.width + xx];
        count++;
      }
    }
    if (count == 0) return 0.0;
    return (sum / count) / 255.0;
  }

  int? _decodeCell(_Cell cell) {
    final h = cell.height, w = cell.width;
    if (h < 8 || w < 2) return null;
    final fill = cell.fill;
    if (fill < _cfg.minCellFill) return null;

    // '1'은 b·c 세로열만 켜져 셀이 매우 좁고 거의 꽉 찬다(fill이 높음).
    // 세그먼트 영역 샘플링·fill 상한 검사보다 먼저 처리해야 한다.
    if (w < 0.30 * h) {
      // col_cov: 각 열의 평균이 seg_on_ratio 이상인 열의 비율.
      var colOnCount = 0;
      for (var xx = 0; xx < w; xx++) {
        var sum = 0;
        for (var yy = 0; yy < h; yy++) {
          sum += cell.data[yy * w + xx];
        }
        final colMean = (sum / h) / 255.0;
        if (colMean >= _cfg.segOnRatio) colOnCount++;
      }
      final colCovMean = colOnCount / w;

      // row_cov: 각 행의 평균이 seg_on_ratio 이상인 행의 비율.
      var rowOnCount = 0;
      for (var yy = 0; yy < h; yy++) {
        var sum = 0;
        for (var xx = 0; xx < w; xx++) {
          sum += cell.data[yy * w + xx];
        }
        final rowMean = (sum / w) / 255.0;
        if (rowMean >= _cfg.segOnRatio) rowOnCount++;
      }
      final rowCov = rowOnCount / h;

      return (colCovMean > 0.6 && rowCov > 0.8) ? 1 : null;
    }

    // 한 자리치고 너무 넓은 셀 = 뭉친 두 자리이거나 회전으로 뭉개진 것.
    if (w > _cfg.maxCellAspect * h) return null;

    // 셀 대부분이 채워짐 = 단색 빨강 블롭(등화/반사/스미어)이지 숫자가 아님.
    if (fill > _cfg.maxCellFill) return null;

    // 이중 임계: on/off 사이 모호한 세그먼트가 하나라도 있으면 이 셀은
    // 판독 불가(null). 세그먼트 1개의 애매함이 이웃 숫자로 둔갑하는 것을 막는다.
    final segs = <String>{};
    for (final name in kSegmentRegions.keys) {
      final r = _segRatio(cell, name);
      if (r >= _cfg.segOnRatio) {
        segs.add(name);
      } else if (r > _cfg.segOffRatio) {
        return null; // 모호 구간 → 정직하게 판독 포기
      }
    }
    return _patternsSorted[_normalizePattern(segs)];
  }

  /// 한 프레임 즉석 판독. 모든 자릿수가 유효할 때만 값, 아니면 null.
  int? readFrame(RoiImage roi) {
    var cells = _splitCells(_mask(roi));
    // 작은 노이즈 얼룩이 유령 숫자(특히 '1')로 읽히지 않게
    // 셀 높이가 ROI 높이의 35% 이상일 때만 숫자로 인정.
    cells = cells.where((c) => c.height >= 0.35 * roi.height).toList();
    if (cells.isEmpty || cells.length > 2) return null;
    final digits = cells.map(_decodeCell).toList();
    if (digits.any((d) => d == null)) return null;
    final str = digits.map((d) => d!.toString()).join();
    return int.parse(str);
  }

  /// 시간 안정화 판독: 최근 프레임 다수결로 확정된 값(없으면 null).
  ///
  /// roi=null은 '프레임 없음'(카메라 공백 등)으로 취급해 null을 투표에
  /// 넣는다 — 공백 동안 이전 값이 stale하게 남는 것을 막는다.
  int? read(RoiImage? roi) {
    _recent.add(roi == null ? null : readFrame(roi));
    while (_recent.length > _cfg.stableWindow) {
      _recent.removeAt(0);
    }
    final counts = <int, int>{};
    for (final v in _recent) {
      if (v == null) continue;
      counts[v] = (counts[v] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    int? bestValue;
    var bestVotes = -1;
    for (final e in counts.entries) {
      if (e.value > bestVotes) {
        bestVotes = e.value;
        bestValue = e.key;
      }
    }
    return bestVotes >= _cfg.stableVotes ? bestValue : null;
  }
}
