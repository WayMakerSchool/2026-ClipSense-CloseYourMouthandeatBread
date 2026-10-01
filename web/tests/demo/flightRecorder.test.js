import { describe, it, expect } from 'vitest'
import { createFlightRecorder } from '../../src/demo/flightRecorder.js'

describe('createFlightRecorder — factory shape', () => {
  it('returns record/toJsonl/count/latencyStats functions', () => {
    const rec = createFlightRecorder()
    expect(typeof rec.record).toBe('function')
    expect(typeof rec.toJsonl).toBe('function')
    expect(typeof rec.count).toBe('function')
    expect(typeof rec.latencyStats).toBe('function')
  })

  it('starts empty', () => {
    const rec = createFlightRecorder()
    expect(rec.count()).toBe(0)
    expect(rec.toJsonl()).toBe('')
    expect(rec.latencyStats()).toEqual({ n: 0, medianMs: null, p95Ms: null })
  })
})

describe('createFlightRecorder — record/count', () => {
  it('count() increments per record()', () => {
    const rec = createFlightRecorder()
    rec.record({ t: 1 })
    rec.record({ t: 2 })
    rec.record({ t: 3 })
    expect(rec.count()).toBe(3)
  })

  it('ignores null/undefined/non-object entries without throwing', () => {
    const rec = createFlightRecorder()
    rec.record(null)
    rec.record(undefined)
    rec.record('not an object')
    rec.record(42)
    rec.record({ t: 1 })
    expect(rec.count()).toBe(1)
  })
})

describe('createFlightRecorder — rollover at maxEntries', () => {
  it('drops oldest entries once maxEntries is exceeded, keeping the newest', () => {
    const rec = createFlightRecorder({ maxEntries: 3 })
    rec.record({ id: 1 })
    rec.record({ id: 2 })
    rec.record({ id: 3 })
    rec.record({ id: 4 })
    rec.record({ id: 5 })

    expect(rec.count()).toBe(3)
    const lines = rec.toJsonl().split('\n').map((l) => JSON.parse(l))
    expect(lines.map((l) => l.id)).toEqual([3, 4, 5])
  })

  it('never exceeds maxEntries across many records', () => {
    const rec = createFlightRecorder({ maxEntries: 5 })
    for (let i = 0; i < 100; i++) rec.record({ id: i })
    expect(rec.count()).toBe(5)
    const lines = rec.toJsonl().split('\n').map((l) => JSON.parse(l))
    expect(lines.map((l) => l.id)).toEqual([95, 96, 97, 98, 99])
  })

  it('defaults maxEntries to 30000 when omitted', () => {
    const rec = createFlightRecorder()
    for (let i = 0; i < 30001; i++) rec.record({ id: i })
    expect(rec.count()).toBe(30000)
  })
})

describe('createFlightRecorder — toJsonl', () => {
  it('produces one JSON object per line, in insertion order', () => {
    const rec = createFlightRecorder()
    rec.record({ a: 1, b: 'x' })
    rec.record({ a: 2, b: 'y' })
    const jsonl = rec.toJsonl()
    const lines = jsonl.split('\n')
    expect(lines).toHaveLength(2)
    expect(JSON.parse(lines[0])).toEqual({ a: 1, b: 'x' })
    expect(JSON.parse(lines[1])).toEqual({ a: 2, b: 'y' })
  })

  it('line count matches count() for larger batches', () => {
    const rec = createFlightRecorder()
    for (let i = 0; i < 250; i++) rec.record({ i })
    expect(rec.toJsonl().split('\n')).toHaveLength(rec.count())
    expect(rec.count()).toBe(250)
  })
})

describe('createFlightRecorder — latencyStats arithmetic', () => {
  it('computes n/medianMs/p95Ms on a hand-built odd-length e2eMs set', () => {
    const rec = createFlightRecorder()
    // sorted: 10, 20, 30, 40, 50 — median = 30 (middle), p95 idx = ceil(0.95*5)-1 = 4 → 50
    for (const e2eMs of [50, 10, 40, 20, 30]) rec.record({ e2eMs })
    const stats = rec.latencyStats()
    expect(stats.n).toBe(5)
    expect(stats.medianMs).toBe(30)
    expect(stats.p95Ms).toBe(50)
  })

  it('computes even-length median as the average of the two middle values', () => {
    const rec = createFlightRecorder()
    for (const e2eMs of [10, 20, 30, 40]) rec.record({ e2eMs })
    const stats = rec.latencyStats()
    expect(stats.n).toBe(4)
    expect(stats.medianMs).toBe(25) // (20+30)/2
  })

  it('ignores null e2eMs entries entirely (not counted in n)', () => {
    const rec = createFlightRecorder()
    rec.record({ e2eMs: 10 })
    rec.record({ e2eMs: null })
    rec.record({ e2eMs: 20 })
    rec.record({ e2eMs: null })
    rec.record({ e2eMs: 30 })
    const stats = rec.latencyStats()
    expect(stats.n).toBe(3)
    expect(stats.medianMs).toBe(20)
  })

  it('ignores undefined and non-finite e2eMs values', () => {
    const rec = createFlightRecorder()
    rec.record({ e2eMs: 10 })
    rec.record({}) // e2eMs undefined
    rec.record({ e2eMs: NaN })
    rec.record({ e2eMs: Infinity })
    rec.record({ e2eMs: 20 })
    const stats = rec.latencyStats()
    expect(stats.n).toBe(2)
    expect(stats.medianMs).toBe(15)
  })

  it('returns all-null stats when every entry has null e2eMs', () => {
    const rec = createFlightRecorder()
    rec.record({ e2eMs: null })
    rec.record({ e2eMs: null })
    const stats = rec.latencyStats()
    expect(stats).toEqual({ n: 0, medianMs: null, p95Ms: null })
  })

  it('a single-value set: median and p95 both equal that value', () => {
    const rec = createFlightRecorder()
    rec.record({ e2eMs: 77 })
    const stats = rec.latencyStats()
    expect(stats.n).toBe(1)
    expect(stats.medianMs).toBe(77)
    expect(stats.p95Ms).toBe(77)
  })

  it('reflects rollover — stats only cover entries currently retained', () => {
    const rec = createFlightRecorder({ maxEntries: 2 })
    rec.record({ e2eMs: 1000 }) // will be dropped
    rec.record({ e2eMs: 10 })
    rec.record({ e2eMs: 20 })
    const stats = rec.latencyStats()
    expect(stats.n).toBe(2)
    expect(stats.medianMs).toBe(15)
  })
})
