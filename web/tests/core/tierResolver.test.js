import { describe, it, expect } from 'vitest'
import { resolveTier } from '../../src/core/tierResolver.js'

describe('resolveTier', () => {
  it('무신호 모드는 C-ITS 가용 여부와 무관하게 Tier 3', () => {
    expect(resolveTier({ citsAvailable: true, noSignalMode: true })).toBe(3)
    expect(resolveTier({ citsAvailable: false, noSignalMode: true })).toBe(3)
  })
  it('C-ITS 정상 → Tier 1', () => {
    expect(resolveTier({ citsAvailable: true, noSignalMode: false })).toBe(1)
  })
  it('C-ITS 불가 → Tier 2 (자동 강등)', () => {
    expect(resolveTier({ citsAvailable: false, noSignalMode: false })).toBe(2)
  })
  it('입력 결측 → Tier 2 (보수적)', () => {
    expect(resolveTier()).toBe(2)
    expect(resolveTier(null)).toBe(2)
    expect(resolveTier({})).toBe(2)
  })
})
