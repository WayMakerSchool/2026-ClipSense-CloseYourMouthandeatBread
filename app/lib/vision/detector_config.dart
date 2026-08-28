/// 검출기 설정 값 타입. 기본값은 저장소 config.json(2026-07-14)과 일치.
/// 실환경 HSV 튜닝은 카메라 조각에서 재조정(이 값은 시작점).
library;

/// HSV 범위(OpenCV 스케일: H 0-179, S/V 0-255). lower/upper 각 [H,S,V].
class HsvRange {
  final List<int> lower;
  final List<int> upper;
  const HsvRange(this.lower, this.upper);
}

class DetectorConfig {
  final List<HsvRange> hsvRed;
  final List<HsvRange> hsvGreen;
  final List<HsvRange> digitRedHsv;
  final double minAreaRatio;
  final double maxAreaRatio;
  final double minCircularity;

  /// 램프 bbox 종횡비(가로/세로) 허용 범위. 신호등 램프는 정사각형에
  /// 가깝고(실측 0.48~0.92), 잔여시간 7세그 숫자 획은 가늘고 길다(0.12~0.42).
  final double minAspectRatio;
  final double maxAspectRatio;
  final double minBrightness;
  final double brightnessJump;
  final double brightnessEmaAlpha;
  final double validExitFactor;
  final int morphKernel;
  final int debounceFrames;
  final double blinkWindowSeconds;
  final int blinkMinToggles;
  final double blinkMinSegmentSeconds;
  final double unknownAfterSeconds;
  final double segOnRatio;
  final double segOffRatio;
  final double minCellFill;
  final double maxCellFill;
  final double maxCellAspect;
  final int stableWindow;
  final int stableVotes;

  const DetectorConfig({
    required this.hsvRed,
    required this.hsvGreen,
    required this.digitRedHsv,
    required this.minAreaRatio,
    required this.maxAreaRatio,
    required this.minCircularity,
    this.minAspectRatio = 0.45,
    this.maxAspectRatio = 2.2,
    required this.minBrightness,
    required this.brightnessJump,
    required this.brightnessEmaAlpha,
    required this.validExitFactor,
    required this.morphKernel,
    required this.debounceFrames,
    required this.blinkWindowSeconds,
    required this.blinkMinToggles,
    required this.blinkMinSegmentSeconds,
    required this.unknownAfterSeconds,
    required this.segOnRatio,
    required this.segOffRatio,
    required this.minCellFill,
    required this.maxCellFill,
    required this.maxCellAspect,
    required this.stableWindow,
    required this.stableVotes,
  });

  const DetectorConfig.defaults()
    : hsvRed = const [
        HsvRange([0, 55, 45], [12, 255, 255]),
        HsvRange([165, 55, 45], [180, 255, 255]),
      ],
      hsvGreen = const [
        HsvRange([35, 45, 45], [100, 255, 255]),
      ],
      digitRedHsv = const [
        HsvRange([0, 100, 80], [10, 255, 255]),
        HsvRange([170, 100, 80], [180, 255, 255]),
      ],
      minAreaRatio = 0.005,
      maxAreaRatio = 0.6,
      minCircularity = 0.12,
      minAspectRatio = 0.45,
      maxAspectRatio = 2.2,
      minBrightness = 35,
      brightnessJump = 60,
      brightnessEmaAlpha = 0.05,
      validExitFactor = 0.6,
      morphKernel = 5,
      debounceFrames = 8,
      blinkWindowSeconds = 2.0,
      blinkMinToggles = 3,
      blinkMinSegmentSeconds = 0.15,
      unknownAfterSeconds = 1.5,
      segOnRatio = 0.5,
      segOffRatio = 0.2,
      minCellFill = 0.08,
      maxCellFill = 0.65,
      maxCellAspect = 0.82,
      stableWindow = 5,
      stableVotes = 3;
}
