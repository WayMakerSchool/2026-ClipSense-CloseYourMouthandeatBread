/// 프레임 소스와 무관한 판정 파이프라인: 검출 → 상태머신 → 숫자 → SignalReading.
///
/// CameraVisionSource(폰 카메라)와 ClipVisionSource(클립 카메라 HTTP 스냅샷)가
/// 같은 코드를 쓴다 — 판정 규칙이 소스마다 갈라지면 한쪽만 고쳐지는 사고가 난다.
/// 프레임 획득·회전·크롭·신선도는 소스의 몫이고, 여기는 BGR ROI 한 장과 그
/// 프레임의 시각(초)만 받는다.
///
/// 시각 [tSec]는 소스가 정한 단조 증가 시계다. 폰 카메라는 스트림 스톱워치,
/// 클립 카메라는 촬영 시각(capturedAtMonoMs) 기준 — 점멸 판정은 프레임 간격에
/// 의존하므로 수신·처리 시각이 아니라 촬영 시각을 넣어야 한다.
///
/// 손상 프레임으로 [process]가 던지면 던지기 전에 [reset]을 끝낸다. 이전 GREEN
/// 이력이 다음 정상 프레임 한 장으로 되살아나지 않게 하기 위해서다(디바운스
/// 재통과 필요). 호출자는 판독을 unknown으로 무효화하면 된다.
library;

import '../signals/signal_reading.dart';
import '../signals/vision_adapter.dart';
import 'color_detector.dart';
import 'detector_config.dart';
import 'digit_reader.dart';
import 'roi_image.dart';
import 'signal_state_machine.dart';

/// 한 프레임 처리 결과. [reading]의 freshMs는 0 — 나이는 소스가 붙인다.
class PipelineResult {
  final SignalReading reading;
  final FrameResult frame;
  final int processMs;

  const PipelineResult({
    required this.reading,
    required this.frame,
    required this.processMs,
  });
}

class VisionPipeline {
  final DetectorConfig _config;
  ColorDetector _detector;
  SignalStateMachine _machine;
  DigitReader _digits;

  VisionPipeline(DetectorConfig config)
    : _config = config,
      _detector = ColorDetector(config),
      _machine = SignalStateMachine(config),
      _digits = DigitReader(config);

  /// 상태머신 현재 상태(RED/GREEN/GREEN_BLINK/UNKNOWN). 진단·테스트용.
  String get state => _machine.state;

  /// ROI 한 장을 처리한다. [tSec]는 단조 증가해야 한다.
  PipelineResult process(RoiImage roi, double tSec) {
    final stopwatch = Stopwatch()..start();
    try {
      final frame = _detector.detect(roi);
      _machine.update(tSec, frame.raw, reason: frame.reason);
      final remainSec = _digits.read(roi)?.toDouble();
      return PipelineResult(
        reading: toReading(_machine.state, remainSec: remainSec),
        frame: frame,
        processMs: stopwatch.elapsedMilliseconds,
      );
    } catch (_) {
      reset();
      rethrow;
    }
  }

  /// 검출기·상태머신·숫자 판독기의 이력을 모두 버린다. 정지·재시작, 손상
  /// 프레임, 소스의 정전(스냅샷 실패 연속) 뒤에 부른다.
  void reset() {
    _detector = ColorDetector(_config);
    _machine = SignalStateMachine(_config);
    _digits = DigitReader(_config);
  }
}
