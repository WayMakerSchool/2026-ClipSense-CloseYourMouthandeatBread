/// 이중 판단 엔진: API + 비전 → walk / wait / unknown (Python judge.py 이식).
///
/// 안전 핵심 (Fail-Safe):
/// - walk는 두 소스가 모두 green + 잔여시간 충분 + 둘 다 fresh일 때만.
/// - 하나라도 불일치/부족/stale → wait.
/// - 잔여시간 기준은 API. 카메라 숫자(7세그)는 거부권만 — API 잔여가 없으면
///   카메라 숫자가 충분해도 wait, 카메라 숫자가 더 짧으면 wait.
/// - 두 소스 모두 unknown 또는 입력 없음 → Decision.unknown.
/// - 기본(allowSingleSource=false)은 엄격: 두 소스 모두 green일 때만 walk.
///   한쪽이 unknown/stale/없음이라 단일 소스만 가용하면 무조건 wait
///   — 카메라가 조용히 실패해도 API 단독으로 walk가 나가지 않는다.
/// - 서울 밖 카메라 단독 운용은 호출자가 allowSingleSource=true로 opt-in.

library;

import 'signal_reading.dart';

enum Decision { walk, wait, unknown }

/// 화면·음성이 사용자가 왜 기다려야 하는지 설명할 수 있도록 보존하는 판정 근거.
enum DecisionReason {
  ready,
  sourcesUnavailable,

  /// API는 쓸 수 있는데 카메라 판독이 없음(미인식·stale·미주입). 사용자가
  /// 취할 행동은 "신호등을 향하기".
  cameraUnavailable,

  /// 카메라 권한이 거부돼 판독 자체가 불가능. [evaluate]는 판독값만 보므로 이
  /// 값을 절대 만들지 않는다 — GuidanceController가 VisionSource 상태
  /// (permissionDenied)를 보고 cameraUnavailable을 이 값으로 바꾼다(결정은
  /// 그대로 wait). 사용자가 취할 행동은 "설정에서 카메라 허용".
  cameraDenied,

  /// 클립 카메라(HTTP 스냅샷)에 연결되지 않아 판독이 불가능. [evaluate]는 이
  /// 값을 절대 만들지 않는다 — GuidanceController가 VisionSource 상태
  /// (unreachable)를 보고 cameraUnavailable을 이 값으로 바꾼다(결정은 그대로
  /// wait). 사용자가 취할 행동은 "클립 전원·Wi-Fi 확인".
  clipUnreachable,

  /// 클립 카메라가 기기 토큰을 거부(401/403). [evaluate]는 만들지 않는다 —
  /// GuidanceController가 VisionSource 상태 failed + 진단 token_rejected 를 보고
  /// cameraUnavailable을 이 값으로 바꾼다(결정은 wait). "신호등을 향하라"는 안내는
  /// 이 상황에서 거짓이므로 "토큰 설정을 확인하라"로 말한다.
  clipTokenRejected,

  /// 카메라 소스가 아직 초기화 중(권한 요청·플러그인 초기화·클립 첫 응답 전)이라
  /// 판독이 없음. [evaluate]는 만들지 않는다 — GuidanceController 가 VisionSource
  /// 상태 starting 을 보고 cameraUnavailable 을 이 값으로 바꾼다(결정은 wait).
  /// 첫 틱에 "신호등을 향하라"고 말하면 거짓이다 — 아직 보지도 않았다. starting 에는
  /// 정지 감시가 없어 초기화가 멈추면 "준비 중"이 계속된다(실기기 확인 항목).
  cameraStarting,

  /// 카메라가 스트리밍 상태인데 kVisionStallMs 넘게 새 프레임이 없음(폰 플러그인
  /// 스트림 정지·클립 카메라 같은 프레임 반복). [evaluate]는 만들지 않는다 —
  /// 컨트롤러가 VisionSource 상태 stalled 를 보고 바꾼다(결정은 wait; 판독은 이미
  /// kStaleMs 에서 stale). 사용자가 취할 행동은 "다시 시작"(화면 두 번 탭 = 정지 후
  /// 시작). 자동 재시작은 실기기 검증 뒤 후속 조각.
  cameraStalled,

