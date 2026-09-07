// 클립 카메라 /capture 응답 헤더 파서. 계약: firmware/README.md "HTTP API",
// 하드웨어 보고서 §10.3~§10.4. 헤더가 없거나 정수가 아니거나 음수거나
// responseUptime < captureUptime 이면 프레임 무효(null) — 추측하지 않는다.
//
// 헤더 이름은 대소문자를 가리지 않는다: dart:io(IOClient)는 응답 헤더 키를
// 소문자('x-frame-seq')로 주고 MockClient는 보낸 그대로('X-Frame-Seq') 준다.
// 대소문자를 가리는 파서는 MockClient 테스트는 통과하고 실기기에서는 모든
// 프레임을 버린다.
import 'package:clip_sense/clip/clip_contract.dart';
import 'package:clip_sense/clip/clip_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, String> good({
  String seq = '1482',
  String capture = '372800221',
  String response = '372812505',
  String boot = 'a83f219c',
}) => {
  'X-Frame-Seq': seq,
  'X-Capture-Uptime-Us': capture,
  'X-Response-Uptime-Us': response,
  'X-Boot-Id': boot,
  'X-Firmware-Version': '0.2.0',
  'X-Camera-Sensor': 'OV3660',
};

void main() {
  test('계약 상수는 펌웨어 http_api.cpp의 헤더 이름과 같다', () {
    expect(kClipTokenHeader, 'X-Clip-Device-Token');
    expect(kClipFrameSeqHeader, 'X-Frame-Seq');
    expect(kClipCaptureUptimeHeader, 'X-Capture-Uptime-Us');
    expect(kClipResponseUptimeHeader, 'X-Response-Uptime-Us');
    expect(kClipBootIdHeader, 'X-Boot-Id');
    expect(kClipFirmwareVersionHeader, 'X-Firmware-Version');
    expect(kClipCameraSensorHeader, 'X-Camera-Sensor');
    expect(kClipCapturePath, '/capture');
    expect(kClipHealthPath, '/health');
    expect(kClipJpegContentType, 'image/jpeg');
  });

  group('parseClipHeaders', () {
    test('펌웨어 README 예시 헤더 → 메타데이터', () {
      final m = parseClipHeaders(good())!;
      expect(m.frameSeq, 1482);
      expect(m.captureUptimeUs, 372800221);
      expect(m.responseUptimeUs, 372812505);
      expect(m.bootId, 'a83f219c');
      expect(m.firmwareVersion, '0.2.0');
      expect(m.cameraSensor, 'OV3660');
      // (372812505 - 372800221) / 1000 = 12.284ms → 정수 ms는 내림하지 않고 올림
      // (보수적: 프레임을 더 오래된 것으로 본다).
      expect(m.serverFrameAgeMs, 13);
    });

    test('소문자 키(dart:io 실전송)도 같은 결과', () {
      final lower = {
        for (final e in good().entries) e.key.toLowerCase(): e.value,
      };
      final m = parseClipHeaders(lower)!;
      expect(m.frameSeq, 1482);
      expect(m.bootId, 'a83f219c');
    });

    test('뒤섞인 대소문자 키도 같은 결과', () {
      final mixed = {
        'x-FRAME-seq': '7',
        'X-capture-Uptime-US': '100',
        'x-Response-uptime-us': '100',
        'X-BOOT-ID': 'b1',
      };
      final m = parseClipHeaders(mixed)!;
      expect(m.frameSeq, 7);
      expect(m.serverFrameAgeMs, 0);
      expect(m.firmwareVersion, isNull);
      expect(m.cameraSensor, isNull);
    });

    test('필수 헤더가 하나라도 없으면 무효', () {
      for (final key in [
        'X-Frame-Seq',
        'X-Capture-Uptime-Us',
        'X-Response-Uptime-Us',
        'X-Boot-Id',
      ]) {
        final h = good()..remove(key);
        expect(parseClipHeaders(h), isNull, reason: key);
      }
    });

    test('정수가 아니거나 음수인 숫자 헤더는 무효(double 경유 금지)', () {
      for (final bad in [
        '',
        ' ',
        'abc',
        '1.5',
        '1e3',
        '-1',
        'NaN',
        'Infinity',
      ]) {
        expect(parseClipHeaders(good(seq: bad)), isNull, reason: 'seq=$bad');
        expect(
          parseClipHeaders(good(capture: bad)),
          isNull,
          reason: 'cap=$bad',
        );
        expect(
          parseClipHeaders(good(response: bad)),
          isNull,
          reason: 'res=$bad',
        );
      }
    });

    test('64비트 마이크로초(uint64) 값도 정확히 읽는다', () {
      final m = parseClipHeaders(
        good(capture: '9007199254740993', response: '9007199254741993'),
      )!;
      expect(m.captureUptimeUs, 9007199254740993);
      expect(m.serverFrameAgeMs, 1);
    });

    test('responseUptime < captureUptime 이면 무효, 같으면 유효(나이 0)', () {
      expect(parseClipHeaders(good(capture: '100', response: '99')), isNull);
      final m = parseClipHeaders(good(capture: '100', response: '100'))!;
      expect(m.serverFrameAgeMs, 0);
    });

    test('bootId가 비어 있거나 공백뿐이면 무효, 앞뒤 공백은 잘라 쓴다', () {
      expect(parseClipHeaders(good(boot: '')), isNull);
      expect(parseClipHeaders(good(boot: '   ')), isNull);
      expect(parseClipHeaders(good(boot: ' a83f219c '))!.bootId, 'a83f219c');
    });

    test('숫자 앞뒤 공백은 허용(HTTP 헤더 값 트림)', () {
      expect(parseClipHeaders(good(seq: ' 12 '))!.frameSeq, 12);
    });

    test('frameSeq 0은 허용(첫 프레임 이전 상태를 펌웨어가 보고할 수 있음)', () {
      expect(parseClipHeaders(good(seq: '0'))!.frameSeq, 0);
    });

    test('같은 값이면 같은 메타데이터(값 객체)', () {
      expect(parseClipHeaders(good()), parseClipHeaders(good()));
      expect(
        parseClipHeaders(good()).hashCode,
        parseClipHeaders(good()).hashCode,
      );
      expect(parseClipHeaders(good()), isNot(parseClipHeaders(good(seq: '1'))));
    });
  });
}
