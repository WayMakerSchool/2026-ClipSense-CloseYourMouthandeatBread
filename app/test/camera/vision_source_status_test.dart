import 'package:camera/camera.dart';
import 'package:clip_sense/app/config.dart';
import 'package:clip_sense/camera/camera_vision_source.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('statusFromCameraError', () {
    // 실제 플러그인이 내는 code 문자열(pub-cache 확인):
    // - camera_avfoundation 0.9.23+2 CameraPermissionManager.swift
    //   :123 CameraAccessDenied / :81 CameraAccessDeniedWithoutPrompt /
    //   :100 CameraAccessRestricted
    // - camera_android_camerax 0.6.30 CameraPermissionsManager.java
    //   :36 CameraAccessDenied
    test('권한 거부 계열 code → permissionDenied', () {
      for (final code in [
        'CameraAccessDenied',
        'CameraAccessDeniedWithoutPrompt',
        'CameraAccessRestricted',
        'cameraPermission',
      ]) {
        expect(
          statusFromCameraError(CameraException(code, 'denied')),
          VisionSourceStatus.permissionDenied,
          reason: code,
        );
      }
    });

    test('PlatformException으로 새어 나온 권한 code도 같은 분류', () {
      expect(
        statusFromCameraError(
          PlatformException(code: 'CameraAccessDenied', message: 'denied'),
        ),
        VisionSourceStatus.permissionDenied,
      );
    });

    // Android "다른 권한 요청 진행 중"은 거부가 아니라 일시 오류다. 거부로 잘못
    // 분류하면 전맹 사용자에게 "설정에서 허용하세요"를 잘못 말하게 된다.
    test('CameraPermissionsRequestOngoing(일시 오류)은 failed', () {
      expect(
        statusFromCameraError(
          CameraException('CameraPermissionsRequestOngoing', 'ongoing'),
        ),
        VisionSourceStatus.failed,
      );
    });

    test('카메라 목록 비어 있음 → unavailable', () {
      expect(
        statusFromCameraError(const NoCameraAvailableException()),
        VisionSourceStatus.unavailable,
      );
    });

    test('그 외 예외 → failed', () {
      for (final e in [
        CameraException('CameraNotFound', 'x'),
        const FormatException('bad frame'),
        Exception('boom'),
        StateError('closed'),
      ]) {
        expect(
          statusFromCameraError(e),
          VisionSourceStatus.failed,
          reason: '$e',
        );
      }
    });
  });

  group('VisionDiagnostics', () {
    test('불변 값 객체: 같은 값이면 같다', () {
      const a = VisionDiagnostics(
        lastReason: 'no_blob',
        areaRatio: 0.003,
        brightness: 120,
        processMs: 31,
        framesProcessed: 10,
        lastFrameAgeMs: 120,
      );
      const b = VisionDiagnostics(
        lastReason: 'no_blob',
        areaRatio: 0.003,
        brightness: 120,
        processMs: 31,
        framesProcessed: 10,
        lastFrameAgeMs: 120,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(const VisionDiagnostics())));
    });

    test('기본값: 이유 없음·수치 null·카운터 0', () {
      const d = VisionDiagnostics();
      expect(d.lastReason, '');
      expect(d.areaRatio, isNull);
      expect(d.brightness, isNull);
      expect(d.processMs, 0);
      expect(d.framesProcessed, 0);
      expect(d.lastFrameAgeMs, isNull);
    });
  });

  test('CameraVisionSource 초기 상태: idle·진단 없음·프리뷰 없음', () {
    final source = CameraVisionSource();
    expect(source.status, VisionSourceStatus.idle);
    expect(source.diagnostics, isNull);
    expect(source.previewController, isNull);
  });

  group('정지 중 초기화 실패는 상태를 덮지 않는다', () {
    test('start 직후 stop이 들어오면 실패해도 idle로 남는다', () async {
      final source = CameraVisionSource(
        cameraLister: () async {
          throw CameraException('CameraAccessDenied', 'denied');
        },
      );
      final started = source.start();
      final stopped = source.stop(); // 초기화 진행 중 정지
      await started;
      await stopped;
      expect(source.status, VisionSourceStatus.idle);
      expect(source.previewController, isNull);
    });

    test('정지 요청이 없으면 실패 상태가 남는다', () async {
      final source = CameraVisionSource(
        cameraLister: () async {
          throw CameraException('CameraAccessDenied', 'denied');
        },
      );
      await source.start();
      expect(source.status, VisionSourceStatus.permissionDenied);
      await source.stop();
      expect(source.status, VisionSourceStatus.idle);
    });

    test('카메라가 없으면 unavailable', () async {
      final source = CameraVisionSource(cameraLister: () async => const []);
      await source.start();
      expect(source.status, VisionSourceStatus.unavailable);
      await source.stop();
    });
  });

  // 정지 감시는 래치가 아니라 "마지막 처리 프레임 나이"의 순수 함수다. 실제 플러그인
  // 정지는 테스트로 만들 수 없으므로(실기기 미검증) 시간 계산은 여기서 고정하고,
  // 소스에서는 스트리밍 진입 전 상태가 stalled 로 새지 않는 것만 확인한다.
  group('statusForStream(정지 감시, 순수 함수)', () {
    test('streaming + 나이 3000ms 이하 → streaming', () {
      for (final age in [0, 1, 2999, 3000]) {
        expect(
          statusForStream(VisionSourceStatus.streaming, lastFrameAgeMs: age),
          VisionSourceStatus.streaming,
          reason: 'age=$age',
        );
      }
    });

    test('streaming + 나이 3000ms 초과 → stalled', () {
      for (final age in [3001, 3250, 60000]) {
        expect(
          statusForStream(VisionSourceStatus.streaming, lastFrameAgeMs: age),
          VisionSourceStatus.stalled,
          reason: 'age=$age',
        );
      }
    });

    test('streaming 인데 나이를 모르면(null) streaming 유지', () {
      expect(
        statusForStream(VisionSourceStatus.streaming, lastFrameAgeMs: null),
        VisionSourceStatus.streaming,
      );
    });

    test('streaming 이 아닌 상태는 나이와 무관하게 그대로(unreachable·failed 가 우선)', () {
      for (final s in [
        VisionSourceStatus.idle,
        VisionSourceStatus.starting,
        VisionSourceStatus.permissionDenied,
        VisionSourceStatus.unavailable,
        VisionSourceStatus.unreachable,
        VisionSourceStatus.failed,
        VisionSourceStatus.stalled,
      ]) {
        expect(statusForStream(s, lastFrameAgeMs: 99999), s, reason: '$s');
        expect(statusForStream(s, lastFrameAgeMs: null), s, reason: '$s');
      }
    });

    test('stallMs 주입: 초과일 때만 stalled(기본값은 kVisionStallMs)', () {
      expect(
        statusForStream(
          VisionSourceStatus.streaming,
          lastFrameAgeMs: 500,
          stallMs: 500,
        ),
        VisionSourceStatus.streaming,
      );
      expect(
        statusForStream(
          VisionSourceStatus.streaming,
          lastFrameAgeMs: 501,
          stallMs: 500,
        ),
        VisionSourceStatus.stalled,
      );
      expect(
        statusForStream(
          VisionSourceStatus.streaming,
          lastFrameAgeMs: kVisionStallMs + 1,
        ),
        VisionSourceStatus.stalled,
      );
    });
  });

  test(
    'CameraVisionSource: 스트리밍 전(idle·권한 거부·카메라 없음)에는 stalled 가 아니다',
    () async {
      expect(CameraVisionSource().status, VisionSourceStatus.idle);

      final denied = CameraVisionSource(
        cameraLister: () async =>
            throw CameraException('CameraAccessDenied', 'x'),
      );
      await denied.start();
      expect(denied.status, VisionSourceStatus.permissionDenied);

      final none = CameraVisionSource(cameraLister: () async => const []);
      await none.start();
      expect(none.status, VisionSourceStatus.unavailable);
      await none.stop();
      expect(none.status, VisionSourceStatus.idle);
    },
  );
}
