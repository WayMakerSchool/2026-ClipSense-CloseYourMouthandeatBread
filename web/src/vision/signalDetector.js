export const REGION_RATIO = 0.6 // 상단 60%만 분석 (신호등 위치)

const STEP = 2            // 샘플링 간격(px)
const MIN_RATIO = 0.003   // 이 미만이면 노이즈로 간주 → unknown
const FULL_RATIO = 0.03   // 이 이상이면 confidence 1.0

export function rgbToHsv(r, g, b) {
  const rn = r / 255, gn = g / 255, bn = b / 255
  const max = Math.max(rn, gn, bn), min = Math.min(rn, gn, bn)
  const d = max - min
  let h = 0
  if (d !== 0) {
    if (max === rn) h = 60 * (((gn - bn) / d) % 6)
    else if (max === gn) h = 60 * ((bn - rn) / d + 2)
    else h = 60 * ((rn - gn) / d + 4)
  }
  if (h < 0) h += 360
  return { h, s: max === 0 ? 0 : d / max, v: max }
}

const isGreen = ({ h, s, v }) => h >= 100 && h <= 200 && s > 0.35 && v > 0.35
const isRed = ({ h, s, v }) => (h <= 20 || h >= 340) && s > 0.35 && v > 0.35

/** 프레임 상단 영역의 신호등 색 판별. 불확실하면 unknown (Fail-Safe). */
export function analyzeFrame(frame) {
  if (!frame || !frame.data || !frame.width || !frame.height) {
    return { color: 'unknown', confidence: 0 }
  }
  const { data, width, height } = frame
  const regionH = Math.floor(height * REGION_RATIO)
  let green = 0, red = 0, sampled = 0

  for (let y = 0; y < regionH; y += STEP) {
    for (let x = 0; x < width; x += STEP) {
      const i = (y * width + x) * 4
      const hsv = rgbToHsv(data[i], data[i + 1], data[i + 2])
      if (isGreen(hsv)) green++
      else if (isRed(hsv)) red++
      sampled++
    }
  }
  if (sampled === 0) return { color: 'unknown', confidence: 0 }

  const gRatio = green / sampled
  const rRatio = red / sampled
  const best = Math.max(gRatio, rRatio)
  if (best < MIN_RATIO) return { color: 'unknown', confidence: 0 }

  return {
    color: gRatio >= rRatio ? 'green' : 'red',
    confidence: Math.min(1, best / FULL_RATIO),
  }
}
