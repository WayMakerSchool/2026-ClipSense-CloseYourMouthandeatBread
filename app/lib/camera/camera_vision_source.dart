/// camera 플러그인 스트림을 비전 판정으로 바꾸는 하드웨어 경계.
///
/// GuidanceController는 [VisionSource]만 알아 카메라 플러그인과 분리된다.
/// 시작/정지는 직렬화되고 최종 요청 상태를 따르므로, 권한 다이얼로그를 기다리는
/// 동안 사용자가 정지하거나 화면을 닫아도 뒤늦게 스트림이 살아나지 않는다.
///
/// 판정(SignalReading)과 별개로 [VisionSourceStatus]·[VisionDiagnostics]를
/// 노출한다 — 실기기에서 권한 거부·미인식·너무 어두움이 모두 같은 unknown으로만
/// 보이던 것을 컨트롤러(권한 거부 이유)와 진단 스트립(디버그 빌드)이 구분한다.
/// 판정 흐름과 fail-safe는 그대로다(진단은 읽기 전용 부산물).
library;

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app/config.dart';
import '../signals/signal_reading.dart';
import '../vision/color_detector.dart';
import '../vision/detector_config.dart';
import '../vision/roi_image.dart';
import '../vision/vision_pipeline.dart';
import 'frame_converter.dart';

/// kClipDebug 빌드에서 처리 프레임 N개마다 debugPrint 한 줄(로그 폭주 방지).
const int _kDebugPrintEveryN = 30;

/// 스트림 프레임을 사용자가 기기를 든 방향 기준으로 세우기 위해 앱이 추가로
/// 돌려야 하는 시계 방향 각도(0/90/180/270). 플랫폼별 플러그인 동작 차이를
/// 여기서만 흡수하는 순수 함수다.
///
/// * Android(CameraX): 버퍼가 센서 좌표계 그대로 오므로 sensor−device만큼 돌린다.
///   전면 카메라는 거울상이라 sensor+device.
/// * iOS(camera_avfoundation 0.9.23+2): sensorOrientation을 90으로 고정 보고하지만
///   (lib/src/utils.dart:17) DefaultCamera.swift updateOrientation(775-795)이
///   AVCaptureVideoDataOutput 연결의 videoOrientation을 기기 방향으로 맞추므로
///   스트림 픽셀버퍼가 이미 회전돼 온다. 여기서 또 돌리면 이중 회전으로 ROI가
///   옆으로 눕는다(색은 되지만 숫자 판독 불가) → 0.
int frameRotationDegrees({
  required TargetPlatform platform,
  required int sensorOrientation,
  required DeviceOrientation deviceOrientation,
  required CameraLensDirection lens,
}) {
  if (platform == TargetPlatform.iOS) return 0;

  final deviceDegrees = switch (deviceOrientation) {
    DeviceOrientation.portraitUp => 0,
    DeviceOrientation.landscapeLeft => 90,
    DeviceOrientation.portraitDown => 180,
    DeviceOrientation.landscapeRight => 270,
  };
  if (lens == CameraLensDirection.front) {
    return (sensorOrientation + deviceDegrees) % 360;
  }
  return (sensorOrientation - deviceDegrees + 360) % 360;
}

/// 카메라 소스의 수명주기·실패 상태. 판정(SignalReading)이 unknown인 이유를
/// 컨트롤러가 구분하고(권한 거부 → "설정에서 허용" 안내) 진단 스트립이 그린다.
enum VisionSourceStatus {
  /// 시작 요청 전이거나 정지된 상태.
  idle,

  /// 카메라 목록 조회·권한 요청·초기화 진행 중.
  starting,

  /// 프레임 스트림 수신 중([VisionSource.previewController]가 유효한 유일한 상태).
  streaming,

  /// 카메라 권한 거부. 신호등을 향해도 못 고치고 설정에서 허용해야 한다.
  permissionDenied,

  /// 사용할 카메라가 없음(시뮬레이터·카메라 없는 기기).
  unavailable,

  /// 그 외 초기화·스트림 실패(다음 시작에서 재시도).
  failed,
}

/// 진단 스트립용 불변 값 객체. 판정에는 쓰지 않는다(읽기 전용 부산물).
@immutable
class VisionDiagnostics {
  /// 마지막 처리 프레임의 [FrameResult.reason](too_dark / brightness_jump /
  /// blob_too_large / no_blob). 색이 검출됐으면 ''. 손상 프레임은 'frame_error'.
  final String lastReason;

