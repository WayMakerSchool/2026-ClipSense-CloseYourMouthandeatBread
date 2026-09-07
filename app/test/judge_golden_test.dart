// 언어 중립 골든 — app/test/fixtures/judge_cases.json 을 이 테스트(Dart, 기준)와
// scripts/test_judge_golden.py(Python, 미러)가 함께 읽는다.
//
// 왜 골든인가: 공모전 보고서는 Python 데이터 계층을 Dart 앱의 미러라고 말한다.
// 같은 JSON 을 두 구현이 읽어야 규칙·근거 이름·문구·기본값이 갈릴 때 두 쪽 CI 가
// 모두 깨진다(한쪽만 조용히 뒤처지지 않는다).
//
// 인코딩 규칙: JSON 은 NaN/Infinity 를 못 쓴다(jsonDecode 가 FormatException).
// 비유한 double 은 문자열 "NaN" | "Infinity" | "-Infinity" 로 쓴다.
//
// 이 파일은 app/lib 의 기존 evaluate()/decide() 만 쓴다 — 케이스가 실패하면 골든이
// 틀린 것이다(Dart 가 기준). 근거는 enum 값이 아니라 이름(문자열)으로 비교한다 —
// 컨트롤러 전용 이유가 Dart enum 에 병렬로 추가돼도(예: 카메라 준비 중·정지 감시)
// 이 파일이 컴파일 실패하지 않고, 골든이 그 이름을 먼저 실어도 안전하다.
import 'dart:convert';
import 'dart:io';

import 'package:clip_sense/app/config.dart';
import 'package:clip_sense/signals/judge.dart';
import 'package:clip_sense/signals/signal_reading.dart';
import 'package:flutter_test/flutter_test.dart';

const _goldenPath = 'app/test/fixtures/judge_cases.json';
const _pythonPath = 'judge.py';

File _fixture(String name) {
  for (final dir in ['test/fixtures', 'app/test/fixtures']) {
    final f = File('$dir/$name');
    if (f.existsSync()) return f;
  }
  throw StateError('fixture 없음: $name (cwd=${Directory.current.path})');
}

/// Dart enum 이름(camelCase) → 골든 이름(snake_case).
String _snake(String camel) =>
    camel.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');

/// 골든 숫자 → double. null 은 null. 비유한 값은 문자열 인코딩만 받는다(그 밖의
/// 문자열·bool 은 골든 오류이므로 던진다 — 조용히 0 이나 1 로 읽으면 안 된다).
double? _double(dynamic v) {
  if (v == null) return null;
  if (v == 'NaN') return double.nan;
  if (v == 'Infinity') return double.infinity;
  if (v == '-Infinity') return double.negativeInfinity;
  if (v is num) return v.toDouble();
  throw StateError('골든 숫자 인코딩 오류: $v');
}

/// 골든의 필수 키. 없으면 던진다 — 로더가 기본값을 채우면 골든이 무엇을 검사하는지
/// 흐려진다(Python 쪽도 [] 색인으로 같은 규칙).
T _req<T>(Map<String, dynamic> m, String key) {
  if (!m.containsKey(key)) throw StateError('골든 키 없음: $key in $m');
  return m[key] as T;
}

SignalReading? _reading(dynamic m, SignalSource source) {
  if (m == null) return null;
  final map = m as Map<String, dynamic>;
  return SignalReading(
    SignalColor.values.byName(_req<String>(map, 'color')),
    _double(_req<dynamic>(map, 'remain')),
    source,
    freshMs: _req<int>(map, 'fresh'),
  );
}

