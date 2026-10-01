import { describe, it, expect } from 'vitest'
import { decide, VERDICTS } from '../../src/core/decisionEngine.js'

const user = { walkingSpeedMps: 0.6 }
const crosswalk = { lengthM: 10 } // 필요시간 = 16.67 + 2 = 18.67초
const g = (remainingSec) => ({ color: 'green', remainingSec, available: true })
const r = (remainingSec) => ({ color: 'red', remainingSec, available: true })
const vGreen = { color: 'green', confidence: 0.87 }
const vRed = { color: 'red', confidence: 0.9 }

describe('Tier 1 — 완전 검증', () => {
  it('둘 다 초록 + 잔여 충분 → CROSS', () => {
    const d = decide({ tier: 1, cits: g(25), vision: vGreen, user, crosswalk })
    expect(d.verdict).toBe(VERDICTS.CROSS)
    expect(d.message).toBe('지금 건너셔도 됩니다')
    expect(d.hapticPattern).toBe('cross')
    expect(d.reason).toBe('DUAL_GREEN_TIME_OK')
  })
  it('둘 다 초록이어도 잔여 부족 → WAIT (설명서 시나리오: 잔여 12초)', () => {
    const d = decide({ tier: 1, cits: g(12), vision: vGreen, user, crosswalk })
    expect(d.verdict).toBe(VERDICTS.WAIT)
    expect(d.message).toBe('시간이 부족합니다')
    expect(d.reason).toBe('TIME_SHORT')
  })
  it('잔여시간 경계: 18.6초 → WAIT, 18.7초 → CROSS', () => {
    expect(decide({ tier: 1, cits: g(18.6), vision: vGreen, user, crosswalk }).verdict).toBe(VERDICTS.WAIT)
    expect(decide({ tier: 1, cits: g(18.7), vision: vGreen, user, crosswalk }).verdict).toBe(VERDICTS.CROSS)
  })
  it('불일치: C-ITS 초록 × 비전 빨강 → WAIT', () => {
    const d = decide({ tier: 1, cits: g(25), vision: vRed, user, crosswalk })
    expect(d.verdict).toBe(VERDICTS.WAIT)
    expect(d.message).toBe('신호 정보가 일치하지 않습니다. 대기하세요')
    expect(d.reason).toBe('SOURCE_MISMATCH')
  })
  it('불일치: C-ITS 빨강 × 비전 초록 → WAIT (빨강 우선)', () => {
    const d = decide({ tier: 1, cits: r(25), vision: vGreen, user, crosswalk })
    expect(d.verdict).toBe(VERDICTS.WAIT)
    expect(d.reason).toBe('RED_SIGNAL')
  })
  it('둘 다 빨강 → WAIT RED_SIGNAL', () => {
    const d = decide({ tier: 1, cits: r(30), vision: vRed, user, crosswalk })
    expect(d.verdict).toBe(VERDICTS.WAIT)
    expect(d.message).toBe('빨간불입니다. 대기하세요')
  })
  it('비전 confidence 미달(0.5) → WAIT VISION_UNCERTAIN', () => {
    const d = decide({ tier: 1, cits: g(25), vision: { color: 'green', confidence: 0.5 }, user, crosswalk })
    expect(d.verdict).toBe(VERDICTS.WAIT)
    expect(d.reason).toBe('VISION_UNCERTAIN')
  })
  it('비전 unknown → WAIT', () => {
    const d = decide({ tier: 1, cits: g(25), vision: { color: 'unknown', confidence: 0 }, user, crosswalk })
    expect(d.verdict).toBe(VERDICTS.WAIT)
  })
  it('cits 결측/available false → WAIT DATA_MISSING', () => {
    expect(decide({ tier: 1, cits: null, vision: vGreen, user, crosswalk }).reason).toBe('DATA_MISSING')
    expect(decide({ tier: 1, cits: { ...g(25), available: false }, vision: vGreen, user, crosswalk }).reason).toBe('DATA_MISSING')
    expect(decide({ tier: 1, cits: g(25), vision: null, user, crosswalk }).reason).toBe('DATA_MISSING')
  })
})

describe('Tier 2 — 보수적 단독', () => {
  it('비전 초록 conf 0.8 → CAUTION (CROSS 아님)', () => {
    const d = decide({ tier: 2, cits: null, vision: { color: 'green', confidence: 0.8 }, user, crosswalk })
    expect(d.verdict).toBe(VERDICTS.CAUTION)
    expect(d.message).toBe('초록불로 보입니다. 주변 확인 후 진행하세요')
    expect(d.hapticPattern).toBe('caution')
    expect(d.reason).toBe('VISION_GREEN_ALONE')
  })
  it('conf 0.7 (<0.75 단독 임계) → WAIT', () => {
    const d = decide({ tier: 2, cits: null, vision: { color: 'green', confidence: 0.7 }, user, crosswalk })
    expect(d.verdict).toBe(VERDICTS.WAIT)
    expect(d.reason).toBe('VISION_UNCERTAIN')
  })
  it('비전 빨강 → WAIT', () => {
    const d = decide({ tier: 2, cits: null, vision: vRed, user, crosswalk })
    expect(d.verdict).toBe(VERDICTS.WAIT)
    expect(d.message).toBe('빨간불로 보입니다. 대기하세요')
  })
  it('비전 unknown → WAIT 확인불가', () => {
    const d = decide({ tier: 2, cits: null, vision: { color: 'unknown', confidence: 0 }, user, crosswalk })
    expect(d.message).toBe('신호를 확인할 수 없습니다. 대기하세요')
  })
})

describe('Tier 3 — 무신호', () => {
  it('무신호 모드 → WARNING 경보', () => {
    const d = decide({ tier: 3, cits: null, vision: { color: 'unknown', confidence: 0 }, user, crosswalk })
    expect(d.verdict).toBe(VERDICTS.WARNING)
    expect(d.message).toBe('신호 없는 횡단보도입니다. 차량에 주의하세요')
    expect(d.hapticPattern).toBe('warning')
    expect(d.reason).toBe('NO_SIGNAL_ZONE')
  })
})

describe('Fail-Safe 기본값 — 어떤 이상 입력도 WAIT', () => {
  it.each([
    ['인자 없음', undefined],
    ['null', null],
    ['빈 객체', {}],
    ['tier만', { tier: 1 }],
    ['알 수 없는 tier', { tier: 99, cits: g(25), vision: vGreen, user, crosswalk }],
    ['문자열 tier', { tier: 'x', cits: g(25), vision: vGreen, user, crosswalk }],
  ])('%s → WAIT', (_label, input) => {
    const d = decide(input)
    expect(d.verdict).toBe(VERDICTS.WAIT)
    expect(d.hapticPattern).toBe('wait')
  })
  it('user/crosswalk 결측 → 필요시간 Infinity → WAIT TIME_SHORT (초록 일치여도)', () => {
    const d = decide({ tier: 1, cits: g(9999), vision: vGreen, user: null, crosswalk: null })
    expect(d.verdict).toBe(VERDICTS.WAIT)
  })
})
