import 'package:clip_sense/app/vision_source_factory.dart';
import 'package:clip_sense/camera/camera_vision_source.dart';
import 'package:clip_sense/clip/clip_vision_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CLIP_CAM_HOST 가 비면 폰 카메라(기본)', () {
    expect(defaultVisionSource(host: '', token: ''), isA<CameraVisionSource>());
    expect(
      defaultVisionSource(host: '   ', token: 'x'),
      isA<CameraVisionSource>(),
    );
  });

  test('CLIP_CAM_HOST 가 있으면 클립 카메라 소스', () {
    final s = defaultVisionSource(
      host: 'http://clipsense-a1b2.local',
      token: 'tok',
    );
    expect(s, isA<ClipVisionSource>());
    expect(
      (s as ClipVisionSource).captureUri.toString(),
      'http://clipsense-a1b2.local/capture',
    );
  });

  test('scheme 없이 host 만 주면 http:// 를 붙인다', () {
    final s =
        defaultVisionSource(host: '192.168.4.1', token: 'tok')
            as ClipVisionSource;
    expect(s.captureUri.toString(), 'http://192.168.4.1/capture');
  });

  test('host 가 URL 로 해석되지 않으면 폰 카메라로 물러나지 않고 던진다(설정 오류를 숨기지 않음)', () {
    expect(
      () => defaultVisionSource(host: 'http://[bad', token: 't'),
      throwsA(isA<ArgumentError>()),
    );
  });
}