  /// 마지막 프레임에서 판정 색(없으면 더 큰 쪽)의 최대 blob 면적 / ROI 면적.
  final double? areaRatio;

  /// 마지막 프레임 ROI 평균 밝기(HSV V, 0~255). too_dark 진단용.
  final double? brightness;

  /// 마지막 프레임 처리 시간(ms). 변환+검출+숫자 판독.
  final int processMs;

  /// 시작 이후 실제로 처리한 프레임 수(건너뛴 프레임 제외).
  final int framesProcessed;

  /// 마지막 처리 프레임 이후 경과(ms). 프레임이 아직 없으면 null.
  final int? lastFrameAgeMs;

  const VisionDiagnostics({
    this.lastReason = '',
    this.areaRatio,
    this.brightness,
    this.processMs = 0,
    this.framesProcessed = 0,
    this.lastFrameAgeMs,
  });

  @override
  bool operator ==(Object other) =>
      other is VisionDiagnostics &&
      other.lastReason == lastReason &&
      other.areaRatio == areaRatio &&
      other.brightness == brightness &&
      other.processMs == processMs &&
      other.framesProcessed == framesProcessed &&
      other.lastFrameAgeMs == lastFrameAgeMs;

  @override
  int get hashCode => Object.hash(
    lastReason,
    areaRatio,
    brightness,
    processMs,
    framesProcessed,
    lastFrameAgeMs,
  );

  @override
  String toString() =>
      'VisionDiagnostics(reason: $lastReason, area: $areaRatio, '
      'brightness: $brightness, ${processMs}ms, frames: $framesProcessed, '
      'age: $lastFrameAgeMs)';
}

/// availableCameras()가 빈 목록을 돌려줄 때(시뮬레이터·카메라 없는 기기) 던진다.
/// [statusFromCameraError]가 [VisionSourceStatus.unavailable]로 분류한다.
class NoCameraAvailableException implements Exception {
  const NoCameraAvailableException();

  @override
  String toString() => 'NoCameraAvailableException: 사용할 카메라가 없습니다';
}

/// 권한 거부로 분류하는 플러그인 오류 code. 출처는 [statusFromCameraError] 참조.
const Set<String> _kPermissionDeniedCodes = {
  'CameraAccessDenied',
  'CameraAccessDeniedWithoutPrompt',
  'CameraAccessRestricted',
  'cameraPermission',
};

/// 카메라 초기화 예외를 소스 상태로 분류하는 순수 함수.
///
/// 권한 거부 code 문자열은 pub-cache의 실제 플러그인에서 확인했다:
/// * iOS camera_avfoundation 0.9.23+2 CameraPermissionManager.swift —
///   "CameraAccessDeniedWithoutPrompt"(:81, 이전에 거부해 다이얼로그 없이 실패),
///   "CameraAccessRestricted"(:100, 보호자 제한 등), "CameraAccessDenied"(:123,
///   방금 다이얼로그에서 거부). avfoundation_camera.dart:74·:107·:379가
///   PlatformException을 CameraException(e.code)로 다시 던진다.
/// * Android camera_android_camerax 0.6.30 CameraPermissionsManager.java:36 —
///   "CameraAccessDenied". android_camera_camerax.dart:381이 CameraException
///   (errorCode)로 던진다. 같은 파일 :32 "CameraPermissionsRequestOngoing"은
///   다른 권한 요청과 겹친 일시 오류라 거부로 보지 않는다(failed → 재시도 가능).
///   거부로 잘못 분류하면 전맹 사용자에게 "설정에서 허용하세요"를 잘못 말한다.
/// * "cameraPermission": 현재 의존성의 어느 플러그인도 code로 내지 않는다
///   (구 camera_android 0.10.8+17에도 Java 식별자로만 등장). 플러그인 교체에
///   대비한 방어적 항목이다.
///
/// PlatformException이 CameraException으로 감싸이지 않고 새어 나온 경우도 같은
/// code로 분류한다. [NoCameraAvailableException] → unavailable, 그 외 → failed.
VisionSourceStatus statusFromCameraError(Object e) {
  if (e is NoCameraAvailableException) return VisionSourceStatus.unavailable;
  final code = switch (e) {
    CameraException() => e.code,
    PlatformException() => e.code,
    _ => null,
  };
  if (code != null && _kPermissionDeniedCodes.contains(code)) {
    return VisionSourceStatus.permissionDenied;
  }
  return VisionSourceStatus.failed;
}

