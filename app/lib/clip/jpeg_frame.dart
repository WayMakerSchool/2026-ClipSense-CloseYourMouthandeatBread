/// 클립 카메라 `/capture` JPEG → 판정용 BGR ROI(순수 Dart).
///
/// image 패키지의 decodeJpg 만 쓴다(플랫폼 채널·dart:ui 없음) — flutter test 로
/// 검증되고 UI isolate 에 묶이지 않는다. 디코드 실패는 null 이다: 깨진 프레임을
/// 검은 프레임으로 대신 만들면 "너무 어두움"이라는 거짓 진단이 나온다.
///
/// 크롭 비율: 펌웨어 기본 프로필은 QVGA(320x240) 전체 프레임이다. 4:3 으로 정직하게
/// 자른 QVGA fixture 실측(scripts/dump_clip_qvga_fixture.py, 2026-09-07)에서 전체
/// 프레임은 점등에도 no_blob(0.40% < 0.5%), 중앙 50% 는 점멸 **소등** 프레임까지
/// GREEN(0.82%) 으로 읽어 부적합, 중앙 25% 는 점등 GREEN 3.4% / 소등 NONE 이었다
/// (기본값 kClipRoiFrac = 0.25). 비율 자체는 호출자가 정한다.
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
