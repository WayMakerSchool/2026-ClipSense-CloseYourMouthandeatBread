// HTTP Camera API (보고서 §10).
//
//   /        80  고대비 단독 점검 화면 (기본 비활성, CLIP_ENABLE_INSPECT_PAGE)
//   /health  80  상태·버전·장애 통계 (JSON)
//   /capture 80  판정용 단일 JPEG
//   /jpg     80  /capture 호환 별칭
//
// 보안(§10.1): /health·/capture·/jpg는 X-Clip-Device-Token을 요구한다.
// CORS는 설정된 origin만 허용하고 와일드카드를 쓰지 않는다.
//
// 이 펌웨어는 MJPEG /stream(포트 81)을 제공하지 않는다. 최종 E2E에서
// stream과 capture를 동시에 돌리지 않기로 했고(§10.1), 한 프레임을 화면과
// 분석이 함께 쓰는 편이 "보인 프레임 = 분석한 프레임"을 지키기 때문이다.
#pragma once

#include <WebServer.h>

#include "camera_service.h"
#include "clip_network.h"

class HttpApi {
 public:
  HttpApi(CameraService& camera, ClipNetwork& net, const char* deviceToken,
          const char* bootId);

  void begin();
  void loop();

 private:
  void handleRoot();
  void handleHealth();
  void handleCapture();
  void handleNotFound();
  void handleOptions();

  // 요청의 Origin이 허용 목록에 있으면 그 값을, 없으면 nullptr을 돌려준다.
  const char* allowedOrigin() const;

  // CORS·캐시 헤더를 붙인다. exposeCaptureHeaders면 X-Frame-Seq 등을 노출한다.
  void applyCommonHeaders(bool exposeCaptureHeaders);

  // 토큰이 맞으면 true. 틀리면 401/403을 직접 보내고 false를 돌려준다.
  bool authorize();

  WebServer _server;
  CameraService& _camera;
  ClipNetwork& _net;
  const char* _deviceToken;
  const char* _bootId;
};
