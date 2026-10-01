/** 내장 카메라 시작. 모바일은 후면 우선. 실패 시 throw — 호출측(UI)에서 안내 표시. */
export async function startCamera(videoEl) {
  const stream = await navigator.mediaDevices.getUserMedia({
    video: { facingMode: 'environment', width: { ideal: 640 } },
    audio: false,
  })
  videoEl.srcObject = stream
  await videoEl.play()
  return stream
}

export function stopStream(stream) {
  stream?.getTracks?.().forEach((t) => t.stop())
}

const TARGET_W = 320 // 분석용 다운스케일 폭 — 320이면 HSV 스캔이 60fps에도 여유

/** video/img 요소의 현재 프레임을 축소해 ImageData로 반환. 준비 안 됐으면 null. */
export function grabFrame(el, canvas) {
  const srcW = el.videoWidth ?? el.naturalWidth ?? 0
  const srcH = el.videoHeight ?? el.naturalHeight ?? 0
  if (!srcW || !srcH) return null
  const w = TARGET_W
  const h = Math.round((srcH / srcW) * TARGET_W)
  canvas.width = w
  canvas.height = h
  const ctx = canvas.getContext('2d', { willReadFrequently: true })
  ctx.drawImage(el, 0, 0, w, h)
  try {
    return ctx.getImageData(0, 0, w, h)
  } catch {
    return null // ESP32 CORS 미허용 등 — 불확실하면 null → 비전 unknown → WAIT
  }
}
