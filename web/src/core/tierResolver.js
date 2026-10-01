/** 신호 환경 3단계 자동 결정. 정보가 없으면 Tier 2(보수적 단독 운용). */
export function resolveTier(input) {
  const { citsAvailable, noSignalMode } = input ?? {}
  if (noSignalMode === true) return 3
  if (citsAvailable === true) return 1
  return 2
}
