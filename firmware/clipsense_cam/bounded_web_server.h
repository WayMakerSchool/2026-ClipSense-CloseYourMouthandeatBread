#pragma once

#include <WebServer.h>

// 헤더와 본문 전체에 같은 전송 기한을 적용한다(느린 클라이언트의 독점 방지).
class BoundedWebServer : public WebServer {
 public:
  using WebServer::WebServer;
  void handleClient() override;

 protected:
  size_t _currentClientWrite(const char* data, size_t length) override;
  size_t _currentClientWrite_P(PGM_P data, size_t length) override;

 private:
  bool _sendStarted = false;
  uint32_t _sendStartedMs = 0;
};
