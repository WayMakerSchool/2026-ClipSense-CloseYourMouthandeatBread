/// 클립 카메라(XIAO ESP32S3 Sense) HTTP 스냅샷 → [VisionSource].
///
/// 폰 카메라 소스와 같은 [VisionPipeline] 으로 판정하고, 프레임 획득만 다르다:
/// `/capture` 를 [kClipPollInterval] 간격으로 폴링(이전 요청이 끝나기 전에는 새
/// 요청 없음), 헤더로 신선도·정지·재부팅을 추적([ClipFreshnessTracker]),
/// accepted 프레임만 JPEG 디코드 → 중앙 ROI → 파이프라인.
///
/// 안전 규칙(하드웨어 보고서 §10.4·§11.3, 설계 리뷰 제약):
/// * `latestReading.freshMs` = 폰 단조 시계 − 마지막 accepted 프레임의 보수적
///   촬영 시각. 같은 프레임(정지)은 신선도를 갱신하지 않으므로 judge 의 2초 규칙에
///   걸려 wait 가 되고, 2초를 넘기면 여기서도 판독을 지우고 파이프라인을 리셋한다.
/// * accepted 가 아닌 모든 결과(busy·503·timeout·transport·헤더/본문 불량·
///   역전·디코드 실패·손상 프레임)는 판독을 즉시 unknown 으로 하고 파이프라인을
///   리셋한다 — 정전 뒤 정상 프레임 한 장으로 GREEN 이 부활하지 않는다.
/// * 상태머신 시각은 기기 촬영 uptime(같은 bootId 안에서 단조 증가)이다. 수신·
///   처리 시각을 쓰면 점멸 판정이 네트워크 지터를 따라간다. bootId 가 바뀌면
///   이력을 버리고 새 시각 축을 쓴다.
/// * 401/403 은 failed(token_rejected) 로 두고 폴링을 멈춘다. 같은 토큰으로
///   재시도해도 결과가 같다. 다음 start() 에서 다시 시도한다.
/// * timeout/transport 는 unreachable — 폴링은 계속하고 다음 응답에서 복귀.
/// * 같은 프레임(sameFrame)·503 등만 kVisionStallMs 넘게 이어지면 status 는 stalled —
///   마지막 accepted 프레임 수신 시각(세션 첫 응답에서 초기화)으로 파생하며 래치가
///   없어 새 accepted 프레임이 오면 streaming 으로 복귀한다. 판독은 이미 kStaleMs 에서
///   지워져 있다. timeout/transport 는 그대로 unreachable 이 우선(스트리밍이 아니므로
///   stalled 아님). 재연결 자체는 진행이 아니다 — 복귀 뒤에도 프레임이 새로 오지
///   않으면 즉시 stalled. 자동 재시작 없음(후속 조각).
///
/// 이 클래스는 실기기(보드·폰)에서 검증되지 않았다. MockClient·루프백 HttpServer
/// ·스크립트 카메라로만 검증됐다.
library;

import 'dart:async';

import 'package:camera/camera.dart' show CameraController;
import 'package:flutter/foundation.dart';

import '../app/config.dart';
import '../camera/camera_vision_source.dart';
import '../signals/signal_reading.dart';
import '../vision/color_detector.dart';
import '../vision/detector_config.dart';
import '../vision/roi_image.dart';
import '../vision/vision_pipeline.dart';
import 'clip_freshness.dart';
import 'clip_snapshot.dart';
import 'clip_snapshot_client.dart';
import 'jpeg_frame.dart';

/// `--dart-define=CLIP_CAM_HOST` 문자열 → http URI. `192.168.4.1`,
/// `clipsense-a1b2.local:80`, `http://host[/prefix]` 를 받는다. 비어 있거나
/// http 가 아니거나 host 가 없으면 ArgumentError — 설정 오류를 폰 카메라로
/// 조용히 대체하지 않는다.
Uri clipBaseUri(String host) {
  final text = host.trim();
  if (text.isEmpty) throw ArgumentError.value(host, 'host', 'empty');
  final withScheme = text.contains('://') ? text : 'http://$text';
  final Uri uri;
  try {
    uri = Uri.parse(withScheme);
  } on FormatException catch (e) {
    throw ArgumentError.value(host, 'host', e.message);
  }
  if (uri.scheme != 'http' || uri.host.isEmpty) {
    throw ArgumentError.value(host, 'host', 'expected http://host[:port]');
  }
  return uri;
}

