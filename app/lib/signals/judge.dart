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
