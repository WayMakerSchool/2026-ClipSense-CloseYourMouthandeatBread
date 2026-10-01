/**
 * SafeGraph-RTA 입력 계약 검증 (원본설계서 §6).
 * 모든 validate* 함수는 절대 throw하지 않고 { ok, errors: string[] }를 반환한다.
 * errors에는 실패한 필드명을 담는다(중복 없이, 발견 순서 보존).
 */

const CITS_COLORS = ['red', 'green', 'unknown']
const VISION_COLORS = ['red', 'green', 'unknown']
const CITS_SOURCE_MODES = ['MOCK', 'RECORDED', 'LIVE']
const VISION_SOURCE_MODES = ['CAMERA', 'RECORDED', 'MOCK']

const isNonEmptyString = (v) => typeof v === 'string' && v.trim().length > 0
const isFiniteNumber = (v) => typeof v === 'number' && Number.isFinite(v)
const isFiniteInteger = (v) => isFiniteNumber(v) && Number.isInteger(v)

function fail(errors, field) {
  if (!errors.includes(field)) errors.push(field)
}

function result(errors) {
  return { ok: errors.length === 0, errors }
}

/**
 * @param {object} target
 * @returns {{ ok: boolean, errors: string[] }}
 */
export function validateTargetContext(target) {
  const errors = []
  const t = target ?? {}

  for (const field of ['intersectionId', 'crosswalkId', 'movementId', 'direction', 'roiBindingId']) {
    if (!isNonEmptyString(t[field])) fail(errors, field)
  }

  if (t.bindingMethod !== 'MANUAL_DEMO') fail(errors, 'bindingMethod')

  return result(errors)
}

/**
 * @param {object} cits
 * @returns {{ ok: boolean, errors: string[] }}
 */
export function validateCitsObservation(cits) {
  const errors = []
  const c = cits ?? {}

  if (typeof c.available !== 'boolean') fail(errors, 'available')

  if (!CITS_COLORS.includes(c.color)) fail(errors, 'color')

  if (!isFiniteNumber(c.remainingSec) || c.remainingSec < 0) fail(errors, 'remainingSec')

  for (const field of ['intersectionId', 'crosswalkId', 'movementId', 'direction']) {
    if (!isNonEmptyString(c[field])) fail(errors, field)
  }

  const hasSourceEpochMs = isFiniteNumber(c.sourceEpochMs) && c.sourceEpochMs >= 0
  if (!hasSourceEpochMs) fail(errors, 'sourceEpochMs')

  if (!isFiniteNumber(c.receivedAtMonoMs) || c.receivedAtMonoMs < 0) fail(errors, 'receivedAtMonoMs')

  if (!isFiniteInteger(c.seq)) fail(errors, 'seq')

  if (!CITS_SOURCE_MODES.includes(c.sourceMode)) fail(errors, 'sourceMode')

  // LIVE인데 sourceEpochMs 없음 → 불합격 (원본 §6.2 주의사항)
  if (c.sourceMode === 'LIVE' && !hasSourceEpochMs) fail(errors, 'sourceEpochMs')

  return result(errors)
}

/**
 * @param {object} vision
 * @returns {{ ok: boolean, errors: string[] }}
 */
export function validateVisionObservation(vision) {
  const errors = []
  const v = vision ?? {}

  if (!VISION_COLORS.includes(v.color)) fail(errors, 'color')

  if (!isFiniteNumber(v.score) || v.score < 0 || v.score > 1) fail(errors, 'score')

  if (!isFiniteNumber(v.quality) || v.quality < 0 || v.quality > 1) fail(errors, 'quality')

  if (!isNonEmptyString(v.roiBindingId)) fail(errors, 'roiBindingId')

  if (!isFiniteNumber(v.capturedAtMonoMs) || v.capturedAtMonoMs < 0) fail(errors, 'capturedAtMonoMs')

  if (!isFiniteInteger(v.frameSeq)) fail(errors, 'frameSeq')

  if (!isFiniteNumber(v.mediaTimeMs) || v.mediaTimeMs < 0) fail(errors, 'mediaTimeMs')

  if (!VISION_SOURCE_MODES.includes(v.sourceMode)) fail(errors, 'sourceMode')

  return result(errors)
}

/**
 * @param {object} clock
 * @returns {{ ok: boolean, errors: string[] }}
 */
export function validateClock(clock) {
  const errors = []
  const c = clock ?? {}

  if (!isFiniteNumber(c.nowEpochMs)) fail(errors, 'nowEpochMs')
  if (!isFiniteNumber(c.nowMonoMs)) fail(errors, 'nowMonoMs')

  return result(errors)
}

const CONFIG_NUMERIC_FIELDS = [
  'minVisionScore',
  'minVisionQuality',
  'maxCitsSourceAgeMs',
  'maxCitsReceiveAgeMs',
  'maxVisionAgeMs',
  'freezeTimeoutMs',
  'futureClockToleranceMs',
  'minDistinctGreenFrames',
  'confirmHoldMs',
  'latencyBudgetMs',
]

/**
 * @param {object} config
 * @returns {{ ok: boolean, errors: string[] }}
 */
export function validateConfig(config) {
  const errors = []
  const cfg = config ?? {}

  if (!isNonEmptyString(cfg.configVersion)) fail(errors, 'configVersion')

  for (const field of CONFIG_NUMERIC_FIELDS) {
    if (!isFiniteNumber(cfg[field]) || cfg[field] < 0) fail(errors, field)
  }

  return result(errors)
}
