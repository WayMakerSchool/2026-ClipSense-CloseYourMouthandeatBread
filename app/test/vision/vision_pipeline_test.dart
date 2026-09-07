// VisionPipeline: CameraVisionSource 안에 갇혀 있던 검출→상태머신→숫자→SignalReading
// 흐름을 프레임 소스와 무관한 순수 객체로 꺼낸 것. 폰 카메라와 클립 카메라가
// 같은 판정 코드를 쓰게 한다. 동작은 추출 전과 같아야 한다(회귀 테스트).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clip_sense/signals/signal_reading.dart';
import 'package:clip_sense/signals/vision_adapter.dart';
import 'package:clip_sense/vision/color_detector.dart';
import 'package:clip_sense/vision/detector_config.dart';
import 'package:clip_sense/vision/digit_reader.dart';
import 'package:clip_sense/vision/roi_image.dart';
import 'package:clip_sense/vision/signal_state_machine.dart';
import 'package:clip_sense/vision/vision_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

File _fixture(String name) {
  for (final dir in ['test/fixtures', 'app/test/fixtures']) {
    final f = File('$dir/$name');
    if (f.existsSync()) return f;
  }
  throw StateError('fixture 없음: $name (cwd=${Directory.current.path})');
}

/// 실클립 시퀀스 fixture: 대표 픽셀 프레임 3장(20·34·54)을 슬롯으로 돌려 쓴다.
class _Sequence {
  final int width;
  final int height;
  final Uint8List bytes;
  final List<int> pixelFrames;
  _Sequence(this.width, this.height, this.bytes, this.pixelFrames);

  RoiImage roiAt(int slot) {
    final n = width * height * 3;
    return RoiImage(
      width,
      height,
      Uint8List.sublistView(bytes, slot * n, (slot + 1) * n),
    );
  }
}

_Sequence _loadSequence() {
  final meta =
      jsonDecode(_fixture('real_signal_sequence.json').readAsStringSync())
          as Map<String, dynamic>;
  return _Sequence(
    meta['width'] as int,
    meta['height'] as int,
    Uint8List.fromList(_fixture('real_signal_sequence.bgr').readAsBytesSync()),
    (meta['pixel_frame_indices'] as List).cast<int>(),
  );
}

RoiImage _solid(int w, int h, int b, int g, int r) {
  final bytes = Uint8List(w * h * 3);
  for (var i = 0; i < w * h; i++) {
    bytes[i * 3] = b;
    bytes[i * 3 + 1] = g;
    bytes[i * 3 + 2] = r;
  }
  return RoiImage(w, h, bytes);
}

void main() {
  const config = DetectorConfig.defaults();

  test('실클립 프레임을 30fps로 넣으면 추출 전과 같은 순서로 GREEN에 도달한다', () {
    final seq = _loadSequence();
    final pipeline = VisionPipeline(config);
    // 추출 전 경로를 손으로 재현한 기준선.
    final detector = ColorDetector(config);
    final machine = SignalStateMachine(config);
    final digits = DigitReader(config);

    var reachedGreenAt = -1;
    for (var i = 0; i < 30; i++) {
      final roi = seq.roiAt(0);
      final t = i / 30.0;
      final result = pipeline.process(roi, t);

      final frame = detector.detect(roi);
      machine.update(t, frame.raw, reason: frame.reason);
      final expected = toReading(
        machine.state,
        remainSec: digits.read(roi)?.toDouble(),
      );

      expect(result.reading.color, expected.color, reason: 'frame $i');
      expect(result.reading.remainSec, expected.remainSec, reason: 'frame $i');
      expect(result.reading.source, SignalSource.vision);
      expect(result.reading.freshMs, 0);
      expect(result.frame.raw, frame.raw, reason: 'frame $i');
      expect(pipeline.state, machine.state, reason: 'frame $i');
      if (reachedGreenAt < 0 && result.reading.color == SignalColor.green) {
        reachedGreenAt = i;
      }
    }
    // debounceFrames(8) 뒤에 GREEN — 0-based 7번째 프레임.
    expect(reachedGreenAt, config.debounceFrames - 1);
  });

  test('reset() 뒤에는 GREEN이 debounce를 다시 통과해야 한다', () {
    final seq = _loadSequence();
    final pipeline = VisionPipeline(config);
    for (var i = 0; i < config.debounceFrames; i++) {
      pipeline.process(seq.roiAt(0), i / 4.0);
    }
    expect(pipeline.state, stateGreen);

    pipeline.reset();
    expect(pipeline.state, stateUnknown);
    // 리셋 직후 한 프레임으로는 GREEN이 부활하지 않는다(정전 뒤 첫 프레임 방어).
    final first = pipeline.process(seq.roiAt(0), 10.0);
    expect(first.reading.color, SignalColor.unknown);
    expect(pipeline.state, stateUnknown);
  });

  test('손상 프레임(바이트 길이 불일치)은 던지고, 던지기 전에 이력을 비운다', () {
    final seq = _loadSequence();
    final pipeline = VisionPipeline(config);
    for (var i = 0; i < config.debounceFrames; i++) {
      pipeline.process(seq.roiAt(0), i / 4.0);
    }
    expect(pipeline.state, stateGreen);

    final corrupt = RoiImage(320, 180, Uint8List(10));
    expect(() => pipeline.process(corrupt, 3.0), throwsA(anything));
    expect(pipeline.state, stateUnknown);
    // 다음 정상 프레임 한 장으로 GREEN이 바로 살아나지 않는다.
    expect(
      pipeline.process(seq.roiAt(0), 3.25).reading.color,
      SignalColor.unknown,
    );
  });

  test('아무 색도 없는 프레임은 NONE→unknown이며 숫자도 null', () {
    final pipeline = VisionPipeline(config);
    final result = pipeline.process(_solid(64, 48, 0, 0, 0), 0);
    expect(result.reading.color, SignalColor.unknown);
    expect(result.reading.remainSec, isNull);
    expect(result.frame.raw, rawNone);
  });

  test('처리 시간을 잰다(ms, 음수 아님)', () {
    final seq = _loadSequence();
    final result = VisionPipeline(config).process(seq.roiAt(0), 0);
    expect(result.processMs, greaterThanOrEqualTo(0));
  });
}
