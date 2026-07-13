import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/signals/signal_reading.dart';

void main() {
  test('필드 보존', () {
    final r = SignalReading(SignalColor.green, 24.1, SignalSource.api,
        freshMs: 120);
    expect(r.color, SignalColor.green);
    expect(r.remainSec, 24.1);
    expect(r.source, SignalSource.api);
    expect(r.freshMs, 120);
  });

  test('raw 기본값 null', () {
    final r = SignalReading(SignalColor.green, 24.1, SignalSource.api);
    expect(r.raw, isNull);
  });

  test('isGo: green이면 true', () {
    final r = SignalReading(SignalColor.green, null, SignalSource.api);
    expect(r.isGo, isTrue);
  });

  test('isGo: red이면 false', () {
    final r = SignalReading(SignalColor.red, null, SignalSource.vision);
    expect(r.isGo, isFalse);
  });

  test('isGo: unknown이면 false', () {
    final r = SignalReading(SignalColor.unknown, null, SignalSource.api);
    expect(r.isGo, isFalse);
  });

  test('remainSec null 허용', () {
    final r = SignalReading(SignalColor.red, null, SignalSource.vision);
    expect(r.remainSec, isNull);
  });

  test('4색 구분', () {
    expect({
      SignalColor.green,
      SignalColor.red,
      SignalColor.clearance,
      SignalColor.unknown
    }.length, 4);
  });
}
