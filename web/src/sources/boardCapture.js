export const BOARD_POLL_MS = 1000
export const BOARD_TIMEOUT_MS = 3000

export function normalizeBoardAddress(address) {
  const value = address.trim()
  if (!value) throw new Error('보드 주소를 입력해 주세요.')
  let url
  try {
    url = new URL(value.includes('://') ? value : `http://${value}`)
  } catch {
    throw new Error('보드 주소 형식을 확인해 주세요. 예: http://192.168.0.50')
  }
  if (url.protocol !== 'http:' || url.username || url.password ||
      url.pathname !== '/' || url.search || url.hash) {
    throw new Error('보드 주소는 경로·토큰 없이 http://주소:포트 형식으로 입력해 주세요.')
  }
  return url.origin
}

export function frameSourceLabel(source, sensor) {
  if (source?.toLowerCase() === 'laptop-upload' || sensor?.toUpperCase() === 'LAPTOP') {
    return '노트북 촬영'
  }
  if (sensor?.toUpperCase() === 'SIM') return '시뮬레이터 (실제 클립 카메라 아님)'
  // 현재 펌웨어의 센서 촬영 응답에는 X-Frame-Source가 없고 센서명만 있다.
  if ((!source || source === 'camera') && /^OV\d+$/i.test(sensor ?? '')) return '클립 카메라'
  return '출처 확인 불가'
}

export function captureErrorMessage(status) {
  switch (status) {
    case 400: return '보드 주소 또는 요청 형식을 확인해 주세요. (400)'
    case 401: return '토큰이 없습니다. 기기 토큰을 입력해 주세요. (401)'
    case 403: return '토큰이 틀립니다. 기기 토큰을 확인해 주세요. (403)'
    case 409: return '보드가 촬영 중입니다. 다음 사진을 기다립니다. (409)'
    case 503: return '보드에 사진이 없습니다. 카메라 또는 노트북 업로드를 확인해 주세요. (503)'
    case 502: return '보드 연결이 끊겼거나 연결할 수 없습니다. 주소·전원·Wi-Fi를 확인해 주세요. (502)'
    case 504: return '보드 응답 시간이 초과되었습니다. 연결을 확인해 주세요. (504)'
    case 404: return '사진 프록시가 없습니다. web 폴더에서 npm run dev로 실행해 주세요. (404)'
    default: return `사진 받기에 실패했습니다. (HTTP ${status})`
  }
}

export async function fetchBoardCapture({ address, token, signal }) {
  const headers = {}
  if (token) headers['X-Clip-Device-Token'] = token
  const response = await fetch(`/board/capture?address=${encodeURIComponent(normalizeBoardAddress(address))}`, {
    headers, signal, cache: 'no-store', credentials: 'omit',
  })
  if (!response.ok) throw new Error(captureErrorMessage(response.status))
  if (response.headers.get('Content-Type')?.split(';')[0].trim() !== 'image/jpeg') {
    throw new Error('보드가 JPEG 사진 대신 다른 응답을 보냈습니다. 주소와 개발 서버를 확인해 주세요.')
  }
  const seq = response.headers.get('X-Frame-Seq')
  if (!seq || !/^\d+$/.test(seq)) throw new Error('사진 번호(X-Frame-Seq)가 없어 사진을 표시할 수 없습니다.')
  const source = response.headers.get('X-Frame-Source')
  const sensor = response.headers.get('X-Camera-Sensor')
  const blob = await response.blob()
  if (!blob.size) throw new Error('보드가 빈 사진을 보냈습니다.')
  return { blob, seq, source, sensor, sourceLabel: frameSourceLabel(source, sensor) }
}

// 표시 전용 폴링. 진행 중인 요청은 겹치지 않고, 중지 후 늦게 온 응답은 폐기한다.
export function startBoardPolling({ address, token, onFrame, onError, capture = fetchBoardCapture }) {
  let stopped = false
  let inFlight = false
  let controller
  async function poll() {
    if (stopped || inFlight) return
    inFlight = true
    controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), BOARD_TIMEOUT_MS)
    try {
      const frame = await capture({ address, token, signal: controller.signal })
      if (!stopped) onFrame(frame)
    } catch (error) {
      if (!stopped) onError(controller.signal.aborted
        ? '보드 응답 시간이 초과되었습니다. 연결을 확인해 주세요.'
        : error instanceof TypeError
          ? '보드 연결이 끊겼거나 연결할 수 없습니다. 개발 서버·주소·Wi-Fi를 확인해 주세요.'
          : error.message)
    } finally {
      clearTimeout(timer)
      inFlight = false
    }
  }
  poll()
  const interval = setInterval(poll, BOARD_POLL_MS)
  return () => {
    stopped = true
    clearInterval(interval)
    controller?.abort()
  }
}
