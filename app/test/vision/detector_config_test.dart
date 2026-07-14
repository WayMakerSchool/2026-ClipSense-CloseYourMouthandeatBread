import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/vision/detector_config.dart';

void main() {
  test('기본값이 config.json과 일치', () {
    const c = DetectorConfig.defaults();
    expect(c.minAreaRatio, 0.005);
    expect(c.maxAreaRatio, 0.6);
    expect(c.minCircularity, 0.12);
    expect(c.minBrightness, 35);
    expect(c.brightnessJump, 60);
    expect(c.brightnessEmaAlpha, 0.05);
    expect(c.validExitFactor, 0.6);
    expect(c.morphKernel, 5);
    expect(c.debounceFrames, 8);
    expect(c.blinkWindowSeconds, 2.0);
    expect(c.blinkMinToggles, 3);
    expect(c.blinkMinSegmentSeconds, 0.15);
    expect(c.unknownAfterSeconds, 1.5);
    expect(c.segOnRatio, 0.5);
    expect(c.segOffRatio, 0.2);
    expect(c.minCellFill, 0.08);
    expect(c.maxCellFill, 0.65);
    expect(c.maxCellAspect, 0.82);
    expect(c.stableWindow, 5);
    expect(c.stableVotes, 3);
  });

  test('HSV red 범위 2개, green 1개', () {
    const c = DetectorConfig.defaults();
    expect(c.hsvRed.length, 2);
    expect(c.hsvRed[0].lower, [0, 55, 45]);
    expect(c.hsvRed[0].upper, [12, 255, 255]);
    expect(c.hsvRed[1].lower, [165, 55, 45]);
    expect(c.hsvGreen.length, 1);
    expect(c.hsvGreen[0].lower, [35, 45, 45]);
    expect(c.hsvGreen[0].upper, [100, 255, 255]);
  });

  test('digit red_hsv 별도 범위 2개', () {
    const c = DetectorConfig.defaults();
    expect(c.digitRedHsv.length, 2);
    expect(c.digitRedHsv[0].lower, [0, 100, 80]);
    expect(c.digitRedHsv[0].upper, [10, 255, 255]);
    expect(c.digitRedHsv[1].lower, [170, 100, 80]);
  });
}
