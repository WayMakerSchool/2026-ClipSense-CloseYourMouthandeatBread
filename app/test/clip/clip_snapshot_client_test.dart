// ClipSnapshotClient: 클립 카메라 /capture 한 번 요청 → 분류된 결과.
// 상태코드 의미는 firmware/clipsense_cam/http_api.cpp 기준:
//   401 missing_device_token / 403 invalid_device_token / 409 capture_busy /
//   503 capture_failed(오래된 프레임을 대신 보내지 않음).
// MockClient 로 분류를, 실제 dart:io HttpServer 로 전송 경로(소문자 헤더·
// 타임아웃이 연결을 실제로 끊는지)를 검증한다.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:clip_sense/clip/clip_contract.dart';
import 'package:clip_sense/clip/clip_snapshot_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final Uint8List _jpegish = Uint8List.fromList([
  0xFF,
  0xD8,
  0xFF,
  0xE0,
  1,
  2,
  3,
]);

Map<String, String> _headers({String? drop}) {
  final h = {
    'Content-Type': 'image/jpeg',
    'X-Frame-Seq': '10',
    'X-Capture-Uptime-Us': '1000000',
    'X-Response-Uptime-Us': '1005000',
    'X-Boot-Id': 'b00t',
  };
  if (drop != null) h.remove(drop);
  return h;
}

ClipSnapshotClient _client(
  http.Client mock, {
  int Function()? clock,
  Duration timeout = const Duration(milliseconds: 800),
}) => ClipSnapshotClient(
  baseUrl: Uri.parse('http://clip.local'),
  token: 'secret-token',
  timeout: timeout,
  clientFactory: () => mock,
  monoClock: clock,
);

