import { createServer } from 'node:http'
import { once } from 'node:events'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { boardCaptureMiddleware } from '../../dev/boardProxy.js'

describe('실제 HTTP 보드 프록시', () => {
  let upstream, proxy, address, proxyAddress
  let nextStatus = 200
  let receivedHeaders, receivedPath
  const runtimeToken = crypto.randomUUID()
  beforeAll(async () => {
    upstream = createServer((req, res) => {
      receivedHeaders = req.headers
      receivedPath = req.url
      res.writeHead(nextStatus, {
        'Content-Type': nextStatus === 200 ? 'image/jpeg' : 'application/json',
        'X-Frame-Seq': '7', 'X-Frame-Source': 'laptop-upload', 'X-Camera-Sensor': 'LAPTOP',
        'Set-Cookie': 'unwanted=value',
      })
      res.end(nextStatus === 200 ? Buffer.from([255, 216, 255, 217]) : '{}')
    })
    proxy = createServer(boardCaptureMiddleware)
    upstream.listen(0, '127.0.0.1')
    proxy.listen(0, '127.0.0.1')
    await Promise.all([once(upstream, 'listening'), once(proxy, 'listening')])
    address = `http://127.0.0.1:${upstream.address().port}`
    proxyAddress = `http://127.0.0.1:${proxy.address().port}`
  })
  afterAll(async () => {
    await Promise.all([upstream, proxy].map((server) => new Promise((resolve) => {
      server.closeAllConnections()
      server.close(resolve)
    })))
  })

  it('고정 /capture에 토큰 헤더만 전달하고 사진과 출처 헤더를 보존한다', async () => {
    const result = await fetch(`${proxyAddress}/capture?address=${encodeURIComponent(address)}`, {
      headers: { 'X-Clip-Device-Token': runtimeToken, Cookie: 'private=value', Authorization: 'unwanted' },
    })
    expect(result.status).toBe(200)
    expect(receivedPath).toBe('/capture')
    expect(receivedHeaders['x-clip-device-token']).toBe(runtimeToken)
    expect(receivedHeaders.cookie).toBeUndefined()
    expect(receivedHeaders.authorization).toBeUndefined()
    expect(result.headers.get('X-Frame-Seq')).toBe('7')
    expect(result.headers.get('X-Frame-Source')).toBe('laptop-upload')
    expect(result.headers.get('X-Camera-Sensor')).toBe('LAPTOP')
    expect(result.headers.get('Cache-Control')).toBe('no-store')
    expect(result.headers.get('Set-Cookie')).toBeNull()
    expect(new Uint8Array(await result.arrayBuffer())).toEqual(new Uint8Array([255, 216, 255, 217]))
  })

  it.each([401, 403, 503])('보드 오류 %s를 그대로 전달한다', async (status) => {
    nextStatus = status
    const result = await fetch(`${proxyAddress}/capture?address=${encodeURIComponent(address)}`)
    expect(result.status).toBe(status)
    expect(receivedHeaders['x-clip-device-token']).toBeUndefined()
  })

  it('잘못된 주소·경로·메서드를 거절한다', async () => {
    expect((await fetch(`${proxyAddress}/capture?address=file:///etc/passwd`)).status).toBe(400)
    expect((await fetch(`${proxyAddress}/other`)).status).toBe(404)
    expect((await fetch(`${proxyAddress}/capture`, { method: 'POST' })).status).toBe(405)
  })

  it('연결 실패를 502로 반환한다', async () => {
    const closed = createServer()
    closed.listen(0, '127.0.0.1')
    await once(closed, 'listening')
    const port = closed.address().port
    await new Promise((resolve) => closed.close(resolve))
    const result = await fetch(`${proxyAddress}/capture?address=${encodeURIComponent(`http://127.0.0.1:${port}`)}`)
    expect(result.status).toBe(502)
  })
})
