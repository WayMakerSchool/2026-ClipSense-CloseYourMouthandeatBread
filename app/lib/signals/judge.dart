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

/// 이 판정을 판단에 쓸 수 있는가 (존재 + unknown 아님 + fresh).
bool _usable(SignalReading? r, int staleMs) =>
    r != null && r.color != SignalColor.unknown && r.freshMs <= staleMs;

/// 가용한 잔여시간 중 가장 짧은 것이 needSec 이상인가.
/// 잔여 정보가 하나도 없으면 보수적으로 false.
bool _remainOk(List<SignalReading> readings, double needSec) {
  final remains = readings
      .map((r) => r.remainSec)
      .where((s) => s != null)
      .cast<double>()
      .toList();
  if (remains.isEmpty) return false;
  return remains.reduce((a, b) => a < b ? a : b) >= needSec;
}

/// 최종 보행 결정. 기본은 엄격 — 두 소스 모두 green일 때만 walk.
Decision decide(SignalReading? api, SignalReading? vision,
    {double needSec = 7.0,
    int staleMs = 2000,
    bool allowSingleSource = false}) {
  final apiOk = _usable(api, staleMs);
  final visOk = _usable(vision, staleMs);

  // 둘 다 못 씀 → 확인 불가
  if (!apiOk && !visOk) return Decision.unknown;

  // 두 소스 다 가용: AND 규칙
  if (apiOk && visOk) {
    final bothGreen =
        api!.color == SignalColor.green && vision!.color == SignalColor.green;
    if (bothGreen && _remainOk([api, vision], needSec)) return Decision.walk;
    return Decision.wait;
  }

  // 단일 소스만 가용
  if (!allowSingleSource) return Decision.wait;
  final single = apiOk ? api! : vision!;
  if (single.color == SignalColor.green && _remainOk([single], needSec)) {
    return Decision.walk;
  }
  return Decision.wait;
}
