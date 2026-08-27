/// 앱 공용 안전·카메라 설정. 교차로와 방향은 GPS 선택 결과로 주입한다.
library;

/// 건너기 시작에 필요한 최소 잔여 초. 이보다 짧으면 walk 안 함.
const double kNeedSec = 7.0;

/// 신호 확인 주기.
const Duration kLoopInterval = Duration(seconds: 1);

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
