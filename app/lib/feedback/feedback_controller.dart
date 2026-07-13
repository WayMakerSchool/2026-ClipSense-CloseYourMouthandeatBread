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

  FeedbackController(this._speech, this._haptic);

  /// Decision을 받아 전환 시에만 안내한다. `Future<void>`여야 각 백엔드의 async
  /// 실패를 개별 await+catch로 잡을 수 있다(void면 못 잡아 멀티채널 보장 깨짐).
  Future<void> onDecision(Decision d, {double? remainSec}) async {
    if (d == _last) return; // 같은 상태 지속 → 조용
    _last = d;

    // 두 백엔드를 각각 개별 await + try/catch. speech가 async로 실패해도
    // haptic await는 반드시 실행된다(멀티채널 독립, 설계 §5).
    try {
      await _speech.speak(speechText(d, remainSec: remainSec));
    } catch (_) {
      // 음성 실패는 삼킴 — 진동을 막지 않는다.
    }
    try {
      await _haptic.play(d);
    } catch (_) {
      // 진동 실패도 삼킴 — 앱을 죽이지 않는다.
    }
  }
}