void main() {
  group('MockClient 분류', () {
    test('200 image/jpeg + 계약 헤더 → ok(meta, jpeg, rtt)', () async {
      var now = 100;
      http.Request? seen;
      final mock = MockClient((req) async {
        seen = req;
        now += 37; // 응답까지 37ms
        return http.Response.bytes(_jpegish, 200, headers: _headers());
      });
      final r = await _client(mock, clock: () => now).capture();
      expect(r, isA<ClipFetchOk>());
      final ok = r as ClipFetchOk;
      expect(ok.meta.frameSeq, 10);
      expect(ok.meta.bootId, 'b00t');
      expect(ok.jpeg, _jpegish);
      expect(ok.rttMs, 37);
      expect(seen!.method, 'GET');
      expect(seen!.url.toString(), 'http://clip.local/capture');
      expect(seen!.headers[kClipTokenHeader], 'secret-token');
    });

    test('baseUrl 에 경로가 있어도 /capture 를 이어 붙인다', () async {
      http.Request? seen;
      final mock = MockClient((req) async {
        seen = req;
        return http.Response.bytes(_jpegish, 200, headers: _headers());
      });
      final c = ClipSnapshotClient(
        baseUrl: Uri.parse('http://192.168.4.1:80/'),
        token: 't',
        clientFactory: () => mock,
      );
      await c.capture();
      expect(seen!.url.toString(), 'http://192.168.4.1/capture');
    });

    test('소문자 헤더(dart:io 형태)도 ok', () async {
      final mock = MockClient(
        (req) async => http.Response.bytes(
          _jpegish,
          200,
          headers: {
            for (final e in _headers().entries) e.key.toLowerCase(): e.value,
          },
        ),
      );
      expect(await _client(mock).capture(), isA<ClipFetchOk>());
    });

    test('Content-Type 파라미터가 붙어도 매체 타입으로 판단한다', () async {
      final mock = MockClient(
        (req) async => http.Response.bytes(
          _jpegish,
          200,
          headers: _headers()..['Content-Type'] = 'image/JPEG; charset=binary',
        ),
      );
      expect(await _client(mock).capture(), isA<ClipFetchOk>());
    });

    for (final (code, failure) in [
      (401, ClipFetchFailure.unauthorized),
      (403, ClipFetchFailure.unauthorized),
      (409, ClipFetchFailure.busy),
      (503, ClipFetchFailure.captureFailed),
      (404, ClipFetchFailure.transport),
      (500, ClipFetchFailure.transport),
    ]) {
      test('$code → ${failure.name}', () async {
        final mock = MockClient(
          (req) async => http.Response('{"error":"x"}', code),
        );
        final r = await _client(mock).capture();
        expect(r, isA<ClipFetchFailed>());
        expect((r as ClipFetchFailed).failure, failure);
        expect(r.statusCode, code);
      });
    }

    test('200 인데 image/jpeg 가 아니면 badContentType(본문 무시)', () async {
      final mock = MockClient(
        (req) async => http.Response.bytes(
          _jpegish,
          200,
          headers: _headers()..['Content-Type'] = 'text/html',
        ),
      );
      final r = await _client(mock).capture() as ClipFetchFailed;
      expect(r.failure, ClipFetchFailure.badContentType);
    });

    test('계약 헤더가 빠지면 badHeaders', () async {
      for (final key in [
        'X-Frame-Seq',
        'X-Capture-Uptime-Us',
        'X-Response-Uptime-Us',
        'X-Boot-Id',
      ]) {
        final mock = MockClient(
          (req) async =>
              http.Response.bytes(_jpegish, 200, headers: _headers(drop: key)),
        );
        final r = await _client(mock).capture() as ClipFetchFailed;
        expect(r.failure, ClipFetchFailure.badHeaders, reason: key);
      }
    });

    test('200 인데 본문이 비면 emptyBody', () async {
      final mock = MockClient(
        (req) async =>
            http.Response.bytes(Uint8List(0), 200, headers: _headers()),
      );
      final r = await _client(mock).capture() as ClipFetchFailed;
      expect(r.failure, ClipFetchFailure.emptyBody);
    });

    test('네트워크 예외 → transport(던지지 않음)', () async {
      final mock = MockClient(
        (req) async => throw const SocketException('down'),
      );
      final r = await _client(mock).capture() as ClipFetchFailed;
      expect(r.failure, ClipFetchFailure.transport);
      expect(r.statusCode, isNull);
    });

    test('응답이 오지 않으면 timeout', () async {
      final mock = MockClient((req) => Completer<http.Response>().future);
      final r =
          await _client(
                mock,
                timeout: const Duration(milliseconds: 40),
              ).capture()
              as ClipFetchFailed;
      expect(r.failure, ClipFetchFailure.timeout);
    });

    test('요청마다 clientFactory 를 새로 부르고 close 한다(타임아웃이 연결을 끊게)', () async {
      var created = 0;
      var closed = 0;
      final c = ClipSnapshotClient(
        baseUrl: Uri.parse('http://clip.local'),
        token: 't',
        clientFactory: () {
          created++;
          return _ClosableMock(
            (req) async =>
                http.Response.bytes(_jpegish, 200, headers: _headers()),
            onClose: () => closed++,
          );
        },
      );
      await c.capture();
      await c.capture();
      expect(created, 2);
      expect(closed, 2);
    });
  });

  group('실제 dart:io HttpServer 왕복', () {
    late HttpServer server;
    late Uri base;
    Future<void> Function(HttpRequest)? handler;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://127.0.0.1:${server.port}');
      server.listen((req) async {
        await handler!(req);
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('펌웨어와 같은 헤더·바디를 실제 소켓으로 받아 ok', () async {
      String? token;
      handler = (req) async {
        token = req.headers.value(kClipTokenHeader);
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType('image', 'jpeg');
        req.response.headers.set('X-Frame-Seq', '77');
        req.response.headers.set('X-Capture-Uptime-Us', '5000');
        req.response.headers.set('X-Response-Uptime-Us', '6500');
        req.response.headers.set('X-Boot-Id', 'real');
        req.response.headers.set('Cache-Control', 'no-store');
        req.response.add(_jpegish);
        await req.response.close();
      };
      final r = await ClipSnapshotClient(baseUrl: base, token: 'tok').capture();
      expect(r, isA<ClipFetchOk>());
      final ok = r as ClipFetchOk;
      expect(ok.meta.frameSeq, 77);
      expect(ok.meta.serverFrameAgeMs, 2);
      expect(ok.jpeg, _jpegish);
      expect(ok.rttMs, greaterThanOrEqualTo(0));
      expect(token, 'tok');
    });

    test('503 capture_failed 는 captureFailed', () async {
      handler = (req) async {
        req.response.statusCode = 503;
        req.response.write('{"error":"capture_failed"}');
        await req.response.close();
      };
      final r =
          await ClipSnapshotClient(baseUrl: base, token: 'tok').capture()
              as ClipFetchFailed;
      expect(r.failure, ClipFetchFailure.captureFailed);
    });

    test('응답이 멈춘 연결은 타임아웃 뒤 끊기고 다음 요청은 정상 동작한다', () async {
      var stalled = 0;
      final stallSeen = Completer<void>();
      handler = (req) async {
        stalled++;
        if (stalled == 1) {
          if (!stallSeen.isCompleted) stallSeen.complete();
          // 첫 요청: 절대 응답하지 않는다(펌웨어가 멈춘 상황).
          await req.response.done.catchError((_) {});
          return;
        }
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType('image', 'jpeg');
        req.response.headers.set('X-Frame-Seq', '1');
        req.response.headers.set('X-Capture-Uptime-Us', '1');
        req.response.headers.set('X-Response-Uptime-Us', '1');
        req.response.headers.set('X-Boot-Id', 'b');
        req.response.add(_jpegish);
        await req.response.close();
      };
      final c = ClipSnapshotClient(
        baseUrl: base,
        token: 'tok',
        timeout: const Duration(milliseconds: 150),
      );
      final sw = Stopwatch()..start();
      final first = await c.capture() as ClipFetchFailed;
      expect(first.failure, ClipFetchFailure.timeout);
      expect(sw.elapsedMilliseconds, lessThan(2000));
      await stallSeen.future;
      final second = await c.capture();
      expect(second, isA<ClipFetchOk>());
    });
  });
}

/// close() 호출을 세는 MockClient 래퍼.
class _ClosableMock extends http.BaseClient {
  final MockClient _inner;
  final void Function() onClose;
  _ClosableMock(MockClientHandler handler, {required this.onClose})
    : _inner = MockClient(handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() {
    onClose();
    _inner.close();
  }
}
