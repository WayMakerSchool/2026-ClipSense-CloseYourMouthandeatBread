/// 클립 카메라(XIAO ESP32S3 Sense) HTTP 계약 상수.
///
/// 출처: firmware/README.md "HTTP API", firmware/clipsense_cam/http_api.cpp,
/// 하드웨어 보고서 §10. 펌웨어와 앱이 같은 문자열을 쓰도록 여기 한 곳에만 둔다.
/// (scripts/verify_firmware_contract.py 가 펌웨어 쪽 문자열을 검사한다.)
library;

/// 모든 데이터 엔드포인트가 요구하는 기기 토큰 헤더.
const String kClipTokenHeader = 'X-Clip-Device-Token';

/// 새 JPEG 획득 성공 시에만 증가 — 정지(freeze) 감지의 유일한 근거.
const String kClipFrameSeqHeader = 'X-Frame-Seq';

/// 획득 순간의 기기 uptime(µs).
const String kClipCaptureUptimeHeader = 'X-Capture-Uptime-Us';

/// 응답 직전의 기기 uptime(µs). capture 와 같은 clock domain.
const String kClipResponseUptimeHeader = 'X-Response-Uptime-Us';

/// 부팅마다 바뀜 — 바뀌면 uptime 비교 이력을 폐기한다.
const String kClipBootIdHeader = 'X-Boot-Id';

const String kClipFirmwareVersionHeader = 'X-Firmware-Version';
const String kClipCameraSensorHeader = 'X-Camera-Sensor';

/// /health 응답의 schemaVersion.
const String kClipSchemaVersion = 'clipsense-camera-api-v1';

const String kClipCapturePath = '/capture';
const String kClipHealthPath = '/health';

/// /capture 정상 응답의 Content-Type.
const String kClipJpegContentType = 'image/jpeg';
