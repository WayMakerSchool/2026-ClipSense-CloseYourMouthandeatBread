/// 판단 결과를 상태별 진동 패턴으로 안내하는 출력.
///
/// HapticOutput은 인터페이스(테스트 시 Fake). VibrationHaptic은 하드웨어 의존이라
/// 단위 테스트하지 않는다(인터페이스 뒤 격리, 실기기 수동). 진동 실패(미지원/권한)는
/// 삼켜 앱을 죽이지 않는다(Fail-Safe).
library;

import 'package:vibration/vibration.dart';

import '../signals/judge.dart';

/// 진동 출력 인터페이스. 실제 구현은 VibrationHaptic.
abstract class HapticOutput {
  Future<void> play(Decision d);
}

/// Decision별 진동 패턴. vibration 패턴은 [wait, vibrate, wait, vibrate, ...]
/// (밀리초, 0부터 wait로 시작). 상태를 소리 없이 촉각으로 구분한다.
/// - walk: 짧게 두 번 (가도 됨)
/// - wait: 길게 한 번 (멈춤)
/// - unknown: 짧게 세 번 (주의)
const Map<Decision, List<int>> hapticPatterns = {
  Decision.walk: [0, 120, 100, 120],
  Decision.wait: [0, 600],
  Decision.unknown: [0, 80, 80, 80, 80, 80],
};

class VibrationHaptic implements HapticOutput {
  @override
  Future<void> play(Decision d) async {
    final pattern = hapticPatterns[d];
    if (pattern == null) return;
    // 진동 지원 안 하는 기기면 조용히 넘어감.
    // vibration 3.x의 hasVibrator()는 Future<bool>(non-nullable).
    final hasVibrator = await Vibration.hasVibrator();
    if (!hasVibrator) return;
    await Vibration.vibrate(pattern: pattern);
  }
}
