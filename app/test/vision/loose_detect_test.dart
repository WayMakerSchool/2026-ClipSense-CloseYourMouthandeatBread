// 시험용 완화 판정(LOOSE_DETECT) — 기본값은 그대로, 완화는 큰 blob·밝기 급변만 푼다.
import 'package:clip_sense/app/config.dart';
import 'package:clip_sense/vision/color_detector.dart';
import 'package:clip_sense/vision/detector_config.dart';
import 'package:flutter_test/flutter_test.dart';

import 'color_detector_test.dart' show frame, green;

void main() {
  test('기본 빌드에서는 완화 판정이 꺼져 있다', () {
    expect(kLooseDetect, isFalse);
    expect(const DetectorConfig.defaults().maxAreaRatio, 0.6);
  });

  test('완화는 큰 blob·밝기 급변·연속 프레임만 바꾸고 색 범위는 그대로 둔다', () {
    const base = DetectorConfig.defaults();
    final loose = base.loosened();
    expect(loose.maxAreaRatio, greaterThan(1.0));
    expect(loose.brightnessJump, greaterThan(255));
    expect(loose.debounceFrames, 4);
    expect(loose.hsvGreen.length, base.hsvGreen.length);
    expect(loose.hsvRed.length, base.hsvRed.length);
    expect(loose.minAreaRatio, base.minAreaRatio);
  });

  test('ROI를 거의 덮는 초록(폰 화면을 가까이 댐): 기본은 버리고 완화는 GREEN', () {
    final strict = ColorDetector(const DetectorConfig.defaults());
    strict.detect(frame());
    final s = strict.detect(frame(circleBgr: green, r: 94)); // ≈70%
    expect(s.raw, rawNone);

    final loose = ColorDetector(const DetectorConfig.defaults().loosened());
    loose.detect(frame());
    final l = loose.detect(frame(circleBgr: green, r: 94));
    expect(l.raw, rawGreen);
  });
}
