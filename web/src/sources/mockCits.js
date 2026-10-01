/** 시연 시나리오용 모의 C-ITS. UI는 mock:true일 때 "모의 신호 주입 중" 배지를 띄운다. */
export const SCENARIOS = {
  NORMAL_GREEN: { label: '정상(초록 40초)', color: 'green', startSec: 40, available: true },
  RED: { label: '빨간불', color: 'red', startSec: 30, available: true },
  MISMATCH: { label: '불일치(C-ITS 빨강)', color: 'red', startSec: 25, available: true },
  SHORT_TIME: { label: '시간부족(잔여 8초)', color: 'green', startSec: 8, available: true },
  OUTAGE: { label: 'API 장애→Tier2', available: false },
}

const FLIP_SEC = 30
const flip = (c) => (c === 'green' ? 'red' : 'green')

export function createMockCits(scenarioKey, createdMs) {
  const sc = SCENARIOS[scenarioKey] ?? SCENARIOS.OUTAGE
  return {
    fetchSignal(nowMs) {
      if (sc.available !== true) return { color: 'unknown', remainingSec: 0, available: false, mock: true }
      const elapsed = Math.max(0, (nowMs - createdMs) / 1000)
      if (elapsed < sc.startSec) {
        return { color: sc.color, remainingSec: Math.ceil(sc.startSec - elapsed), available: true, mock: true }
      }
      const after = elapsed - sc.startSec
      const phases = Math.floor(after / FLIP_SEC)
      const color = phases % 2 === 0 ? flip(sc.color) : sc.color
      return { color, remainingSec: Math.ceil(FLIP_SEC - (after % FLIP_SEC)), available: true, mock: true }
    },
  }
}
