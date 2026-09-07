// 끝단 통합: GuidanceController ⊕ ClipVisionSource 를 같은 가짜 시계로 묶어,
// 클립 카메라 스냅샷이 실제로 보행 판정(walk/wait)과 음성까지 이어지는지 고정한다.
// 네트워크·타이머 없음(스크립트 카메라 + pollOnce/tickOnce 수동 구동).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clip_sense/app/config.dart';
import 'package:clip_sense/app/guidance_controller.dart';
import 'package:clip_sense/clip/clip_snapshot.dart';
import 'package:clip_sense/clip/clip_snapshot_client.dart';
import 'package:clip_sense/clip/clip_vision_source.dart';
import 'package:clip_sense/feedback/feedback_controller.dart';
import 'package:clip_sense/feedback/haptic_output.dart';
import 'package:clip_sense/feedback/speech_output.dart';
import 'package:clip_sense/signals/judge.dart';
import 'package:clip_sense/signals/signal_reading.dart';
import 'package:clip_sense/vision/roi_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

File _fixture(String name) {
  for (final dir in ['test/fixtures', 'app/test/fixtures']) {
    final f = File('$dir/$name');
    if (f.existsSync()) return f;
  }
  throw StateError('fixture 없음: $name');
}

final Uint8List greenJpeg = () {
  final meta =
      jsonDecode(_fixture('real_signal_roi.json').readAsStringSync())
          as Map<String, dynamic>;
  final roi = RoiImage(
    meta['width'] as int,
    meta['height'] as int,
    Uint8List.fromList(_fixture('real_signal_roi.bgr').readAsBytesSync()),
  );
  return img.encodeJpg(
    img.Image.fromBytes(
      width: roi.width,
      height: roi.height,
      bytes: roi.bytes.buffer,
      bytesOffset: roi.bytes.offsetInBytes,
      numChannels: 3,
      order: img.ChannelOrder.bgr,
    ),
    quality: 90,
  );
}();

class _Speech implements SpeechOutput {
  final List<String> spoken = [];
  @override
  Future<void> speak(String text) async => spoken.add(text);
}

class _Haptic implements HapticOutput {
  @override
  Future<void> play(Decision d) async {}
}

void main() {
  late int now;
  late List<ClipFetchResult Function()> script;
  late _Speech speech;

  ClipFetchResult next() =>
      (script.isEmpty ? script : [script.removeAt(0)]).first();

  ClipFetchOk frame(int seq, {String boot = 'a'}) => ClipFetchOk(
    20,
    meta: ClipCaptureMeta(
      frameSeq: seq,
      captureUptimeUs: seq * 250000,
      responseUptimeUs: seq * 250000 + 5000,
      bootId: boot,
    ),
    jpeg: greenJpeg,
  );

  setUp(() {
    now = 100000;
    script = [];
    speech = _Speech();
  });

  (GuidanceController, ClipVisionSource) build({SignalReading? apiReading}) {
    final source = ClipVisionSource(
      baseUrl: Uri.parse('http://clip.local'),
      token: 't',
      roiFrac: 1.0, // fixture 가 이미 320x180 ROI
      pollInterval: const Duration(days: 1),
      capture: () async => next(),
      monoClock: () => now,
    );
    final controller = GuidanceController(
      feedback: FeedbackController(speech, _Haptic()),
      itstId: '1537',
      direction: 'ne',
      vision: source,
      allowSingleSource: false,
      clock: () => now,
      fetch: (itstId, direction, apiKey, {required nowMs}) async =>
          apiReading ??
          const SignalReading(SignalColor.green, 15, SignalSource.api),
    );
    return (controller, source);
  }

  Future<void> poll(ClipVisionSource s, ClipFetchResult Function() step) async {
    script.add(step);
    now += 250;
    await s.pollOnce();
  }

  test('클립 프레임 8장(2초) + API 초록 15초 → "지금 건너셔도 됩니다"', () async {
    final (c, s) = build();
    for (var i = 1; i <= 7; i++) {
      await poll(s, () => frame(i));
    }
    await c.tickOnce();
    expect(c.decision, Decision.wait);
    expect(c.reason, DecisionReason.cameraUnavailable, reason: '디바운스 전');

    await poll(s, () => frame(8));
    await c.tickOnce();
    expect(c.decision, Decision.walk);
    expect(speech.spoken.last, contains('지금 건너셔도 됩니다'));
    expect(speech.spoken.last, contains('15초'));
    c.dispose();
  });

  test('클립 카메라가 멈추면(같은 frameSeq) 2초 뒤 대기로 떨어진다', () async {
    final (c, s) = build();
    for (var i = 1; i <= 8; i++) {
      await poll(s, () => frame(i));
    }
    await c.tickOnce();
    expect(c.decision, Decision.walk);

    // 정지: 같은 프레임 반복. 1.75초까지는 신선(walk 유지), 2초를 넘기면 wait.
    for (var i = 0; i < 7; i++) {
      await poll(s, () => frame(8));
    }
    await c.tickOnce();
    expect(s.latestReading.freshMs, lessThanOrEqualTo(kStaleMs));
    expect(c.decision, Decision.walk);

    await poll(s, () => frame(8));
    await poll(s, () => frame(8));
    await c.tickOnce();
    expect(c.decision, Decision.wait);
    expect(c.reason, DecisionReason.cameraUnavailable);
    expect(speech.spoken.last, contains('기다리세요'));
    c.dispose();
  });

  test('클립 카메라 응답 없음 → "클립 카메라에 연결할 수 없습니다" + 대기', () async {
    final (c, s) = build();
    for (var i = 1; i <= 8; i++) {
      await poll(s, () => frame(i));
    }
    await c.tickOnce();
    expect(c.decision, Decision.walk);

    await poll(
      s,
      () => ClipFetchFailed(800, failure: ClipFetchFailure.timeout),
    );
    await c.tickOnce();
    expect(c.decision, Decision.wait);
    expect(c.reason, DecisionReason.clipUnreachable);
    expect(
      speech.spoken.last,
      '클립 카메라에 연결할 수 없습니다. 전원과 Wi-Fi 연결을 확인해 주세요. 기다리세요',
    );
    c.dispose();
  });

  test('재부팅(bootId 변경) 뒤 정상 프레임 한 장으로는 건너라고 하지 않는다', () async {
    final (c, s) = build();
    for (var i = 1; i <= 8; i++) {
      await poll(s, () => frame(i));
    }
    await c.tickOnce();
    expect(c.decision, Decision.walk);

    await poll(s, () => frame(1, boot: 'b'));
    await c.tickOnce();
    expect(c.decision, Decision.wait);
    for (var i = 2; i <= 8; i++) {
      await poll(s, () => frame(i, boot: 'b'));
    }
    await c.tickOnce();
    expect(c.decision, Decision.walk);
    c.dispose();
  });

  test('API 가 빨강이면 클립이 초록이어도 빨간불 안내(엄격 AND 는 그대로)', () async {
    final (c, s) = build(
      apiReading: const SignalReading(SignalColor.red, null, SignalSource.api),
    );
    for (var i = 1; i <= 8; i++) {
      await poll(s, () => frame(i));
    }
    await c.tickOnce();
    expect(c.decision, Decision.wait);
    expect(c.reason, DecisionReason.conflict);
    c.dispose();
  });
}
