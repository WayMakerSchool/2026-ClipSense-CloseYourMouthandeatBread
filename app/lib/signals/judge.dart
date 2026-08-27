/// 이중 판단 엔진: API + 비전 → walk / wait / unknown (Python judge.py 이식).
///
/// 안전 핵심 (Fail-Safe):
/// - walk는 두 소스가 모두 green + 잔여시간 충분 + 둘 다 fresh일 때만.
/// - 하나라도 불일치/부족/stale → wait.
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
  sourceUnavailable,
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
    case DecisionReason.sourceUnavailable:
      return 'API 또는 카메라 신호를 확인하는 중입니다';
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

  // 단일 소스만 가용
  if (!allowSingleSource) {
    return const DecisionResult(
      Decision.wait,
      DecisionReason.sourceUnavailable,
    );
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
