import 'package:clip_sense/app/config.dart';
import 'package:clip_sense/app/demo_signal.dart';
import 'package:clip_sense/signals/signal_reading.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('기본 빌드에서는 시연 신호가 꺼져 있다(실제 API 사용)', () {
    expect(kDemoSignal, isEmpty);
    expect(demoSignalFetch(kDemoSignal), isNull);
    expect(demoSignalFetch('anything-else'), isNull);
  });

  test('cycle: 초록 30초(잔여 감소) → 빨강 20초 → 반복, 원문은 시연 표시', () async {
    var t = 1000000;
    final fetch = demoSignalFetch('cycle', clock: () => t)!;
    Future<SignalReading> at(int ms) {
      t = 1000000 + ms;
      return fetch('1537', 'ne', '', nowMs: t);
    }

    final g0 = await at(0);
    expect(g0.color, SignalColor.green);
    expect(g0.remainSec, 30.0);
    expect(g0.raw, kDemoSignalRaw);
    expect(g0.source, SignalSource.api);

    expect((await at(23000)).remainSec, closeTo(7.0, 1e-9));
    expect((await at(29900)).color, SignalColor.green);

    final r = await at(30000);
    expect(r.color, SignalColor.red);
    expect(r.remainSec, isNull);
    expect(r.raw, kDemoSignalRaw);

    expect((await at(49999)).color, SignalColor.red);
    final again = await at(50000);
    expect(again.color, SignalColor.green);
    expect(again.remainSec, 30.0);
  });
}
