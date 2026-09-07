/// 클립 카메라 `/capture` 한 번 요청 → 분류된 결과(전송 계층).
///
/// 판정하지 않는다. 펌웨어(http_api.cpp)의 상태코드·헤더·본문을 계약대로 검사해
/// [ClipFetchOk] 또는 [ClipFetchFailed] 로만 바꾼다. 어떤 실패도 던지지 않는다 —
/// 소스가 unknown 으로 수렴시키고, 이유는 진단으로 남긴다.
///
/// 요청마다 [http.Client] 를 새로 만들고 끝나면 닫는다. `Future.timeout` 만으로는
/// 소켓이 살아남아 ESP32 WebServer(한 번에 한 클라이언트)를 붙잡을 수 있기
/// 때문이다. 닫으면(IOClient → HttpClient.close(force: true)) 연결이 실제로 끊겨
/// 다음 폴링이 막히지 않는다.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'clip_contract.dart';
import 'clip_snapshot.dart';

enum ClipFetchFailure {
  /// 401 토큰 없음 / 403 토큰 불일치. 재시도해도 같으므로 소스는 failed 로 간다.
  unauthorized,

  /// 409 capture_busy — 다른 요청이 카메라를 점유 중. 다음 폴링에서 재시도.
  busy,

  /// 503 capture_failed — 획득 실패. 펌웨어는 오래된 프레임을 대신 보내지 않는다.
  captureFailed,

  /// 200 이지만 image/jpeg 가 아님(캡티브 포털·다른 서버).
  badContentType,

  /// 계약 헤더가 없거나 유효하지 않음(다른 펌웨어·프록시가 헤더를 벗김).
  badHeaders,

  /// 200 인데 본문이 비어 있음.
  emptyBody,

  /// 제한 시간 안에 응답이 오지 않음.
  timeout,

  /// 그 외 HTTP 상태(404·500…)나 소켓·DNS 오류.
  transport,
}

sealed class ClipFetchResult {
  /// 요청 전송 → 결과 확정까지 폰 단조 시계 경과(ms).
  final int rttMs;
  const ClipFetchResult(this.rttMs);
}

@immutable
class ClipFetchOk extends ClipFetchResult {
  final ClipCaptureMeta meta;
  final Uint8List jpeg;
  const ClipFetchOk(super.rttMs, {required this.meta, required this.jpeg});

  @override
  String toString() => 'ClipFetchOk($meta, ${jpeg.length}B, rtt ${rttMs}ms)';
}

@immutable
class ClipFetchFailed extends ClipFetchResult {
  final ClipFetchFailure failure;
  final int? statusCode;
  final String detail;
  const ClipFetchFailed(
    super.rttMs, {
    required this.failure,
    this.statusCode,
    this.detail = '',
  });

  @override
  String toString() =>
      'ClipFetchFailed(${failure.name}, status: $statusCode, $detail)';
}

class ClipSnapshotClient {
  final Uri _captureUri;
  final String _token;
  final Duration _timeout;
  final http.Client Function() _clientFactory;
  final int Function() _monoClock;

  /// [baseUrl] 은 `http://host[:port][/prefix]`. `/capture` 를 이어 붙인다.
  ClipSnapshotClient({
    required Uri baseUrl,
    required String token,
    Duration timeout = const Duration(milliseconds: 800),
    http.Client Function()? clientFactory,
    int Function()? monoClock,
  }) : _captureUri = _join(baseUrl, kClipCapturePath),
       _token = token,
       _timeout = timeout,
       _clientFactory = clientFactory ?? http.Client.new,
       _monoClock = monoClock ?? _defaultMonoMs;

  static final Stopwatch _stopwatch = Stopwatch()..start();
  static int _defaultMonoMs() => _stopwatch.elapsedMilliseconds;

  static Uri _join(Uri base, String path) {
    final prefix = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(path: '$prefix$path', query: null, fragment: null);
  }

  Uri get captureUri => _captureUri;

  Future<ClipFetchResult> capture() async {
    final client = _clientFactory();
    final started = _monoClock();
    int rtt() => _monoClock() - started;
    try {
      final response = await client
          .get(
            _captureUri,
            headers: {kClipTokenHeader: _token, 'Accept': kClipJpegContentType},
          )
          .timeout(_timeout);
      return _classify(response, rtt());
    } on TimeoutException {
      return ClipFetchFailed(rtt(), failure: ClipFetchFailure.timeout);
    } catch (e) {
      return ClipFetchFailed(
        rtt(),
        failure: ClipFetchFailure.transport,
        detail: e.runtimeType.toString(),
      );
    } finally {
      // 타임아웃·오류 뒤에도 소켓을 실제로 끊는다(위 library 주석).
      try {
        client.close();
      } catch (_) {}
    }
  }

  static ClipFetchResult _classify(http.Response response, int rttMs) {
    final code = response.statusCode;
    if (code == 401 || code == 403) {
      return ClipFetchFailed(
        rttMs,
        failure: ClipFetchFailure.unauthorized,
        statusCode: code,
      );
    }
    if (code == 409) {
      return ClipFetchFailed(
        rttMs,
        failure: ClipFetchFailure.busy,
        statusCode: code,
      );
    }
    if (code == 503) {
      return ClipFetchFailed(
        rttMs,
        failure: ClipFetchFailure.captureFailed,
        statusCode: code,
      );
    }
    if (code < 200 || code >= 300) {
      return ClipFetchFailed(
        rttMs,
        failure: ClipFetchFailure.transport,
        statusCode: code,
      );
    }

    if (_mediaType(response.headers) != kClipJpegContentType) {
      return ClipFetchFailed(
        rttMs,
        failure: ClipFetchFailure.badContentType,
        statusCode: code,
        detail: _mediaType(response.headers) ?? '',
      );
    }
    final meta = parseClipHeaders(response.headers);
    if (meta == null) {
      return ClipFetchFailed(
        rttMs,
        failure: ClipFetchFailure.badHeaders,
        statusCode: code,
      );
    }
    final body = response.bodyBytes;
    if (body.isEmpty) {
      return ClipFetchFailed(
        rttMs,
        failure: ClipFetchFailure.emptyBody,
        statusCode: code,
      );
    }
    return ClipFetchOk(rttMs, meta: meta, jpeg: body);
  }

  /// Content-Type 의 매체 타입만(파라미터 제외, 소문자). 헤더 이름은 대소문자
  /// 무시(dart:io 는 소문자, MockClient 는 보낸 그대로).
  static String? _mediaType(Map<String, String> headers) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'content-type') {
        return entry.value.split(';').first.trim().toLowerCase();
      }
    }
    return null;
  }
}
