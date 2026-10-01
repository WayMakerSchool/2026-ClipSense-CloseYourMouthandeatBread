import { useEffect, useRef, useState } from 'react'
import { analyzeFrame, REGION_RATIO } from '../vision/signalDetector.js'
import { startCamera, stopStream, grabFrame } from '../sources/videoSource.js'

const ANALYZE_MS = 300
const STEP = 4 // 다운샘플 간격(px) — quality 산식은 analyzeFrame과 별개로 독립 계산

/**
 * ROI(REGION_RATIO 상단) 프레임 품질 산식 (스펙 §2.10 "구현 파일에 산식 주석 문서화"):
 *
 *   quality = validPixelRatio × normalizedAvgBrightness
 *
 * - validPixelRatio: ROI 내 샘플링된 픽셀 중 "유효"(완전한 검정이 아닌, 즉
 *   alpha>0이고 r|g|b 중 하나라도 0을 넘는) 픽셀의 비율. 카메라 미기동·크롭
 *   실패 등으로 프레임이 비어있으면 0에 수렴한다.
 * - normalizedAvgBrightness: ROI 내 유효 픽셀의 HSV V(명도, 0~1)를 평균한
 *   값. 너무 어둡거나(저조도) 완전 포화(과다노출)여도 신호색 판별
 *   신뢰도가 낮아지므로, 평균 명도가 0.5(중간 밝기)에 가까울수록 1에
 *   가깝고 양 극단(0 또는 1)에 가까울수록 0에 가까워지도록
 *   `1 - |v - 0.5| / 0.5` 로 정규화한다.
 *
 * 두 항의 곱은 [0,1] 범위이며, "픽셀이 충분히 채워져 있고 동시에 밝기가
 * 신호색 판별에 적합한 중간 대역인가"를 함께 반영한다. contracts.js의
 * `validateVisionObservation`이 요구하는 quality ∈ [0,1] 계약을 만족한다.
 */
function computeQuality(frame) {
  if (!frame || !frame.data || !frame.width || !frame.height) return 0
  const { data, width, height } = frame
  const regionH = Math.floor(height * REGION_RATIO)
  if (regionH <= 0 || width <= 0) return 0

  let sampled = 0
  let valid = 0
  let brightnessSum = 0

  for (let y = 0; y < regionH; y += STEP) {
    for (let x = 0; x < width; x += STEP) {
      const i = (y * width + x) * 4
      const r = data[i]
      const g = data[i + 1]
      const b = data[i + 2]
      const a = data[i + 3]
      sampled++
      if (a > 0 && (r > 0 || g > 0 || b > 0)) {
        valid++
        const v = Math.max(r, g, b) / 255
        brightnessSum += v
      }
    }
  }

  if (sampled === 0) return 0
  const validPixelRatio = valid / sampled
  if (valid === 0) return 0
  const avgV = brightnessSum / valid
  const normalizedAvgBrightness = Math.max(0, 1 - Math.abs(avgV - 0.5) / 0.5)
  return Math.min(1, Math.max(0, validPixelRatio * normalizedAvgBrightness))
}

/**
 * 내장 카메라(또는 ESP32 스트림) 프레임을 주기적으로 캡처해 onVision으로
 * 전달한다. 기존 v1 계약(`{ color, confidence }`)은 그대로 유지하고,
 * 스펙 §2.10에 따라 SafeGraph-RTA vision observation 매핑에 필요한
 * `frameSeq`(단조 증가 카운터) · `capturedAtMonoMs`(performance.now(),
 * UI 계층이므로 허용 — 안전 코어에는 clock 인자로 전달됨) · `quality`를
 * 추가한다.
 */
export default function CameraView({ mode, espUrl, onVision }) {
  const videoRef = useRef(null)
  const imgRef = useRef(null)
  const canvasRef = useRef(document.createElement('canvas'))
  const onVisionRef = useRef(onVision)
  onVisionRef.current = onVision
  const frameSeqRef = useRef(0)
  const [error, setError] = useState(null)

  useEffect(() => {
    let stream = null
    let cancelled = false
    setError(null)
    if (mode === 'camera') {
      startCamera(videoRef.current)
        .then((s) => { if (cancelled) stopStream(s); else stream = s })
        .catch(() => setError('카메라 접근이 거부되었습니다. 브라우저 권한을 확인하세요.'))
    }
    return () => { cancelled = true; stopStream(stream) }
  }, [mode])

  useEffect(() => {
    const id = setInterval(() => {
      const el = mode === 'camera' ? videoRef.current : imgRef.current
      if (!el) return
      const frame = grabFrame(el, canvasRef.current)
      frameSeqRef.current += 1
      const base = frame ? analyzeFrame(frame) : { color: 'unknown', confidence: 0 }
      onVisionRef.current({
        ...base,
        frameSeq: frameSeqRef.current,
        capturedAtMonoMs: performance.now(),
        quality: computeQuality(frame),
      })
    }, ANALYZE_MS)
    return () => clearInterval(id)
  }, [mode])

  return (
    <div className="camera-view">
      {mode === 'camera' ? (
        <video ref={videoRef} muted playsInline />
      ) : (
        <img ref={imgRef} src={espUrl} crossOrigin="anonymous" alt="ESP32 스트림" />
      )}
      <div className="region-line" style={{ top: `${REGION_RATIO * 100}%` }} />
      <span className="region-label">↑ 신호등 분석 영역</span>
      {error && <div className="camera-error">{error}</div>}
    </div>
  )
}
