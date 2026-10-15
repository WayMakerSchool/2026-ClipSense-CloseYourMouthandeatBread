import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  captureErrorMessage, fetchBoardCapture, frameSourceLabel,
  normalizeBoardAddress, startBoardPolling,
} from '../../src/sources/boardCapture.js'

afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals() })

describe('보드 사진 계약', () => {
  it('주소 입력을 정규화하고 URL 안의 비밀·경로·다른 스킴을 거절한다', () => {
    expect(normalizeBoardAddress(' localhost:8080 ')).toBe('http://localhost:8080')
    expect(normalizeBoardAddress('http://192.168.0.50/')).toBe('http://192.168.0.50')
    for (const address of ['', 'https://board', 'file:///capture', 'http://user:secret@board', 'board/capture', 'board/?token=secret']) {
      expect(() => normalizeBoardAddress(address)).toThrow()
    }
  })

  it('노트북 표시가 센서명보다 우선하고 시뮬레이터·미확인 출처를 구분한다', () => {
    expect(frameSourceLabel('laptop-upload', 'OV2640')).toBe('노트북 촬영')
    expect(frameSourceLabel(null, 'LAPTOP')).toBe('노트북 촬영')
    expect(frameSourceLabel(null, 'SIM')).toContain('시뮬레이터')
    expect(frameSourceLabel(null, 'OV3660')).toBe('클립 카메라')
    expect(frameSourceLabel(null, null)).toBe('출처 확인 불가')
    expect(frameSourceLabel('unknown-relay', 'OV3660')).toBe('출처 확인 불가')
  })

  it('동일 출처 프록시를 사용하고 토큰을 헤더로만 전송하며 응답 메타데이터를 읽는다', async () => {
    const runtimeToken = crypto.randomUUID()
    const request = vi.fn().mockResolvedValue(new Response('jpeg', { headers: {
      'Content-Type': 'image/jpeg', 'X-Frame-Seq': '42', 'X-Frame-Source': 'laptop-upload', 'X-Camera-Sensor': 'LAPTOP',
    } }))
    vi.stubGlobal('fetch', request)
    const photo = await fetchBoardCapture({ address: 'localhost:8080', token: runtimeToken })
    expect(request.mock.calls[0][0]).toBe('/board/capture?address=http%3A%2F%2Flocalhost%3A8080')
    expect(request.mock.calls[0][0]).not.toContain(runtimeToken)
    expect(request.mock.calls[0][1]).toMatchObject({ headers: { 'X-Clip-Device-Token': runtimeToken }, cache: 'no-store', credentials: 'omit' })
    expect(photo).toMatchObject({ seq: '42', sensor: 'LAPTOP', sourceLabel: '노트북 촬영' })
    expect(photo.blob.size).toBe(4)
  })

  it.each([401, 403, 503, 502, 504])('HTTP %s의 이유를 표시한다', async (status) => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('', { status })))
    await expect(fetchBoardCapture({ address: 'localhost:8080', token: '' })).rejects.toThrow(captureErrorMessage(status))
    expect(fetch).toHaveBeenCalledWith(expect.any(String), expect.objectContaining({ headers: {} }))
  })

  it.each([
    { 'Content-Type': 'text/html', 'X-Frame-Seq': '1' },
    { 'Content-Type': 'image/jpeg' },
    { 'Content-Type': 'image/jpeg', 'X-Frame-Seq': 'invalid' },
  ])('잘못된 응답을 사진으로 표시하지 않는다: %j', async (headers) => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('body', { headers })))
    await expect(fetchBoardCapture({ address: 'localhost:8080' })).rejects.toThrow()
  })
})

describe('1초 폴링과 중지', () => {
  it('즉시·1초 간격으로 받고 실패 후에도 복구한다', async () => {
    vi.useFakeTimers()
    const photo = { seq: '2' }
    const capture = vi.fn().mockRejectedValueOnce(new Error(captureErrorMessage(503))).mockResolvedValue(photo)
    const onFrame = vi.fn(), onError = vi.fn()
    const stop = startBoardPolling({ address: 'localhost:8080', capture, onFrame, onError })
    await vi.advanceTimersByTimeAsync(0)
    expect(onError).toHaveBeenCalledWith(captureErrorMessage(503))
    await vi.advanceTimersByTimeAsync(999)
    expect(capture).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(onFrame).toHaveBeenCalledWith(photo)
    await vi.advanceTimersByTimeAsync(1000)
    expect(capture).toHaveBeenCalledTimes(3)
    stop()
    await vi.advanceTimersByTimeAsync(5000)
    expect(capture).toHaveBeenCalledTimes(3)
  })

  it('요청을 겹치지 않고 중지 시 취소하며 늦은 응답을 버린다', async () => {
    vi.useFakeTimers()
    let resolve
    const capture = vi.fn(() => new Promise((done) => { resolve = done }))
    const onFrame = vi.fn(), onError = vi.fn()
    const stop = startBoardPolling({ capture, onFrame, onError })
    await vi.advanceTimersByTimeAsync(2000)
    expect(capture).toHaveBeenCalledTimes(1)
    stop()
    expect(capture.mock.calls[0][0].signal.aborted).toBe(true)
    resolve({ seq: 'old' })
    await vi.advanceTimersByTimeAsync(0)
    expect(onFrame).not.toHaveBeenCalled()
    expect(onError).not.toHaveBeenCalled()
  })

  it('응답이 멈추면 시간 초과를 표시한다', async () => {
    vi.useFakeTimers()
    const capture = vi.fn(({ signal }) => new Promise((resolve, reject) => {
      signal.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')))
    }))
    const onError = vi.fn()
    const stop = startBoardPolling({ capture, onFrame: vi.fn(), onError })
    await vi.advanceTimersByTimeAsync(3000)
    expect(onError).toHaveBeenCalledWith(expect.stringContaining('시간이 초과'))
    stop()
  })

  it('네트워크 오류는 주소와 연결을 확인하도록 표시한다', async () => {
    vi.useFakeTimers()
    const onError = vi.fn()
    const stop = startBoardPolling({ capture: async () => { throw new TypeError('fetch failed') }, onFrame: vi.fn(), onError })
    await vi.advanceTimersByTimeAsync(0)
    expect(onError).toHaveBeenCalledWith(expect.stringContaining('연결이 끊겼거나'))
    stop()
  })
})
