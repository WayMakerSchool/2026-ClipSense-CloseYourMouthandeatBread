import { describe, it, expect } from 'vitest'
import { fetchSignal, parsePedSignal } from '../../src/sources/citsClient.js'

// 경찰청 실시간 신호 API 응답 item 예시 (실제 샘플 확보 시 필드명 대조할 것)
const item = { itstId: '1234', ntPdsgStatNm: 'protected-Movement-Allowed', ntPdsgRmdrCs: 154 }

describe('parsePedSignal', () => {
  it('protected-Movement-Allowed + 154(1/10초) → green 15.4초', () => {
    expect(parsePedSignal(item, 'nt')).toEqual({ color: 'green', remainingSec: 15.4, available: true })
  })
  it('stop-And-Remain → red', () => {
    const r = parsePedSignal({ ntPdsgStatNm: 'stop-And-Remain', ntPdsgRmdrCs: 300 }, 'nt')
    expect(r.color).toBe('red')
  })
  it('방위 키 지정 (wt)', () => {
    const r = parsePedSignal({ wtPdsgStatNm: 'protected-Movement-Allowed', wtPdsgRmdrCs: 90 }, 'wt')
    expect(r).toEqual({ color: 'green', remainingSec: 9, available: true })
  })
  it('필드 결측/모르는 상태명 → available false (Fail-Safe)', () => {
    expect(parsePedSignal({}, 'nt').available).toBe(false)
    expect(parsePedSignal({ ntPdsgStatNm: '???', ntPdsgRmdrCs: 10 }, 'nt').available).toBe(false)
    expect(parsePedSignal(null, 'nt').available).toBe(false)
  })
})

describe('fetchSignal', () => {
  it('정상 응답 → 파싱 결과', async () => {
    const fetchFn = async () => ({ ok: true, json: async () => ({ response: { body: { items: { item: [item] } } } }) })
    const r = await fetchSignal({ itstId: '1234', fetchFn })
    expect(r).toEqual({ color: 'green', remainingSec: 15.4, available: true })
  })
  it('배열 대신 단일 item 객체 응답도 처리', async () => {
    const fetchFn = async () => ({ ok: true, json: async () => ({ response: { body: { items: { item } } } }) })
    expect((await fetchSignal({ itstId: '1234', fetchFn })).color).toBe('green')
  })
  it('네트워크 오류 → available false (throw 금지)', async () => {
    const fetchFn = async () => { throw new Error('network down') }
    expect((await fetchSignal({ itstId: '1234', fetchFn })).available).toBe(false)
  })
  it('HTTP 500 → available false', async () => {
    const fetchFn = async () => ({ ok: false, status: 500 })
    expect((await fetchSignal({ itstId: '1234', fetchFn })).available).toBe(false)
  })
  it('타임아웃 → available false', async () => {
    const fetchFn = (_url, { signal }) =>
      new Promise((_res, rej) => signal.addEventListener('abort', () => rej(new Error('aborted'))))
    const r = await fetchSignal({ itstId: '1234', timeoutMs: 30, fetchFn })
    expect(r.available).toBe(false)
  })
})
