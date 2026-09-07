/// 앱 공용 안전·카메라 설정. 교차로와 방향은 GPS 선택 결과로 주입한다.
library;

/// 건너기 시작에 필요한 최소 잔여 초. 이보다 짧으면 walk 안 함.
const double kNeedSec = 7.0;

/// 신호 확인 주기.
const Duration kLoopInterval = Duration(seconds: 1);

/// 판정에 쓸 수 있는 판독의 최대 나이(ms). API·카메라 모두 이보다 오래되면
/// unknown으로 취급한다(안전 정책 "둘 다 2초 이내 최신"). judge/signal_api의
/// 기본값과 같지만 컨트롤러는 이 상수를 명시적으로 넘긴다.
const int kStaleMs = 2000;

/// T-Data API 키. 하드코딩 금지 — --dart-define=TDATA_KEY=... 로 주입.
const String kApiKey = String.fromEnvironment('TDATA_KEY');

/// API와 카메라가 모두 초록일 때만 보행을 허용한다.
const bool kAllowSingleSource = false;

/// 진단 스트립(카메라 프리뷰+ROI, API/카메라 상태 한 줄) 표시 여부.
///
/// 기본 false — 전맹 사용자용 배포 빌드에는 절대 들어가지 않는다. 시연 영상·실기기
/// 디버깅 빌드에서만 `--dart-define=CLIP_DEBUG=true`로 켠다(app_config_test가 기본값 고정).
const bool kClipDebug = bool.fromEnvironment('CLIP_DEBUG');

/// 카메라 프레임 중앙에서 검출에 사용할 가로·세로 비율.
///
/// 실측 근거(2026-08-27, 서울 보행등 근접 클립 1280x720): 중앙 50%에서는 초록 램프가
/// ROI의 0.39%(블러 없음)~0.62%(블러)로 minAreaRatio 0.5% 경계에 걸려 판정이 흔들리지만,
/// 25%(320x180)에서는 2.4%로 여유가 있고 처리 픽셀 수도 1/4이다. 사용자는 신호등을
/// 화면 중앙에 두도록 안내받으므로 좁은 ROI가 오히려 주변 초록(간판·나무)도 덜 잡는다.
const double kRoiFrac = 0.25;

/// 실시간 스트림 부하를 줄이기 위해 처리할 프레임 간격(첫 프레임부터 처리).
const int kCameraProcessEveryN = 3;

/// camera 플러그인의 해상도 프리셋 이름. 실제 enum 변환은 카메라 계층만 담당한다.
const String kCameraResolutionPreset = 'medium';

/// 클립 카메라(XIAO ESP32S3 Sense) 주소. 비어 있으면(기본) 폰 카메라를 쓴다.
/// `--dart-define=CLIP_CAM_HOST=192.168.0.42`(STA 모드 LAN IP) 또는
/// `http://clipsense-a1b2.local`. 펌웨어 SoftAP `192.168.4.1`은 복구 경로라 인터넷이
/// 없어 API가 닿지 않는다(항상 대기).
/// 하드코딩 금지. mDNS(.local) 해석은 OS 에 맡긴다(Android 는 해석 못 할 수 있음
/// → IP 사용).
const String kClipCamHost = String.fromEnvironment('CLIP_CAM_HOST');

/// 클립 카메라 기기 토큰(펌웨어 secrets.h 의 CLIP_DEVICE_TOKEN 과 같은 값).
/// `--dart-define=CLIP_CAM_TOKEN=...`. 하드코딩 금지.
const String kClipCamToken = String.fromEnvironment('CLIP_CAM_TOKEN');

/// 클립 프레임(QVGA 320x240 전체)에서 검출에 쓸 중앙 비율.
///
/// 실측(scripts/dump_clip_qvga_fixture.py, 실클립을 4:3 으로 잘라 QVGA 로 줄임):
/// 1.0 은 점등 프레임에서도 초록 0.40% < 0.5% 로 no_blob, 0.5 는 점멸 **소등**
/// 프레임에서도 GREEN(0.82%) 이 나와 점멸을 놓치므로 기본값 불가, 0.25(80x60)는
/// 점등 GREEN 3.4% / 소등 NONE. 실기기 프레임으로 다시 측정할 항목.
const double kClipRoiFrac = 0.25;

/// 클립 카메라 스냅샷 폴링 간격(하드웨어 보고서 §11.3). 이전 요청이 끝나기 전에는
/// 새 요청을 보내지 않으므로 실효 간격은 이보다 길 수 있다.
const Duration kClipPollInterval = Duration(milliseconds: 250);

/// 스냅샷 한 요청의 제한 시간(§11.3 초기값). 넘기면 연결을 끊고 unknown.
const Duration kClipRequestTimeout = Duration(milliseconds: 800);
