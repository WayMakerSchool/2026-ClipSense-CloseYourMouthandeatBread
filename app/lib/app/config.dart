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

/// 카메라 프레임 중앙에서 검출에 사용할 가로·세로 비율.
const double kRoiFrac = 0.5;

/// 실시간 스트림 부하를 줄이기 위해 처리할 프레임 간격(첫 프레임부터 처리).
const int kCameraProcessEveryN = 3;

/// camera 플러그인의 해상도 프리셋 이름. 실제 enum 변환은 카메라 계층만 담당한다.
const String kCameraResolutionPreset = 'medium';