abstract interface class VisionSource {
  /// 최신 판정. 구현체는 호출 시점까지의 실제 경과 시간을 freshMs에 반영한다.
  SignalReading get latestReading;

  /// 수명주기·실패 상태. 판정이 unknown인 이유를 구분하는 데만 쓴다.
  VisionSourceStatus get status;

  /// 마지막 처리 프레임의 진단. 아직 프레임이 없으면 null.
  VisionDiagnostics? get diagnostics;

  /// 스트리밍 중일 때만 non-null. 화면이 CameraPreview로 그린다(디버그 빌드).
  /// 정지·실패 직후에는 null이어야 한다 — 폐기된 컨트롤러를 그리면 안 된다.
  CameraController? get previewController;

  /// 여러 번 불러도 안전해야 한다.
  Future<void> start();

  /// 초기화 중이거나 이미 정지한 상태에서도 여러 번 불러도 안전해야 한다.
  Future<void> stop();
}

class CameraVisionSource implements VisionSource {
  final double _roiFrac;
  final int _processEveryN;

  /// 검출→상태머신→숫자→판독. 클립 카메라 소스와 같은 객체를 쓴다.
  final VisionPipeline _pipeline;

  CameraController? _controller;
  Future<void> _lifecycle = Future<void>.value();
  bool _desiredRunning = false;
  bool _processingFrame = false;
  int _frameIndex = 0;

  final Stopwatch _clock = Stopwatch();
  SignalReading _latest = _unknownReading;
  int? _lastFrameElapsedMs;

  VisionSourceStatus _status = VisionSourceStatus.idle;
  VisionDiagnostics? _diagnostics;
  int? _diagnosticsElapsedMs;
  int _framesProcessed = 0;

  /// 사용 가능한 카메라 목록 조회. 테스트가 플랫폼 채널 없이 초기화 실패
  /// 경로를 재현할 수 있도록 주입 가능하게 둔다(기본은 플러그인 함수).
  final Future<List<CameraDescription>> Function() _cameraLister;

  CameraVisionSource({
    DetectorConfig config = const DetectorConfig.defaults(),
    double roiFrac = kRoiFrac,
    int processEveryN = kCameraProcessEveryN,
    Future<List<CameraDescription>> Function()? cameraLister,
  }) : assert(roiFrac > 0 && roiFrac <= 1),
       assert(processEveryN > 0),
       _cameraLister = cameraLister ?? availableCameras,
       _roiFrac = roiFrac,
       _processEveryN = processEveryN,
       _pipeline = VisionPipeline(config);

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
  VisionSourceStatus get status => _status;

  @override
  VisionDiagnostics? get diagnostics {
    final snapshot = _diagnostics;
    final recordedAt = _diagnosticsElapsedMs;
    if (snapshot == null || recordedAt == null) return null;
    // latestReading.freshMs와 같은 방식 — 호출 시점까지의 실제 경과를 반영한다.
    final age = (_clock.elapsedMilliseconds - recordedAt).clamp(0, 1 << 31);
    return VisionDiagnostics(
      lastReason: snapshot.lastReason,
      areaRatio: snapshot.areaRatio,
      brightness: snapshot.brightness,
      processMs: snapshot.processMs,
      framesProcessed: snapshot.framesProcessed,
      lastFrameAgeMs: age,
    );
  }

  @override
  CameraController? get previewController =>
      _status == VisionSourceStatus.streaming ? _controller : null;

  @override
  Future<void> start() {
    _desiredRunning = true;
    // 이미 스트리밍 중이면 그대로. 아니면 큐가 돌기 전에도 "시작 중"으로 보인다.
    if (_status != VisionSourceStatus.streaming) {
      _status = VisionSourceStatus.starting;
    }
    return _enqueueReconcile();
  }

  @override
  Future<void> stop() {
    // 호출 즉시 오래된 green을 숨기고 프리뷰도 내린다(폐기될 컨트롤러를 화면이
    // 그리지 않게). 실제 플러그인 정리는 직렬 큐에서 끝낸다.
    _desiredRunning = false;
    _status = VisionSourceStatus.idle;
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
      _status = VisionSourceStatus.idle;
      await _releaseController();
      return;
    }
    final current = _controller;
    if (current != null && current.value.isStreamingImages) {
      _status = VisionSourceStatus.streaming;
      return;
    }

