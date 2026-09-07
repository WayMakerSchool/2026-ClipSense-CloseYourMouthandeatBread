/// 클립 카메라 `/capture` JPEG → 판정용 BGR ROI(순수 Dart).
///
/// image 패키지의 decodeJpg 만 쓴다(플랫폼 채널·dart:ui 없음) — flutter test 로
/// 검증되고 UI isolate 에 묶이지 않는다. 디코드 실패는 null 이다: 깨진 프레임을
/// 검은 프레임으로 대신 만들면 "너무 어두움"이라는 거짓 진단이 나온다.
///
/// 크롭 비율: 펌웨어 기본 프로필은 QVGA(320x240) 전체 프레임이다. 실측
/// (scripts/measure_clip_frame_size.py, 2026-09-07) 전체 프레임에서는 램프
/// 면적이 minAreaRatio 를 절대 넘지 못했고(84/84 no_blob) 중앙 50% 크롭이
/// 가장 많은 프레임을 잡았다(59/84). 비율 자체는 호출자가 정한다.
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../camera/frame_converter.dart' show bgrCenterCrop, centerCrop;
import '../vision/roi_image.dart';

export '../camera/frame_converter.dart' show bgrCenterCrop;

/// JPEG 바이트를 디코드해 중앙 [roiFrac] ROI 를 BGR 로 돌려준다.
/// 디코드 실패·빈 입력·크기 0 → null. roiFrac 이 (0, 1] 밖이면 ArgumentError.
RoiImage? decodeJpegToRoiBgr(Uint8List jpeg, double roiFrac) {
  // 비율 검증은 입력이 비어 있어도 먼저 — 설정 오류를 조용히 삼키지 않는다.
  centerCrop(1, 1, roiFrac);
  if (jpeg.isEmpty) return null;

  img.Image? decoded;
  try {
    decoded = img.decodeJpg(jpeg);
  } catch (_) {
    return null;
  }
  if (decoded == null || decoded.width <= 0 || decoded.height <= 0) {
    return null;
  }

  final Uint8List bgr;
  try {
    bgr = decoded.getBytes(order: img.ChannelOrder.bgr);
  } catch (_) {
    return null;
  }
  final expected = decoded.width * decoded.height * 3;
  if (bgr.length != expected) return null;

  return bgrCenterCrop(RoiImage(decoded.width, decoded.height, bgr), roiFrac);
}
