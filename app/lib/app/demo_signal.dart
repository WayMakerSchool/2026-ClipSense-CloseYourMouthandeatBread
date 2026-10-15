/// 시연용 신호 데이터 (`--dart-define=DEMO_SIGNAL=cycle`).
///
/// 실시간 API를 쓸 수 없는 시연 환경(실내, API 승인 대기)에서 판정 흐름을 보여 주기
/// 위한 가정값이다. 실제 신호가 아니며, 판독 원문(raw)을 [kDemoSignalRaw]로 표시해
/// 화면이 "시연 데이터"임을 알린다. 기본 빌드에서는 꺼져 있다(app_config_test 고정).
///
/// 주기: 초록 [greenSec]초(남은 시간이 실제 시간만큼 줄어듦) → 빨강 [redSec]초 → 반복.
///
/// `DEMO_SIGNAL=color`는 같은 주기로 **색만** 주고 남은 시간은 비운다(null). API로
/// 실제 얻지 못한 잔여 초를 만들어 내지 않는 시험용이다 — 초록이 겹쳐도 판정은
/// "남은 시간을 확인할 수 없습니다"로 대기한다(엄격 정책 그대로).
library;

import '../signals/signal_reading.dart';
import 'guidance_controller.dart';

/// 시연 데이터임을 표시하는 판독 원문. 화면 배너가 이 값을 보고 켜진다.
const String kDemoSignalRaw = 'DEMO_SIGNAL';

/// [mode]가 'cycle'이면 시연 주기 fetch, 'color'면 같은 주기에서 색만(잔여 null),
/// 그 외(빈 문자열 포함)는 null(실제 API 사용).
FetchReading? demoSignalFetch(
  String mode, {
  int greenSec = 30,
  int redSec = 20,
  int Function()? clock,
}) {
  if (mode != 'cycle' && mode != 'color') return null;
  final withRemain = mode == 'cycle';
  final now = clock ?? () => DateTime.now().millisecondsSinceEpoch;
  final startMs = now();
  final periodMs = (greenSec + redSec) * 1000;
  return (
    String itstId,
    String direction,
    String apiKey, {
    required int nowMs,
  }) async {
    final phaseMs = (now() - startMs) % periodMs;
    if (phaseMs < greenSec * 1000) {
      return SignalReading(
        SignalColor.green,
        withRemain ? (greenSec * 1000 - phaseMs) / 1000.0 : null,
        SignalSource.api,
        freshMs: 200,
        raw: kDemoSignalRaw,
      );
    }
    return const SignalReading(
      SignalColor.red,
      null,
      SignalSource.api,
      freshMs: 200,
      raw: kDemoSignalRaw,
    );
  };
}
