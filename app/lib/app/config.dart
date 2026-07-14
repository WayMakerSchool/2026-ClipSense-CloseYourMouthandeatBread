/// 앱 고정 설정. GPS 자동 교차로 선택은 별도 조각 — 지금은 고정 1개.
library;

/// 프로토타입 기본 교차로: 실측(2026-07-14)에서 st 방향 보행 초록 확인됨.
/// 실기기 사용 시 사용자 실제 위치 교차로로 교체(근본 해결은 GPS 자동선택).
const String kItstId = '1620';

/// 방위 접두사. nt/et/st/wt/ne/se/sw/nw 중 하나.
const String kDirection = 'st';

/// 건너기 시작에 필요한 최소 잔여 초. 이보다 짧으면 walk 안 함.
const double kNeedSec = 7.0;

/// 신호 확인 주기.
const Duration kLoopInterval = Duration(seconds: 1);

/// T-Data API 키. 하드코딩 금지 — --dart-define=TDATA_KEY=... 로 주입.
const String kApiKey = String.fromEnvironment('TDATA_KEY');

/// ⚠️ 임시: 카메라 검출기가 stub(항상 unknown)이라 엄격 AND면 영원히 wait이다.
/// API 단독 판단을 임시 허용한다. 카메라 검출기 완성 시 반드시 false로 복귀.
const bool kAllowSingleSource = true;
