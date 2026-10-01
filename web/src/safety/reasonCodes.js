/**
 * SafeGraph-RTA reason code enum, 우선순위, 시스템 출력 문구 (원본설계서 §9.4, §10).
 */

// 원본 §10 — 필수 reason code 17개. 값은 동명 문자열.
export const REASONS = Object.freeze({
  INVALID_INPUT: 'INVALID_INPUT',
  TARGET_UNBOUND: 'TARGET_UNBOUND',
  TARGET_MISMATCH: 'TARGET_MISMATCH',
  CITS_MISSING: 'CITS_MISSING',
  CITS_STALE: 'CITS_STALE',
  VISION_STALE: 'VISION_STALE',
  REPLAY_OR_REORDER: 'REPLAY_OR_REORDER',
  VIDEO_FROZEN: 'VIDEO_FROZEN',
  RED_SIGNAL: 'RED_SIGNAL',
  VISION_UNCERTAIN: 'VISION_UNCERTAIN',
  SOURCE_MISMATCH: 'SOURCE_MISMATCH',
  TIME_SHORT: 'TIME_SHORT',
  CONFIRMING: 'CONFIRMING',
  SAFEGRAPH_CONFIRMED: 'SAFEGRAPH_CONFIRMED',
  VISION_ONLY_INFORMATION: 'VISION_ONLY_INFORMATION',
  NO_SIGNAL_INFORMATION: 'NO_SIGNAL_INFORMATION',
  INTERNAL_ERROR: 'INTERNAL_ERROR',
})

// 스펙 §2.2 순서 그대로 (fail-safe 대표 코드 선택용).
export const REASON_PRIORITY = Object.freeze([
  'INVALID_INPUT',
  'TARGET_UNBOUND',
  'TARGET_MISMATCH',
  'RED_SIGNAL',
  'CITS_MISSING',
  'CITS_STALE',
  'VISION_STALE',
  'REPLAY_OR_REORDER',
  'VIDEO_FROZEN',
  'VISION_UNCERTAIN',
  'SOURCE_MISMATCH',
  'TIME_SHORT',
  'CONFIRMING',
])

/**
 * failedChecks 목록에서 REASON_PRIORITY 순서를 따라 대표 reason을 고른다.
 * 목록에 없는 코드만 있거나 입력이 비어 있으면 fail-safe로 INVALID_INPUT을 반환한다.
 * @param {string[]} failedChecks
 * @returns {string}
 */
export function pickPrimaryReason(failedChecks) {
  if (!Array.isArray(failedChecks) || failedChecks.length === 0) {
    return REASONS.INVALID_INPUT
  }
  const present = new Set(failedChecks)
  for (const code of REASON_PRIORITY) {
    if (present.has(code)) return code
  }
  return REASONS.INVALID_INPUT
}

// 원본 §9.4 — 문구는 byte-exact.
export const MESSAGES = Object.freeze({
  WAIT: '현재 횡단 안내를 제공할 수 없습니다. 대기하세요.',
  VERIFYING: '보행신호를 확인하고 있습니다. 대기하세요.',
  INFORMATION_ONLY: '신호 정보가 일부만 확인되었습니다. 횡단 판단을 제공하지 않습니다.',
})

/**
 * SIGNAL_CONFIRMED 문구 — 잔여시간을 정수 초로 삽입한다.
 * @param {number} remainingSec
 * @returns {string}
 */
export function confirmedMessage(remainingSec) {
  const sec = Math.trunc(remainingSec)
  return `보행신호가 확인되었습니다. 잔여시간은 ${sec}초입니다. 주변 차량에 주의하세요.`
}
