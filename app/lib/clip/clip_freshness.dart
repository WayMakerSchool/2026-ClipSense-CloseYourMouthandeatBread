/// 클립 프레임의 신선도·진행(정지/역전/재부팅) 추적기(순수 로직).
///
/// 기기 uptime 과 폰의 단조 시계는 다른 clock domain 이라 직접 뺄 수 없다.
/// 그래서 "요청 기반 보수적 추정"만 한다(하드웨어 보고서 §10.4):
///
///     conservativeAgeMs = rttMs + serverFrameAgeMs
///     capturedAtMonoMs  = receivedMonoMs - conservativeAgeMs
///
/// 진행 규칙(§11.3): 새 frameSeq 일 때만 관측을 갱신하고, 같은 프레임은 신선도를
/// 갱신하지 않는다(정지된 카메라가 계속 "새 것"으로 보이지 않게). sequence 역전은
/// replayOrReorder 로 거부하되 고수위는 유지한다. bootId 가 바뀌면 이력을 즉시
/// 폐기한다 — uptime 이 0 으로 돌아오는 것은 역전이 아니라 새 이력이다.
/// uptime 역행만으로는 절대 리셋하지 않는다(재부팅을 숨기는 재생 공격·버그와
/// 구분할 수 없으므로 거부가 안전하다).
library;

import 'package:flutter/foundation.dart';

import 'clip_snapshot.dart';

enum ClipFrameVerdict {
  /// 새 프레임. [ClipFrameObservation.capturedAtMonoMs] 가 유효하다.
  accepted,

  /// 직전에 받아들인 것과 같은 프레임(frameSeq·촬영시각 동일). 신선도를
  /// 갱신하지 않는다 — 카메라가 멈추면 이 판정만 반복되고 판독은 늙어 간다.
  sameFrame,

  /// 같은 boot 안에서 frameSeq 나 촬영시각이 뒤로 갔다(재전송·순서 뒤바뀜·
  /// 원자성 위반). 거부하고 고수위를 유지한다.
  replayOrReorder,
}

/// [ClipFreshnessTracker.observe] 의 결과. 불변.
@immutable
class ClipFrameObservation {
  final ClipFrameVerdict verdict;

  /// 이 관측에서 bootId 가 바뀌어 이력을 폐기했는가(판정 파이프라인도 함께
  /// 리셋해야 한다 — 재부팅 전 프레임으로 쌓은 debounce 이력은 무효).
  final bool bootChanged;

  /// 보수적 나이(ms) = rtt + 서버 프레임 나이. 거부된 프레임도 값은 계산한다
  /// (진단용).
  final int conservativeAgeMs;

  /// 폰 단조 시계 기준 촬영 시각(ms). accepted 일 때만 non-null.
  final int? capturedAtMonoMs;

  const ClipFrameObservation({
    required this.verdict,
    required this.bootChanged,
    required this.conservativeAgeMs,
    this.capturedAtMonoMs,
  });

  @override
  String toString() =>
      'ClipFrameObservation(${verdict.name}, bootChanged: $bootChanged, '
      'age: ${conservativeAgeMs}ms, capturedAt: $capturedAtMonoMs)';
}

class ClipFreshnessTracker {
  String? _bootId;
  ClipCaptureMeta? _lastAccepted;

  /// 마지막으로 받아들인 프레임의 메타데이터(고수위). 없으면 null.
  ClipCaptureMeta? get lastAccepted => _lastAccepted;

  /// 이력 폐기. 소스 정지·재시작 시 호출한다.
  void reset() {
    _bootId = null;
    _lastAccepted = null;
  }

  /// 응답 하나를 관측한다. [rttMs] 는 요청 전송→응답 수신의 폰 단조 시계 경과,
  /// [receivedMonoMs] 는 응답을 다 받은 폰 단조 시각.
  ClipFrameObservation observe(
    ClipCaptureMeta meta, {
    required int rttMs,
    required int receivedMonoMs,
  }) {
    // 음수 rtt 는 시계 오류다. 0 으로 보되 나이를 줄이지는 않는다.
    final rtt = rttMs < 0 ? 0 : rttMs;
    final age = rtt + meta.serverFrameAgeMs;

    var bootChanged = false;
    if (_bootId != null && _bootId != meta.bootId) {
      bootChanged = true;
      _lastAccepted = null;
    }
    _bootId = meta.bootId;

    final last = _lastAccepted;
    if (last != null) {
      final sameSeq = meta.frameSeq == last.frameSeq;
      final sameCapture = meta.captureUptimeUs == last.captureUptimeUs;
      if (sameSeq && sameCapture) {
        return ClipFrameObservation(
          verdict: ClipFrameVerdict.sameFrame,
          bootChanged: bootChanged,
          conservativeAgeMs: age,
        );
      }
      final advanced =
          meta.frameSeq > last.frameSeq &&
          meta.captureUptimeUs > last.captureUptimeUs;
      if (!advanced) {
        return ClipFrameObservation(
          verdict: ClipFrameVerdict.replayOrReorder,
          bootChanged: bootChanged,
          conservativeAgeMs: age,
        );
      }
    }

    _lastAccepted = meta;
    return ClipFrameObservation(
      verdict: ClipFrameVerdict.accepted,
      bootChanged: bootChanged,
      conservativeAgeMs: age,
      capturedAtMonoMs: receivedMonoMs - age,
    );
  }
}
