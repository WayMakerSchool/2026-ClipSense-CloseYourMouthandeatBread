// 시뮬레이터 끝단(선택 실행): scripts/clip_cam_sim.py 가 떠 있을 때만 실제 소켓으로
// ClipVisionSource 를 붙여 장애 주입(freeze·reboot·503·stall)에 대한 반응을 확인한다.
//
// 기본 `flutter test` 에서는 건너뛴다(외부 프로세스 의존 → CI 에서 흔들리면 안 된다).
//
//   CLIP_DEVICE_TOKEN=simtoken .venv/bin/python scripts/clip_cam_sim.py --port 8765 --quiet
//   cd app && flutter test test/clip/clip_sim_e2e_test.dart \
//       --dart-define=CLIP_SIM_URL=http://127.0.0.1:8765 --dart-define=CLIP_SIM_TOKEN=simtoken
//
// 이 테스트가 통과해도 실기기 검증은 아니다 — "계약을 말하는 서버를 앱이 받아들인다"
// 까지만 증명한다(보드의 실제 JPEG·왕복 시간·인식 거리는 미측정).
import 'dart:convert';
import 'dart:io';

import 'package:clip_sense/camera/camera_vision_source.dart';
import 'package:clip_sense/clip/clip_snapshot_client.dart';
import 'package:clip_sense/clip/clip_vision_source.dart';
import 'package:flutter_test/flutter_test.dart';

const String kSimUrl = String.fromEnvironment('CLIP_SIM_URL');
const String kSimToken = String.fromEnvironment('CLIP_SIM_TOKEN');

/// 시뮬레이터 전용 제어 엔드포인트(펌웨어 계약 밖). Python 표준 서버는 chunked
/// 본문을 읽지 못하므로 Content-Length 를 명시한다.
Future<void> setFault(Uri base, String mode) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(base.replace(path: '/__sim/fault'));
    final body = utf8.encode(jsonEncode({'mode': mode}));
    req.headers.contentType = ContentType.json;
    req.contentLength = body.length;
    req.add(body);
    final resp = await req.close();
    expect(resp.statusCode, 200, reason: 'fault $mode');
    await resp.drain<void>();
  } finally {
    client.close();
  }
}

void main() {
  final enabled = kSimUrl.isNotEmpty && kSimToken.isNotEmpty;
  final base = enabled ? Uri.parse(kSimUrl) : Uri.parse('http://127.0.0.1:1');

  test(
    '클라이언트: 시뮬레이터에서 ok(소문자 헤더·JPEG 매직), 틀린 토큰은 unauthorized',
    () async {
      await setFault(base, 'none');
      final ok =
          await ClipSnapshotClient(baseUrl: base, token: kSimToken).capture()
              as ClipFetchOk;
      expect(ok.meta.frameSeq, greaterThan(0));
      expect(ok.jpeg.length, greaterThan(1000));
      expect(ok.jpeg[0], 0xFF);
      expect(ok.jpeg[1], 0xD8);

      final bad =
          await ClipSnapshotClient(
                baseUrl: base,
                token: '${kSimToken}x',
              ).capture()
              as ClipFetchFailed;
      expect(bad.failure, ClipFetchFailure.unauthorized);
    },
    skip: enabled ? false : 'CLIP_SIM_URL/CLIP_SIM_TOKEN 미지정 — 시뮬레이터 끝단은 수동 실행',
  );

  test(
    '소스: 정상 → freeze(same_frame) → reboot(새 bootId) → 503 → stall(timeout→unreachable) → 복귀',
    () async {
      await setFault(base, 'none');
      final s = ClipVisionSource(
        baseUrl: base,
        token: kSimToken,
        pollInterval: const Duration(days: 1), // pollOnce 로 수동 구동
      );
      for (var i = 0; i < 6; i++) {
        await s.pollOnce();
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      expect(s.status, VisionSourceStatus.streaming);
      expect(s.diagnostics!.framesProcessed, greaterThanOrEqualTo(3));

      await setFault(base, 'freeze');
      await s.pollOnce();
      await s.pollOnce();
      expect(s.diagnostics!.lastReason, 'same_frame');

      final bootBefore = s.lastMeta?.bootId;
      await setFault(base, 'reboot');
      await s.pollOnce();
      await setFault(base, 'none');
      await s.pollOnce();
      expect(s.lastMeta?.bootId, isNot(bootBefore));

      await setFault(base, 'capture_failed');
      await s.pollOnce();
      expect(s.diagnostics!.lastReason, 'capture_failed');
      expect(s.status, VisionSourceStatus.streaming);

      await setFault(base, 'stall');
      await s.pollOnce();
      expect(s.diagnostics!.lastReason, 'timeout');
      expect(s.status, VisionSourceStatus.unreachable);

      await setFault(base, 'none');
      await s.pollOnce();
      expect(s.status, VisionSourceStatus.streaming);
      await s.stop();
    },
    skip: enabled ? false : 'CLIP_SIM_URL/CLIP_SIM_TOKEN 미지정 — 시뮬레이터 끝단은 수동 실행',
  );
}
