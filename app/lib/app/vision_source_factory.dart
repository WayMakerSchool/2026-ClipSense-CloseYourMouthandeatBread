/// 실행 설정에 따라 비전 소스를 고른다: 클립 카메라(CLIP_CAM_HOST) 또는 폰 카메라.
///
/// 순수 함수라 main.dart 배선을 테스트할 수 있다. 호스트가 있는데 URL 로 해석되지
/// 않으면 던진다 — 설정 오류를 폰 카메라로 조용히 대체하면 시연에서 "클립이
/// 동작한다"고 착각하게 된다.
library;

import '../camera/camera_vision_source.dart';
import '../clip/clip_vision_source.dart';

VisionSource defaultVisionSource({
  required String host,
  required String token,
}) {
  if (host.trim().isEmpty) return CameraVisionSource();
  return ClipVisionSource(baseUrl: clipBaseUri(host), token: token);
}
