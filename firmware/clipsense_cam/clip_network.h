// Wi-Fi 상태기계 (보고서 §9.4).
//
//   BOOT
//   └─ STA_CONNECTING
//      ├─ 성공         → STA_ACTIVE
//      └─ 제한시간 실패 → AP_RECOVERY
//
//   STA_ACTIVE 중 연결 두절
//   ├─ 카메라 관측은 unavailable이 되고
//   ├─ 앱은 freshness 만료 즉시 WAIT으로 내려가며
//   └─ ESP32는 같은 STA에 비동기로 재접속한다.
//
// SoftAP는 자동 안전 failover가 아니라 사람이 직접 붙는 복구 경로다.
// Wi-Fi 자격정보를 입력받는 provisioning endpoint는 이 범위에 없다.
#pragma once

#include <Arduino.h>
#include <WiFi.h>

#include "config.h"

enum class NetState {
  Boot,
  StaConnecting,
  StaActive,
  StaReconnecting,
  ApRecovery,
};

class ClipNetwork {
 public:
  // STA 접속을 시작한다. 제한시간을 넘기면 복구 AP로 전환한다.
  void begin(const char* ssid, const char* password, const char* apPassword);

  // 주기적으로 호출한다(블로킹하지 않는다). 연결 상태 변화를 처리한다.
  void loop();

  NetState state() const { return _state; }

  // /health 의 networkMode 로 나가는 문자열: "STA" | "STA_RECONNECTING" | "AP" | "BOOT"
  const char* modeName() const;

  IPAddress ip() const;
  int rssiDbm() const;
  uint32_t disconnectCount() const { return _disconnectCount; }
  const String& hostname() const { return _hostname; }
  const String& apSsid() const { return _apSsid; }

  // STA로 붙어 있고 IP를 받은 상태인가.
  bool staOnline() const { return _state == NetState::StaActive; }

 private:
  void enterStaConnecting();
  void enterStaActive();
  void enterApRecovery();
  void startMdns();

  NetState _state = NetState::Boot;
  const char* _ssid = "";
  const char* _password = "";
  const char* _apPassword = "";
  String _hostname;
  String _apSsid;
  uint32_t _connectStartedMs = 0;
  uint32_t _lastRetryMs = 0;
  uint32_t _retryCount = 0;
  uint32_t _disconnectCount = 0;
  bool _mdnsStarted = false;
};
