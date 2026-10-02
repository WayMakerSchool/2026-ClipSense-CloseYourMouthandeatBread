/// 시연용 신호 데이터 (`--dart-define=DEMO_SIGNAL=cycle`).
///
/// 실시간 API를 쓸 수 없는 시연 환경(실내, API 승인 대기)에서 판정 흐름을 보여 주기
/// 위한 가정값이다. 실제 신호가 아니며, 판독 원문(raw)을 [kDemoSignalRaw]로 표시해
/// 화면이 "시연 데이터"임을 알린다. 기본 빌드에서는 꺼져 있다(app_config_test 고정).
///
/// 주기: 초록 [greenSec]초(남은 시간이 실제 시간만큼 줄어듦) → 빨강 [redSec]초 → 반복.
library;

import '../signals/signal_reading.dart';
import 'guidance_controller.dart';

/// 시연 데이터임을 표시하는 판독 원문. 화면 배너가 이 값을 보고 켜진다.
const String kDemoSignalRaw = 'DEMO_SIGNAL';

/// [mode]가 'cycle'이면 시연 주기 fetch, 그 외(빈 문자열 포함)는 null(실제 API 사용).
FetchReading? demoSignalFetch(
  String mode, {
  int greenSec = 30,
  int redSec = 20,
  int Function()? clock,
}) {
  if (mode != 'cycle') return null;
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
        (greenSec * 1000 - phaseMs) / 1000.0,
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
