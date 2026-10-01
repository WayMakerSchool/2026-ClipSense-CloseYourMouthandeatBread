import { describe, it, expect, vi } from 'vitest'
import { PATTERNS, vibrate } from '../../src/feedback/haptic.js'

describe('haptic', () => {
  it('판정별 패턴이 정의되어 있다 (decide hapticPattern 키와 일치)', () => {
    expect(Object.keys(PATTERNS).sort()).toEqual(['caution', 'cross', 'wait', 'warning'])
    expect(PATTERNS.cross).toEqual([800])
  })
  it('vibrate는 패턴 배열로 주입 함수를 호출', () => {
    const fn = vi.fn(() => true)
    expect(vibrate('wait', fn)).toBe(true)
    expect(fn).toHaveBeenCalledWith([400, 150, 400])
  })
  it('알 수 없는 패턴/함수 없음 → false (무해)', () => {
    expect(vibrate('nope', vi.fn())).toBe(false)
    expect(vibrate('cross', undefined)).toBe(false)
  })
})
