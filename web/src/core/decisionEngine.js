import { requiredCrossingSec } from './crossingTime.js'

export const VERDICTS = { CROSS: 'CROSS', CAUTION: 'CAUTION', WARNING: 'WARNING', WAIT: 'WAIT' }

const CONF_DUAL = 0.6   // Tier 1: C-ITS와 교차검증되므로 상대적으로 완화
const CONF_SOLO = 0.75  // Tier 2: 비전 단독이므로 더 엄격

const MSG = {
  CROSS: '지금 건너셔도 됩니다',
  CAUTION: '초록불로 보입니다. 주변 확인 후 진행하세요',
  WARNING: '신호 없는 횡단보도입니다. 차량에 주의하세요',
  TIME_SHORT: '시간이 부족합니다',
  MISMATCH: '신호 정보가 일치하지 않습니다. 대기하세요',
  RED: '빨간불입니다. 대기하세요',
  RED_VISION: '빨간불로 보입니다. 대기하세요',
  UNKNOWN: '신호를 확인할 수 없습니다. 대기하세요',
}

const wait = (reason, message = MSG.UNKNOWN) =>
  ({ verdict: VERDICTS.WAIT, message, hapticPattern: 'wait', reason })

/**
 * 이중검증 + Fail-Safe 판정.
 * 어떤 경로로도 조건이 완전히 충족되지 않으면 WAIT를 반환한다.
 * 예외가 발생해도 WAIT를 반환한다.
 */
export function decide(input) {
  try {
    const { tier, cits, vision, user, crosswalk } = input ?? {}

    if (tier === 3) {
      return {
        verdict: VERDICTS.WARNING, message: MSG.WARNING,
        hapticPattern: 'warning', reason: 'NO_SIGNAL_ZONE',
      }
    }

    if (tier === 2) {
      if (!vision || vision.color === 'unknown') return wait('VISION_UNCERTAIN')
      if (vision.color === 'red') return wait('RED_SIGNAL', MSG.RED_VISION)
      if (vision.color === 'green' && vision.confidence >= CONF_SOLO) {
        return {
          verdict: VERDICTS.CAUTION, message: MSG.CAUTION,
          hapticPattern: 'caution', reason: 'VISION_GREEN_ALONE',
        }
      }
      return wait('VISION_UNCERTAIN')
    }

    if (tier === 1) {
      // 캐스케이드: 결측 → 빨강 → 비전 불확실 → 불일치 → 시간 → CROSS
      if (!cits || cits.available !== true || !vision) return wait('DATA_MISSING')
      if (cits.color === 'red') return wait('RED_SIGNAL', MSG.RED)
      if (cits.color !== 'green') return wait('DATA_MISSING')
      if (vision.color === 'unknown' || !(vision.confidence >= CONF_DUAL)) {
        return wait('VISION_UNCERTAIN')
      }
      if (vision.color !== 'green') return wait('SOURCE_MISMATCH', MSG.MISMATCH)

      const needSec = requiredCrossingSec({ ...(crosswalk ?? {}), ...(user ?? {}) })
      if (!(cits.remainingSec >= needSec)) return wait('TIME_SHORT', MSG.TIME_SHORT)

      return {
        verdict: VERDICTS.CROSS, message: MSG.CROSS,
        hapticPattern: 'cross', reason: 'DUAL_GREEN_TIME_OK',
      }
    }

    return wait('INVALID_INPUT') // 알 수 없는 tier — 무조건 대기
  } catch {
    return wait('INVALID_INPUT') // 어떤 예외도 삼키고 대기
  }
}
