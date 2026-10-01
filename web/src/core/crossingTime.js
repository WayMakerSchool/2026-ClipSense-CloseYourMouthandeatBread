/**
 * 필요 횡단시간(초) = 거리/보행속도 + 여유 마진.
 * 유효하지 않은 입력은 Infinity를 반환한다 — Infinity는 어떤 잔여시간과
 * 비교해도 "부족"이므로 판정 엔진이 자연히 WAIT로 수렴한다 (Fail-Safe).
 */
export function requiredCrossingSec(input) {
  if (!input || typeof input !== 'object') return Infinity
  const { lengthM, walkingSpeedMps, marginSec = 2 } = input
  if (!Number.isFinite(lengthM) || lengthM <= 0) return Infinity
  if (!Number.isFinite(walkingSpeedMps) || walkingSpeedMps <= 0) return Infinity
  if (!Number.isFinite(marginSec) || marginSec < 0) return Infinity
  return lengthM / walkingSpeedMps + marginSec
}
