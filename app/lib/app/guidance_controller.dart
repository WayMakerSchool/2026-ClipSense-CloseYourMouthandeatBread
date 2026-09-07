/// 엔진 루프 컨트롤러. 1초마다 실API→판단→음성/햅틱, 화면에 상태 통지.
///
/// Flutter 위젯에 의존하지 않는다(ChangeNotifier만). fetch·interval을 주입해
/// 네트워크·타이머 없이 테스트한다. tickOnce()는 한 틱을 노출(테스트·수동 호출).
library;

import 'dart:async';

import 'package:camera/camera.dart' show CameraController;
import 'package:flutter/foundation.dart';

import '../camera/camera_vision_source.dart';
import '../signals/signal_reading.dart';
import '../signals/signal_api.dart' as api;
import '../signals/vision_adapter.dart';
import '../signals/judge.dart';
import '../feedback/feedback_controller.dart';
import 'config.dart';

/// 주입 가능한 fetch 시그니처(실제 fetchReading의 축약형).
typedef FetchReading =
    Future<SignalReading> Function(
      String itstId,
      String direction,
      String apiKey, {
      required int nowMs,
    });

class GuidanceController extends ChangeNotifier {
  final FeedbackController _feedback;
  final String _itstId;
  final String _direction;
  final FetchReading _fetch;
  final Duration _interval;
  final bool _allowSingleSource;
  final VisionSource? _vision;
  final String _apiKey;
  final bool _apiConfigured;

  /// 밀리초 시계. API 요청 전후를 같은 시계로 재어 fetch 소요 시간을 구한다.
  /// 테스트가 주입해 지연 재-aging을 결정적으로 검증한다.
  final int Function() _clock;

  Timer? _timer;
  Future<void>? _activeTick;
  int _generation = 0;
  bool _running = false;
  bool _disposed = false;
  Decision _decision = Decision.unknown;
  DecisionReason _reason = DecisionReason.sourcesUnavailable;
  double? _remainSec;
  SignalReading? _lastApiReading;
  SignalReading? _lastVisionReading;

  GuidanceController({
    required FeedbackController feedback,
    required String itstId,
    required String direction,
    VisionSource? vision,
    FetchReading? fetch,
    Duration interval = kLoopInterval,
    bool allowSingleSource = kAllowSingleSource,
    String apiKey = kApiKey,
    int Function()? clock,
  }) : _feedback = feedback,
       _clock = clock ?? _wallClockMs,
       _itstId = itstId,
       _direction = direction,
       _vision = vision,
       _apiKey = apiKey,
       _apiConfigured = fetch != null || apiKey.isNotEmpty,
       _fetch = fetch ?? _defaultFetch,
       _interval = interval,
       _allowSingleSource = allowSingleSource;

  static int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;

  static Future<SignalReading> _defaultFetch(
    String itstId,
    String direction,
    String apiKey, {
    required int nowMs,
  }) {
    return api.fetchReading(itstId, direction, apiKey, nowMs: nowMs);
  }

  bool get running => _running;
  bool get apiConfigured => _apiConfigured;
  Decision get decision => _decision;
  DecisionReason get reason => _reason;
  double? get remainSec => _remainSec;

  /// 진단용(디버그 스트립). 마지막 틱이 판정에 실제로 쓴 API·카메라 판독 —
  /// 판정에는 관여하지 않는다. fetch 실패 틱과 정지 뒤에는 null.
  SignalReading? get lastApiReading => _lastApiReading;
  SignalReading? get lastVisionReading => _lastVisionReading;

  /// 카메라 소스 상태·진단·프리뷰(소스에 위임, 카메라 미주입이면 null).
  VisionSourceStatus? get visionStatus => _vision?.status;
  VisionDiagnostics? get visionDiagnostics => _vision?.diagnostics;
  CameraController? get visionPreviewController => _vision?.previewController;

  void start() {
    if (_running) return;
    _running = true;
    _generation++;
    // 이전 세션의 느린 fetch가 아직 진행 중이어도 새 세션의 첫 판정을 그 뒤로
    // 미루지 않는다. 옛 tick은 generation 불일치로 결과가 버려진다.
    _activeTick = null;
    unawaited(_startVision());
    _timer = Timer.periodic(_interval, (_) => unawaited(tickOnce()));
    notifyListeners();
    unawaited(tickOnce()); // 시작 즉시 첫 확인(1초 기다리지 않음)
  }

  /// 안내 정지. 실제로 실행 중이었고 [announce]면 정지 음성을 낸다(탭·
  /// 백그라운드 정지 — 전맹 사용자가 멈춘 것을 알 수 있게). 이미 정지된 상태의
  /// 호출은 말하지 않는다(중복 안내 방지). 화면을 떠나는 dispose() 경로는
  /// stop()을 거치지 않으므로 말하지 않는다.
  void stop({bool announce = true}) {
    final wasRunning = _running;
    _timer?.cancel();
    _timer = null;
    _running = false;
    _generation++; // 이미 진행 중인 API 응답이 정지 상태를 되살리지 못하게 무효화
    _activeTick = null; // 다음 start()의 첫 tick이 옛 fetch를 기다리지 않게
    unawaited(_stopVision());
    _feedback.reset();
    // 정지 시 마지막 판정을 지운다 — 그대로 두면 정지 후에도 화면/스크린리더가
    // 오래된 "건너세요"(walk)를 계속 보여줄 수 있음(안전: 실시간 근거 없는
    // 판정을 전맹 사용자에게 노출하면 안 됨).
    _decision = Decision.unknown;
    _reason = DecisionReason.sourcesUnavailable;
    _remainSec = null;
    _lastApiReading = null;
    _lastVisionReading = null;
    // 정지 음성은 판정 정리 뒤에 — 진행 중이던 판정 음성(TTS)을 끊고 나온다.
    if (wasRunning && announce) unawaited(_feedback.announceStopped());
    notifyListeners();
  }

