import 'package:clip_sense/app/config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('카메라 연결 후 안전 기본값은 엄격 AND다', () {
    expect(kAllowSingleSource, isFalse);
  });

  test('카메라 처리 기본값', () {
    expect(kRoiFrac, 0.5);
    expect(kCameraProcessEveryN, 3);
    expect(kCameraResolutionPreset, 'medium');
  });
}
