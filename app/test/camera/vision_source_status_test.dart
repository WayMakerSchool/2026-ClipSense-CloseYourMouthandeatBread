import 'package:camera/camera.dart';
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
}
