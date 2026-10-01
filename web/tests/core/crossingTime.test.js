import { describe, it, expect } from 'vitest'
import { requiredCrossingSec } from '../../src/core/crossingTime.js'

describe('requiredCrossingSec', () => {
  it('10m, 0.6m/s, 마진 2초 → 18.67초', () => {
    expect(requiredCrossingSec({ lengthM: 10, walkingSpeedMps: 0.6 })).toBeCloseTo(18.67, 2)
  })
  it('마진 0 지정 시 16.67초', () => {
    expect(requiredCrossingSec({ lengthM: 10, walkingSpeedMps: 0.6, marginSec: 0 })).toBeCloseTo(16.67, 2)
  })
  it('속도 0 → Infinity (Fail-Safe)', () => {
    expect(requiredCrossingSec({ lengthM: 10, walkingSpeedMps: 0 })).toBe(Infinity)
  })
  it('음수 거리 → Infinity', () => {
    expect(requiredCrossingSec({ lengthM: -5, walkingSpeedMps: 0.6 })).toBe(Infinity)
  })
  it('인자 없음/null → Infinity', () => {
    expect(requiredCrossingSec()).toBe(Infinity)
    expect(requiredCrossingSec(null)).toBe(Infinity)
    expect(requiredCrossingSec({})).toBe(Infinity)
  })
})
