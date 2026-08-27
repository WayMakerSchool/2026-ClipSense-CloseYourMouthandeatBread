/// camera 플러그인 스트림을 비전 판정으로 바꾸는 하드웨어 경계.
///
/// GuidanceController는 [VisionSource]만 알아 카메라 플러그인과 분리된다.
/// 시작/정지는 직렬화되고 최종 요청 상태를 따르므로, 권한 다이얼로그를 기다리는
/// 동안 사용자가 정지하거나 화면을 닫아도 뒤늦게 스트림이 살아나지 않는다.
library;

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app/config.dart';
import '../signals/signal_reading.dart';
import '../signals/vision_adapter.dart';
import '../vision/color_detector.dart';
import '../vision/detector_config.dart';
import '../vision/digit_reader.dart';
import '../vision/roi_image.dart';
import '../vision/signal_state_machine.dart';
import 'frame_converter.dart';

abstract interface class VisionSource {
  /// 최신 판정. 구현체는 호출 시점까지의 실제 경과 시간을 freshMs에 반영한다.
  SignalReading get latestReading;

  /// 여러 번 불러도 안전해야 한다.
  Future<void> start();

  /// 초기화 중이거나 이미 정지한 상태에서도 여러 번 불러도 안전해야 한다.
  Future<void> stop();
}

class CameraVisionSource implements VisionSource {
  final DetectorConfig _config;
  final double _roiFrac;
  final int _processEveryN;

  ColorDetector _detector;
  SignalStateMachine _stateMachine;
  DigitReader _digitReader;

  CameraController? _controller;
  Future<void> _lifecycle = Future<void>.value();
  bool _desiredRunning = false;
  bool _processingFrame = false;
  int _frameIndex = 0;

  final Stopwatch _clock = Stopwatch();
  SignalReading _latest = _unknownReading;
  int? _lastFrameElapsedMs;

  CameraVisionSource({
    DetectorConfig config = const DetectorConfig.defaults(),
    double roiFrac = kRoiFrac,
    int processEveryN = kCameraProcessEveryN,
  }) : assert(roiFrac > 0 && roiFrac <= 1),
       assert(processEveryN > 0),
       _config = config,
       _roiFrac = roiFrac,
       _processEveryN = processEveryN,
       _detector = ColorDetector(config),
       _stateMachine = SignalStateMachine(config),
       _digitReader = DigitReader(config);

  static const SignalReading _unknownReading = SignalReading(
    SignalColor.unknown,
    null,
    SignalSource.vision,
  );

  @override
  SignalReading get latestReading {
    final updatedAt = _lastFrameElapsedMs;
    if (updatedAt == null) return _unknownReading;
    final age = (_clock.elapsedMilliseconds - updatedAt).clamp(0, 1 << 31);
    return SignalReading(
      _latest.color,
      _latest.remainSec,
      SignalSource.vision,
      freshMs: age,
      raw: _latest.raw,
    );
  }

  @override
  Future<void> start() {
    _desiredRunning = true;
    return _enqueueReconcile();
  }

  @override
  Future<void> stop() {
    // 호출 즉시 오래된 green을 숨긴다. 실제 플러그인 정리는 직렬 큐에서 끝낸다.
    _desiredRunning = false;
    _invalidateReading();
    return _enqueueReconcile();
  }

  Future<void> _enqueueReconcile() {
    final next = _lifecycle.then((_) => _reconcile());
    // _reconcile은 모든 플랫폼 오류를 fail-safe로 흡수하므로 큐가 끊기지 않는다.
    _lifecycle = next;
    return next;
  }

