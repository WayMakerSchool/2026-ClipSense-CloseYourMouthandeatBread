import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/signals/signal_reading.dart';
import 'package:clip_sense/signals/vision_adapter.dart';

void main() {
  test('RED 매핑', () => expect(toReading('RED').color, SignalColor.red));
  test('GREEN 매핑', () => expect(toReading('GREEN').color, SignalColor.green));
  test('GREEN_BLINK → clearance',
      () => expect(toReading('GREEN_BLINK').color, SignalColor.clearance));
  test('UNKNOWN 매핑',
      () => expect(toReading('UNKNOWN').color, SignalColor.unknown));

  test('source=vision', () {
    expect(toReading('GREEN').source, SignalSource.vision);
  });

  test('잔여·신선도 보존', () {
    final r = toReading('GREEN', remainSec: 12.0, freshMs: 100);
    expect(r.remainSec, 12.0);
    expect(r.freshMs, 100);
  });

  test('잔여 기본 null', () {
    expect(toReading('RED').remainSec, isNull);
  });

  test('미지 상태 → unknown', () {
    expect(toReading('SOMETHING_ELSE').color, SignalColor.unknown);
  });

  test('visionStub은 항상 unknown', () {
    final r = visionStub();
    expect(r.color, SignalColor.unknown);
    expect(r.source, SignalSource.vision);
    expect(r.remainSec, isNull);
  });
}
