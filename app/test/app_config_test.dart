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
}