  /// 카메라는 쓸 수 있는데 API 판독이 없음(미응답·unknown·stale). 사용자가
  /// 취할 행동은 없고 그냥 기다린다.
  apiUnavailable,
  apiKeyMissing,
  redSignal,
  clearance,
  conflict,
  remainingUnavailable,
  remainingInsufficient,
}

class DecisionResult {
  final Decision decision;
  final DecisionReason reason;

  const DecisionResult(this.decision, this.reason);
}

/// 판정 근거의 짧은 한국어 설명. 화면과 TTS가 같은 의미를 전달하게 공유한다.
String decisionReasonText(DecisionReason reason) {
  switch (reason) {
    case DecisionReason.ready:
      return 'API와 카메라가 모두 초록입니다';
    case DecisionReason.sourcesUnavailable:
      return 'API와 카메라 신호를 확인할 수 없습니다';
    // 이유 문구는 마침표 없이 둔다 — 화면('기다리세요. {이유}.')과 음성
    // ('{이유}. 기다리세요')이 조합할 때 마침표를 붙이므로, 지정 문구
    // "카메라가 신호등을 찾지 못했습니다. 신호등을 향해 주세요."가 글자 그대로
    // 들어간다(끝에 마침표를 넣으면 ".."가 된다).
    case DecisionReason.cameraUnavailable:
      return '카메라가 신호등을 찾지 못했습니다. 신호등을 향해 주세요';
    case DecisionReason.cameraDenied:
      return '카메라 권한이 없습니다. 설정에서 카메라를 허용해 주세요';
    case DecisionReason.clipUnreachable:
      return '클립 카메라에 연결할 수 없습니다. 전원과 Wi-Fi 연결을 확인해 주세요';
    case DecisionReason.clipTokenRejected:
      return '클립 카메라가 접속을 거부했습니다. 기기 토큰 설정을 확인해 주세요';
    case DecisionReason.cameraStarting:
      return '카메라를 준비하는 중입니다';
    // "두 번 눌러"는 화면 전체가 토글 버튼이라 정지(1회)+시작(1회)이다. 스크린리더
    // (TalkBack/VoiceOver)에서는 더블탭 한 번이 활성화 한 번이므로 두 번 더블탭해야
    // 한다 — 문구는 촬영 대본과 같게 두고, 실기기에서 안내가 맞는지 확인할 항목.
    case DecisionReason.cameraStalled:
      return '카메라 영상이 멈췄습니다. 화면을 두 번 눌러 다시 시작해 주세요';
    case DecisionReason.apiUnavailable:
      return '신호 정보를 아직 받지 못했습니다';
    case DecisionReason.apiKeyMissing:
      return 'T-Data API 키가 설정되지 않았습니다';
    case DecisionReason.redSignal:
      return '빨간불입니다';
    case DecisionReason.clearance:
      return '초록불이 곧 끝납니다';
    case DecisionReason.conflict:
      return 'API와 카메라 신호가 일치하지 않습니다';
    case DecisionReason.remainingUnavailable:
      return '남은 시간을 확인할 수 없습니다';
    case DecisionReason.remainingInsufficient:
      return '안전하게 건널 시간이 부족합니다';
  }
}

/// 이 판정을 판단에 쓸 수 있는가 (존재 + unknown 아님 + fresh).
bool _usable(SignalReading? r, int staleMs) =>
    r != null &&
    r.color != SignalColor.unknown &&
    r.freshMs >= 0 &&
    r.freshMs <= staleMs;

