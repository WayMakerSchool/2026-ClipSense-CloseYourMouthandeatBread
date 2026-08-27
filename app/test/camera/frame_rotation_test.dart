import 'package:camera/camera.dart';
import 'package:clip_sense/camera/camera_vision_source.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _allOrientations = [
  DeviceOrientation.portraitUp,
  DeviceOrientation.landscapeLeft,
  DeviceOrientation.portraitDown,
  DeviceOrientation.landscapeRight,
];

void main() {
  group('frameRotationDegrees', () {
    group('Android(CameraX)는 센서 좌표계 버퍼를 그대로 주므로 앱이 돌린다', () {
      int back(DeviceOrientation orientation) => frameRotationDegrees(
        platform: TargetPlatform.android,
        sensorOrientation: 90,
        deviceOrientation: orientation,
        lens: CameraLensDirection.back,
      );
      int front(DeviceOrientation orientation) => frameRotationDegrees(
        platform: TargetPlatform.android,
        sensorOrientation: 270,
        deviceOrientation: orientation,
        lens: CameraLensDirection.front,
      );

      test('후면 sensor 90: 세로 → 90, 가로는 0/180', () {
        expect(back(DeviceOrientation.portraitUp), 90);
        expect(back(DeviceOrientation.landscapeLeft), 0);
        expect(back(DeviceOrientation.portraitDown), 270);
        expect(back(DeviceOrientation.landscapeRight), 180);
      });

      test('전면 sensor 270(거울상): sensor+device', () {
        expect(front(DeviceOrientation.portraitUp), 270);
        expect(front(DeviceOrientation.landscapeLeft), 0);
        expect(front(DeviceOrientation.portraitDown), 90);
        expect(front(DeviceOrientation.landscapeRight), 180);
      });

      test('후면 sensor 0 세로는 회전 없음', () {
        expect(
          frameRotationDegrees(
            platform: TargetPlatform.android,
            sensorOrientation: 0,
            deviceOrientation: DeviceOrientation.portraitUp,
            lens: CameraLensDirection.back,
          ),
          0,
        );
      });

      test('결과는 항상 rotateBgr가 받는 0/90/180/270', () {
        for (final orientation in _allOrientations) {
          for (final sensor in const [0, 90, 180, 270]) {
            for (final lens in CameraLensDirection.values) {
              final degrees = frameRotationDegrees(
                platform: TargetPlatform.android,
                sensorOrientation: sensor,
                deviceOrientation: orientation,
                lens: lens,
              );
              expect(degrees, isIn(const [0, 90, 180, 270]));
            }
          }
        }
      });
    });

    group('iOS(AVFoundation)는 캡처 연결 videoOrientation으로 이미 회전된 버퍼를 준다', () {
      test('후면: 모든 기기 방향에서 0 (이중 회전 금지)', () {
        for (final orientation in _allOrientations) {
          expect(
            frameRotationDegrees(
              platform: TargetPlatform.iOS,
              sensorOrientation: 90,
              deviceOrientation: orientation,
              lens: CameraLensDirection.back,
            ),
            0,
            reason: '$orientation',
          );
        }
      });

      test('전면: 모든 기기 방향에서 0', () {
        for (final orientation in _allOrientations) {
          expect(
            frameRotationDegrees(
              platform: TargetPlatform.iOS,
              sensorOrientation: 90,
              deviceOrientation: orientation,
              lens: CameraLensDirection.front,
            ),
            0,
            reason: '$orientation',
          );
        }
      });

      test('플러그인이 보고하는 sensorOrientation 값과 무관하게 0', () {
        for (final sensor in const [0, 90, 180, 270]) {
          expect(
            frameRotationDegrees(
              platform: TargetPlatform.iOS,
              sensorOrientation: sensor,
              deviceOrientation: DeviceOrientation.portraitUp,
              lens: CameraLensDirection.back,
            ),
            0,
            reason: 'sensor $sensor',
          );
        }
      });
    });
  });
}
