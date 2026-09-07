// ClipVisionSource: 클립 카메라 HTTP 스냅샷 → VisionSource.
// 전송(ClipSnapshotClient)은 capture 함수로, 시계는 monoClock 으로 주입해
// 네트워크·타이머 없이 결정적으로 검증한다. 프레임은 실클립 ROI fixture 를
// JPEG 으로 인코딩한 것(코덱 왕복은 jpeg_frame_test 가 따로 고정).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clip_sense/app/config.dart';
import 'package:clip_sense/camera/camera_vision_source.dart';
import 'package:clip_sense/clip/clip_snapshot.dart';
import 'package:clip_sense/clip/clip_snapshot_client.dart';
import 'package:clip_sense/clip/clip_vision_source.dart';
import 'package:clip_sense/signals/signal_reading.dart';
import 'package:clip_sense/vision/detector_config.dart';
import 'package:clip_sense/vision/roi_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

File _fixture(String name) {
  for (final dir in ['test/fixtures', 'app/test/fixtures']) {
    final f = File('$dir/$name');
    if (f.existsSync()) return f;
  }
  throw StateError('fixture 없음: $name (cwd=${Directory.current.path})');
}

final Uint8List greenJpeg = () {
  final meta =
      jsonDecode(_fixture('real_signal_roi.json').readAsStringSync())
          as Map<String, dynamic>;
  final bytes = Uint8List.fromList(
    _fixture('real_signal_roi.bgr').readAsBytesSync(),
  );
  final roi = RoiImage(meta['width'] as int, meta['height'] as int, bytes);
  final image = img.Image.fromBytes(
    width: roi.width,
    height: roi.height,
    bytes: roi.bytes.buffer,
    bytesOffset: roi.bytes.offsetInBytes,
    numChannels: 3,
    order: img.ChannelOrder.bgr,
  );
  return img.encodeJpg(image, quality: 90);
}();

/// 펌웨어 흉내: 호출마다 정해진 결과를 순서대로 돌려주는 스크립트 카메라.
class ScriptedCamera {
  final List<ClipFetchResult Function()> script = [];
  int calls = 0;
  int inFlight = 0;
  int maxInFlight = 0;
  Completer<void>? gate;

  Future<ClipFetchResult> capture() async {
    calls++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      if (gate != null) await gate!.future;
      final index = calls - 1;
      final step = index < script.length ? script[index] : script.last;
      return step();
    } finally {
      inFlight--;
    }
  }
}

ClipFetchOk ok({
  required int seq,
  required int captureUs,
  int serverAgeUs = 5000,
  String boot = 'boot-a',
  int rttMs = 20,
  Uint8List? jpeg,
}) => ClipFetchOk(
  rttMs,
  meta: ClipCaptureMeta(
    frameSeq: seq,
    captureUptimeUs: captureUs,
    responseUptimeUs: captureUs + serverAgeUs,
    bootId: boot,
  ),
  jpeg: jpeg ?? greenJpeg,
);

ClipFetchFailed failed(ClipFetchFailure f, {int? status}) =>
    ClipFetchFailed(20, failure: f, statusCode: status);

