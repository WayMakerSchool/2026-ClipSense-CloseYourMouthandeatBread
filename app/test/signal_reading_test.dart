import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/signals/signal_reading.dart';

void main() {
  test('필드 보존', () {
    final r = SignalReading(
      SignalColor.green,
      24.1,
      SignalSource.api,
      freshMs: 120,
    );
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
    expect(
      {
        SignalColor.green,
        SignalColor.red,
        SignalColor.clearance,
        SignalColor.unknown,
      }.length,
      4,
    );
  });

  group('aged', () {
    test('지연만큼 신선도는 늘고 잔여 초는 준다(색·출처·원문 보존)', () {
      const r = SignalReading(
        SignalColor.green,
        8.0,
        SignalSource.api,
        freshMs: 100,
        raw: 'protected-Movement-Allowed',
      );
      final a = r.aged(3000);
      expect(a.color, SignalColor.green);
      expect(a.source, SignalSource.api);
      expect(a.raw, 'protected-Movement-Allowed');
      expect(a.freshMs, 3100);
      expect(a.remainSec, closeTo(5.0, 1e-9));
    });

    test('잔여 null이면 null 유지', () {
      const r = SignalReading(SignalColor.red, null, SignalSource.api);
      expect(r.aged(1000).remainSec, isNull);
      expect(r.aged(1000).freshMs, 1000);
    });

    test('잔여는 0 아래로 내려가지 않는다', () {
      const r = SignalReading(SignalColor.green, 2.0, SignalSource.api);
      expect(r.aged(5000).remainSec, 0.0);
    });

    test('0 이하 지연은 같은 값(젊어지지 않음)', () {
      const r = SignalReading(
        SignalColor.green,
        8.0,
        SignalSource.api,
        freshMs: 700,
      );
      expect(identical(r.aged(0), r), isTrue);
      expect(identical(r.aged(-500), r), isTrue);
    });

    test('비유한 잔여(NaN/∞)는 그대로 둔다(judge가 불가로 처리)', () {
      const nan = SignalReading(
        SignalColor.green,
        double.nan,
        SignalSource.api,
      );
      expect(nan.aged(1000).remainSec!.isNaN, isTrue);
      const inf = SignalReading(
        SignalColor.green,
        double.infinity,
        SignalSource.api,
      );
      expect(inf.aged(1000).remainSec, double.infinity);
    });
  });
}