/// 401/403 때 [VisionDiagnostics.lastReason] 에 남기는 값. 컨트롤러가 이 값을
/// 보고 "토큰 설정을 확인하라"(clipTokenRejected)로 말한다.
const String kClipTokenRejectedReason = 'token_rejected';

/// [VisionDiagnostics.lastReason] 에 남기는 실패 이유 문자열.
String clipFailureReason(ClipFetchFailure failure) => switch (failure) {
  ClipFetchFailure.unauthorized => kClipTokenRejectedReason,
  ClipFetchFailure.busy => 'busy',
  ClipFetchFailure.captureFailed => 'capture_failed',
  ClipFetchFailure.badContentType => 'bad_content_type',
  ClipFetchFailure.badHeaders => 'bad_headers',
  ClipFetchFailure.emptyBody => 'empty_body',
  ClipFetchFailure.timeout => 'timeout',
  ClipFetchFailure.transport => 'transport',
};

typedef ClipCapture = Future<ClipFetchResult> Function();

class ClipVisionSource implements VisionSource {
  final ClipCapture _capture;
  final Uri _captureUri;
  final double _roiFrac;
  final Duration _pollInterval;
  final int _staleMs;
  final int _stallMs;
  final int Function() _mono;
  final RoiImage? Function(Uint8List jpeg, double roiFrac) _decode;

  final VisionPipeline _pipeline;
  final ClipFreshnessTracker _tracker = ClipFreshnessTracker();

  VisionSourceStatus _status = VisionSourceStatus.idle;
  bool _desiredRunning = false;
  int _generation = 0;
  Future<void>? _activePoll;

  SignalReading _latest = _unknownReading;
  int? _capturedAtMonoMs;
  VisionDiagnostics? _diagnostics;
  int? _diagnosticsAtMonoMs;
  int _framesProcessed = 0;
  ClipCaptureMeta? _lastMeta;
  int? _lastRttMs;

  /// 정지 감시 기준점(폰 단조 ms): 세션의 첫 응답에서 초기화, 이후 accepted
  /// 프레임마다 갱신. 실패 응답·재연결은 진행이 아니다.
  int? _lastProgressMonoMs;

  /// [baseUrl]·[token] 으로 실제 [ClipSnapshotClient] 를 만든다. 테스트는
  /// [capture] 로 전송을, [monoClock] 으로 시계를, [decoder] 로 디코드를 주입한다.
  ClipVisionSource({
    required Uri baseUrl,
    required String token,
    DetectorConfig config = const DetectorConfig.defaults(),
    double roiFrac = kClipRoiFrac,
    Duration pollInterval = kClipPollInterval,
    Duration requestTimeout = kClipRequestTimeout,
    int staleMs = kStaleMs,
    int stallMs = kVisionStallMs,
    ClipCapture? capture,
    int Function()? monoClock,
    RoiImage? Function(Uint8List jpeg, double roiFrac)? decoder,
  }) : assert(roiFrac > 0 && roiFrac <= 1),
       _captureUri = ClipSnapshotClient(
         baseUrl: baseUrl,
         token: token,
       ).captureUri,
       _capture =
           capture ??
           ClipSnapshotClient(
             baseUrl: baseUrl,
             token: token,
             timeout: requestTimeout,
             monoClock: monoClock,
           ).capture,
       _roiFrac = roiFrac,
       _pollInterval = pollInterval,
       _staleMs = staleMs,
       _stallMs = stallMs,
       _mono = monoClock ?? _defaultMonoMs,
       _decode = decoder ?? decodeJpegToRoiBgr,
       _pipeline = VisionPipeline(config);

  static final Stopwatch _stopwatch = Stopwatch()..start();
  static int _defaultMonoMs() => _stopwatch.elapsedMilliseconds;

  static const SignalReading _unknownReading = SignalReading(
    SignalColor.unknown,
    null,
    SignalSource.vision,
  );

  /// 실제로 요청하는 `/capture` 주소(설정 확인·테스트용).
  Uri get captureUri => _captureUri;

  /// 마지막 accepted 프레임의 메타데이터(진단용). 정지·실패 뒤에는 null.
  ClipCaptureMeta? get lastMeta => _lastMeta;

  /// 마지막 응답의 왕복 시간(ms, 진단용).
  int? get lastRttMs => _lastRttMs;

