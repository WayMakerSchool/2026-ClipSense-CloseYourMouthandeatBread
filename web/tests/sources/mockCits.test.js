import { describe, it, expect } from 'vitest'
import { createMockCits, SCENARIOS } from '../../src/sources/mockCits.js'

describe('mockCits', () => {
  it('NORMAL_GREEN: 초록 40초에서 실시간 카운트다운', () => {
    const m = createMockCits('NORMAL_GREEN', 0)
    expect(m.fetchSignal(0)).toMatchObject({ color: 'green', remainingSec: 40, available: true, mock: true })
    expect(m.fetchSignal(5000).remainingSec).toBe(35)
    expect(m.fetchSignal(39000).remainingSec).toBe(1)
  })
  it('0 도달 시 빨강 30초로 반전, 30초 후 다시 초록', () => {
    const m = createMockCits('NORMAL_GREEN', 0)
    expect(m.fetchSignal(40000)).toMatchObject({ color: 'red', remainingSec: 30 })
    expect(m.fetchSignal(69000).color).toBe('red')
    expect(m.fetchSignal(70000).color).toBe('green')
  })
  it('MISMATCH: C-ITS는 빨강 (비전이 초록이면 판정 엔진이 불일치 차단)', () => {
    expect(createMockCits('MISMATCH', 0).fetchSignal(0).color).toBe('red')
  })
  it('SHORT_TIME: 초록인데 잔여 8초 (필요 18.67초 미달)', () => {
    expect(createMockCits('SHORT_TIME', 0).fetchSignal(0)).toMatchObject({ color: 'green', remainingSec: 8 })
  })
  it('OUTAGE: available false → Tier 2 강등 유발', () => {
    expect(createMockCits('OUTAGE', 0).fetchSignal(0).available).toBe(false)
  })
  it('알 수 없는 시나리오 → OUTAGE와 동일 (Fail-Safe)', () => {
    expect(createMockCits('nope', 0).fetchSignal(0).available).toBe(false)
  })
  it('SCENARIOS에 5개 시나리오와 label 존재', () => {
    expect(Object.keys(SCENARIOS)).toEqual(['NORMAL_GREEN', 'RED', 'MISMATCH', 'SHORT_TIME', 'OUTAGE'])
    for (const s of Object.values(SCENARIOS)) expect(typeof s.label).toBe('string')
  })
})
