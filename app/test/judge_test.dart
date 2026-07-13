import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/signals/signal_reading.dart';
import 'package:clip_sense/signals/judge.dart';

SignalReading api(SignalColor color, {double? remain = 30.0, int fresh = 100}) =>
    SignalReading(color, remain, SignalSource.api, freshMs: fresh);
SignalReading vis(SignalColor color, {double? remain, int fresh = 100}) =>
    SignalReading(color, remain, SignalSource.vision, freshMs: fresh);

void main() {
  test('둘 다 초록 → walk', () {
    expect(decide(api(SignalColor.green, remain: 30), vis(SignalColor.green)),
        Decision.walk);
  });

  test('API초록·비전빨강 → wait', () {
    expect(decide(api(SignalColor.green), vis(SignalColor.red)), Decision.wait);
  });
  test('API빨강·비전초록 → wait', () {
    expect(decide(api(SignalColor.red), vis(SignalColor.green)), Decision.wait);
  });
  test('API초록·비전점멸 → wait', () {
    expect(decide(api(SignalColor.green), vis(SignalColor.clearance)),
        Decision.wait);
  });
  test('API점멸·비전초록 → wait', () {
    expect(decide(api(SignalColor.clearance), vis(SignalColor.green)),
        Decision.wait);
  });

  test('둘 다 빨강 → wait', () {
    expect(decide(api(SignalColor.red), vis(SignalColor.red)), Decision.wait);
  });

  test('잔여 부족 → wait', () {
    expect(
        decide(api(SignalColor.green, remain: 3.0), vis(SignalColor.green),
            needSec: 7.0),
        Decision.wait);
  });

  test('잔여 정보 없음 → wait', () {
    expect(
        decide(api(SignalColor.green, remain: null),
            vis(SignalColor.green, remain: null),
            needSec: 7.0),
        Decision.wait);
  });

  test('한쪽 stale → wait', () {
    expect(
        decide(api(SignalColor.green, remain: 30, fresh: 5000),
            vis(SignalColor.green),
            staleMs: 2000),
        Decision.wait);
  });

  test('둘 다 unknown → unknown', () {
    expect(
        decide(api(SignalColor.unknown, remain: null),
            vis(SignalColor.unknown, remain: null)),
        Decision.unknown);
  });

  test('비전 단독 초록 → walk (allowSingleSource)', () {
    expect(
        decide(null, vis(SignalColor.green, remain: 30),
            allowSingleSource: true),
        Decision.walk);
  });

  test('단일 소스 비허용 → wait', () {
    expect(
        decide(null, vis(SignalColor.green, remain: 30),
            allowSingleSource: false),
        Decision.wait);
  });

  test('비전 단독 빨강 → wait', () {
    expect(decide(null, vis(SignalColor.red), allowSingleSource: true),
        Decision.wait);
  });

  test('둘 다 null → unknown', () {
    expect(decide(null, null), Decision.unknown);
  });

  test('단일 소스 초록·잔여없음 → wait', () {
    expect(
        decide(null, vis(SignalColor.green, remain: null),
            allowSingleSource: true),
        Decision.wait);
  });

  // 안전 정책(사용자 확정): 기본 엄격 — 카메라 unknown이면 API 초록도 wait
  test('기본: 비전 unknown이면 API 초록이어도 wait', () {
    expect(
        decide(api(SignalColor.green, remain: 30),
            vis(SignalColor.unknown, remain: null)),
        Decision.wait);
  });
  test('기본: API unknown이면 비전 초록이어도 wait', () {
    expect(
        decide(api(SignalColor.unknown, remain: null),
            vis(SignalColor.green, remain: 30)),
        Decision.wait);
  });
  test('기본: 비전 stale이면 API 초록이어도 wait', () {
    expect(
        decide(api(SignalColor.green, remain: 30),
            vis(SignalColor.green, remain: 30, fresh: 5000)),
        Decision.wait);
  });
  test('기본: API null이면 비전 초록이어도 wait', () {
    expect(decide(null, vis(SignalColor.green, remain: 30)), Decision.wait);
  });
}