  @override
  SignalReading get latestReading {
    final capturedAt = _capturedAtMonoMs;
    if (capturedAt == null) return _unknownReading;
    final age = (_mono() - capturedAt).clamp(0, 1 << 31);
    return SignalReading(
      _latest.color,
      _latest.remainSec,
      SignalSource.vision,
      freshMs: age,
      raw: _latest.raw,
    );
  }

  /// 내부 `_status` 는 stalled 를 갖지 않는다 — 스트리밍 중 마지막 accepted 프레임
  /// 나이로 파생한다([statusForStream]).
  @override
  VisionSourceStatus get status {
    final anchor = _lastProgressMonoMs;
    return statusForStream(
      _status,
      lastFrameAgeMs: _status == VisionSourceStatus.streaming && anchor != null
          ? (_mono() - anchor).clamp(0, 1 << 31)
          : null,
      stallMs: _stallMs,
    );
  }

  @override
  VisionDiagnostics? get diagnostics {
    final snapshot = _diagnostics;
    final recordedAt = _diagnosticsAtMonoMs;
    if (snapshot == null || recordedAt == null) return null;
    return VisionDiagnostics(
      lastReason: snapshot.lastReason,
      areaRatio: snapshot.areaRatio,
      brightness: snapshot.brightness,
      processMs: snapshot.processMs,
      framesProcessed: snapshot.framesProcessed,
      lastFrameAgeMs: (_mono() - recordedAt).clamp(0, 1 << 31),
    );
  }

  /// 클립 카메라는 폰 화면에 그릴 프리뷰가 없다(항상 null).
  @override
  CameraController? get previewController => null;

  @override
  Future<void> start() async {
    if (_desiredRunning) return;
    _desiredRunning = true;
    _generation++;
    _status = VisionSourceStatus.starting;
    _lastProgressMonoMs = null;
    _tracker.reset();
    _pipeline.reset();
    _invalidateReading();
    _resetDiagnostics();
    unawaited(_loop(_generation));
  }

  @override
  Future<void> stop() async {
    _desiredRunning = false;
    _generation++;
    _status = VisionSourceStatus.idle;
    _lastProgressMonoMs = null;
    _invalidateReading();
    _resetDiagnostics();
    _tracker.reset();
    _pipeline.reset();
    // 진행 중인 요청은 generation 불일치로 결과가 버려진다. 완료는 기다리지
    // 않는다(타임아웃까지 stop 이 막히면 안 된다).
  }

  Future<void> _loop(int generation) async {
    while (_desiredRunning && generation == _generation) {
      await pollOnce();
      if (!_desiredRunning || generation != _generation) return;
      if (_status == VisionSourceStatus.failed) return; // 토큰 거부: 재시도 무의미
      await Future<void>.delayed(_pollInterval);
    }
  }

  /// 스냅샷 한 번 → 판정 갱신. 동시에 여러 번 불리면 진행 중인 한 번을 공유한다
  /// (테스트·수동 호출용; 루프가 이 함수를 쓴다).
  Future<void> pollOnce() {
    final active = _activePoll;
    if (active != null) return active;
    final generation = _generation;
    late final Future<void> operation;
    operation = () async {
      try {
        final result = await _capture();
        if (generation != _generation) return; // stop()/재시작 뒤 늦은 응답
        _handle(result);
      } catch (_) {
        if (generation != _generation) return;
        _fail('transport', VisionSourceStatus.unreachable);
      } finally {
        if (identical(_activePoll, operation)) _activePoll = null;
      }
    }();
    _activePoll = operation;
    return operation;
  }

