/** 판정별 진동 패턴 (ms). decide()의 hapticPattern 키와 1:1. */
export const PATTERNS = {
  cross: [800],                       // 길고 부드럽게 — 안전 확인
  caution: [200, 120, 200],           // 짧게 두 번 — 경계
  warning: [120, 80, 120, 80, 120],   // 빠르게 세 번 — 경보
  wait: [400, 150, 400],              // 강하게 두 번 — 대기
}

export function vibrate(patternName, vibrateFn = globalThis.navigator?.vibrate?.bind(globalThis.navigator)) {
  const pattern = PATTERNS[patternName]
  if (!pattern || typeof vibrateFn !== 'function') return false
  vibrateFn(pattern)
  return true
}
