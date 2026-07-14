/// 디바운스 + 점멸 감지 상태 머신. detector.py SignalStateMachine 이식
/// (162~277행). 매 프레임 update(t, raw)를 호출한다. t는 영상 입력이면
/// 프레임 시각(frame_idx / fps), 카메라면 경과 시간(초). 상태가 바뀔 때만
/// Transition을 반환하므로 음성은 전환당 정확히 1회 재생된다.
///
/// 디바운스는 raw 판정의 '연속' 횟수를 그대로 센다 — 판정이 조금이라도
/// 흔들리면 카운트가 리셋되어 안내가 나가지 않는 안전한 방향으로 실패한다.
///
/// 판정 우선순위(매 프레임):
///   1. RED 연속 N프레임          → RED   (빨강은 점멸 패턴과 무관하므로 최우선)
///   2. GREEN↔NONE 토글 ≥ M회/2초 → GREEN_BLINK
///   3. GREEN 연속 N프레임        → GREEN (점멸 켜짐 구간의 연속 GREEN은 2가 먼저 잡음)
///   4. NONE 지속 ≥ 1.5초         → UNKNOWN (점멸 꺼짐 구간(~0.5초)보다 길어야 함)
///
/// 점멸 이탈 히스테리시스: 진입은 토글 ≥ M이지만, GREEN_BLINK에서 GREEN으로
/// 복귀하려면 윈도에 토글이 0이어야 한다(2초간 완전 안정). 느린 점멸에서
/// 토글 수가 임계 경계에 걸려 GREEN↔BLINK가 플래핑하는 것을 막는다.
///
/// 판정 보류 NONE(reason이 too_dark/brightness_jump/blob_too_large/
/// camera_fail)은 '실제 소등'과 구분해 점멸 이력에 넣지 않는다 — 모니터
/// 촬영 시 노출 변동으로 생기는 NONE 런이 가짜 점멸로 집계되는 것을 막는다.
/// UNKNOWN 전환용 NONE 지속시간에는 그대로 포함된다(정직 상태 경로 유지).
library;

import 'detector_config.dart';

const String stateRed = 'RED';
const String stateGreen = 'GREEN';
const String stateGreenBlink = 'GREEN_BLINK';
const String stateUnknown = 'UNKNOWN';

const String _rawRed = 'RED';
const String _rawGreen = 'GREEN';
const String _rawNone = 'NONE';

const Set<String> holdReasons = {
  'too_dark',
  'brightness_jump',
  'blob_too_large',
  'camera_fail',
};

class Transition {
  final double t;
  final String oldState;
  final String newState;

  const Transition({
    required this.t,
    required this.oldState,
    required this.newState,
  });
}

class _Run {
  final String value;
  final double startTime;
  const _Run(this.value, this.startTime);
}

class SignalStateMachine {
  final DetectorConfig _cfg;

  String state = stateUnknown; // 초기 상태 (시작 시 안내 없음)

  String? _consecRaw;
  int _consecCount = 0;
  final List<(double, String)> _history = []; // (t, raw), 시간순 append
  double? _lastActiveT; // 마지막으로 NONE이 아니었던 시각

  SignalStateMachine(this._cfg);

  int get debounceFrames => _cfg.debounceFrames;
  double get blinkWindowSeconds => _cfg.blinkWindowSeconds;
  int get blinkMinToggles => _cfg.blinkMinToggles;
  double get blinkMinSegmentSeconds => _cfg.blinkMinSegmentSeconds;
  double get unknownAfterSeconds => _cfg.unknownAfterSeconds;

  /// 윈도 내 GREEN↔NONE 토글 수. 토글 양쪽 구간이 모두 최소 지속시간
  /// (blinkMinSegmentSeconds) 이상일 때만 센다 — 검출 경계에서 튀는 짧은
  /// 플리커가 가짜 점멸로 잡히는 것을 막는다 (실제 점멸은 ~0.5초 구간).
  int _countBlinkToggles(double now) {
    final runs = <_Run>[];
    for (final entry in _history) {
      final t = entry.$1;
      final v = entry.$2;
      if (runs.isEmpty || runs.last.value != v) {
        runs.add(_Run(v, t));
      }
    }
    var toggles = 0;
    for (var i = 1; i < runs.length; i++) {
      final a = runs[i - 1].value;
      final startA = runs[i - 1].startTime;
      final b = runs[i].value;
      final startB = runs[i].startTime;
      final pair = {a, b};
      if (pair.length != 2 || !pair.containsAll({_rawGreen, _rawNone})) {
        continue;
      }
      final durA = startB - startA;
      final durB = (i + 1 < runs.length ? runs[i + 1].startTime : now) - startB;
      if (durA >= blinkMinSegmentSeconds && durB >= blinkMinSegmentSeconds) {
        toggles++;
      }
    }
    return toggles;
  }

  /// 블로킹 UI(ROI 선택 등)로 시간이 점프한 뒤 호출. 상태는 유지하되
  /// 시간 기반 이력을 비워 가짜 UNKNOWN/전환이 나가지 않게 한다.
  void resume() {
    _history.clear();
    _consecRaw = null;
    _consecCount = 0;
    _lastActiveT = null;
  }

  Transition? update(double t, String raw, {String reason = ''}) {
    if (raw == _consecRaw) {
      _consecCount++;
    } else {
      _consecRaw = raw;
      _consecCount = 1;
    }

    // 판정 보류 NONE은 점멸 이력에서 제외 (실제 소등 no_blob만 집계)
    if (!(raw == _rawNone && holdReasons.contains(reason))) {
      _history.add((t, raw));
    }
    while (_history.isNotEmpty && _history.first.$1 < t - blinkWindowSeconds) {
      _history.removeAt(0);
    }

    if (raw != _rawNone) {
      _lastActiveT = t;
    } else {
      _lastActiveT ??= t; // 시작부터 NONE이면 여기서부터 지속 시간 측정
    }

    final debounced = _consecCount >= debounceFrames;
    final noneDuration = t - _lastActiveT!;

    final toggles = _countBlinkToggles(t);
    final blinkExitOk = state != stateGreenBlink || toggles == 0;

    String? target;
    if (raw == _rawRed && debounced) {
      target = stateRed;
    } else if (toggles >= blinkMinToggles) {
      target = stateGreenBlink;
    } else if (raw == _rawGreen && debounced && blinkExitOk) {
      target = stateGreen;
    } else if (raw == _rawNone && noneDuration >= unknownAfterSeconds) {
      target = stateUnknown;
    }

    if (target != null && target != state) {
      final old = state;
      state = target;
      return Transition(t: t, oldState: old, newState: target);
    }
    return null;
  }
}
