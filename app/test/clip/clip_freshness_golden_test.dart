// 언어 중립 골든 — app/test/fixtures/clip_freshness_cases.json 을 이 테스트(Dart,
// 기준)와 scripts/test_clip_snapshot.py(Python, 미러)가 함께 읽는다.
//
// 왜 골든인가: 클립 카메라 계약(헤더 이름·숫자 해석·신선도 규칙)이 앱과 Python
// 데이터 계층에서 갈리면 한쪽은 프레임을 받고 다른 쪽은 버린다. 같은 JSON 을 두
// 구현이 읽어야 갈림이 두 쪽 CI 에서 함께 보인다.
//
// 인코딩 규칙: 헤더 값의 보이지 않는 문자(제어 문자·BOM·NBSP·전각 공백)는 JSON
// \uXXXX 이스케이프로만 쓴다. expect 블록의 정수는 2^63 미만만 날것 숫자로 쓴다
// (Dart jsonDecode 는 그 이상을 double 로 조용히 읽는다).
//
// 이 파일은 app/lib 의 기존 parseClipHeaders/ClipFreshnessTracker 만 쓴다 —
// 케이스가 실패하면 골든이 틀린 것이다(Dart 가 기준).
import 'dart:convert';
import 'dart:io';

import 'package:clip_sense/clip/clip_contract.dart';
import 'package:clip_sense/clip/clip_freshness.dart';
import 'package:clip_sense/clip/clip_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

const _goldenPath = 'app/test/fixtures/clip_freshness_cases.json';
const _pythonPath = 'clip_snapshot.py';

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

/// 골든의 필수 키. 없으면 던진다 — 로더가 기본값을 채우면 골든이 무엇을 검사하는지
/// 흐려진다(Python 쪽도 [] 색인으로 같은 규칙).
T _req<T>(Map<String, dynamic> m, String key) {
  if (!m.containsKey(key)) throw StateError('골든 키 없음: $key in $m');
  return m[key] as T;
}

void main() {
  final golden =
      jsonDecode(_fixture('clip_freshness_cases.json').readAsStringSync())
          as Map<String, dynamic>;
  final contract = (golden['contract'] as Map).cast<String, String>();
  final headerCases = (golden['header_cases'] as List)
      .cast<Map<String, dynamic>>();
  final sequences = (golden['sequences'] as List).cast<Map<String, dynamic>>();

  test('골든 contract 블록은 clip_contract.dart 상수와 같다', () {
    expect(golden['schema'], 'clipsense-clip-freshness-golden-v1');
    expect(contract, {
      'token_header': kClipTokenHeader,
      'frame_seq_header': kClipFrameSeqHeader,
      'capture_uptime_header': kClipCaptureUptimeHeader,
      'response_uptime_header': kClipResponseUptimeHeader,
      'boot_id_header': kClipBootIdHeader,
      'firmware_version_header': kClipFirmwareVersionHeader,
      'camera_sensor_header': kClipCameraSensorHeader,
      'schema_version': kClipSchemaVersion,
      'capture_path': kClipCapturePath,
      'health_path': kClipHealthPath,
      'jpeg_content_type': kClipJpegContentType,
    }, reason: '→ $_goldenPath contract 와 $_pythonPath CLIP_* 상수를 갱신');
    expect(contract.length, 11);
  });

  test('골든 verdicts 는 ClipFrameVerdict 이름·순서와 같다', () {
    expect(
      golden['verdicts'],
      ClipFrameVerdict.values.map((v) => _snake(v.name)).toList(),
      reason:
          '→ $_goldenPath verdicts 와 $_pythonPath VERDICT_*·ALL_VERDICTS 를 '
          'Dart 선언 순서로',
    );
  });

  test('헤더 케이스 16개 이상·시퀀스 10개 이상·이름 중복 없음', () {
    expect(headerCases.length, greaterThanOrEqualTo(16));
    expect(sequences.length, greaterThanOrEqualTo(10));
    final names = [
      ...headerCases.map((c) => c['name']),
      ...sequences.map((s) => s['name']),
    ];
    expect(names.toSet().length, names.length);
  });

  test('골든 시퀀스의 accepted 는 captured_at 이 있고 나머지는 null 이다(골든 자체 일관성)', () {
    for (final s in sequences) {
      for (final step in (s['steps'] as List).cast<Map<String, dynamic>>()) {
        if (step['reset'] == true) continue;
        final e = _req<Map<String, dynamic>>(step, 'expect');
        final accepted = _req<String>(e, 'verdict') == 'accepted';
        expect(
          _req<int?>(e, 'captured_at_mono_ms') != null,
          accepted,
          reason: '${s['name']}: $e',
        );
      }
    }
  });

  for (final c in headerCases) {
    test('header: ${c['name']}', () {
      final headers = (_req<Map<String, dynamic>>(
        c,
        'headers',
      )).cast<String, String>();
      final m = parseClipHeaders(headers);
      final e = _req<Map<String, dynamic>?>(c, 'expect');
      if (e == null) {
        expect(m, isNull, reason: '$m');
        return;
      }
      expect(m, isNotNull);
      expect(m!.frameSeq, _req<int>(e, 'frame_seq'));
      expect(m.captureUptimeUs, _req<int>(e, 'capture_uptime_us'));
      expect(m.responseUptimeUs, _req<int>(e, 'response_uptime_us'));
      expect(m.bootId, _req<String>(e, 'boot_id'));
      expect(m.firmwareVersion, _req<String?>(e, 'firmware_version'));
      expect(m.cameraSensor, _req<String?>(e, 'camera_sensor'));
      expect(m.serverFrameAgeMs, _req<int>(e, 'server_frame_age_ms'));
    });
  }

  for (final s in sequences) {
    test('sequence: ${s['name']}', () {
      final tracker = ClipFreshnessTracker();
      final steps = (s['steps'] as List).cast<Map<String, dynamic>>();
      for (var i = 0; i < steps.length; i++) {
        final step = steps[i];
        if (step['reset'] == true) {
          tracker.reset();
          expect(tracker.lastAccepted, isNull, reason: 'step $i');
          continue;
        }
        final meta = _req<Map<String, dynamic>>(step, 'meta');
        final o = tracker.observe(
          ClipCaptureMeta(
            frameSeq: _req<int>(meta, 'seq'),
            captureUptimeUs: _req<int>(meta, 'capture'),
            responseUptimeUs: _req<int>(meta, 'response'),
            bootId: _req<String>(meta, 'boot'),
          ),
          rttMs: _req<int>(step, 'rtt_ms'),
          receivedMonoMs: _req<int>(step, 'received_mono_ms'),
        );
        final e = _req<Map<String, dynamic>>(step, 'expect');
        expect(
          _snake(o.verdict.name),
          _req<String>(e, 'verdict'),
          reason: 'step $i',
        );
        expect(o.bootChanged, _req<bool>(e, 'boot_changed'), reason: 'step $i');
        expect(
          o.conservativeAgeMs,
          _req<int>(e, 'conservative_age_ms'),
          reason: 'step $i',
        );
        expect(
          o.capturedAtMonoMs,
          _req<int?>(e, 'captured_at_mono_ms'),
          reason: 'step $i',
        );
        expect(
          tracker.lastAccepted?.frameSeq,
          _req<int?>(e, 'last_accepted_seq'),
          reason: 'step $i',
        );
      }
    });
  }
}
