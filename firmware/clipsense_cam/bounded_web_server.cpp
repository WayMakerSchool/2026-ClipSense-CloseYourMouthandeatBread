#include "bounded_web_server.h"

#include <errno.h>
#include <lwip/sockets.h>

namespace {
constexpr uint32_t kSendTimeoutMs = 1000;
constexpr size_t kSendChunkBytes = 1460;
}  // namespace

void BoundedWebServer::handleClient() {
  // WebServer는 한 번의 handleClient()에서 한 요청을 동기 처리한다.
  _sendStarted = false;
  WebServer::handleClient();
}

size_t BoundedWebServer::_currentClientWrite(const char* data, size_t length) {
  if (length == 0) return 0;
  if (!_sendStarted) {
    _sendStarted = true;
    _sendStartedMs = millis();
  }

  const int socketFd = _currentClient.fd();
  if (socketFd < 0) return 0;
  size_t written = 0;
  while (written < length &&
         static_cast<uint32_t>(millis() - _sendStartedMs) < kSendTimeoutMs) {
    const size_t remaining = length - written;
    const size_t chunk = remaining < kSendChunkBytes ? remaining : kSendChunkBytes;
    // NetworkClient::write()의 고정 select 대기·재시도를 우회해야 기한을 지킨다.
    const int sent = ::send(socketFd, data + written, chunk, MSG_DONTWAIT);
    if (sent > 0) {
      written += static_cast<size_t>(sent);
    } else if (sent < 0 && errno != EAGAIN && errno != EWOULDBLOCK &&
               errno != EINTR) {
      break;
    } else {
      // Wi-Fi 작업에 실행 시간을 주되, 조금씩 전송돼도 전체 기한은 늘리지 않는다.
      delay(1);
    }
  }

  if (written != length) {
    // Content-Length보다 짧은 응답은 연결을 닫아 실패로 드러낸다.
    // 호출자는 정상 전송 때와 같은 경로로 framebuffer를 반환한다.
    _currentClient.stop();
  }
  return written;
}

size_t BoundedWebServer::_currentClientWrite_P(PGM_P data, size_t length) {
  // ESP32의 플래시 문자열은 메모리에 매핑되어 같은 전송 경로를 쓸 수 있다.
  return _currentClientWrite(data, length);
}