  Future<void> _reconcile() async {
    if (!_desiredRunning) {
      await _releaseController();
      return;
    }
    final current = _controller;
    if (current != null && current.value.isStreamingImages) return;

    try {
      final cameras = await availableCameras();
      if (!_desiredRunning || cameras.isEmpty) {
        _invalidateReading();
        return;
      }

      final description = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        description,
        _resolutionPreset(kCameraResolutionPreset),
        enableAudio: false,
        imageFormatGroup: _requestedImageFormat,
      );
      _controller = controller;
      await controller.initialize();

      if (!_desiredRunning) {
        await _releaseController();
        return;
      }

      _resetPipeline();
      _clock
        ..reset()
        ..start();
      await controller.startImageStream(_handleImage);

      // stop()이 startImageStream의 플랫폼 round-trip 중 들어온 경우.
      if (!_desiredRunning) await _releaseController();
    } catch (_) {
      _invalidateReading();
      await _releaseController();
    }
  }

  ImageFormatGroup get _requestedImageFormat =>
      defaultTargetPlatform == TargetPlatform.iOS
      ? ImageFormatGroup.bgra8888
      : ImageFormatGroup.yuv420;

  ResolutionPreset _resolutionPreset(String name) {
    switch (name) {
      case 'low':
        return ResolutionPreset.low;
      case 'high':
        return ResolutionPreset.high;
      case 'veryHigh':
        return ResolutionPreset.veryHigh;
      case 'ultraHigh':
        return ResolutionPreset.ultraHigh;
      case 'max':
        return ResolutionPreset.max;
      case 'medium':
      default:
        return ResolutionPreset.medium;
    }
  }

  void _handleImage(CameraImage image) {
    if (!_desiredRunning || _processingFrame) return;
    final shouldProcess = _frameIndex % _processEveryN == 0;
    _frameIndex++;
    if (!shouldProcess) return;

    _processingFrame = true;
    try {
      final roi = rotateBgr(_convert(image), _frameRotationDegrees());
      final frame = _detector.detect(roi);
      final t = _clock.elapsedMicroseconds / Duration.microsecondsPerSecond;
      _stateMachine.update(t, frame.raw, reason: frame.reason);
      final remainSec = _digitReader.read(roi)?.toDouble();
      _latest = toReading(_stateMachine.state, remainSec: remainSec);
      _lastFrameElapsedMs = _clock.elapsedMilliseconds;
    } catch (_) {
      // 손상 프레임 뒤에 이전 GREEN 상태가 즉시 부활하지 않도록 상태 이력도
      // 함께 비운다. 다음 정상 프레임은 다시 debounce를 통과해야 한다.
      _resetPipeline();
      _invalidateReading();
    } finally {
      _processingFrame = false;
    }
  }

  RoiImage _convert(CameraImage image) {
    switch (image.format.group) {
      case ImageFormatGroup.yuv420:
        if (image.planes.length < 3) {
          throw const FormatException('YUV420 frame needs three planes');
        }
        final y = image.planes[0];
        final u = image.planes[1];
        final v = image.planes[2];
        final uPixelStride = u.bytesPerPixel ?? 1;
        final vPixelStride = v.bytesPerPixel ?? 1;
        if (u.bytesPerRow != v.bytesPerRow || uPixelStride != vPixelStride) {
          throw const FormatException('U/V plane layouts do not match');
        }
        return yuv420ToRoiBgr(
          YuvPlanes(
            y: y.bytes,
            u: u.bytes,
            v: v.bytes,
            width: image.width,
            height: image.height,
            yRowStride: y.bytesPerRow,
            uvRowStride: u.bytesPerRow,
            uvPixelStride: uPixelStride,
          ),
          _roiFrac,
        );
      case ImageFormatGroup.bgra8888:
        if (image.planes.isEmpty) {
          throw const FormatException('BGRA frame needs one plane');
        }
        final plane = image.planes.first;
        return bgra8888ToRoiBgr(
          plane.bytes,
          image.width,
          image.height,
          plane.bytesPerRow,
          _roiFrac,
        );
      case ImageFormatGroup.unknown:
      case ImageFormatGroup.jpeg:
      case ImageFormatGroup.nv21:
        throw FormatException(
          'unsupported camera format: ${image.format.group}',
        );
    }
  }

  int _frameRotationDegrees() {
    final controller = _controller;
    if (controller == null) return 0;
    final deviceDegrees = switch (controller.value.deviceOrientation) {
      DeviceOrientation.portraitUp => 0,
      DeviceOrientation.landscapeLeft => 90,
      DeviceOrientation.portraitDown => 180,
      DeviceOrientation.landscapeRight => 270,
    };
    final sensorDegrees = controller.description.sensorOrientation;
    if (controller.description.lensDirection == CameraLensDirection.front) {
      return (sensorDegrees + deviceDegrees) % 360;
    }
    return (sensorDegrees - deviceDegrees + 360) % 360;
  }

  void _resetPipeline() {
    _detector = ColorDetector(_config);
    _stateMachine = SignalStateMachine(_config);
    _digitReader = DigitReader(_config);
    _frameIndex = 0;
  }

  void _invalidateReading() {
    _latest = _unknownReading;
    _lastFrameElapsedMs = null;
  }

  Future<void> _releaseController() async {
    final controller = _controller;
    _controller = null;
    _clock.stop();
    _invalidateReading();
    if (controller == null) return;

    try {
      if (controller.value.isInitialized &&
          controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {
      // 정리 실패도 사용자에게 오래된 판정을 노출하지 않는 것이 우선이다.
    }
    try {
      await controller.dispose();
    } catch (_) {
      // dispose는 최선 노력. 읽기 상태는 위에서 이미 unknown으로 무효화했다.
    }
  }
}
