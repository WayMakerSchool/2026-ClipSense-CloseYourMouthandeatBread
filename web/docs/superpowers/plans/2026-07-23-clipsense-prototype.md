# ClipSense 프로토타입 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 이중 검증(C-ITS × 비전 AI) + Fail-Safe 판정을 시연 가능한 React+Vite+PWA 웹 프로토타입.

**Architecture:** `core/`(순수 판정 로직, Vitest 검증) ← `sources/`(C-ITS 실호출/모의, 카메라/ESP32 어댑터) + `vision/`(HSV 신호등 판별) → `ui/`(검증 현황 화면) + `feedback/`(TTS·진동). 판정 엔진 기본값은 무조건 WAIT.

**Tech Stack:** React 18, Vite, vite-plugin-pwa, Vitest, Web Speech API, Vibration API, Canvas/getUserMedia. JavaScript only (TS 미사용).

**Spec:** `docs/superpowers/specs/2026-07-23-clipsense-prototype-design.md`

## Global Constraints

- 작업 디렉토리: `/Users/daniellim/Desktop/ClipSense/Prototype` (모든 명령 여기서 실행)
- Node 22 / npm 10, `"type": "module"`
- 기본 파라미터: 보행속도 `0.6` m/s, 횡단거리 `10` m, 여유 마진 `2` 초
- confidence 임계값: Tier 1 `0.6`, Tier 2 `0.75`
- 히스테리시스 hold: `1500` ms (CROSS/CAUTION만. WAIT/WARNING은 즉시)
- TTS 중복 방지 쿨다운: `4000` ms
- 안내 문구 (정확히 이 문자열, 설명서 표1 대응):
  - CROSS: `지금 건너셔도 됩니다`
  - CAUTION: `초록불로 보입니다. 주변 확인 후 진행하세요`
  - WARNING: `신호 없는 횡단보도입니다. 차량에 주의하세요`
  - WAIT(시간부족): `시간이 부족합니다`
  - WAIT(불일치): `신호 정보가 일치하지 않습니다. 대기하세요`
  - WAIT(빨간불): `빨간불입니다. 대기하세요` / Tier 2는 `빨간불로 보입니다. 대기하세요`
  - WAIT(확인불가/데이터결측): `신호를 확인할 수 없습니다. 대기하세요`
- 안전 고지 (앱 상단 상시): `⚠️ 본 프로토타입은 기술 검증용 시연이며 실제 보행 판단에 사용할 수 없습니다`
- API 키는 `.env.local`에만 (커밋 금지 — .gitignore에 이미 포함됨)
- 커밋 메시지 끝에 `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

### Task 1: 프로젝트 스캐폴드 (Vite + React + PWA + Vitest)

**Files:**
- Create: `package.json`, `vite.config.js`, `index.html`, `src/main.jsx`, `src/App.jsx`, `src/App.css`, `public/icon.svg`

**Interfaces:**
- Produces: `npm run dev`(포트 5173), `npm test`(Vitest) 동작하는 빈 앱. 안전 고지 배너 노출.

- [ ] **Step 1: package.json 작성**

```json
{
  "name": "clipsense-prototype",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview",
    "test": "vitest run",
    "test:watch": "vitest"
  }
}
```

- [ ] **Step 2: 의존성 설치**

Run: `npm i react react-dom && npm i -D vite @vitejs/plugin-react vitest vite-plugin-pwa`
Expected: 오류 없이 완료, `package.json`에 dependencies/devDependencies 추가됨

- [ ] **Step 3: vite.config.js 작성**

```js
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'

export default defineConfig({
  plugins: [
    react(),
    VitePWA({
      registerType: 'autoUpdate',
      manifest: {
        name: 'ClipSense Prototype',
        short_name: 'ClipSense',
        description: '시각장애인 횡단보도 보행 안전 보조 — 기술 검증용 프로토타입',
        theme_color: '#101418',
        background_color: '#101418',
        icons: [{ src: 'icon.svg', sizes: 'any', type: 'image/svg+xml' }],
      },
    }),
  ],
})
```

- [ ] **Step 4: index.html 작성**

```html
<!doctype html>
<html lang="ko">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>ClipSense — 기술 검증용 프로토타입</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
```

- [ ] **Step 5: src/main.jsx 작성**

```jsx
import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App.jsx'

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
)
```

- [ ] **Step 6: src/App.jsx 셸 작성** (Task 10에서 전면 교체됨)

```jsx
import './App.css'

