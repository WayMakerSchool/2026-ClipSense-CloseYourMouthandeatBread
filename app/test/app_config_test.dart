import 'package:clip_sense/app/config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('카메라 연결 후 안전 기본값은 엄격 AND다', () {
    expect(kAllowSingleSource, isFalse);
  });

  test('카메라 처리 기본값', () {
    // 실측(서울 보행등 근접 클립): 중앙 50%에서는 초록 blob이 minAreaRatio 경계(0.5%)에
    // 걸리고, 25%(1280x720 → 320x180)에서는 2.4%로 여유가 있다.
    expect(kRoiFrac, 0.25);
    expect(kCameraProcessEveryN, 3);
    expect(kCameraResolutionPreset, 'medium');
  });

  // 진단 스트립은 --dart-define=CLIP_DEBUG=true 빌드에서만 켜진다. 기본 빌드
  // (전맹 사용자용 배포)에는 프리뷰·상태 텍스트가 절대 들어가면 안 된다.
  test('진단 플래그 기본값은 꺼짐', () {
    expect(kClipDebug, isFalse);
  });

  test('kStaleMs: 두 소스 모두 2초 이내 최신일 때만 판정에 쓴다(안전 정책 상수)', () {
    expect(kStaleMs, 2000);
  });

  test('클립 카메라 설정: 기본은 미설정(폰 카메라), 하드코딩 금지', () {
    expect(kClipCamHost, '');
    expect(kClipCamToken, '');
    expect(kClipPollInterval, const Duration(milliseconds: 250));
    expect(kClipRequestTimeout, const Duration(milliseconds: 800));
    expect(kClipRoiFrac, 0.25);
  });

  test('kVisionStallMs: 3초 — 신선도 한계(kStaleMs)보다 길어 정지 안내가 안전 탈락 뒤에만 나온다', () {
    expect(kVisionStallMs, 3000);
    expect(kVisionStallMs, greaterThan(kStaleMs));
  });
}
