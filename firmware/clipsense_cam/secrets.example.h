// 이 파일을 secrets.h 로 복사한 뒤 값을 채운다.
//
//     cp secrets.example.h secrets.h
//
// secrets.h 는 .gitignore 되어 있다. Wi-Fi 비밀번호와 기기 토큰을 커밋하지 않는다
// (보고서 §9.4 권장 사항).
#pragma once

// ── STA(기존 Wi-Fi에 접속) 자격정보 ───────────────────────────────────────
// 2.4GHz 대역만 쓴다. ESP32-S3는 5GHz를 지원하지 않는다.
#define CLIP_WIFI_SSID "your-2g4-ssid"
#define CLIP_WIFI_PASSWORD "your-wifi-password"

// ── 카메라 API 기기 토큰 ──────────────────────────────────────────────────
// /health, /capture, /jpg 요청의 X-Clip-Device-Token 헤더와 대조한다.
// Wi-Fi 비밀번호와 다른 값을 쓰고, 기기마다 다르게 준다(§10.1).
// 생성 예: openssl rand -hex 16
#define CLIP_DEVICE_TOKEN "replace-with-a-random-32-char-token"

// ── 복구용 SoftAP 비밀번호 ────────────────────────────────────────────────
// STA 연결에 실패했을 때 켜지는 복구 AP의 비밀번호.
// 공통 공개 비밀번호를 쓰지 않는다(§9.4). 8자 이상이어야 WPA2가 걸린다.
#define CLIP_AP_PASSWORD "replace-with-device-specific-pass"
