/// 판단 결과(Decision)를 음성·진동으로 조율하는 컨트롤러 (설계 §4.1).
///
/// 판단하지 않고, 출력 자체도 하지 않는다(백엔드에 위임). Decision이 이전과
/// 다를 때만(전환 시에만) 안내하고, 같은 상태 지속 중에는 조용하다.
library;

import '../signals/judge.dart';
import 'speech_output.dart';
import 'haptic_output.dart';

class FeedbackController {
  final SpeechOutput _speech;
  final HapticOutput _haptic;
  Decision? _last; // 직전에 안내한 Decision(초기 null → 첫 Decision은 항상 안내)
  DecisionReason? _lastReason;

  FeedbackController(this._speech, this._haptic);

  /// 안내 세션이 정지됐다 다시 시작되면 같은 상태라도 첫 판정을 다시 알린다.
  void reset() {
    _last = null;
    _lastReason = null;
  }

  /// Decision을 받아 전환 시에만 안내한다. `Future<void>`여야 각 백엔드의 async
  /// 실패를 개별 await+catch로 잡을 수 있다(void면 못 잡아 멀티채널 보장 깨짐).
  Future<void> onDecision(
    Decision d, {
    double? remainSec,
    DecisionReason? reason,
  }) async {
    if (d == _last && reason == _lastReason) return; // 같은 상태·근거 지속 → 조용
    _last = d;
    _lastReason = reason;

    // 두 백엔드를 각각 개별 await + try/catch. speech가 async로 실패해도
    // haptic await는 반드시 실행된다(멀티채널 독립, 설계 §5).
    try {
      await _speech.speak(speechText(d, remainSec: remainSec, reason: reason));
    } catch (_) {
      // 음성 실패는 삼킴 — 진동을 막지 않는다.
    }
    try {
      await _haptic.play(d);
    } catch (_) {
      // 진동 실패도 삼킴 — 앱을 죽이지 않는다.
    }
  }

  /// 안내가 멈췄음을 음성으로만 알린다. 진동은 판정 전환(walk/wait/unknown)
  /// 채널로만 쓰므로 여기서는 울리지 않는다. 판정 전환 기억(_last)은 건드리지
  /// 않는다 — 세션 초기화는 stop()이 reset()으로 따로 한다.
  /// 음성 실패는 삼킨다(정지 자체는 이미 끝났다, Fail-Safe).
  Future<void> announceStopped() async {
    try {
      await _speech.speak(kStoppedSpeechText);
    } catch (_) {
      // 음성 실패는 삼킴.
    }
  }
}
