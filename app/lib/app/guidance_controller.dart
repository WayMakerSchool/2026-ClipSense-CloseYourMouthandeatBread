/// 엔진 루프 컨트롤러. 1초마다 실API→판단→음성/햅틱, 화면에 상태 통지.
///
/// Flutter 위젯에 의존하지 않는다(ChangeNotifier만). fetch·interval을 주입해
/// 네트워크·타이머 없이 테스트한다. tickOnce()는 한 틱을 노출(테스트·수동 호출).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../signals/signal_reading.dart';
import '../signals/signal_api.dart' as api;
import '../signals/vision_adapter.dart';
import '../signals/judge.dart';
import '../feedback/feedback_controller.dart';
import 'config.dart';

/// 주입 가능한 fetch 시그니처(실제 fetchReading의 축약형).
typedef FetchReading = Future<SignalReading> Function(
    String itstId, String direction, String apiKey,
    {required int nowMs});

class GuidanceController extends ChangeNotifier {
  final FeedbackController _feedback;
  final FetchReading _fetch;
  final Duration _interval;
  final bool _allowSingleSource;

  Timer? _timer;
  bool _running = false;
  bool _disposed = false;
  Decision _decision = Decision.unknown;
  double? _remainSec;

  GuidanceController({
    required FeedbackController feedback,
    FetchReading? fetch,
    Duration interval = kLoopInterval,
    bool allowSingleSource = kAllowSingleSource,
  })  : _feedback = feedback,
        _fetch = fetch ?? _defaultFetch,
        _interval = interval,
        _allowSingleSource = allowSingleSource;

  static Future<SignalReading> _defaultFetch(
      String itstId, String direction, String apiKey,
      {required int nowMs}) {
    return api.fetchReading(itstId, direction, apiKey, nowMs: nowMs);
  }

  bool get running => _running;
  Decision get decision => _decision;
  double? get remainSec => _remainSec;

  void start() {
    if (_running) return;
    _running = true;
    _timer = Timer.periodic(_interval, (_) => tickOnce());
    notifyListeners();
    tickOnce(); // 시작 즉시 첫 확인(1초 기다리지 않음)
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
    notifyListeners();
  }

  void toggle() => _running ? stop() : start();

  /// 한 틱: 실API→판단→음성/햅틱→상태통지. 예외는 삼켜 unknown으로 수렴
  /// (타이머가 죽지 않게 — 1초 뒤 재시도).
  Future<void> tickOnce() async {
    Decision d;
    double? remain;
    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final apiReading = await _fetch(kItstId, kDirection, kApiKey, nowMs: nowMs);
      final visionReading = visionStub();
      d = decide(apiReading, visionReading,
          needSec: kNeedSec, allowSingleSource: _allowSingleSource);
      remain = d == Decision.walk ? apiReading.remainSec : null;
    } catch (_) {
      d = Decision.unknown;
      remain = null;
    }
    if (_disposed) return; // dispose() 도중/이후 도착한 틱 — 상태 갱신 금지

    _decision = d;
    _remainSec = remain;
    await _feedback.onDecision(d, remainSec: remain);
    if (_disposed) return; // 위 await 중 dispose된 경우 — notifyListeners 금지
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