  void toggle() => _running ? stop() : start();

  Future<void> _startVision() async {
    final vision = _vision;
    if (vision == null) return;
    try {
      await vision.start();
    } catch (_) {
      // 카메라 권한 거부·초기화 실패는 unknown 판정으로 수렴한다.
    }
    // 권한 다이얼로그/초기화를 기다리는 사이 정지 또는 화면 폐기가 들어오면
    // 늦게 완료된 start가 카메라를 되살리지 못하게 한 번 더 정지한다.
    // 그 사이 새 start가 들어왔다면 _running=true이므로 최신 요청을 보존한다.
    if (_disposed || !_running) await _stopVision();
  }

  Future<void> _stopVision() async {
    try {
      await _vision?.stop();
    } catch (_) {
      // stop은 정리 경로다. 실패해도 화면 판정은 아래 stop()/dispose()가 지운다.
    }
  }

  /// 한 틱: 실API→판단→음성/햅틱→상태통지. 예외는 삼켜 unknown으로 수렴
  /// (타이머가 죽지 않게 — 1초 뒤 재시도).
  Future<void> tickOnce() {
    if (_disposed) return Future<void>.value();
    final active = _activeTick;
    if (active != null) return active; // 5초 fetch 동안 1초 타이머가 중첩되지 않게 함

    // start()가 만든 틱만 generation에 묶는다. 정지 상태에서 테스트·수동 호출한
    // tickOnce()는 기존 공개 계약대로 한 번의 독립 판정을 수행한다.
    final generation = _running ? _generation : null;
    late final Future<void> operation;
    operation = () async {
      try {
        await _performTick(generation);
      } finally {
        if (identical(_activeTick, operation)) _activeTick = null;
      }
    }();
    _activeTick = operation;
    return operation;
  }

  bool _isTickCurrent(int? generation) {
    if (_disposed) return false;
    return generation == null || (_running && generation == _generation);
  }

  Future<void> _performTick(int? generation) async {
    DecisionResult result;
    double? remain;
    SignalReading? apiUsed;
    SignalReading? visionUsed;
    try {
      final nowMs = _clock();
      final fetched = _apiConfigured
          ? await _fetch(_itstId, _direction, _apiKey, nowMs: nowMs)
          : const SignalReading(SignalColor.unknown, null, SignalSource.api);
      if (!_isTickCurrent(generation)) return;
      // 파서는 요청 전 시각(nowMs) 기준으로 신선도를 계산한다. 응답이 늦게
      // 왔으면(타임아웃 5초까지) 판정 시점에는 그만큼 더 오래된 값이므로 fetch
      // 소요 시간만큼 다시 늙힌다 — 신선도 2초 규칙과 잔여시간이 "판정 시점"
      // 기준으로 성립하게 한다. 시계가 거꾸로 가면(음수) 손대지 않는다.
      final apiReading = fetched.aged(_clock() - nowMs);

      final visionReading = _vision?.latestReading ?? visionStub();
      result = evaluate(
        apiReading,
        visionReading,
        needSec: kNeedSec,
        staleMs: kStaleMs,
        allowSingleSource: _allowSingleSource,
      );
      apiUsed = apiReading;
      visionUsed = visionReading;
      // 카메라 권한 거부: judge는 판독값만 보므로 "미인식"과 구분할 수 없다.
      // 소스 상태가 permissionDenied이고 judge가 카메라 불가라 했을 때만 이유를
      // 바꾼다 — 결정(wait)은 그대로(안전 정책 불변), 문구만 "설정에서 허용".
      if (result.reason == DecisionReason.cameraUnavailable &&
          _vision?.status == VisionSourceStatus.permissionDenied) {
        result = DecisionResult(result.decision, DecisionReason.cameraDenied);
      }
      if (!_apiConfigured) {
        result = DecisionResult(result.decision, DecisionReason.apiKeyMissing);
      }
      remain = result.decision == Decision.walk
          ? _minimumRemain(apiReading.remainSec, visionReading.remainSec)
          : null;
    } catch (_) {
      result = const DecisionResult(
        Decision.unknown,
        DecisionReason.sourcesUnavailable,
      );
      remain = null;
    }
    if (!_isTickCurrent(generation)) return;

    _decision = result.decision;
    _reason = result.reason;
    _remainSec = remain;
    _lastApiReading = apiUsed;
    _lastVisionReading = visionUsed;
    await _feedback.onDecision(
      result.decision,
      remainSec: remain,
      reason: result.reason,
    );
    if (!_isTickCurrent(generation)) return;
    notifyListeners();
  }

  /// 화면을 떠날 때의 정리. stop(announce: false)와 같은 뜻 — 정지 음성 없음
  /// (route pop 뒤에 "안내를 멈췄습니다"가 나오면 사용자를 헷갈리게 한다).
  @override
  void dispose() {
    _disposed = true;
    _running = false;
    _generation++;
    _timer?.cancel();
    _timer = null;
    unawaited(_stopVision());
    super.dispose();
  }
}

double? _minimumRemain(double? a, double? b) {
  if (a == null) return b;
  if (b == null) return a;
  return a < b ? a : b;
}