void main() {
  late ScriptedCamera cam;
  late int now;

  ClipVisionSource make({
    double roiFrac = 1.0,
    Duration poll = const Duration(days: 1),
  }) {
    return ClipVisionSource(
      baseUrl: Uri.parse('http://clip.local'),
      token: 't',
      config: const DetectorConfig.defaults(),
      roiFrac: roiFrac,
      pollInterval: poll,
      capture: cam.capture,
      monoClock: () => now,
    );
  }

  /// 250ms 간격으로 accepted 프레임 [n]장을 넣는다(seq·촬영시각 증가).
  Future<void> feed(
    ClipVisionSource s,
    int n, {
    int startSeq = 1,
    String boot = 'boot-a',
  }) async {
    for (var i = 0; i < n; i++) {
      final seq = startSeq + i;
      cam.script.add(() => ok(seq: seq, captureUs: seq * 250000, boot: boot));
      now += 250;
      await s.pollOnce();
    }
  }

  setUp(() {
    cam = ScriptedCamera();
    now = 10000;
  });

  /// 벽시계 고정 대기는 전체 스위트 부하에서 흔들린다 — 조건이 될 때까지(상한
  /// 2초) 기다린다. 상한에 걸리면 expect 가 실패해 원인을 드러낸다.
  Future<void> waitUntil(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!condition() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('초기: idle, unknown, 프리뷰 없음(클립은 화면 프리뷰가 없다), 진단 없음', () {
    final s = make();
    expect(s.status, VisionSourceStatus.idle);
    expect(s.latestReading.color, SignalColor.unknown);
    expect(s.latestReading.source, SignalSource.vision);
    expect(s.previewController, isNull);
    expect(s.diagnostics, isNull);
  });

  test('start(): 첫 응답 전엔 starting, 응답 뒤 streaming; stop(): idle', () async {
    final s = make();
    cam.gate = Completer<void>();
    cam.script.add(() => ok(seq: 1, captureUs: 1000));
    await s.start();
    expect(s.status, VisionSourceStatus.starting);
    expect(cam.calls, 1, reason: '시작 즉시 첫 스냅샷 요청');
    cam.gate!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(s.status, VisionSourceStatus.streaming);
    await s.stop();
    expect(s.status, VisionSourceStatus.idle);
  });

  test('accepted 프레임이 debounce 만큼 쌓이면 GREEN, 신선도는 촬영 시각 기준', () async {
    final s = make();
    await feed(s, 7);
    expect(s.status, VisionSourceStatus.streaming);
    expect(
      s.latestReading.color,
      SignalColor.unknown,
      reason: '7장은 debounce 미달',
    );

    await feed(s, 1, startSeq: 8);
    expect(s.latestReading.color, SignalColor.green);
    // 마지막 프레임: rtt 20 + 서버 나이 5ms → 촬영시각 = now - 25.
    expect(s.latestReading.freshMs, 25);
    now += 1000;
    expect(s.latestReading.freshMs, 1025);
    expect(s.diagnostics?.framesProcessed, 8);
    expect(s.diagnostics?.lastReason, '');
    expect(s.lastMeta?.frameSeq, 8);
    expect(s.lastRttMs, 20);
    await s.stop();
  });

  // ROI 비율별 실제 QVGA 프레임 기하는 clip_qvga_fixture_test.dart 가 고정한다.

  test('정지(frozen) frameSeq: 같은 프레임은 신선도를 갱신하지 않고 늙어 간다', () async {
    final s = make();
    await feed(s, 8);
    expect(s.latestReading.color, SignalColor.green);
    ClipFetchOk frozen() => ok(seq: 8, captureUs: 8 * 250000);
    // 같은 프레임을 계속 받아도 촬영 시각은 그대로 → freshMs 만 커진다.
    for (var i = 0; i < 4; i++) {
      cam.script.add(frozen);
      now += 250;
      await s.pollOnce();
    }
    expect(s.diagnostics?.lastReason, 'same_frame');
    expect(s.latestReading.freshMs, 25 + 1000);
    expect(
      s.latestReading.color,
      SignalColor.green,
      reason: 'kStaleMs 이전엔 색 유지(judge가 나이로 거른다)',
    );

    // kStaleMs 를 넘긴 정지 → 판독 무효 + 파이프라인 리셋.
    for (var i = 0; i < 5; i++) {
      cam.script.add(frozen);
      now += 250;
      await s.pollOnce();
    }
    expect(s.latestReading.color, SignalColor.unknown);
    // 다시 움직여도 한 장으로는 GREEN 이 부활하지 않는다.
    await feed(s, 1, startSeq: 9);
    expect(s.latestReading.color, SignalColor.unknown);
    await s.stop();
  });

  test('503 capture_failed: 즉시 unknown, 파이프라인 리셋(한 장으로 GREEN 복귀 금지)', () async {
    final s = make();
    await feed(s, 8);
    expect(s.latestReading.color, SignalColor.green);

    cam.script.add(() => failed(ClipFetchFailure.captureFailed, status: 503));
    now += 250;
    await s.pollOnce();
    expect(s.latestReading.color, SignalColor.unknown);
    expect(s.status, VisionSourceStatus.streaming, reason: '기기는 닿는다');
    expect(s.diagnostics?.lastReason, 'capture_failed');

    await feed(s, 1, startSeq: 9);
    expect(s.latestReading.color, SignalColor.unknown);
    await feed(s, 7, startSeq: 10);
    expect(s.latestReading.color, SignalColor.green);
    await s.stop();
  });

  test(
    'busy(409)·badHeaders·badContentType·emptyBody 도 unknown + 이유',
    () async {
      final s = make();
      await s.start();
      for (final (f, reason) in [
        (ClipFetchFailure.busy, 'busy'),
        (ClipFetchFailure.badHeaders, 'bad_headers'),
        (ClipFetchFailure.badContentType, 'bad_content_type'),
        (ClipFetchFailure.emptyBody, 'empty_body'),
      ]) {
        cam.script.add(() => failed(f));
        now += 250;
        await s.pollOnce();
        expect(s.latestReading.color, SignalColor.unknown, reason: reason);
        expect(s.diagnostics?.lastReason, reason);
        expect(s.status, VisionSourceStatus.streaming, reason: reason);
      }
      await s.stop();
    },
  );

  test('timeout·transport → unreachable, 다음 ok 에서 streaming 복귀', () async {
    final s = make();
    await feed(s, 8);
    cam.script.add(() => failed(ClipFetchFailure.timeout));
    now += 250;
    await s.pollOnce();
    expect(s.status, VisionSourceStatus.unreachable);
    expect(s.latestReading.color, SignalColor.unknown);
    expect(s.diagnostics?.lastReason, 'timeout');

    cam.script.add(() => failed(ClipFetchFailure.transport));
    now += 250;
    await s.pollOnce();
    expect(s.status, VisionSourceStatus.unreachable);
    expect(s.diagnostics?.lastReason, 'transport');

    await feed(s, 1, startSeq: 9);
    expect(s.status, VisionSourceStatus.streaming);
    await s.stop();
  });

  test('401/403 → failed + token_rejected, 폴링 루프 종료', () async {
    final s = make(poll: const Duration(milliseconds: 5));
    cam.script.add(() => failed(ClipFetchFailure.unauthorized, status: 403));
    await s.start();
    await waitUntil(() => s.status == VisionSourceStatus.failed);
    expect(s.status, VisionSourceStatus.failed);
    expect(s.diagnostics?.lastReason, 'token_rejected');
    expect(s.latestReading.color, SignalColor.unknown);
    final callsAfterFailure = cam.calls;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(cam.calls, callsAfterFailure, reason: '같은 토큰으로 재시도하지 않는다');
    await s.stop();
    expect(s.status, VisionSourceStatus.idle);
  });

  test('bootId 변경: 이력 폐기 → 새 boot 프레임은 debounce 부터 다시', () async {
    final s = make();
    await feed(s, 8);
    expect(s.latestReading.color, SignalColor.green);

    // 재부팅: seq 1, uptime 작음, 새 bootId.
    await feed(s, 1, startSeq: 1, boot: 'boot-b');
    expect(s.latestReading.color, SignalColor.unknown);
    expect(s.diagnostics?.lastReason, '');
    expect(s.lastMeta?.bootId, 'boot-b');
    await feed(s, 7, startSeq: 2, boot: 'boot-b');
    expect(s.latestReading.color, SignalColor.green);
    await s.stop();
  });

  test('replayOrReorder: 거부, unknown, 이유 기록', () async {
    final s = make();
    await feed(s, 8);
    cam.script.add(() => ok(seq: 3, captureUs: 3 * 250000));
    now += 250;
    await s.pollOnce();
    expect(s.latestReading.color, SignalColor.unknown);
    expect(s.diagnostics?.lastReason, 'replay_or_reorder');
    await s.stop();
  });

  test('JPEG 디코드 실패 → decode_failed, unknown', () async {
    final s = make();
    cam.script.add(
      () => ok(seq: 1, captureUs: 1000, jpeg: Uint8List.fromList([1, 2, 3])),
    );
    await s.pollOnce();
    expect(s.latestReading.color, SignalColor.unknown);
    expect(s.diagnostics?.lastReason, 'decode_failed');
    expect(s.status, VisionSourceStatus.streaming);
    await s.stop();
  });

  test('stop(): idle·unknown, 정지 뒤 늦게 도착한 응답은 버린다', () async {
    final s = make();
    await feed(s, 8);
    cam.gate = Completer<void>();
    cam.script.add(() => ok(seq: 9, captureUs: 9 * 250000));
    final pending = s.pollOnce();
    await s.stop();
    expect(s.status, VisionSourceStatus.idle);
    expect(s.latestReading.color, SignalColor.unknown);
    cam.gate!.complete();
    await pending;
    expect(s.latestReading.color, SignalColor.unknown);
    expect(s.status, VisionSourceStatus.idle);
    expect(s.diagnostics, isNull);
  });

  test('폴링 루프: 겹치지 않고 반복하며 stop 으로 멈춘다', () async {
    final s = make(poll: const Duration(milliseconds: 5));
    var seq = 0;
    cam.script.add(() {
      seq++;
      return ok(seq: seq, captureUs: seq * 250000);
    });
    await s.start();
    await waitUntil(() => cam.calls >= 3);
    expect(cam.calls, greaterThanOrEqualTo(3));
    expect(cam.maxInFlight, 1);
    await s.stop();
    final after = cam.calls;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(cam.calls, after, reason: 'stop 뒤에는 새 요청이 없다');
  });

  test('start 를 여러 번 불러도 루프는 하나', () async {
    final s = make(poll: const Duration(milliseconds: 5));
    cam.script.add(() => ok(seq: 1, captureUs: 1000));
    await s.start();
    await s.start();
    await s.start();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(cam.maxInFlight, 1);
    await s.stop();
  });

  test('기본 폴링 간격·타임아웃·ROI 는 config 상수', () {
    expect(kClipPollInterval, const Duration(milliseconds: 250));
    expect(kClipRequestTimeout, const Duration(milliseconds: 800));
    expect(kClipRoiFrac, 0.25);
  });

  group('정지 감시(stalled)', () {
    test(
      '정지(frozen) 프레임이 3초를 넘기면 stalled, 판독은 이미 unknown, 새 프레임에 streaming 복귀',
      () async {
        final s = make();
        await feed(s, 8);
        expect(s.status, VisionSourceStatus.streaming);
        ClipFetchOk frozen() => ok(seq: 8, captureUs: 8 * 250000);
        for (var i = 0; i < 12; i++) {
          cam.script.add(frozen);
          now += 250;
          await s.pollOnce();
        }
        // 마지막 accepted 프레임 수신 뒤 3000ms → 아직 streaming(경계 포함).
        expect(s.status, VisionSourceStatus.streaming);
        expect(s.latestReading.color, SignalColor.unknown, reason: '2초 규칙이 먼저');
        cam.script.add(frozen);
        now += 250;
        await s.pollOnce();
        expect(s.status, VisionSourceStatus.stalled);
        expect(s.diagnostics?.lastReason, 'same_frame');

        await feed(s, 1, startSeq: 9);
        expect(
          s.status,
          VisionSourceStatus.streaming,
          reason: '래치 없음 — 새 프레임이 오면 복귀',
        );
        await s.stop();
      },
    );

    test(
      'stalled 뒤 timeout 은 unreachable 이 우선, 재연결 뒤에도 같은 프레임이면 즉시 stalled',
      () async {
        final s = make();
        await feed(s, 8);
        ClipFetchOk frozen() => ok(seq: 8, captureUs: 8 * 250000);
        for (var i = 0; i < 13; i++) {
          cam.script.add(frozen);
          now += 250;
          await s.pollOnce();
        }
        expect(s.status, VisionSourceStatus.stalled);

        cam.script.add(() => failed(ClipFetchFailure.timeout));
        now += 250;
        await s.pollOnce();
        expect(s.status, VisionSourceStatus.unreachable);

        // 재연결(같은 프레임 응답)은 진행이 아니다 → 바로 stalled.
        cam.script.add(frozen);
        now += 250;
        await s.pollOnce();
        expect(s.status, VisionSourceStatus.stalled);
        await s.stop();
      },
    );

    test('503 만 이어지면(기기는 닿는데 프레임이 없음) 첫 응답 3초 뒤 stalled', () async {
      final s = make();
      // 첫 응답(k=1)이 기준점. k=13 은 정확히 3000ms(경계 포함 → streaming), k=14 부터 stalled.
      for (var k = 1; k <= 14; k++) {
        cam.script.add(
          () => failed(ClipFetchFailure.captureFailed, status: 503),
        );
        now += 250;
        await s.pollOnce();
        if (k == 1 || k == 13) {
          expect(s.status, VisionSourceStatus.streaming, reason: 'k=$k');
        }
      }
      expect(s.status, VisionSourceStatus.stalled);
      expect(s.latestReading.color, SignalColor.unknown);
      await s.stop();
    });

    test('start() 직후 첫 응답 전에는 starting(stalled 아님), stop() 뒤에는 idle', () async {
      final s = make();
      cam.gate = Completer<void>();
      cam.script.add(() => ok(seq: 1, captureUs: 1000));
      await s.start();
      now += 10000;
      expect(s.status, VisionSourceStatus.starting);
      cam.gate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(s.status, VisionSourceStatus.streaming);
      now += 10000;
      expect(s.status, VisionSourceStatus.stalled);
      await s.stop();
      expect(s.status, VisionSourceStatus.idle);
    });
  });
}