void main() {
  final golden =
      jsonDecode(_fixture('judge_cases.json').readAsStringSync())
          as Map<String, dynamic>;
  final defaults = golden['defaults'] as Map<String, dynamic>;
  final cases = (golden['cases'] as List).cast<Map<String, dynamic>>();
  final goldenReasons = (golden['reasons'] as List).cast<String>();
  final reasonText = (golden['reason_text'] as Map).cast<String, String>();
  final neverEmitted = (golden['never_emitted_by_evaluate'] as List)
      .cast<String>()
      .toSet();
  final dartReasons = DecisionReason.values.map((r) => _snake(r.name)).toList();

  double needSecOf(Map<String, dynamic> c) =>
      _double(c['need_sec'] ?? defaults['need_sec'])!;
  int staleMsOf(Map<String, dynamic> c) =>
      (c['stale_ms'] ?? defaults['stale_ms']) as int;
  bool allowOf(Map<String, dynamic> c) =>
      (c['allow_single_source'] ?? defaults['allow_single_source']) as bool;

  test('골든 스키마와 파일 자체 일관성', () {
    expect(golden['schema'], 'clipsense-judge-golden-v1');
    expect(golden['non_finite_encoding'], ['NaN', 'Infinity', '-Infinity']);
    expect(goldenReasons.toSet().length, goldenReasons.length, reason: '중복');
    expect(
      reasonText.keys.toSet(),
      goldenReasons.toSet(),
      reason: 'reason_text 키 집합은 reasons 와 같아야 한다',
    );
    for (final r in neverEmitted) {
      expect(goldenReasons, contains(r), reason: 'never_emitted 는 reasons 안에');
    }
  });

  test('골든 decisions 어휘는 Decision enum 과 이름·순서가 같다', () {
    expect(
      golden['decisions'],
      Decision.values.map((d) => d.name).toList(),
      reason: '→ $_goldenPath decisions 와 $_pythonPath WALK/WAIT/UNKNOWN 매핑',
    );
  });

  test('골든 reasons 어휘는 DecisionReason 을 빠짐없이 같은 순서로 담는다', () {
    final missing = dartReasons
        .where((r) => !goldenReasons.contains(r))
        .toList();
    expect(
      missing,
      isEmpty,
      reason:
          'Dart 에 있는데 골든에 없는 이유 $missing → $_goldenPath'
          '(reasons·reason_text·never_emitted_by_evaluate)와 $_pythonPath'
          '(REASON_*·ALL_REASONS·REASON_TEXT·CONTROLLER_ONLY_REASONS)를 갱신',
    );
    // 골든이 Dart 보다 앞설 수 있는 건 컨트롤러 전용 이유뿐 — evaluate() 케이스가
    // 의존하지 않으므로 병렬로 추가되는 enum 값을 골든이 먼저 실어도 안전하다.
    // evaluate 가 낼 수 있는 이유가 골든에만 있으면 골든이 틀렸다.
    final extra = goldenReasons.where((r) => !dartReasons.contains(r)).toList();
    final extraEmittable = extra
        .where((r) => !neverEmitted.contains(r))
        .toList();
    expect(
      extraEmittable,
      isEmpty,
      reason:
          '골든에만 있는 evaluate 이유 $extraEmittable → Dart enum 에 없다. '
          '$_goldenPath 을 고치거나 app/lib/signals/judge.dart 에 추가',
    );
    final goldenOrderOfDart = goldenReasons
        .where(dartReasons.contains)
        .toList();
    expect(
      goldenOrderOfDart,
      dartReasons,
      reason:
          '순서 불일치(Dart 선언 순서 기준) → $_goldenPath reasons 와 '
          '$_pythonPath ALL_REASONS 를 Dart 순서로',
    );
  });

  test('골든 reason_text 는 decisionReasonText 와 글자 그대로 같다', () {
    for (final r in DecisionReason.values) {
      expect(
        reasonText[_snake(r.name)],
        decisionReasonText(r),
        reason:
            '${r.name} → $_goldenPath reason_text 와 $_pythonPath REASON_TEXT 갱신',
      );
    }
  });

  test('골든 defaults 는 app/config.dart 정책 상수와 같다', () {
    expect(defaults['need_sec'], kNeedSec);
    expect(defaults['stale_ms'], kStaleMs);
    expect(defaults['allow_single_source'], kAllowSingleSource);
  });

  // 골든 defaults 가 장식이 아니라는 증명: 이름 붙은 인자를 아예 넘기지 않은 호출이
  // 골든 defaults 를 명시한 호출과 경계(7.0/6.9, 2000/2001, 단일 소스)에서 같아야
  // 한다. 위 테스트와 합치면 evaluate 의 매개변수 기본값이 kNeedSec/kStaleMs 에
  // 묶인다 — 정책 상수를 바꾸면 Python 기본값도 골든을 통해 함께 깨진다.
  test('evaluate/decide 의 매개변수 기본값은 골든 defaults 와 같다(경계 입력)', () {
    SignalReading api(double? remain, [int fresh = 100]) => SignalReading(
      SignalColor.green,
      remain,
      SignalSource.api,
      freshMs: fresh,
    );
    SignalReading vis([int fresh = 100]) => SignalReading(
      SignalColor.green,
      null,
      SignalSource.vision,
      freshMs: fresh,
    );
    final boundary = <(SignalReading?, SignalReading?, String, String)>[
      (api(7.0), vis(), 'walk', 'ready'),
      (api(6.9), vis(), 'wait', 'remaining_insufficient'),
      (api(30), vis(2000), 'walk', 'ready'),
      (api(30), vis(2001), 'wait', 'camera_unavailable'),
      (null, api(30), 'wait', 'api_unavailable'),
    ];
    for (final (a, v, decision, reason) in boundary) {
      final implicit = evaluate(a, v);
      final explicit = evaluate(
        a,
        v,
        needSec: _double(defaults['need_sec'])!,
        staleMs: defaults['stale_ms'] as int,
        allowSingleSource: defaults['allow_single_source'] as bool,
      );
      expect(implicit.decision, explicit.decision, reason: 'api=$a vision=$v');
      expect(implicit.reason, explicit.reason, reason: 'api=$a vision=$v');
      expect(implicit.decision.name, decision, reason: 'api=$a vision=$v');
      expect(_snake(implicit.reason.name), reason, reason: 'api=$a vision=$v');
      expect(decide(a, v), implicit.decision, reason: 'api=$a vision=$v');
    }
  });

  test('케이스는 30개 이상이고 이름이 겹치지 않는다', () {
    expect(cases.length, greaterThanOrEqualTo(30));
    expect(cases.map((c) => c['name']).toSet().length, cases.length);
  });

  test('never_emitted_by_evaluate 이유는 어떤 케이스 기대값에도 없다', () {
    for (final c in cases) {
      final expected = _req<Map<String, dynamic>>(c, 'expect');
      expect(
        neverEmitted,
        isNot(contains(_req<String>(expected, 'reason'))),
        reason: c['name'] as String,
      );
    }
  });

  // judge_test.dart 의 격자와 같지만 문자열 이름으로 비교한다 — Python 미러가 같은
  // 격자를 돌리므로 여기 둔다.
  test('evaluate 는 컨트롤러 전용 이유를 어떤 입력에도 내지 않는다(전수 격자)', () {
    final readings = <SignalReading?>[null];
    for (final color in SignalColor.values) {
      for (final remain in [null, 3.0, 30.0]) {
        for (final fresh in [0, 5000]) {
          readings.add(
            SignalReading(color, remain, SignalSource.api, freshMs: fresh),
          );
          readings.add(
            SignalReading(color, remain, SignalSource.vision, freshMs: fresh),
          );
        }
      }
    }
    for (final a in readings) {
      for (final v in readings) {
        for (final single in [false, true]) {
          final name = _snake(
            evaluate(a, v, allowSingleSource: single).reason.name,
          );
          expect(
            neverEmitted,
            isNot(contains(name)),
            reason: '$name api=$a vision=$v allowSingleSource=$single',
          );
          expect(goldenReasons, contains(name));
        }
      }
    }
  });

  for (final c in cases) {
    test('golden: ${c['name']}', () {
      final api = _reading(_req<dynamic>(c, 'api'), SignalSource.api);
      final vision = _reading(_req<dynamic>(c, 'vision'), SignalSource.vision);
      final expected = _req<Map<String, dynamic>>(c, 'expect');
      final result = evaluate(
        api,
        vision,
        needSec: needSecOf(c),
        staleMs: staleMsOf(c),
        allowSingleSource: allowOf(c),
      );
      expect(result.decision.name, _req<String>(expected, 'decision'));
      expect(_snake(result.reason.name), _req<String>(expected, 'reason'));
      // 축약 API 는 항상 같은 결정을 낸다.
      expect(
        decide(
          api,
          vision,
          needSec: needSecOf(c),
          staleMs: staleMsOf(c),
          allowSingleSource: allowOf(c),
        ),
        result.decision,
      );
      // 옵션을 하나도 지정하지 않은 케이스는 인자 없는 호출과도 같아야 한다.
      final usesDefaults =
          !c.containsKey('need_sec') &&
          !c.containsKey('stale_ms') &&
          !c.containsKey('allow_single_source');
      if (usesDefaults) {
        final implicit = evaluate(api, vision);
        expect(implicit.decision, result.decision);
        expect(implicit.reason, result.reason);
      }
    });
  }
}
