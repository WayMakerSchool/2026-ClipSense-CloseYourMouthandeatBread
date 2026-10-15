import { normalizeBoardAddress } from '../src/sources/boardCapture.js'

// 화면 입력 주소를 받으므로 고정 target 대신 Vite 미들웨어 프록시를 사용한다.
// 브라우저는 HTTPS 동일 출처만 호출하고 Vite가 HTTP 보드의 /capture를 호출한다.
export function boardProxyPlugin() {
  return {
    name: 'clipsense-board-proxy',
    apply: 'serve',
    configureServer(server) {
      server.middlewares.use('/board', boardCaptureMiddleware)
    },
  }
}

export async function boardCaptureMiddleware(req, res) {
  res.setHeader('Cache-Control', 'no-store')
  const fail = (status) => {
    res.statusCode = status
    res.setHeader('Content-Type', 'application/json')
    res.end(JSON.stringify({ error: 'board_capture_failed' }))
  }
  const requestUrl = new URL(req.url ?? '', 'http://internal.local')
  if (requestUrl.pathname !== '/capture') return fail(404)
  if (req.method !== 'GET') {
    res.setHeader('Allow', 'GET')
    return fail(405)
  }
  let address
  try {
    address = normalizeBoardAddress(requestUrl.searchParams.get('address') ?? '')
  } catch {
    return fail(400)
  }
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 2500)
  const disconnect = () => { if (!res.writableEnded) controller.abort() }
  res.on('close', disconnect)
  try {
    const headers = {}
    const token = req.headers['x-clip-device-token']
    if (typeof token === 'string') headers['X-Clip-Device-Token'] = token
    const upstream = await fetch(`${address}/capture`, {
      headers, signal: controller.signal, redirect: 'error', cache: 'no-store',
    })
    // 본문 수신에도 타임아웃 적용. 쿠키·인증·리디렉션 헤더는 전달하지 않는다.
    const body = Buffer.from(await upstream.arrayBuffer())
    res.statusCode = upstream.status
    for (const header of ['Content-Type', 'X-Frame-Seq', 'X-Frame-Source', 'X-Camera-Sensor']) {
      const value = upstream.headers.get(header)
      if (value !== null) res.setHeader(header, value)
    }
    res.end(body)
  } catch {
    if (!res.destroyed) fail(controller.signal.aborted ? 504 : 502)
  } finally {
    clearTimeout(timer)
    res.off('close', disconnect)
  }
}