/// 가용한 잔여시간 중 가장 짧은 것이 needSec 이상인가.
/// 잔여 정보가 하나도 없으면 보수적으로 false.
DecisionReason _remainReason(List<SignalReading> readings, double needSec) {
  final remains = readings
      .map((r) => r.remainSec)
      .where((s) => s != null)
      .cast<double>()
      .toList();
  if (remains.isEmpty ||
      !needSec.isFinite ||
      needSec < 0 ||
      remains.any((value) => !value.isFinite || value < 0)) {
    return DecisionReason.remainingUnavailable;
  }
  return remains.reduce((a, b) => a < b ? a : b) >= needSec
      ? DecisionReason.ready
      : DecisionReason.remainingInsufficient;
}

/// 최종 보행 결정과 근거. 기본은 엄격 — 두 소스 모두 green일 때만 walk.
DecisionResult evaluate(
  SignalReading? api,
  SignalReading? vision, {
  double needSec = 7.0,
  int staleMs = 2000,
  bool allowSingleSource = false,
}) {
  final apiOk = _usable(api, staleMs);
  final visOk = _usable(vision, staleMs);

  // 둘 다 못 씀 → 확인 불가
  if (!apiOk && !visOk) {
    return const DecisionResult(
      Decision.unknown,
      DecisionReason.sourcesUnavailable,
    );
  }

  // 두 소스 다 가용: AND 규칙
  if (apiOk && visOk) {
    final apiColor = api!.color;
    final visionColor = vision!.color;
    if (apiColor == SignalColor.green && visionColor == SignalColor.green) {
      // 잔여시간의 기준은 API. 카메라 7세그 판독은 오독 가능성이 있어
      // 단독 근거로 쓰지 않고, API보다 짧을 때만 wait로 작용한다(거부권).
      if (api.remainSec == null) {
        return const DecisionResult(
          Decision.wait,
          DecisionReason.remainingUnavailable,
        );
      }
      final remainReason = _remainReason([api, vision], needSec);
      return DecisionResult(
        remainReason == DecisionReason.ready ? Decision.walk : Decision.wait,
        remainReason,
      );
    }
    if (apiColor != visionColor) {
      return const DecisionResult(Decision.wait, DecisionReason.conflict);
    }
    if (apiColor == SignalColor.clearance) {
      return const DecisionResult(Decision.wait, DecisionReason.clearance);
    }
    return const DecisionResult(Decision.wait, DecisionReason.redSignal);
  }

  // 단일 소스만 가용 → 엄격 모드면 wait. 어느 쪽이 빠졌는지를 이유에 남긴다
  // — 카메라 미인식이면 "신호등을 향하라", API 미응답이면 "기다리라"로
  // 사용자가 취할 행동이 다르다(결정은 둘 다 wait, 안전 정책 불변).
  if (!allowSingleSource) {
    return apiOk
        ? const DecisionResult(Decision.wait, DecisionReason.cameraUnavailable)
        : const DecisionResult(Decision.wait, DecisionReason.apiUnavailable);
  }
  final single = apiOk ? api! : vision!;
  if (single.color == SignalColor.green) {
    final remainReason = _remainReason([single], needSec);
    return DecisionResult(
      remainReason == DecisionReason.ready ? Decision.walk : Decision.wait,
      remainReason,
    );
  }
  if (single.color == SignalColor.clearance) {
    return const DecisionResult(Decision.wait, DecisionReason.clearance);
  }
  return const DecisionResult(Decision.wait, DecisionReason.redSignal);
}

/// 기존 호출자용 축약 API. 상세 근거가 필요하면 [evaluate]를 사용한다.
Decision decide(
  SignalReading? api,
  SignalReading? vision, {
  double needSec = 7.0,
  int staleMs = 2000,
  bool allowSingleSource = false,
}) {
  return evaluate(
    api,
    vision,
    needSec: needSec,
    staleMs: staleMs,
    allowSingleSource: allowSingleSource,
  ).decision;
}
