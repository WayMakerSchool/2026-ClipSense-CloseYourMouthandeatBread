import { describe, it, expect } from 'vitest'
import { createStabilizer } from '../../src/core/stabilizer.js'

const WAIT = { verdict: 'WAIT', message: '빨간불입니다. 대기하세요' }
const WAIT2 = { verdict: 'WAIT', message: '시간이 부족합니다' }
const CROSS = { verdict: 'CROSS', message: '지금 건너셔도 됩니다' }
const WARNING = { verdict: 'WARNING', message: '신호 없는 횡단보도입니다. 차량에 주의하세요' }

describe('stabilizer', () => {
  it('첫 WAIT은 즉시 확정 + changed', () => {
    const s = createStabilizer()
    const { result, changed } = s.update(WAIT, 0)
    expect(result.verdict).toBe('WAIT')
    expect(changed).toBe(true)
  })
  it('CROSS는 1.5초 유지 전까지 확정되지 않는다', () => {
    const s = createStabilizer()
    s.update(WAIT, 0)
    expect(s.update(CROSS, 100).result.verdict).toBe('WAIT')
    expect(s.update(CROSS, 1000).result.verdict).toBe('WAIT')
    const { result, changed } = s.update(CROSS, 1700)
    expect(result.verdict).toBe('CROSS')
    expect(changed).toBe(true)
  })
  it('CROSS 대기 중 1프레임 튐(WAIT) → 즉시 WAIT, hold 재시작', () => {
    const s = createStabilizer()
    s.update(WAIT, 0)
    s.update(CROSS, 100)
    const mid = s.update(WAIT, 800) // 안전 방향은 즉시
    expect(mid.result.verdict).toBe('WAIT')
    s.update(CROSS, 900)
    expect(s.update(CROSS, 2300).result.verdict).toBe('WAIT') // 900+1500=2400 미달
    expect(s.update(CROSS, 2500).result.verdict).toBe('CROSS')
  })
  it('WARNING은 즉시 반영', () => {
    const s = createStabilizer()
    s.update(WAIT, 0)
    const { result, changed } = s.update(WARNING, 100)
    expect(result.verdict).toBe('WARNING')
    expect(changed).toBe(true)
  })
  it('같은 WAIT 반복 → changed false, 메시지 다른 WAIT → changed true', () => {
    const s = createStabilizer()
    s.update(WAIT, 0)
    expect(s.update(WAIT, 500).changed).toBe(false)
    expect(s.update(WAIT2, 1000).changed).toBe(true)
  })
  it('null result → 현재 상태 유지, changed false', () => {
    const s = createStabilizer()
    s.update(WAIT, 0)
    const { result, changed } = s.update(null, 500)
    expect(result.verdict).toBe('WAIT')
    expect(changed).toBe(false)
  })
})