  void _handle(ClipFetchResult result) {
    _lastRttMs = result.rttMs;
    switch (result) {
      case ClipFetchFailed(:final failure):
        final reason = clipFailureReason(failure);
        switch (failure) {
          case ClipFetchFailure.unauthorized:
            _fail(reason, VisionSourceStatus.failed);
          case ClipFetchFailure.timeout:
          case ClipFetchFailure.transport:
            _fail(reason, VisionSourceStatus.unreachable);
          case ClipFetchFailure.busy:
          case ClipFetchFailure.captureFailed:
          case ClipFetchFailure.badContentType:
          case ClipFetchFailure.badHeaders:
          case ClipFetchFailure.emptyBody:
            _fail(reason, VisionSourceStatus.streaming);
        }
      case ClipFetchOk(:final meta, :final jpeg):
        final now = _mono();
        _enterStreaming(now);
        final observation = _tracker.observe(
          meta,
          rttMs: result.rttMs,
          receivedMonoMs: now,
        );
        if (observation.bootChanged) {
          // 재부팅: 이전 boot 프레임으로 쌓은 디바운스·점멸 이력은 무효.
          _pipeline.reset();
          _invalidateReading();
        }
        switch (observation.verdict) {
          case ClipFrameVerdict.accepted:
            _lastMeta = meta;
            _lastProgressMonoMs = now; // 새 프레임 = 진행(디코드 결과와 무관)
            _accept(meta, jpeg, observation.capturedAtMonoMs!, now);
          case ClipFrameVerdict.sameFrame:
            // 신선도를 갱신하지 않는다 — 판독은 그대로 늙는다. 2초를 넘긴
            // 정지는 판독을 지우고 파이프라인을 리셋한다(GREEN 부활 방지).
            final capturedAt = _capturedAtMonoMs;
            if (capturedAt != null && now - capturedAt > _staleMs) {
              _pipeline.reset();
              _invalidateReading();
            }
            _recordFailure('same_frame', now);
          case ClipFrameVerdict.replayOrReorder:
            _pipeline.reset();
            _invalidateReading();
            _recordFailure('replay_or_reorder', now);
        }
    }
  }

  void _accept(
    ClipCaptureMeta meta,
    Uint8List jpeg,
    int capturedAtMonoMs,
    int now,
  ) {
    final stopwatch = Stopwatch()..start();
    final roi = _decode(jpeg, _roiFrac);
    if (roi == null) {
      _pipeline.reset();
      _invalidateReading();
      _recordFailure(
        'decode_failed',
        now,
        processMs: stopwatch.elapsedMilliseconds,
      );
      return;
    }
    try {
      // 상태머신 시각 = 기기 촬영 uptime(초). 같은 boot 안에서 단조 증가.
      final tSec = meta.captureUptimeUs / Duration.microsecondsPerSecond;
      final result = _pipeline.process(roi, tSec);
      _latest = result.reading;
      _capturedAtMonoMs = capturedAtMonoMs;
      _framesProcessed++;
      _diagnostics = VisionDiagnostics(
        lastReason: result.frame.reason,
        areaRatio: _dominantAreaRatio(result.frame),
        brightness: result.frame.brightness,
        processMs: stopwatch.elapsedMilliseconds,
        framesProcessed: _framesProcessed,
      );
      _diagnosticsAtMonoMs = now;
    } catch (_) {
      // process() 는 던지기 전에 스스로 리셋한다. 판독만 지우면 된다.
      _invalidateReading();
      _recordFailure(
        'frame_error',
        now,
        processMs: stopwatch.elapsedMilliseconds,
      );
    }
  }

  /// 전송 실패: 판독 무효 + 파이프라인 리셋 + 상태·이유 기록.
  void _fail(String reason, VisionSourceStatus status) {
    final now = _mono();
    if (status == VisionSourceStatus.streaming) {
      _enterStreaming(now); // 기기는 닿는다(409/503/헤더 불량) — 응답은 받았다
    } else {
      _status = status;
    }
    _pipeline.reset();
    _invalidateReading();
    _recordFailure(reason, now);
  }

  /// 응답을 받아 스트리밍 상태로 들어간다. 정지 감시 기준점은 세션의 첫 응답에서만
  /// 초기화한다 — 재연결이나 실패 응답은 진행이 아니므로 기준점을 당기지 않는다.
  void _enterStreaming(int now) {
    _status = VisionSourceStatus.streaming;
    _lastProgressMonoMs ??= now;
  }

  void _recordFailure(String reason, int now, {int processMs = 0}) {
    _diagnostics = VisionDiagnostics(
      lastReason: reason,
      processMs: processMs,
      framesProcessed: _framesProcessed,
    );
    _diagnosticsAtMonoMs = now;
  }

  static double _dominantAreaRatio(FrameResult frame) => switch (frame.raw) {
    rawRed => frame.red.areaRatio,
    rawGreen => frame.green.areaRatio,
    _ =>
      frame.red.areaRatio > frame.green.areaRatio
          ? frame.red.areaRatio
          : frame.green.areaRatio,
  };

  void _invalidateReading() {
    _latest = _unknownReading;
    _capturedAtMonoMs = null;
    _lastMeta = null;
  }

  void _resetDiagnostics() {
    _diagnostics = null;
    _diagnosticsAtMonoMs = null;
    _framesProcessed = 0;
    _lastRttMs = null;
  }
}
