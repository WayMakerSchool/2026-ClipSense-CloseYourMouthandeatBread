/// 이진 마스크(255=전경)의 외곽 경계추적 → 면적·둘레·원형도. 순수 함수.
///
/// OpenCV `findContours(RETR_EXTERNAL, CHAIN_APPROX_SIMPLE)` +
/// `contourArea` + `arcLength` + 원형도(4π·area/perimeter²)의 근사 이식.
/// 100% 일치가 목표가 아니라, 판정에 쓰는 값(면적·원형도)이 임계값과
/// 정합하는 것이 목표. 원≈1.0, 사각<원.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 외곽 경계 점열. xs[i],ys[i]가 i번째 경계 픽셀 좌표(시계방향).
class Contour {
  final List<int> xs;
  final List<int> ys;
  const Contour(this.xs, this.ys);

  int get length => xs.length;
  bool get isEmpty => xs.isEmpty;
}

/// 8-이웃 오프셋(시계방향, 동쪽에서 시작). Moore tracing 순서.
const _dx = <int>[1, 1, 0, -1, -1, -1, 0, 1];
const _dy = <int>[0, 1, 1, 1, 0, -1, -1, -1];

/// 255 blob들을 8-이웃 연결요소로 분리 후, 각 blob의 외곽 경계를
/// Moore-neighbor tracing(시작=최상단-최좌측, 시계방향)으로 추출.
/// 반환은 blob별 1개(외부 경계만; 구멍 무시 = RETR_EXTERNAL).
List<Contour> findContours(Uint8List mask, int w, int h) {
  if (w <= 0 || h <= 0 || mask.length < w * h) return const [];

  // 8-이웃 flood fill로 blob 라벨링. labels: 0=배경, >=1=blob id.
  final labels = Int32List(w * h);
  var nextLabel = 0;
  final stack = <int>[];

  for (var sy = 0; sy < h; sy++) {
    for (var sx = 0; sx < w; sx++) {
      final start = sy * w + sx;
      if (mask[start] != 255 || labels[start] != 0) continue;
      nextLabel++;
      labels[start] = nextLabel;
      stack.add(start);
      while (stack.isNotEmpty) {
        final p = stack.removeLast();
        final py = p ~/ w;
        final px = p - py * w;
        for (var k = 0; k < 8; k++) {
          final nx = px + _dx[k];
          final ny = py + _dy[k];
          if (nx < 0 || nx >= w || ny < 0 || ny >= h) continue;
          final np = ny * w + nx;
          if (mask[np] == 255 && labels[np] == 0) {
            labels[np] = nextLabel;
            stack.add(np);
          }
        }
      }
    }
  }

  if (nextLabel == 0) return const [];

  // 각 blob의 시작 픽셀(최상단-최좌측)을 라벨 순 스캔으로 확보.
  final startIdx = Int32List(nextLabel + 1)..fillRange(0, nextLabel + 1, -1);
  for (var i = 0; i < w * h; i++) {
    final lb = labels[i];
    if (lb != 0 && startIdx[lb] == -1) startIdx[lb] = i;
  }

  final contours = <Contour>[];
  for (var lb = 1; lb <= nextLabel; lb++) {
    final s = startIdx[lb];
    if (s < 0) continue;
    contours.add(_traceBoundary(labels, w, h, lb, s));
  }
  return contours;
}

/// 라벨 [lb] blob의 외곽 경계를 Moore-neighbor tracing으로 시계방향 추출.
/// [start]는 blob의 최상단-최좌측 픽셀(스캔 순서상 처음 만나는 픽셀).
Contour _traceBoundary(Int32List labels, int w, int h, int lb, int start) {
  final startY = start ~/ w;
  final startX = start - startY * w;

  bool isBlob(int x, int y) =>
      x >= 0 && x < w && y >= 0 && y < h && labels[y * w + x] == lb;

  final xs = <int>[startX];
  final ys = <int>[startY];

  // 단일 픽셀 blob: 이웃 없음 → 점 하나로 반환.
  var hasNeighbor = false;
  for (var k = 0; k < 8; k++) {
    if (isBlob(startX + _dx[k], startY + _dy[k])) {
      hasNeighbor = true;
      break;
    }
  }
  if (!hasNeighbor) return Contour(xs, ys);

  // Moore tracing. 시작 픽셀은 최상단-최좌측이므로 진입방향은 위쪽(북).
  // backtrack = 이전에 있던(배경) 셀 방향; 서쪽(-x)에서 진입했다고 보고
  // 동쪽 이웃부터 시계방향 탐색을 시작한다.
  var curX = startX, curY = startY;
  // 마지막으로 온 방향의 반대(=이전 배경 셀)로부터 탐색 재개.
  // 최상단-최좌측 픽셀의 서쪽/북쪽은 배경이므로 backtrack dir=서(index 4).
  var backtrack = 4; // 서쪽(-1,0)

  const maxSteps = 1 << 24; // 무한루프 방어(과대 상한).
  var steps = 0;

  while (true) {
    // backtrack 셀 다음(시계방향)부터 첫 blob 이웃을 찾는다.
    var found = false;
    var searchStart = (backtrack + 1) % 8;
    var nextX = curX, nextY = curY, nextDir = backtrack;
    for (var i = 0; i < 8; i++) {
      final k = (searchStart + i) % 8;
      final nx = curX + _dx[k];
      final ny = curY + _dy[k];
      if (isBlob(nx, ny)) {
        nextX = nx;
        nextY = ny;
        nextDir = k;
        found = true;
        break;
      }
    }
    if (!found) break; // 고립 픽셀(위에서 걸러지지만 안전).

    // 새 backtrack = 새 픽셀에서 본 현재 픽셀 방향.
    backtrack = (nextDir + 4) % 8;
    curX = nextX;
    curY = nextY;

    // Jacob 정지조건: 시작 픽셀로 되돌아옴.
    if (curX == startX && curY == startY) break;

    xs.add(curX);
    ys.add(curY);

    if (++steps > maxSteps) break;
  }

  return Contour(xs, ys);
}

/// shoelace 다각형 면적: 0.5*|Σ(x_i*y_{i+1} - x_{i+1}*y_i)|.
double contourArea(Contour c) {
  final n = c.length;
  if (n < 3) return 0.0;
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    final j = (i + 1) % n;
    sum += c.xs[i] * c.ys[j] - c.xs[j] * c.ys[i];
  }
  return sum.abs() / 2.0;
}

/// 닫힌 경로 둘레: 인접 경계점 유클리드 거리 합(마지막→처음 닫음).
double arcLength(Contour c) {
  final n = c.length;
  if (n < 2) return 0.0;
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    final j = (i + 1) % n;
    final dx = (c.xs[j] - c.xs[i]).toDouble();
    final dy = (c.ys[j] - c.ys[i]).toDouble();
    sum += math.sqrt(dx * dx + dy * dy);
  }
  return sum;
}

/// 원형도: 4π·area/perimeter². perimeter 0이면 0(0나눗셈 방지).
double circularity(Contour c) {
  final p = arcLength(c);
  if (p <= 0) return 0.0;
  return 4 * math.pi * contourArea(c) / (p * p);
}
