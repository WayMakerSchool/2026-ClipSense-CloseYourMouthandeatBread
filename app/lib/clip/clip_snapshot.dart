/// 클립 카메라 `/capture` 응답 헤더 → 프레임 메타데이터(순수 함수).
///
/// 계약(하드웨어 보고서 §10.3~§10.4, firmware/README.md): 헤더가 없거나 숫자가
/// 정수가 아니거나 음수거나 `responseUptime < captureUptime` 이면 프레임을
/// 무효로 처리한다. 무효는 null 이다 — 기본값으로 채워 "그럴듯한" 프레임을
/// 만들지 않는다(추측 금지).
///
/// 헤더 이름은 대소문자를 가리지 않는다. dart:io(IOClient)는 응답 헤더 키를
/// 소문자로 주고 MockClient 는 보낸 그대로 준다. 대소문자를 가리면 테스트는
/// 통과하고 실기기에서는 모든 프레임이 버려진다.
library;

import 'package:flutter/foundation.dart';

import 'clip_contract.dart';

/// `/capture` 한 응답의 메타데이터. JPEG 바이트는 여기 없다(원자적으로 함께
/// 온 값만 담는다).
@immutable
class ClipCaptureMeta {
  final int frameSeq;
  final int captureUptimeUs;
  final int responseUptimeUs;
  final String bootId;
  final String? firmwareVersion;
  final String? cameraSensor;

  const ClipCaptureMeta({
    required this.frameSeq,
    required this.captureUptimeUs,
    required this.responseUptimeUs,
    required this.bootId,
    this.firmwareVersion,
    this.cameraSensor,
  });

  /// 펌웨어 안에서 프레임이 이미 늙은 시간(ms). 올림 — 보수적으로 더 오래된
  /// 것으로 본다(§10.4 `serverFrameAgeMs`).
  int get serverFrameAgeMs {
    final us = responseUptimeUs - captureUptimeUs;
    return (us + 999) ~/ 1000;
  }

  @override
  bool operator ==(Object other) =>
      other is ClipCaptureMeta &&
      other.frameSeq == frameSeq &&
      other.captureUptimeUs == captureUptimeUs &&
      other.responseUptimeUs == responseUptimeUs &&
      other.bootId == bootId &&
      other.firmwareVersion == firmwareVersion &&
      other.cameraSensor == cameraSensor;

  @override
  int get hashCode => Object.hash(
    frameSeq,
    captureUptimeUs,
    responseUptimeUs,
    bootId,
    firmwareVersion,
    cameraSensor,
  );

  @override
  String toString() =>
      'ClipCaptureMeta(seq: $frameSeq, capture: ${captureUptimeUs}us, '
      'response: ${responseUptimeUs}us, boot: $bootId)';
}

/// 헤더 맵에서 이름을 대소문자 무시로 찾는다. 앞뒤 공백은 잘라 돌려준다.
String? _header(Map<String, String> headers, String name) {
  final wanted = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == wanted) return entry.value.trim();
  }
  return null;
}

/// 십진 숫자만으로 된 음수 아닌 정수만 허용. double 을 거치지 않는다(64비트 µs
/// 보존). '1e3'·'1.5'·'NaN'·'Infinity' 는 물론 '+5'·'0x10' 처럼 int.tryParse 가
/// 받아 주는 표기도 거부한다 — 펌웨어는 부호 없는 십진수만 보낸다.
int? _nonNegativeInt(String? text) {
  if (text == null || text.isEmpty) return null;
  for (final unit in text.codeUnits) {
    if (unit < 0x30 || unit > 0x39) return null;
  }
  return int.tryParse(text); // 19자리 초과(64비트 넘침)는 null
}

/// `/capture` 응답 헤더를 [ClipCaptureMeta] 로. 계약 위반이면 null.
ClipCaptureMeta? parseClipHeaders(Map<String, String> headers) {
  final frameSeq = _nonNegativeInt(_header(headers, kClipFrameSeqHeader));
  final capture = _nonNegativeInt(_header(headers, kClipCaptureUptimeHeader));
  final response = _nonNegativeInt(_header(headers, kClipResponseUptimeHeader));
  final bootId = _header(headers, kClipBootIdHeader);
  if (frameSeq == null ||
      capture == null ||
      response == null ||
      bootId == null ||
      bootId.isEmpty) {
    return null;
  }
  if (response < capture) return null;

  String? optional(String name) {
    final v = _header(headers, name);
    return v == null || v.isEmpty ? null : v;
  }

  return ClipCaptureMeta(
    frameSeq: frameSeq,
    captureUptimeUs: capture,
    responseUptimeUs: response,
    bootId: bootId,
    firmwareVersion: optional(kClipFirmwareVersionHeader),
    cameraSensor: optional(kClipCameraSensorHeader),
  );
}
