/// 서울 T-Data 실시간 보행신호 API 번역기 (Python signal_api.py 이식).
///
/// 책임: (교차로 레코드, 방위) → SignalReading(source: api). 판단하지 않는다.
/// 정직성: 모르는 상태값·stale·미래시각·null·오류는 전부 unknown (green 추측 금지).

import 'signal_reading.dart';

/// API 상태 enum(SAE J2735) → 색. 화이트리스트: 여기 없는 값은 unknown.
const Map<String, SignalColor> statusMap = {
  'protected-Movement-Allowed': SignalColor.green,
  'permissive-Movement-Allowed': SignalColor.green,
  'protected-clearance': SignalColor.clearance,
  'permissive-clearance': SignalColor.clearance,
  'stop-And-Remain': SignalColor.red,
};

/// 1/10초 단위 잔여값 → 초. 파싱 불가/null이면 null.
double? _toRemainSec(dynamic rawCs) {
  if (rawCs == null || rawCs == '') return null;
  final v = double.tryParse(rawCs.toString());
  if (v == null) return null;
  return double.parse((v / 10.0).toStringAsFixed(1));
}

/// 레코드 배열 + 방위 접두사(예 'ne') → SignalReading(source: api).
///
/// itstId가 주어지면 records 중 itstId 일치 첫 레코드만 사용(다른 교차로 신호
/// 오독 방지). 일치 없으면 unknown. itstId가 null이면 records[0](하위호환).
/// 미지 상태/stale/미래시각/신호 없음/빈 배열/itstId 불일치 → 전부 unknown.
SignalReading parseReading(List records, String direction, int nowMs,
    {int staleMs = 2000, String? itstId}) {
  if (records.isEmpty) {
    return const SignalReading(SignalColor.unknown, null, SignalSource.api);
  }

  Map rec;
  if (itstId == null) {
    rec = records[0] as Map;
  } else {
    final match = records.cast<Map>().where(
        (r) => r['itstId']?.toString() == itstId.toString());
    if (match.isEmpty) {
      return const SignalReading(SignalColor.unknown, null, SignalSource.api);
    }
    rec = match.first;
  }

  final stat = rec['${direction}PdsgStatNm'];
  final rmdr = rec['${direction}PdsgRmdrCs'];
  final raw = stat?.toString();

  // 신선도 — 전송시각 없거나 파싱 불가면 신선도 불명 → unknown (raw 보존).
  final trsm = rec['trsmUtcTime'];
  if (trsm == null) {
    return SignalReading(SignalColor.unknown, null, SignalSource.api, raw: raw);
  }
  final trsmMs = double.tryParse(trsm.toString());
  if (trsmMs == null) {
    return SignalReading(SignalColor.unknown, null, SignalSource.api, raw: raw);
  }
  final freshMs = (nowMs - trsmMs).toInt();

  // 미래 시각(시계 오차) — 작은 음수는 허용, 큰 음수만 거부.
  if (freshMs < -staleMs) {
    return SignalReading(SignalColor.unknown, null, SignalSource.api, raw: raw);
  }
  // stale → unknown (원문 보존)
  if (freshMs > staleMs) {
    return SignalReading(SignalColor.unknown, null, SignalSource.api,
        freshMs: freshMs, raw: raw);
  }

  final color = statusMap[stat] ?? SignalColor.unknown;
  final remain = color != SignalColor.unknown ? _toRemainSec(rmdr) : null;
  return SignalReading(color, remain, SignalSource.api,
      freshMs: freshMs < 0 ? 0 : freshMs, raw: raw);
}
