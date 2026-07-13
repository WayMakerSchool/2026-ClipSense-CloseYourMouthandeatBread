import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/signals/signal_reading.dart';
import 'package:clip_sense/signals/signal_api.dart';

const now = 1783943330618;

// 실측 응답을 본뜬 레코드 (Python test_signal_api.py의 rec() 대응).
Map<String, dynamic> rec({Map<String, dynamic> over = const {}}) {
  final base = <String, dynamic>{
    'itstId': '1537',
    'trsmUtcTime': now,
    'ntPdsgStatNm': null,
    'ntPdsgRmdrCs': null,
    'nePdsgStatNm': 'protected-Movement-Allowed',
    'nePdsgRmdrCs': 241,
    'nwPdsgStatNm': 'stop-And-Remain',
    'nwPdsgRmdrCs': 281,
    'stPdsgStatNm': 'protected-clearance',
    'stPdsgRmdrCs': 33,
  };
  base.addAll(over);
  return base;
}

void main() {
  test('초록 매핑 + 잔여 241→24.1', () {
    final r = parseReading([rec()], 'ne', now);
    expect(r.color, SignalColor.green);
    expect(r.remainSec, 24.1);
    expect(r.source, SignalSource.api);
    expect(r.raw, 'protected-Movement-Allowed');
  });

  test('빨강 매핑', () {
    expect(parseReading([rec()], 'nw', now).color, SignalColor.red);
  });

  test('clearance 매핑', () {
    expect(parseReading([rec()], 'st', now).color, SignalColor.clearance);
  });

  test('None 방위 → unknown', () {
    final r = parseReading([rec()], 'nt', now);
    expect(r.color, SignalColor.unknown);
    expect(r.remainSec, isNull);
  });

  test('미지 상태 → unknown, raw 보존', () {
    final r = parseReading([
      rec(over: {'nePdsgStatNm': 'some-New-Phase'})
    ], 'ne', now);
    expect(r.color, SignalColor.unknown);
    expect(r.raw, 'some-New-Phase');
  });

  test('stale → unknown', () {
    final r = parseReading([rec()], 'ne', now + 5000, staleMs: 2000);
    expect(r.color, SignalColor.unknown);
  });

  test('fresh_ms 계산', () {
    final r = parseReading([rec()], 'ne', now + 500, staleMs: 2000);
    expect(r.color, SignalColor.green);
    expect(r.freshMs, 500);
  });

  test('빈 배열 → unknown', () {
    expect(parseReading([], 'ne', now).color, SignalColor.unknown);
  });

  test('문자열 잔여 처리', () {
    final r = parseReading([
      rec(over: {'nePdsgRmdrCs': '241'})
    ], 'ne', now);
    expect(r.remainSec, 24.1);
  });

  test('statusMap 알려진 값만', () {
    expect(statusMap.keys.toSet(), {
      'protected-Movement-Allowed',
      'permissive-Movement-Allowed',
      'protected-clearance',
      'permissive-clearance',
      'stop-And-Remain',
    });
  });

  test('trsmUtcTime null → unknown', () {
    final r = parseReading([
      rec(over: {'trsmUtcTime': null})
    ], 'ne', now);
    expect(r.color, SignalColor.unknown);
    expect(r.raw, 'protected-Movement-Allowed');
  });

  test('trsmUtcTime 파싱불가 → unknown', () {
    final r = parseReading([
      rec(over: {'trsmUtcTime': 'not-a-number'})
    ], 'ne', now);
    expect(r.color, SignalColor.unknown);
  });

  test('여러 레코드 중 itstId 매칭 선택', () {
    final multi = [
      rec(over: {
        'itstId': '9999',
        'nePdsgStatNm': 'stop-And-Remain',
        'nePdsgRmdrCs': 50
      }),
      rec(over: {
        'itstId': '1537',
        'nePdsgStatNm': 'protected-Movement-Allowed',
        'nePdsgRmdrCs': 241
      }),
    ];
    final r = parseReading(multi, 'ne', now, itstId: '1537');
    expect(r.color, SignalColor.green);
    expect(r.remainSec, 24.1);
  });

  test('매칭 itstId 없으면 unknown', () {
    final multi = [
      rec(over: {'itstId': '9999'}),
      rec(over: {'itstId': '1537'}),
    ];
    expect(parseReading(multi, 'ne', now, itstId: '0000').color,
        SignalColor.unknown);
  });

  test('itstId 미지정 시 첫 레코드(하위호환)', () {
    final multi = [
      rec(over: {'itstId': '9999', 'nePdsgStatNm': 'stop-And-Remain'}),
      rec(over: {'itstId': '1537'}),
    ];
    expect(parseReading(multi, 'ne', now).color, SignalColor.red);
  });

  test('미래 시각(큰 음수 fresh) → unknown', () {
    final r = parseReading([
      rec(over: {'trsmUtcTime': now + 10000})
    ], 'ne', now, staleMs: 2000);
    expect(r.color, SignalColor.unknown);
  });

  test('작은 시계오차는 허용(초록 통과)', () {
    final r = parseReading([
      rec(over: {'trsmUtcTime': now + 100})
    ], 'ne', now, staleMs: 2000);
    expect(r.color, SignalColor.green);
  });

  test('정확히 stale_ms 경계는 fresh(초록 통과)', () {
    final r = parseReading([rec()], 'ne', now + 2000, staleMs: 2000);
    expect(r.color, SignalColor.green);
  });

  test('stale_ms 초과는 unknown', () {
    final r = parseReading([rec()], 'ne', now + 2001, staleMs: 2000);
    expect(r.color, SignalColor.unknown);
  });
}