export default function App() {
  return (
    <div className="app">
      <div className="safety-banner">
        ⚠️ 본 프로토타입은 기술 검증용 시연이며 실제 보행 판단에 사용할 수 없습니다
      </div>
      <h1>ClipSense Prototype</h1>
    </div>
  )
}
```

- [ ] **Step 7: src/App.css 최소 작성** (Task 10에서 전면 교체됨)

```css
body { margin: 0; background: #101418; color: #f5f7fa; font-family: 'Apple SD Gothic Neo', sans-serif; }
.safety-banner { background: #ffd600; color: #000; font-weight: 700; padding: 8px 16px; text-align: center; }
```

- [ ] **Step 8: public/icon.svg 작성**

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><rect width="512" height="512" rx="96" fill="#101418"/><circle cx="256" cy="160" r="70" fill="#ff1744"/><circle cx="256" cy="352" r="70" fill="#00e676"/></svg>
```

- [ ] **Step 9: 구동 확인**

Run: `npm run dev -- --port 5173` (백그라운드) 후 `curl -s http://localhost:5173 | grep -o "<title>[^<]*"`
Expected: `<title>ClipSense — 기술 검증용 프로토타입` 출력. 확인 후 dev 서버 종료.
Run: `npm test`
Expected: "No test files found" (정상 — 아직 테스트 없음, exit code는 실패일 수 있으므로 출력 문구로 판단)

- [ ] **Step 10: 커밋**

```bash
git add package.json package-lock.json vite.config.js index.html src/ public/
git commit -m "feat: Vite+React+PWA 스캐폴드 및 안전 고지 배너"
```

---

### Task 2: core/crossingTime — 필요 횡단시간

**Files:**
- Create: `src/core/crossingTime.js`
- Test: `tests/core/crossingTime.test.js`

**Interfaces:**
- Produces: `requiredCrossingSec({ lengthM, walkingSpeedMps, marginSec = 2 }) → Number`. **유효하지 않은 입력이면 `Infinity`** (Infinity는 어떤 잔여시간 비교도 통과 못 함 → 자연히 WAIT. Fail-Safe를 타입 수준에서 구현).

- [ ] **Step 1: 실패하는 테스트 작성** — `tests/core/crossingTime.test.js`

```js
import { describe, it, expect } from 'vitest'
import { requiredCrossingSec } from '../../src/core/crossingTime.js'

describe('requiredCrossingSec', () => {
  it('10m, 0.6m/s, 마진 2초 → 18.67초', () => {
    expect(requiredCrossingSec({ lengthM: 10, walkingSpeedMps: 0.6 })).toBeCloseTo(18.67, 2)
  })
  it('마진 0 지정 시 16.67초', () => {
    expect(requiredCrossingSec({ lengthM: 10, walkingSpeedMps: 0.6, marginSec: 0 })).toBeCloseTo(16.67, 2)
  })
  it('속도 0 → Infinity (Fail-Safe)', () => {
    expect(requiredCrossingSec({ lengthM: 10, walkingSpeedMps: 0 })).toBe(Infinity)
  })
  it('음수 거리 → Infinity', () => {
    expect(requiredCrossingSec({ lengthM: -5, walkingSpeedMps: 0.6 })).toBe(Infinity)
  })
  it('인자 없음/null → Infinity', () => {
    expect(requiredCrossingSec()).toBe(Infinity)
    expect(requiredCrossingSec(null)).toBe(Infinity)
    expect(requiredCrossingSec({})).toBe(Infinity)
  })
})
```

- [ ] **Step 2: 실패 확인**

Run: `npm test -- tests/core/crossingTime.test.js`
Expected: FAIL — "Failed to load" 또는 "requiredCrossingSec is not a function"

- [ ] **Step 3: 구현** — `src/core/crossingTime.js`

```js
/**
 * 필요 횡단시간(초) = 거리/보행속도 + 여유 마진.
 * 유효하지 않은 입력은 Infinity를 반환한다 — Infinity는 어떤 잔여시간과
 * 비교해도 "부족"이므로 판정 엔진이 자연히 WAIT로 수렴한다 (Fail-Safe).
 */
export function requiredCrossingSec(input) {
  if (!input || typeof input !== 'object') return Infinity
  const { lengthM, walkingSpeedMps, marginSec = 2 } = input
  if (!Number.isFinite(lengthM) || lengthM <= 0) return Infinity
  if (!Number.isFinite(walkingSpeedMps) || walkingSpeedMps <= 0) return Infinity
  if (!Number.isFinite(marginSec) || marginSec < 0) return Infinity
  return lengthM / walkingSpeedMps + marginSec
}
```

- [ ] **Step 4: 통과 확인**

Run: `npm test -- tests/core/crossingTime.test.js`
Expected: PASS (5 tests)

- [ ] **Step 5: 커밋**

```bash
git add src/core/crossingTime.js tests/core/crossingTime.test.js
git commit -m "feat(core): 필요 횡단시간 계산 — 무효 입력은 Infinity로 Fail-Safe"
```

---

### Task 3: core/tierResolver — Tier 자동 결정

**Files:**
- Create: `src/core/tierResolver.js`
- Test: `tests/core/tierResolver.test.js`

**Interfaces:**
- Produces: `resolveTier({ citsAvailable, noSignalMode }) → 1 | 2 | 3`. 무신호 모드가 최우선, C-ITS 정상이면 1, **그 외 전부 2** (정보 없음 = 보수적 단독 운용).

- [ ] **Step 1: 실패하는 테스트 작성** — `tests/core/tierResolver.test.js`

```js
import { describe, it, expect } from 'vitest'
import { resolveTier } from '../../src/core/tierResolver.js'

describe('resolveTier', () => {
  it('무신호 모드는 C-ITS 가용 여부와 무관하게 Tier 3', () => {
    expect(resolveTier({ citsAvailable: true, noSignalMode: true })).toBe(3)
    expect(resolveTier({ citsAvailable: false, noSignalMode: true })).toBe(3)
  })
  it('C-ITS 정상 → Tier 1', () => {
    expect(resolveTier({ citsAvailable: true, noSignalMode: false })).toBe(1)
  })
  it('C-ITS 불가 → Tier 2 (자동 강등)', () => {
    expect(resolveTier({ citsAvailable: false, noSignalMode: false })).toBe(2)
  })
  it('입력 결측 → Tier 2 (보수적)', () => {
    expect(resolveTier()).toBe(2)
    expect(resolveTier(null)).toBe(2)
    expect(resolveTier({})).toBe(2)
  })
})
```

- [ ] **Step 2: 실패 확인**

Run: `npm test -- tests/core/tierResolver.test.js`
Expected: FAIL

- [ ] **Step 3: 구현** — `src/core/tierResolver.js`

```js
/** 신호 환경 3단계 자동 결정. 정보가 없으면 Tier 2(보수적 단독 운용). */
export function resolveTier(input) {
  const { citsAvailable, noSignalMode } = input ?? {}
  if (noSignalMode === true) return 3
  if (citsAvailable === true) return 1
  return 2
}
```

- [ ] **Step 4: 통과 확인**

Run: `npm test -- tests/core/tierResolver.test.js`
Expected: PASS (4 tests)

- [ ] **Step 5: 커밋**

```bash
git add src/core/tierResolver.js tests/core/tierResolver.test.js
git commit -m "feat(core): Tier 1/2/3 자동 결정 — C-ITS 실패 시 자동 강등"
```

---

### Task 4: core/decisionEngine — 이중검증 + Fail-Safe 판정 (심장부)

**Files:**
- Create: `src/core/decisionEngine.js`
- Test: `tests/core/decisionEngine.test.js`

**Interfaces:**
- Consumes: `requiredCrossingSec` (Task 2)
- Produces:
  - `VERDICTS = { CROSS, CAUTION, WARNING, WAIT }` (값 = 동명 문자열)
  - `decide({ tier, cits, vision, user, crosswalk }) → { verdict, message, hapticPattern, reason }`
    - `cits: { color: 'green'|'red'|'unknown', remainingSec: Number, available: Boolean }`
    - `vision: { color: 'green'|'red'|'unknown', confidence: Number }`
    - `user: { walkingSpeedMps }`, `crosswalk: { lengthM }`
    - `hapticPattern: 'cross'|'caution'|'warning'|'wait'` (Task 8의 PATTERNS 키와 일치)
    - `reason`: `'DUAL_GREEN_TIME_OK'|'TIME_SHORT'|'SOURCE_MISMATCH'|'RED_SIGNAL'|'VISION_UNCERTAIN'|'VISION_GREEN_ALONE'|'DATA_MISSING'|'NO_SIGNAL_ZONE'|'INVALID_INPUT'`

판정 캐스케이드 (Tier 1): 데이터 결측 → C-ITS 빨강 → 비전 불확실 → 색 불일치 → 시간 부족 → (전부 통과 시에만) CROSS. **함수 마지막 줄과 catch는 무조건 WAIT.**

- [ ] **Step 1: 실패하는 테스트 작성** — `tests/core/decisionEngine.test.js`

```js
import { describe, it, expect } from 'vitest'
import { decide, VERDICTS } from '../../src/core/decisionEngine.js'

const user = { walkingSpeedMps: 0.6 }
const crosswalk = { lengthM: 10 } // 필요시간 = 16.67 + 2 = 18.67초
const g = (remainingSec) => ({ color: 'green', remainingSec, available: true })
const r = (remainingSec) => ({ color: 'red', remainingSec, available: true })
const vGreen = { color: 'green', confidence: 0.87 }
const vRed = { color: 'red', confidence: 0.9 }

describe('Tier 1 — 완전 검증', () => {
  it('둘 다 초록 + 잔여 충분 → CROSS', () => {
    const d = decide({ tier: 1, cits: g(25), vision: vGreen, user, crosswalk })
    expect(d.verdict).toBe(VERDICTS.CROSS)
    expect(d.message).toBe('지금 건너셔도 됩니다')
    expect(d.hapticPattern).toBe('cross')
    expect(d.reason).toBe('DUAL_GREEN_TIME_OK')
  })
  it('둘 다 초록이어도 잔여 부족 → WAIT (설명서 시나리오: 잔여 12초)', () => {
    const d = decide({ tier: 1, cits: g(12), vision: vGreen, user, crosswalk })
    expect(d.verdict).toBe(VERDICTS.WAIT)
    expect(d.message).toBe('시간이 부족합니다')
    expect(d.reason).toBe('TIME_SHORT')
  })
  it('잔여시간 경계: 18.6초 → WAIT, 18.7초 → CROSS', () => {
    expect(decide({ tier: 1, cits: g(18.6), vision: vGreen, user, crosswalk }).verdict).toBe(VERDICTS.WAIT)
    expect(decide({ tier: 1, cits: g(18.7), vision: vGreen, user, crosswalk }).verdict).toBe(VERDICTS.CROSS)
  })
  it('불일치: C-ITS 초록 × 비전 빨강 → WAIT', () => {
    const d = decide({ tier: 1, cits: g(25), vision: vRed, user, crosswalk })
    expect(d.verdict).toBe(VERDICTS.WAIT)
    expect(d.message).toBe('신호 정보가 일치하지 않습니다. 대기하세요')
    expect(d.reason).toBe('SOURCE_MISMATCH')
  })
  it('불일치: C-ITS 빨강 × 비전 초록 → WAIT (빨강 우선)', () => {
    const d = decide({ tier: 1, cits: r(25), vision: vGreen, user, crosswalk })
    expect(d.verdict).toBe(VERDICTS.WAIT)
    expect(d.reason).toBe('RED_SIGNAL')
  })
  it('둘 다 빨강 → WAIT RED_SIGNAL', () => {
    const d = decide({ tier: 1, cits: r(30), vision: vRed, user, crosswalk })
    expect(d.verdict).toBe(VERDICTS.WAIT)
    expect(d.message).toBe('빨간불입니다. 대기하세요')
  })
  it('비전 confidence 미달(0.5) → WAIT VISION_UNCERTAIN', () => {
    const d = decide({ tier: 1, cits: g(25), vision: { color: 'green', confidence: 0.5 }, user, crosswalk })
    expect(d.verdict).toBe(VERDICTS.WAIT)
    expect(d.reason).toBe('VISION_UNCERTAIN')
  })
  it('비전 unknown → WAIT', () => {
    const d = decide({ tier: 1, cits: g(25), vision: { color: 'unknown', confidence: 0 }, user, crosswalk })
    expect(d.verdict).toBe(VERDICTS.WAIT)
  })
  it('cits 결측/available false → WAIT DATA_MISSING', () => {
    expect(decide({ tier: 1, cits: null, vision: vGreen, user, crosswalk }).reason).toBe('DATA_MISSING')
    expect(decide({ tier: 1, cits: { ...g(25), available: false }, vision: vGreen, user, crosswalk }).reason).toBe('DATA_MISSING')
    expect(decide({ tier: 1, cits: g(25), vision: null, user, crosswalk }).reason).toBe('DATA_MISSING')
  })
})

describe('Tier 2 — 보수적 단독', () => {
  it('비전 초록 conf 0.8 → CAUTION (CROSS 아님)', () => {
    const d = decide({ tier: 2, cits: null, vision: { color: 'green', confidence: 0.8 }, user, crosswalk })
    expect(d.verdict).toBe(VERDICTS.CAUTION)
    expect(d.message).toBe('초록불로 보입니다. 주변 확인 후 진행하세요')
    expect(d.hapticPattern).toBe('caution')
    expect(d.reason).toBe('VISION_GREEN_ALONE')
  })
  it('conf 0.7 (<0.75 단독 임계) → WAIT', () => {
    const d = decide({ tier: 2, cits: null, vision: { color: 'green', confidence: 0.7 }, user, crosswalk })
    expect(d.verdict).toBe(VERDICTS.WAIT)
    expect(d.reason).toBe('VISION_UNCERTAIN')
  })
  it('비전 빨강 → WAIT', () => {
    const d = decide({ tier: 2, cits: null, vision: vRed, user, crosswalk })
    expect(d.verdict).toBe(VERDICTS.WAIT)
    expect(d.message).toBe('빨간불로 보입니다. 대기하세요')
  })
  it('비전 unknown → WAIT 확인불가', () => {
    const d = decide({ tier: 2, cits: null, vision: { color: 'unknown', confidence: 0 }, user, crosswalk })
    expect(d.message).toBe('신호를 확인할 수 없습니다. 대기하세요')
  })
})

describe('Tier 3 — 무신호', () => {
  it('무신호 모드 → WARNING 경보', () => {
    const d = decide({ tier: 3, cits: null, vision: { color: 'unknown', confidence: 0 }, user, crosswalk })
    expect(d.verdict).toBe(VERDICTS.WARNING)
    expect(d.message).toBe('신호 없는 횡단보도입니다. 차량에 주의하세요')
    expect(d.hapticPattern).toBe('warning')
    expect(d.reason).toBe('NO_SIGNAL_ZONE')
  })
})

describe('Fail-Safe 기본값 — 어떤 이상 입력도 WAIT', () => {
  it.each([
    ['인자 없음', undefined],
    ['null', null],
    ['빈 객체', {}],
    ['tier만', { tier: 1 }],
    ['알 수 없는 tier', { tier: 99, cits: g(25), vision: vGreen, user, crosswalk }],
    ['문자열 tier', { tier: 'x', cits: g(25), vision: vGreen, user, crosswalk }],
  ])('%s → WAIT', (_label, input) => {
    const d = decide(input)
    expect(d.verdict).toBe(VERDICTS.WAIT)
    expect(d.hapticPattern).toBe('wait')
  })
  it('user/crosswalk 결측 → 필요시간 Infinity → WAIT TIME_SHORT (초록 일치여도)', () => {
    const d = decide({ tier: 1, cits: g(9999), vision: vGreen, user: null, crosswalk: null })
    expect(d.verdict).toBe(VERDICTS.WAIT)
  })
})
```

- [ ] **Step 2: 실패 확인**

Run: `npm test -- tests/core/decisionEngine.test.js`
Expected: FAIL

- [ ] **Step 3: 구현** — `src/core/decisionEngine.js`

```js
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
```

- [ ] **Step 4: 통과 확인**

Run: `npm test -- tests/core/decisionEngine.test.js`
Expected: PASS (전체 테스트)

- [ ] **Step 5: 전체 테스트 회귀 확인 후 커밋**

Run: `npm test`
Expected: 전부 PASS

```bash
git add src/core/decisionEngine.js tests/core/decisionEngine.test.js
git commit -m "feat(core): 이중검증 Fail-Safe 판정 엔진 — 기본값 WAIT, 불일치 전수 차단"
```

---

### Task 5: core/stabilizer — 비대칭 히스테리시스

**Files:**
- Create: `src/core/stabilizer.js`
- Test: `tests/core/stabilizer.test.js`

**Interfaces:**
- Consumes: `decide()` 결과 객체 (verdict/message 필드만 사용)
- Produces: `createStabilizer({ holdMs = 1500 } = {}) → { update(result, nowMs) → { result, changed } }`
  - WAIT/WARNING: 즉시 반영. CROSS/CAUTION: 동일 verdict가 `holdMs` 연속 유지될 때만 반영.
  - `changed`: 확정 결과의 verdict 또는 message가 직전과 달라진 순간 true (TTS 발화 트리거).

- [ ] **Step 1: 실패하는 테스트 작성** — `tests/core/stabilizer.test.js`

```js
import { describe, it, expect } from 'vitest'
import { createStabilizer } from '../../src/core/stabilizer.js'

const WAIT = { verdict: 'WAIT', message: '빨간불입니다. 대기하세요' }
const WAIT2 = { verdict: 'WAIT', message: '시간이 부족합니다' }
const CROSS = { verdict: 'CROSS', message: '지금 건너셔도 됩니다' }
const WARNING = { verdict: 'WARNING', message: '신호 없는 횡단보도입니다. 차량에 주의하세요' }

describe('stabilizer', () => {
  it('첫 WAIT은 즉시 확정 + changed', () => {
    const s = createStabilizer()
    const { result, changed } = s.update(WAIT, 0)
    expect(result.verdict).toBe('WAIT')
    expect(changed).toBe(true)
  })
  it('CROSS는 1.5초 유지 전까지 확정되지 않는다', () => {
    const s = createStabilizer()
    s.update(WAIT, 0)
    expect(s.update(CROSS, 100).result.verdict).toBe('WAIT')
    expect(s.update(CROSS, 1000).result.verdict).toBe('WAIT')
    const { result, changed } = s.update(CROSS, 1700)
    expect(result.verdict).toBe('CROSS')
    expect(changed).toBe(true)
  })
  it('CROSS 대기 중 1프레임 튐(WAIT) → 즉시 WAIT, hold 재시작', () => {
    const s = createStabilizer()
    s.update(WAIT, 0)
    s.update(CROSS, 100)
    const mid = s.update(WAIT, 800) // 안전 방향은 즉시
    expect(mid.result.verdict).toBe('WAIT')
    s.update(CROSS, 900)
    expect(s.update(CROSS, 2300).result.verdict).toBe('WAIT') // 900+1500=2400 미달
    expect(s.update(CROSS, 2500).result.verdict).toBe('CROSS')
  })
  it('WARNING은 즉시 반영', () => {
    const s = createStabilizer()
    s.update(WAIT, 0)
    const { result, changed } = s.update(WARNING, 100)
    expect(result.verdict).toBe('WARNING')
    expect(changed).toBe(true)
  })
  it('같은 WAIT 반복 → changed false, 메시지 다른 WAIT → changed true', () => {
    const s = createStabilizer()
    s.update(WAIT, 0)
    expect(s.update(WAIT, 500).changed).toBe(false)
    expect(s.update(WAIT2, 1000).changed).toBe(true)
  })
  it('null result → 현재 상태 유지, changed false', () => {
    const s = createStabilizer()
    s.update(WAIT, 0)
    const { result, changed } = s.update(null, 500)
    expect(result.verdict).toBe('WAIT')
    expect(changed).toBe(false)
  })
})
```

- [ ] **Step 2: 실패 확인**

Run: `npm test -- tests/core/stabilizer.test.js`
Expected: FAIL

- [ ] **Step 3: 구현** — `src/core/stabilizer.js`

```js
/**
 * 비대칭 히스테리시스: 허가 방향(CROSS/CAUTION)은 holdMs 연속 유지 시에만
 * 확정하고, 안전 방향(WAIT/WARNING)은 즉시 확정한다.
 */
const IMMEDIATE = new Set(['WAIT', 'WARNING'])

export function createStabilizer({ holdMs = 1500 } = {}) {
  let current = null
  let candidate = null
  let candidateSince = null

  const commit = (result) => {
    const changed =
      !current || current.verdict !== result.verdict || current.message !== result.message
    current = result
    candidate = null
    candidateSince = null
    return { result: current, changed }
  }

  return {
    update(result, nowMs) {
      if (!result) return { result: current, changed: false }

      if (IMMEDIATE.has(result.verdict)) return commit(result)

      // CROSS/CAUTION: holdMs 연속 유지 검사
      if (!candidate || candidate.verdict !== result.verdict) {
        candidate = result
        candidateSince = nowMs
        return { result: current, changed: false }
      }
      if (nowMs - candidateSince >= holdMs) return commit(result)
      return { result: current, changed: false }
    },
  }
}
```

- [ ] **Step 4: 통과 확인**

Run: `npm test -- tests/core/stabilizer.test.js`
Expected: PASS (6 tests)

- [ ] **Step 5: 커밋**

```bash
git add src/core/stabilizer.js tests/core/stabilizer.test.js
git commit -m "feat(core): 비대칭 히스테리시스 — 허가는 1.5초 유지 시, 안전 전환은 즉시"
```

---

### Task 6: vision/signalDetector — HSV 신호등 색 판별

**Files:**
- Create: `src/vision/signalDetector.js`
- Test: `tests/vision/signalDetector.test.js`

**Interfaces:**
- Produces:
  - `analyzeFrame(frame) → { color: 'green'|'red'|'unknown', confidence: Number }` — `frame`은 `{ data: Uint8ClampedArray, width, height }` 덕타입 (ImageData 그대로 또는 테스트용 일반 객체)
  - `rgbToHsv(r, g, b) → { h: 0~360, s: 0~1, v: 0~1 }`
  - `REGION_RATIO = 0.6` (상단 60%만 분석 — 신호등은 화면 위쪽)
- 판별: 상단 영역을 2px 간격 샘플링, 초록(h 100~200, s>0.35, v>0.35) / 빨강(h≤20 또는 h≥340, s>0.35, v>0.35) 픽셀 비율로 색·confidence 산출. 비율 0.3% 미만이면 unknown, 3% 이상이면 confidence 1.0.

- [ ] **Step 1: 실패하는 테스트 작성** — `tests/vision/signalDetector.test.js`

```js
import { describe, it, expect } from 'vitest'
import { analyzeFrame, rgbToHsv, REGION_RATIO } from '../../src/vision/signalDetector.js'

/** w×h 프레임을 base색으로 채우고, blocks[{x,y,w,h,rgb}]를 덧그린다 */
function makeFrame(width, height, baseRgb, blocks = []) {
  const data = new Uint8ClampedArray(width * height * 4)
  const put = (x, y, [r, g, b]) => {
    const i = (y * width + x) * 4
    data[i] = r; data[i + 1] = g; data[i + 2] = b; data[i + 3] = 255
  }
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) put(x, y, baseRgb)
  for (const bl of blocks)
    for (let y = bl.y; y < bl.y + bl.h; y++)
      for (let x = bl.x; x < bl.x + bl.w; x++) put(x, y, bl.rgb)
  return { data, width, height }
}

const GRAY = [128, 128, 128]
const GREEN = [0, 230, 120]   // 보행 신호 초록 (h≈151)
const RED = [255, 20, 40]     // 신호 빨강 (h≈355)

describe('rgbToHsv', () => {
  it('순수 초록/빨강/무채색 변환', () => {
    expect(rgbToHsv(0, 255, 0).h).toBeCloseTo(120, 0)
    expect(rgbToHsv(255, 0, 0).h).toBeCloseTo(0, 0)
    const gray = rgbToHsv(128, 128, 128)
    expect(gray.s).toBeCloseTo(0, 2)
  })
})

describe('analyzeFrame', () => {
  it('상단에 충분한 초록 광원 → green, confidence 1', () => {
    const f = makeFrame(100, 100, GRAY, [{ x: 40, y: 10, w: 20, h: 20, rgb: GREEN }])
    const r = analyzeFrame(f)
    expect(r.color).toBe('green')
    expect(r.confidence).toBeCloseTo(1, 1)
  })
  it('상단에 빨강 광원 → red', () => {
    const f = makeFrame(100, 100, GRAY, [{ x: 40, y: 10, w: 20, h: 20, rgb: RED }])
    expect(analyzeFrame(f).color).toBe('red')
  })
  it('무채색 화면 → unknown, confidence 0', () => {
    const r = analyzeFrame(makeFrame(100, 100, GRAY))
    expect(r.color).toBe('unknown')
    expect(r.confidence).toBe(0)
  })
  it('하단(REGION_RATIO 밖) 초록은 무시된다 — 신호등은 위쪽에 있다', () => {
    const yBelow = Math.floor(100 * REGION_RATIO) + 5
    const f = makeFrame(100, 100, GRAY, [{ x: 40, y: yBelow, w: 20, h: 20, rgb: GREEN }])
    expect(analyzeFrame(f).color).toBe('unknown')
  })
  it('아주 작은 초록(노이즈 수준) → unknown', () => {
    const f = makeFrame(100, 100, GRAY, [{ x: 50, y: 10, w: 2, h: 2, rgb: GREEN }])
    expect(analyzeFrame(f).color).toBe('unknown')
  })
  it('무효 입력 → unknown (Fail-Safe)', () => {
    expect(analyzeFrame(null).color).toBe('unknown')
    expect(analyzeFrame({}).color).toBe('unknown')
  })
})
```

- [ ] **Step 2: 실패 확인**

Run: `npm test -- tests/vision/signalDetector.test.js`
Expected: FAIL

- [ ] **Step 3: 구현** — `src/vision/signalDetector.js`

```js
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
```

- [ ] **Step 4: 통과 확인**

Run: `npm test -- tests/vision/signalDetector.test.js`
Expected: PASS (7 tests)

- [ ] **Step 5: 커밋**

```bash
git add src/vision/signalDetector.js tests/vision/signalDetector.test.js
git commit -m "feat(vision): HSV 기반 신호등 색 판별 — 불확실 시 unknown"
```

---

### Task 7: sources — mockCits + citsClient + Vite 프록시

**Files:**
- Create: `src/sources/mockCits.js`, `src/sources/citsClient.js`, `.env.local.example`
- Modify: `vite.config.js` (프록시 추가)
- Test: `tests/sources/mockCits.test.js`, `tests/sources/citsClient.test.js`

**Interfaces:**
- Produces:
  - `SCENARIOS = { NORMAL_GREEN, RED, MISMATCH, SHORT_TIME, OUTAGE }` (키 = 시나리오 id, 값 = `{ label, color, startSec, available }`)
  - `createMockCits(scenarioKey, createdMs) → { fetchSignal(nowMs) → { color, remainingSec, available, mock: true } }` — 생성 시점부터 실시간 카운트다운, 0 도달 시 색 반전(초록↔빨강, 30초 주기)
  - `fetchSignal({ itstId, dir = 'nt', timeoutMs = 3000, fetchFn = fetch }) → Promise<{ color, remainingSec, available }>` — 실호출. **모든 실패는 `{ available: false }`** (throw 금지 — 실패가 곧 Tier 2 강등 신호)
  - `parsePedSignal(item, dir = 'nt') → { color, remainingSec, available }` — 경찰청 실시간 신호 API 필드 규격: `{dir}PdsgStatNm`(보행신호 상태명: `'protected-Movement-Allowed'`→green, `'stop-And-Remain'`→red), `{dir}PdsgRmdrCs`(잔여시간, 1/10초 단위)

- [ ] **Step 1: mockCits 실패하는 테스트 작성** — `tests/sources/mockCits.test.js`

```js
import { describe, it, expect } from 'vitest'
import { createMockCits, SCENARIOS } from '../../src/sources/mockCits.js'

describe('mockCits', () => {
  it('NORMAL_GREEN: 초록 20초에서 실시간 카운트다운', () => {
    const m = createMockCits('NORMAL_GREEN', 0)
    expect(m.fetchSignal(0)).toMatchObject({ color: 'green', remainingSec: 20, available: true, mock: true })
    expect(m.fetchSignal(5000).remainingSec).toBe(15)
    expect(m.fetchSignal(19000).remainingSec).toBe(1)
  })
  it('0 도달 시 빨강 30초로 반전, 30초 후 다시 초록', () => {
    const m = createMockCits('NORMAL_GREEN', 0)
    expect(m.fetchSignal(20000)).toMatchObject({ color: 'red', remainingSec: 30 })
    expect(m.fetchSignal(49000).color).toBe('red')
    expect(m.fetchSignal(50000).color).toBe('green')
  })
  it('MISMATCH: C-ITS는 빨강 (비전이 초록이면 판정 엔진이 불일치 차단)', () => {
    expect(createMockCits('MISMATCH', 0).fetchSignal(0).color).toBe('red')
  })
  it('SHORT_TIME: 초록인데 잔여 8초 (필요 18.67초 미달)', () => {
    expect(createMockCits('SHORT_TIME', 0).fetchSignal(0)).toMatchObject({ color: 'green', remainingSec: 8 })
  })
  it('OUTAGE: available false → Tier 2 강등 유발', () => {
    expect(createMockCits('OUTAGE', 0).fetchSignal(0).available).toBe(false)
  })
  it('알 수 없는 시나리오 → OUTAGE와 동일 (Fail-Safe)', () => {
    expect(createMockCits('nope', 0).fetchSignal(0).available).toBe(false)
  })
  it('SCENARIOS에 5개 시나리오와 label 존재', () => {
    expect(Object.keys(SCENARIOS)).toEqual(['NORMAL_GREEN', 'RED', 'MISMATCH', 'SHORT_TIME', 'OUTAGE'])
    for (const s of Object.values(SCENARIOS)) expect(typeof s.label).toBe('string')
  })
})
```

- [ ] **Step 2: 실패 확인**

Run: `npm test -- tests/sources/mockCits.test.js`
Expected: FAIL

- [ ] **Step 3: mockCits 구현** — `src/sources/mockCits.js`

```js
/** 시연 시나리오용 모의 C-ITS. UI는 mock:true일 때 "모의 신호 주입 중" 배지를 띄운다. */
export const SCENARIOS = {
  NORMAL_GREEN: { label: '정상(초록 20초)', color: 'green', startSec: 20, available: true },
  RED: { label: '빨간불', color: 'red', startSec: 30, available: true },
  MISMATCH: { label: '불일치(C-ITS 빨강)', color: 'red', startSec: 25, available: true },
  SHORT_TIME: { label: '시간부족(잔여 8초)', color: 'green', startSec: 8, available: true },
  OUTAGE: { label: 'API 장애→Tier2', available: false },
}

const FLIP_SEC = 30
const flip = (c) => (c === 'green' ? 'red' : 'green')

export function createMockCits(scenarioKey, createdMs) {
  const sc = SCENARIOS[scenarioKey] ?? SCENARIOS.OUTAGE
  return {
    fetchSignal(nowMs) {
      if (sc.available !== true) return { color: 'unknown', remainingSec: 0, available: false, mock: true }
      const elapsed = Math.max(0, (nowMs - createdMs) / 1000)
      if (elapsed < sc.startSec) {
        return { color: sc.color, remainingSec: Math.ceil(sc.startSec - elapsed), available: true, mock: true }
      }
      const after = elapsed - sc.startSec
      const phases = Math.floor(after / FLIP_SEC)
      const color = phases % 2 === 0 ? flip(sc.color) : sc.color
      return { color, remainingSec: Math.ceil(FLIP_SEC - (after % FLIP_SEC)), available: true, mock: true }
    },
  }
}
```

- [ ] **Step 4: mockCits 통과 확인**

Run: `npm test -- tests/sources/mockCits.test.js`
Expected: PASS (7 tests)

- [ ] **Step 5: citsClient 실패하는 테스트 작성** — `tests/sources/citsClient.test.js`

```js
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
```

- [ ] **Step 6: 실패 확인**

Run: `npm test -- tests/sources/citsClient.test.js`
Expected: FAIL

- [ ] **Step 7: citsClient 구현** — `src/sources/citsClient.js`

```js
/**
 * 경찰청 C-ITS 실시간 보행신호 클라이언트.
 * 모든 실패는 { available: false }로 수렴한다 — throw하지 않는다.
 * 실패가 곧 tierResolver의 Tier 2 자동 강등 신호이기 때문이다.
 */
const STAT_MAP = {
  'protected-Movement-Allowed': 'green',
  'permissive-Movement-Allowed': 'green',
  'stop-And-Remain': 'red',
  'stop-Then-Proceed': 'red',
}

const UNAVAILABLE = { color: 'unknown', remainingSec: 0, available: false }

/** item의 방위별 보행신호 필드를 파싱. dir: nt|et|st|wt (북/동/남/서) */
export function parsePedSignal(item, dir = 'nt') {
  if (!item || typeof item !== 'object') return { ...UNAVAILABLE }
  const stat = item[`${dir}PdsgStatNm`]
  const rmdrCs = item[`${dir}PdsgRmdrCs`]
  const color = STAT_MAP[stat]
  if (!color || !Number.isFinite(Number(rmdrCs))) return { ...UNAVAILABLE }
  return { color, remainingSec: Number(rmdrCs) / 10, available: true }
}

export async function fetchSignal({ itstId, dir = 'nt', timeoutMs = 3000, fetchFn = fetch } = {}) {
  const ctrl = new AbortController()
  const timer = setTimeout(() => ctrl.abort(), timeoutMs)
  try {
    const res = await fetchFn(`/cits?itstId=${encodeURIComponent(itstId ?? '')}&type=json&numOfRows=1`, {
      signal: ctrl.signal,
    })
    if (!res.ok) return { ...UNAVAILABLE }
    const json = await res.json()
    let item = json?.response?.body?.items?.item
    if (Array.isArray(item)) item = item[0]
    return parsePedSignal(item, dir)
  } catch {
    return { ...UNAVAILABLE }
  } finally {
    clearTimeout(timer)
  }
}
```

- [ ] **Step 8: 통과 확인**

Run: `npm test -- tests/sources/citsClient.test.js`
Expected: PASS (9 tests)

- [ ] **Step 9: vite.config.js에 프록시 추가** (전체 교체)

```js
import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '')
  return {
    plugins: [
      react(),
      VitePWA({
        registerType: 'autoUpdate',
        manifest: {
          name: 'ClipSense Prototype',
          short_name: 'ClipSense',
          description: '시각장애인 횡단보도 보행 안전 보조 — 기술 검증용 프로토타입',
          theme_color: '#101418',
          background_color: '#101418',
          icons: [{ src: 'icon.svg', sizes: 'any', type: 'image/svg+xml' }],
        },
      }),
    ],
    server: {
      proxy: {
        // '/cits?...' → CITS_TARGET '?...&serviceKey=...' (키는 서버측 은닉)
        '/cits': {
          target: env.CITS_TARGET ?? 'http://localhost:9',
          changeOrigin: true,
          rewrite: (path) =>
            path.replace(/^\/cits/, env.CITS_PATH ?? '') + `&serviceKey=${env.CITS_KEY ?? ''}`,
        },
      },
    },
  }
})
```

- [ ] **Step 10: .env.local.example 작성**

```bash
# 실제 값은 .env.local에 작성 (git 미포함).
# CITS_TARGET: API 호스트 (예: https://apis.data.go.kr)
# CITS_PATH:   호스트 이하 경로 (예: /B552061/pdsgStat/getPdsgStat — 발급 문서의 실제 경로로 교체)
# CITS_KEY:    공공데이터포털 발급 serviceKey (URL 인코딩된 값)
# VITE_CITS_ITST_ID: 테스트 성공한 교차로 ID
CITS_TARGET=https://apis.data.go.kr
CITS_PATH=/CHANGE_ME
CITS_KEY=CHANGE_ME
VITE_CITS_ITST_ID=CHANGE_ME
```

- [ ] **Step 11: [사용자 확인 필요] 실호출 검증**

사용자에게 성공했던 호출의 **엔드포인트 URL·응답 JSON 샘플·교차로 ID**를 요청하고 `.env.local` 작성.
Run: `npm run dev` 후 `curl -s 'http://localhost:5173/cits?itstId=<교차로ID>&type=json&numOfRows=1'`
Expected: JSON 응답. **응답의 보행신호 필드명이 `parsePedSignal`의 `{dir}PdsgStatNm`/`{dir}PdsgRmdrCs` 규격과 다르면 STAT_MAP·필드명을 실제 응답에 맞춰 수정하고 테스트도 동기화** (이 스텝은 사용자 자료 도착 전이면 건너뛰고 다음 태스크 진행 — mock으로 개발 계속 가능. 도착 후 복귀).

- [ ] **Step 12: 전체 테스트 후 커밋**

Run: `npm test`
Expected: 전부 PASS

```bash
git add src/sources/ tests/sources/ vite.config.js .env.local.example
git commit -m "feat(sources): C-ITS 클라이언트(실패=Tier2 강등) + 시연용 모의 신호 + 프록시"
```

---

### Task 8: feedback — TTS 발화 관리 + 진동 패턴

**Files:**
- Create: `src/feedback/tts.js`, `src/feedback/haptic.js`
- Test: `tests/feedback/tts.test.js`, `tests/feedback/haptic.test.js`

**Interfaces:**
- Consumes: `decide()`의 `message`, `hapticPattern`
- Produces:
  - `createAnnouncer({ speak, cooldownMs = 4000 } = {}) → { announce(message, nowMs) → Boolean }` — 같은 메시지는 쿨다운 내 재발화 안 함(true=발화됨). 다른 메시지는 즉시 발화. `speak` 미주입 시 Web Speech API(ko-KR) 사용.
  - `PATTERNS = { cross: [800], caution: [200, 120, 200], warning: [120, 80, 120, 80, 120], wait: [400, 150, 400] }`
  - `vibrate(patternName, vibrateFn?) → Boolean` — Vibration API 없으면 false (데스크톱 무해)

- [ ] **Step 1: 실패하는 테스트 작성** — `tests/feedback/tts.test.js`

```js
import { describe, it, expect, vi } from 'vitest'
import { createAnnouncer } from '../../src/feedback/tts.js'

describe('announcer', () => {
  it('새 메시지는 발화, 같은 메시지는 쿨다운 내 침묵', () => {
    const speak = vi.fn()
    const a = createAnnouncer({ speak, cooldownMs: 4000 })
    expect(a.announce('지금 건너셔도 됩니다', 0)).toBe(true)
    expect(a.announce('지금 건너셔도 됩니다', 2000)).toBe(false)
    expect(speak).toHaveBeenCalledTimes(1)
  })
  it('쿨다운 경과 후 같은 메시지 재발화', () => {
    const speak = vi.fn()
    const a = createAnnouncer({ speak, cooldownMs: 4000 })
    a.announce('시간이 부족합니다', 0)
    expect(a.announce('시간이 부족합니다', 4100)).toBe(true)
    expect(speak).toHaveBeenCalledTimes(2)
  })
  it('다른 메시지는 쿨다운 무관 즉시 발화', () => {
    const speak = vi.fn()
    const a = createAnnouncer({ speak, cooldownMs: 4000 })
    a.announce('빨간불입니다. 대기하세요', 0)
    expect(a.announce('지금 건너셔도 됩니다', 500)).toBe(true)
  })
  it('빈 메시지는 발화하지 않음', () => {
    const speak = vi.fn()
    const a = createAnnouncer({ speak })
    expect(a.announce('', 0)).toBe(false)
    expect(a.announce(null, 0)).toBe(false)
    expect(speak).not.toHaveBeenCalled()
  })
})
```

`tests/feedback/haptic.test.js`:

```js
import { describe, it, expect, vi } from 'vitest'
import { PATTERNS, vibrate } from '../../src/feedback/haptic.js'

describe('haptic', () => {
  it('판정별 패턴이 정의되어 있다 (decide hapticPattern 키와 일치)', () => {
    expect(Object.keys(PATTERNS).sort()).toEqual(['caution', 'cross', 'wait', 'warning'])
    expect(PATTERNS.cross).toEqual([800])
  })
  it('vibrate는 패턴 배열로 주입 함수를 호출', () => {
    const fn = vi.fn(() => true)
    expect(vibrate('wait', fn)).toBe(true)
    expect(fn).toHaveBeenCalledWith([400, 150, 400])
  })
  it('알 수 없는 패턴/함수 없음 → false (무해)', () => {
    expect(vibrate('nope', vi.fn())).toBe(false)
    expect(vibrate('cross', undefined)).toBe(false)
  })
})
```

- [ ] **Step 2: 실패 확인**

Run: `npm test -- tests/feedback`
Expected: FAIL (두 파일 모두)

- [ ] **Step 3: 구현** — `src/feedback/tts.js`

```js
function defaultSpeak(message) {
  if (typeof speechSynthesis === 'undefined') return
  speechSynthesis.cancel() // 이전 안내 즉시 중단 — 최신 판정이 항상 우선
  const u = new SpeechSynthesisUtterance(message)
  u.lang = 'ko-KR'
  u.rate = 1.05
  speechSynthesis.speak(u)
}

/** 같은 안내의 기관총 반복을 막는 발화 관리자. 메시지가 바뀌면 즉시 발화. */
export function createAnnouncer({ speak = defaultSpeak, cooldownMs = 4000 } = {}) {
  let lastMessage = null
  let lastAt = -Infinity
  return {
    announce(message, nowMs) {
      if (!message) return false
      if (message === lastMessage && nowMs - lastAt < cooldownMs) return false
      lastMessage = message
      lastAt = nowMs
      speak(message)
      return true
    },
  }
}
```

`src/feedback/haptic.js`:

```js
/** 판정별 진동 패턴 (ms). decide()의 hapticPattern 키와 1:1. */
export const PATTERNS = {
  cross: [800],                       // 길고 부드럽게 — 안전 확인
  caution: [200, 120, 200],           // 짧게 두 번 — 경계
  warning: [120, 80, 120, 80, 120],   // 빠르게 세 번 — 경보
  wait: [400, 150, 400],              // 강하게 두 번 — 대기
}

export function vibrate(patternName, vibrateFn = globalThis.navigator?.vibrate?.bind(globalThis.navigator)) {
  const pattern = PATTERNS[patternName]
  if (!pattern || typeof vibrateFn !== 'function') return false
  vibrateFn(pattern)
  return true
}
```

- [ ] **Step 4: 통과 확인**

Run: `npm test -- tests/feedback`
Expected: PASS (7 tests)

- [ ] **Step 5: 커밋**

```bash
git add src/feedback/ tests/feedback/
git commit -m "feat(feedback): TTS 발화 쿨다운 관리 + 판정별 진동 패턴"
```

---

### Task 9: sources/videoSource + ui/CameraView — 영상 입력 어댑터

**Files:**
- Create: `src/sources/videoSource.js`, `src/ui/CameraView.jsx`

**Interfaces:**
- Consumes: `analyzeFrame` (Task 6)
- Produces:
  - `startCamera(videoEl) → Promise<MediaStream>` (후면 카메라 우선)
  - `stopStream(stream)`
  - `grabFrame(el, canvas) → { data, width, height } | null` — video/img 요소를 320px 폭으로 캔버스에 그려 ImageData 반환
  - `<CameraView mode={'camera'|'esp32'} espUrl={String} onVision={(result) => {}} />` — 300ms 간격으로 `analyzeFrame` 실행해 `onVision` 콜백. REGION_RATIO 경계선 오버레이 표시. ESP32 모드는 MJPEG `<img>` 소스 사용 (**보너스 자리** — URL만 꽂으면 동작).

- [ ] **Step 1: videoSource 구현** — `src/sources/videoSource.js` (브라우저 API 래퍼 — 자동 테스트 대신 Step 3 수동 검증)

```js
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
```

- [ ] **Step 2: CameraView 구현** — `src/ui/CameraView.jsx`

```jsx
import { useEffect, useRef, useState } from 'react'
import { analyzeFrame, REGION_RATIO } from '../vision/signalDetector.js'
import { startCamera, stopStream, grabFrame } from '../sources/videoSource.js'

const ANALYZE_MS = 300

export default function CameraView({ mode, espUrl, onVision }) {
  const videoRef = useRef(null)
  const imgRef = useRef(null)
  const canvasRef = useRef(document.createElement('canvas'))
  const onVisionRef = useRef(onVision)
  onVisionRef.current = onVision
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
      // 프레임 없음 = 불확실 = unknown → 판정 엔진이 WAIT 처리
      onVisionRef.current(frame ? analyzeFrame(frame) : { color: 'unknown', confidence: 0 })
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
```

- [ ] **Step 3: 수동 검증** (App.jsx에 임시로 `<CameraView mode="camera" onVision={(v) => console.log(v)} />` 추가)

Run: `npm run dev` → 브라우저에서 http://localhost:5173 열기 → 카메라 허용
Expected: ① 카메라 영상 표시 ② 60% 지점에 분석 경계선 ③ 콘솔에 300ms 간격 `{color, confidence}` ④ 폰/모니터에 초록 이미지를 비추면 `color: 'green'` 전환. 확인 후 임시 코드 제거.

- [ ] **Step 4: 회귀 확인 후 커밋**

Run: `npm test`
Expected: 전부 PASS

```bash
git add src/sources/videoSource.js src/ui/CameraView.jsx src/App.jsx
git commit -m "feat(video): 카메라/ESP32 영상 어댑터 + 분석 영역 오버레이"
```

---

### Task 10: UI 통합 — VerifyPanel · GuidePanel · ScenarioBar · App 오케스트레이션

**Files:**
- Create: `src/ui/VerifyPanel.jsx`, `src/ui/GuidePanel.jsx`, `src/ui/ScenarioBar.jsx`
- Modify: `src/App.jsx` (전면 교체), `src/App.css` (전면 교체)

**Interfaces:**
- Consumes: Task 2~9의 모든 export (정확한 시그니처는 각 태스크 Interfaces 참조)
- Produces: 500ms 판정 루프 — `(mock|실호출) C-ITS + 최신 비전 → resolveTier → decide → stabilizer → 화면/TTS/진동`

- [ ] **Step 1: VerifyPanel 작성** — `src/ui/VerifyPanel.jsx`

```jsx
const DOT = { green: '🟢', red: '🔴', unknown: '⚪' }

export default function VerifyPanel({ cits, vision, tier, needSec }) {
  return (
    <section className="verify-panel" aria-label="검증 현황">
      <h2>이중 검증 현황 <span className={`tier-badge tier-${tier}`}>Tier {tier}</span></h2>
      <div className="verify-row">
        <span className="src-name">C-ITS 신호</span>
        {cits?.available ? (
          <span>{DOT[cits.color]} {cits.color === 'green' ? '초록' : cits.color === 'red' ? '빨강' : '불명'} · 잔여 {Math.round(cits.remainingSec)}초</span>
        ) : (
          <span className="src-down">⛔ 수신 불가 (Tier 2 강등)</span>
        )}
        {cits?.mock && <span className="mock-badge">모의 신호 주입 중</span>}
      </div>
      <div className="verify-row">
        <span className="src-name">비전 AI</span>
        <span>{DOT[vision?.color ?? 'unknown']} {vision?.color === 'green' ? '초록' : vision?.color === 'red' ? '빨강' : '불명'} · conf {(vision?.confidence ?? 0).toFixed(2)}</span>
      </div>
      <div className="verify-row">
        <span className="src-name">필요 횡단시간</span>
        <span>{needSec === Infinity ? '—' : `${needSec.toFixed(1)}초`} (0.6m/s × 10m + 여유 2초)</span>
      </div>
    </section>
  )
}
```

- [ ] **Step 2: GuidePanel 작성** — `src/ui/GuidePanel.jsx`

```jsx
import { PATTERNS } from '../feedback/haptic.js'

export default function GuidePanel({ decision }) {
  const verdict = decision?.verdict ?? 'WAIT'
  const pattern = PATTERNS[decision?.hapticPattern] ?? []
  return (
    <section className={`guide-panel guide-${verdict.toLowerCase()}`} aria-live="assertive">
      <div className="guide-message">{decision?.message ?? '시스템 준비 중입니다. 대기하세요'}</div>
      <div className="guide-meta">
        <span>판정: {verdict}</span>
        <span>사유: {decision?.reason ?? '-'}</span>
        <span className="haptic-viz" title="진동 패턴">
          📳 {pattern.map((ms, i) => (
            <i key={i} className={i % 2 === 0 ? 'buzz' : 'gap'} style={{ width: `${ms / 12}px` }} />
          ))}
        </span>
      </div>
    </section>
  )
}
```

- [ ] **Step 3: ScenarioBar 작성** — `src/ui/ScenarioBar.jsx`

```jsx
import { SCENARIOS } from '../sources/mockCits.js'

export default function ScenarioBar({ scenario, setScenario, noSignal, setNoSignal, videoMode, setVideoMode, espUrl, setEspUrl }) {
  return (
    <section className="scenario-bar" aria-label="시연 시나리오">
      <div className="row">
        <span className="row-label">C-ITS 소스</span>
        <button className={scenario === 'LIVE' ? 'on' : ''} onClick={() => setScenario('LIVE')}>실데이터</button>
        {Object.entries(SCENARIOS).map(([key, { label }]) => (
          <button key={key} className={scenario === key ? 'on' : ''} onClick={() => setScenario(key)}>{label}</button>
        ))}
        <button className={noSignal ? 'on danger' : 'danger'} onClick={() => setNoSignal(!noSignal)}>무신호 T3</button>
      </div>
      <div className="row">
        <span className="row-label">영상 소스</span>
        <button className={videoMode === 'camera' ? 'on' : ''} onClick={() => setVideoMode('camera')}>내장 카메라</button>
        <button className={videoMode === 'esp32' ? 'on' : ''} onClick={() => setVideoMode('esp32')}>ESP32 클립캠</button>
        {videoMode === 'esp32' && (
          <input value={espUrl} onChange={(e) => setEspUrl(e.target.value)} placeholder="http://<esp32-ip>/stream" />
        )}
      </div>
    </section>
  )
}
```

- [ ] **Step 4: App.jsx 전면 교체**

```jsx
import { useEffect, useRef, useState } from 'react'
import { resolveTier } from './core/tierResolver.js'
import { decide } from './core/decisionEngine.js'
import { createStabilizer } from './core/stabilizer.js'
import { requiredCrossingSec } from './core/crossingTime.js'
import { createMockCits } from './sources/mockCits.js'
import { fetchSignal } from './sources/citsClient.js'
import { createAnnouncer } from './feedback/tts.js'
import { vibrate } from './feedback/haptic.js'
import CameraView from './ui/CameraView.jsx'
import VerifyPanel from './ui/VerifyPanel.jsx'
import GuidePanel from './ui/GuidePanel.jsx'
import ScenarioBar from './ui/ScenarioBar.jsx'
import './App.css'

const USER = { walkingSpeedMps: 0.6 }   // 고령자·청각장애 중복 수혜자 기준
const CROSSWALK = { lengthM: 10 }
const TICK_MS = 500
const NEED_SEC = requiredCrossingSec({ ...CROSSWALK, ...USER })

export default function App() {
  const [scenario, setScenario] = useState('NORMAL_GREEN')
  const [noSignal, setNoSignal] = useState(false)
  const [videoMode, setVideoMode] = useState('camera')
  const [espUrl, setEspUrl] = useState('')
  const [cits, setCits] = useState(null)
  const [vision, setVision] = useState({ color: 'unknown', confidence: 0 })
  const [tier, setTier] = useState(2)
  const [decision, setDecision] = useState(null)

  const visionRef = useRef(vision)
  const mockRef = useRef(createMockCits(scenario, Date.now()))
  const stabRef = useRef(createStabilizer())
  const announcerRef = useRef(createAnnouncer())
  const busyRef = useRef(false)

  useEffect(() => {
    if (scenario !== 'LIVE') mockRef.current = createMockCits(scenario, Date.now())
  }, [scenario])

  useEffect(() => {
    const id = setInterval(async () => {
      if (busyRef.current) return // LIVE fetch가 tick보다 느릴 때 중첩 방지
      busyRef.current = true
      try {
        const now = Date.now()
        const citsState = scenario === 'LIVE'
          ? await fetchSignal({ itstId: import.meta.env.VITE_CITS_ITST_ID })
          : mockRef.current.fetchSignal(now)
        const v = visionRef.current
        const t = resolveTier({ citsAvailable: citsState?.available === true, noSignalMode: noSignal })
        const d = decide({ tier: t, cits: citsState, vision: v, user: USER, crosswalk: CROSSWALK })
        const { result, changed } = stabRef.current.update(d, now)
        setCits(citsState); setVision(v); setTier(t); setDecision(result)
        if (changed && result && announcerRef.current.announce(result.message, now)) {
          vibrate(result.hapticPattern)
        }
      } finally {
        busyRef.current = false
      }
    }, TICK_MS)
    return () => clearInterval(id)
  }, [scenario, noSignal])

  return (
    <div className="app">
      <div className="safety-banner">
        ⚠️ 본 프로토타입은 기술 검증용 시연이며 실제 보행 판단에 사용할 수 없습니다
      </div>
      <header className="app-header">
        <h1>ClipSense</h1>
        <p>C-ITS × 비전 AI 이중검증 · Fail-Safe 횡단 보조 — 기술 검증 프로토타입</p>
      </header>
      <main className="main-grid">
        <CameraView mode={videoMode} espUrl={espUrl} onVision={(v) => { visionRef.current = v }} />
        <VerifyPanel cits={cits} vision={vision} tier={tier} needSec={NEED_SEC} />
      </main>
      <GuidePanel decision={decision} />
      <ScenarioBar
        scenario={scenario} setScenario={setScenario}
        noSignal={noSignal} setNoSignal={setNoSignal}
        videoMode={videoMode} setVideoMode={setVideoMode}
        espUrl={espUrl} setEspUrl={setEspUrl}
      />
    </div>
  )
}
```

- [ ] **Step 5: App.css 전면 교체** (고대비 다크, 판정별 색상)

```css
* { box-sizing: border-box; }
body { margin: 0; background: #101418; color: #f5f7fa; font-family: 'Apple SD Gothic Neo', 'Pretendard', sans-serif; }
.app { max-width: 1100px; margin: 0 auto; padding-bottom: 24px; }

.safety-banner { background: #ffd600; color: #000; font-weight: 800; padding: 10px 16px; text-align: center; font-size: 15px; }
.app-header { padding: 16px 20px 4px; }
.app-header h1 { margin: 0; font-size: 28px; letter-spacing: 1px; }
.app-header p { margin: 4px 0 0; color: #9aa7b5; font-size: 14px; }

.main-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; padding: 16px 20px; }
@media (max-width: 800px) { .main-grid { grid-template-columns: 1fr; } }

.camera-view { position: relative; background: #000; border-radius: 12px; overflow: hidden; min-height: 260px; }
.camera-view video, .camera-view img { width: 100%; height: 100%; object-fit: cover; display: block; }
.region-line { position: absolute; left: 0; right: 0; border-top: 2px dashed #ffd600; }
.region-label { position: absolute; right: 8px; bottom: 8px; font-size: 12px; color: #ffd600; background: rgba(0,0,0,.55); padding: 2px 8px; border-radius: 6px; }
.camera-error { position: absolute; inset: 0; display: grid; place-items: center; background: rgba(0,0,0,.8); color: #ff8a80; padding: 20px; text-align: center; }

.verify-panel { background: #1a2027; border-radius: 12px; padding: 16px 20px; }
.verify-panel h2 { margin: 0 0 12px; font-size: 18px; display: flex; align-items: center; gap: 10px; }
.tier-badge { font-size: 13px; padding: 3px 10px; border-radius: 20px; font-weight: 700; }
.tier-1 { background: #00e676; color: #003316; }
.tier-2 { background: #ffb300; color: #332200; }
.tier-3 { background: #ff5722; color: #fff; }
.verify-row { display: flex; align-items: center; gap: 12px; padding: 10px 0; border-top: 1px solid #2a323c; font-size: 16px; flex-wrap: wrap; }
.src-name { color: #9aa7b5; min-width: 110px; font-size: 14px; }
.src-down { color: #ff8a80; font-weight: 700; }
.mock-badge { background: #7c4dff; color: #fff; font-size: 12px; padding: 2px 10px; border-radius: 20px; font-weight: 700; }

.guide-panel { margin: 0 20px; border-radius: 16px; padding: 28px 24px; text-align: center; transition: background .3s; }
.guide-message { font-size: clamp(28px, 5vw, 44px); font-weight: 900; line-height: 1.25; }
.guide-meta { margin-top: 10px; display: flex; gap: 18px; justify-content: center; font-size: 14px; opacity: .85; flex-wrap: wrap; align-items: center; }
.guide-cross { background: #00c853; color: #00210d; }
.guide-caution { background: #ffb300; color: #2b1d00; }
.guide-warning { background: #ff5722; color: #fff; }
.guide-wait { background: #d50000; color: #fff; }
.haptic-viz { display: inline-flex; align-items: center; gap: 2px; }
.haptic-viz i { display: inline-block; height: 10px; border-radius: 3px; }
.haptic-viz .buzz { background: currentColor; }
.haptic-viz .gap { background: transparent; }

.scenario-bar { margin: 16px 20px 0; background: #1a2027; border-radius: 12px; padding: 12px 16px; }
.scenario-bar .row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; padding: 6px 0; }
.row-label { color: #9aa7b5; font-size: 13px; min-width: 80px; }
.scenario-bar button { background: #2a323c; color: #dfe7ef; border: 1px solid #3a4450; border-radius: 8px; padding: 8px 14px; font-size: 14px; cursor: pointer; }
.scenario-bar button.on { background: #2962ff; border-color: #2962ff; color: #fff; font-weight: 700; }
.scenario-bar button.danger.on { background: #ff5722; border-color: #ff5722; }
.scenario-bar input { background: #101418; color: #dfe7ef; border: 1px solid #3a4450; border-radius: 8px; padding: 8px 12px; min-width: 240px; }
```

- [ ] **Step 6: 3막 시나리오 수동 검증**

Run: `npm run dev` → 브라우저 열기 → 카메라 허용. 각 버튼별 기대 결과:

| 조작 | 기대 결과 |
|------|-----------|
| `정상(초록 20초)` + 카메라에 초록 이미지 | 1.5초 후 초록 배경 "지금 건너셔도 됩니다" + TTS. 잔여 18.67초 미만이 되는 순간 "시간이 부족합니다" WAIT로 즉시 전환 |
| `불일치(C-ITS 빨강)` + 카메라 초록 유지 | 빨간 배경 "빨간불입니다. 대기하세요" (RED_SIGNAL — 즉시) |
| `시간부족(잔여 8초)` + 초록 | "시간이 부족합니다" WAIT |
| `API 장애→Tier2` + 초록 | Tier 배지 2로 강등 + (conf≥0.75면) 호박색 "초록불로 보입니다. 주변 확인 후 진행하세요" |
| `무신호 T3` 토글 | 주황 배경 "신호 없는 횡단보도입니다. 차량에 주의하세요" |
| 카메라를 가리거나 회색 벽 비춤 | 어떤 시나리오든 WAIT 계열로 수렴 |

Expected: 표 전부 일치. TTS가 한국어로 발화되고 같은 안내는 4초 내 반복되지 않음.

- [ ] **Step 7: 회귀 확인 후 커밋**

Run: `npm test`
Expected: 전부 PASS

```bash
git add src/ui/ src/App.jsx src/App.css
git commit -m "feat(ui): 이중검증 화면 통합 — 검증현황·판정·시나리오 원클릭 주입"
```

---

### Task 11: README + 시연 촬영 체크리스트 + 최종 검증

**Files:**
- Create: `README.md`, `docs/demo-checklist.md`

**Interfaces:**
- Consumes: 전체 태스크 결과물
- Produces: 실행법·시연 촬영 절차 문서. 발표자료 제작 시 이 체크리스트의 장면 번호를 그대로 인용.

- [ ] **Step 1: README.md 작성**

```markdown
# ClipSense 프로토타입

옷깃 클립 카메라 × 경찰청 C-ITS × 비전 AI 이중검증 — 시각장애인 횡단보도 보행 안전 보조 시스템의 기술 검증용 웹 프로토타입 (React + Vite + PWA).

> ⚠️ 본 프로토타입은 기술 검증용 시연이며 실제 보행 판단에 사용할 수 없습니다.

## 실행

​```bash
npm install
npm run dev        # http://localhost:5173
npm test           # core/vision/sources/feedback 단위 테스트
​```

## C-ITS 실데이터 연동 (선택)

`.env.local.example`을 `.env.local`로 복사해 발급받은 serviceKey·경로·교차로 ID를 입력.
미설정 시에도 모의 시나리오로 전체 기능 시연 가능 (화면에 "모의 신호 주입 중" 표시).

## 구조

- `src/core/` — 판정 로직 (순수 함수, 기본값 WAIT Fail-Safe). Vitest 검증
- `src/sources/` — C-ITS 실호출/모의, 카메라/ESP32 영상 어댑터
- `src/vision/` — HSV 신호등 색 판별
- `src/feedback/` — TTS(ko-KR)·진동 패턴
- `src/ui/` — 검증 현황·판정·시나리오 화면
```

- [ ] **Step 2: docs/demo-checklist.md 작성**

```markdown
# 시연 영상 촬영 체크리스트 (3막, 목표 90초)

사전 준비: `npm run dev` 구동, 화면 녹화 시작(브라우저 탭 + 시스템 오디오),
보조 모니터/폰에 보행 신호등 초록·빨강 이미지 준비, TTS 볼륨 확인.

## 1막 — 정상 이중검증 (약 30초)
1. [ ] 안전 고지 배너가 보이는 전체 화면에서 시작
2. [ ] (실데이터 연동 시) `실데이터` 클릭 → VerifyPanel에 실제 C-ITS 수신 표시
       (미연동 시) `정상(초록 20초)` 클릭 — "모의 신호 주입 중" 배지 정직하게 노출
3. [ ] 카메라에 초록 신호 이미지 → 비전 🟢 conf 표시
4. [ ] 1.5초 유지 후 초록 배경 "지금 건너셔도 됩니다" + TTS
5. [ ] 잔여시간이 필요시간(18.7초) 아래로 떨어지는 순간 → 자동으로 "시간이 부족합니다" WAIT
       ★ 나레이션: "초록불이어도 완주할 수 없으면 건너라고 하지 않습니다"

## 2막 — Fail-Safe (약 30초) ★ 하이라이트
6. [ ] 카메라는 초록 유지한 채 `불일치(C-ITS 빨강)` 클릭
7. [ ] 즉시 빨간 배경 WAIT — ★ 나레이션: "비전 AI가 초록이라고 해도, 저희는 건너라고 하지 않습니다"
8. [ ] `시간부족(잔여 8초)` 클릭 → "시간이 부족합니다"

## 3막 — Tier 자동 강등 (약 30초)
9. [ ] `API 장애→Tier2` 클릭 → Tier 배지 1→2 강등, "초록불로 보입니다. 주변 확인 후 진행하세요" (CROSS 아님)
10. [ ] `무신호 T3` 토글 → 주황 경보 "신호 없는 횡단보도입니다. 차량에 주의하세요"
11. [ ] 카메라 가림 → 어떤 상태든 WAIT 수렴으로 마무리

## 보너스 (ESP32 셋업 성공 시에만)
12. [ ] `ESP32 클립캠` 선택 + 스트림 URL 입력 → 실물 클립캠 영상으로 1~2막 반복
```

- [ ] **Step 3: 최종 전체 검증**

Run: `npm test`
Expected: 전체 테스트 PASS (core 4 파일 + vision 1 + sources 2 + feedback 2)
Run: `npm run build`
Expected: 빌드 성공 (`dist/` 생성, PWA manifest 포함)

- [ ] **Step 4: 커밋**

```bash
git add README.md docs/demo-checklist.md
git commit -m "docs: 실행 안내 + 시연 촬영 3막 체크리스트"
```

---

## Self-Review 결과

- **스펙 커버리지**: 판정 엔진 표(T4), Tier 강등(T3·T7), 잔여시간 검증(T2·T4), 히스테리시스(T5), HSV 비전(T6), C-ITS 실호출+mock(T7), TTS·진동(T8), 카메라/ESP32 토글(T9), UI 3패널+안전고지(T1·T10), 3막 시연(T11), PWA(T1), 테스트 계획 §10(T2~T8) — 전부 매핑됨. TF.js 보조는 스펙상 "여유 시"이므로 계획 제외 (전 태스크 완료 후 시간 남으면 별도 논의).
- **타입 일관성**: `hapticPattern` 키(`cross|caution|warning|wait`)가 T4 decide ↔ T8 PATTERNS ↔ T10 GuidePanel에서 일치. `{color, remainingSec, available}` 형태가 T7 mock/실호출 ↔ T4 decide에서 일치. `walkingSpeedMps` 명칭 T2↔T4↔T10 일치.
- **미결 의존**: T7 Step 11만 사용자 자료(엔드포인트·샘플 JSON·교차로 ID) 필요 — 건너뛰기 가능하게 설계됨.
```