    _status = VisionSourceStatus.starting;
    try {
      final cameras = await _cameraLister();
      if (!_desiredRunning) {
        _invalidateReading();
        _status = VisionSourceStatus.idle;
        return;
      }
      if (cameras.isEmpty) throw const NoCameraAvailableException();

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
        _status = VisionSourceStatus.idle;
        await _releaseController();
        return;
      }

      _resetPipeline();
      _resetDiagnostics();
      _clock
        ..reset()
        ..start();
      await controller.startImageStream(_handleImage);
      _status = VisionSourceStatus.streaming;

      // stop()이 startImageStream의 플랫폼 round-trip 중 들어온 경우.
      if (!_desiredRunning) {
        _status = VisionSourceStatus.idle;
        await _releaseController();
      }
    } catch (e) {
      // 실패 상태는 다음 start()/stop()까지 남는다 — 컨트롤러가 권한 거부를
      // 구분해 말하고, 진단 스트립이 원인을 보여 준다. 판정은 unknown(fail-safe).
      // 단, 초기화 도중 stop()이 들어왔다면 이미 정지한 것이므로 idle을 지킨다.
      _status = _desiredRunning
          ? statusFromCameraError(e)
          : VisionSourceStatus.idle;
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
    final stopwatch = Stopwatch()..start();
    try {
      final roi = rotateBgr(_convert(image), _frameRotationDegrees());
      final t = _clock.elapsedMicroseconds / Duration.microsecondsPerSecond;
      final result = _pipeline.process(roi, t);
      _latest = result.reading;
      _lastFrameElapsedMs = _clock.elapsedMilliseconds;
      _recordDiagnostics(result.frame, stopwatch.elapsedMilliseconds);
    } catch (_) {
      // 손상 프레임 뒤에 이전 GREEN 상태가 즉시 부활하지 않도록 상태 이력도
      // 함께 비운다(변환 단계 실패도 포함). 다음 정상 프레임은 다시 debounce를
      // 통과해야 한다.
      _resetPipeline();
      _invalidateReading();
      // 진단은 판정과 무관한 부산물이다. 여기서 던지면 플러그인 스트림
      // 콜백으로 예외가 새어 나가므로 별도로 삼킨다.
      try {
        _recordDiagnostics(null, stopwatch.elapsedMilliseconds);
      } catch (_) {}
    } finally {
      _processingFrame = false;
    }
  }

  /// 진단 갱신(판정과 무관한 읽기 전용 값). [frame]이 null이면 손상 프레임.
  void _recordDiagnostics(FrameResult? frame, int processMs) {
    _framesProcessed++;
    final diag = frame == null
        ? VisionDiagnostics(
            lastReason: 'frame_error',
            processMs: processMs,
            framesProcessed: _framesProcessed,
          )
        : VisionDiagnostics(
            lastReason: frame.reason,
            areaRatio: _dominantAreaRatio(frame),
            brightness: frame.brightness,
            processMs: processMs,
            framesProcessed: _framesProcessed,
          );
    _diagnostics = diag;
    _diagnosticsElapsedMs = _clock.elapsedMilliseconds;

    if (kClipDebug && _framesProcessed % _kDebugPrintEveryN == 0) {
      final area = diag.areaRatio?.toStringAsFixed(4) ?? '-';
      final brightness = diag.brightness?.toStringAsFixed(0) ?? '-';
      final reason = diag.lastReason.isEmpty ? '-' : diag.lastReason;
      debugPrint(
        '[vision] #$_framesProcessed ${_status.name} '
        'state=${_latest.color.name} raw=${frame?.raw ?? '-'} '
        'reason=$reason area=$area v=$brightness ${processMs}ms',
      );
    }
  }

  /// 판정 색의 blob 면적 비율. NONE이면 더 큰 쪽(임계 미달 진단용).
  static double _dominantAreaRatio(FrameResult frame) => switch (frame.raw) {
    rawRed => frame.red.areaRatio,
    rawGreen => frame.green.areaRatio,
    _ =>
      frame.red.areaRatio > frame.green.areaRatio
          ? frame.red.areaRatio
          : frame.green.areaRatio,
  };

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
    return frameRotationDegrees(
      platform: defaultTargetPlatform,
      sensorOrientation: controller.description.sensorOrientation,
      deviceOrientation: controller.value.deviceOrientation,
      lens: controller.description.lensDirection,
    );
  }

  void _resetPipeline() {
    _pipeline.reset();
    _frameIndex = 0;
  }

  void _resetDiagnostics() {
    _diagnostics = null;
    _diagnosticsElapsedMs = null;
    _framesProcessed = 0;
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
    _resetDiagnostics();
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
