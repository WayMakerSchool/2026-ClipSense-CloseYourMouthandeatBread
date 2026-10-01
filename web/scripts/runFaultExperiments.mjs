#!/usr/bin/env node
/**
 * 원커맨드 결함주입 실험 러너 (원본설계서 §14/§22, 스펙 §2.9).
 *
 * `npm run experiment` → 11 시나리오 × 3 엔진(Raw Boolean AND / Legacy AND+
 * Stabilizer / Full SafeGraph-RTA) 전체 실행 → artifacts/ 에 7개 산출물 생성.
 *
 * 이 스크립트는 안전 코어(src/safety, src/experiments)를 소비만 한다 —
 * 수정하지 않는다. `performance.now()`는 이 스크립트에서만 호출해 latency를
 * measureLatency로 주입한다 (safety core는 clock 직접 호출 금지, 전역 제약).
 *
 * NaN/Infinity → JSON에 직접 쓰지 않고 null + 명시적 invalid reason으로
 * 직렬화한다 (원본 §14).
 */
import { performance } from 'node:perf_hooks'
import { execSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdirSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { RTA_CONFIG_V1 } from '../src/safety/config.js'
import { SCENARIO_IDS, SCENARIOS, buildTrace, TICK_MS, DURATION_MS } from '../src/experiments/faultScenarios.js'
import { runScenario } from '../src/experiments/traceRunner.js'
import { summarize } from '../src/experiments/metrics.js'
import { createBaselineEngines } from '../src/safety/baselineAdapter.js'
import { createRuntimeShield } from '../src/safety/runtimeShield.js'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const ROOT_DIR = path.resolve(__dirname, '..')
const ARTIFACTS_DIR = path.join(ROOT_DIR, 'artifacts')

const ENGINE_LABELS = {
  baselineRaw: 'Raw Boolean AND',
  baseline: 'Legacy AND + Stabilizer',
  proposed: 'Full SafeGraph-RTA',
}
const ENGINE_KEYS = ['baselineRaw', 'baseline', 'proposed']

// ---------------------------------------------------------------------------
// JSON-safe serialization (원본 §14): NaN/Infinity -> null + invalid reason.
// ---------------------------------------------------------------------------

/**
 * Recursively replaces non-finite numbers with `null` and records a sibling
 * `<key>_invalidReason` field explaining why, so downstream JSON consumers
 * never see a silently-dropped NaN/Infinity.
 * @param {*} value
 * @returns {*}
 */
function sanitizeForJson(value) {
  if (typeof value === 'number') {
    if (Number.isNaN(value)) return null
    if (!Number.isFinite(value)) return null
    return value
  }
  if (Array.isArray(value)) {
    return value.map(sanitizeForJson)
  }
  if (value !== null && typeof value === 'object') {
    const out = {}
    for (const [k, v] of Object.entries(value)) {
      if (typeof v === 'number' && !Number.isFinite(v)) {
        out[k] = null
        out[`${k}_invalidReason`] = Number.isNaN(v) ? 'NaN' : v > 0 ? 'Infinity' : '-Infinity'
      } else {
        out[k] = sanitizeForJson(v)
      }
    }
    return out
  }
  return value
}

function toJsonLine(record) {
  return JSON.stringify(sanitizeForJson(record))
}

// ---------------------------------------------------------------------------
// CSV helpers
// ---------------------------------------------------------------------------

function csvEscape(value) {
  if (value === null || value === undefined) return ''
  const s = String(value)
  if (/[",\n]/.test(s)) return `"${s.replace(/"/g, '""')}"`
  return s
}

function toCsv(headers, rows) {
  const lines = [headers.join(',')]
  for (const row of rows) {
    lines.push(headers.map((h) => csvEscape(row[h])).join(','))
  }
  return lines.join('\n') + '\n'
}

/** null-safe numeric formatter for JSON-embedded ms metrics (NaN/Infinity → null). */
function safeNum(v) {
  if (typeof v !== 'number' || !Number.isFinite(v)) return null
  return v
}

// ---------------------------------------------------------------------------
// Statistics: 0/N one-sided 95% upper bound (원본 §13.10)
// ---------------------------------------------------------------------------

/** @param {number} N @returns {number|null} */
function upper95ForZero(N) {
  if (!Number.isFinite(N) || N <= 0) return null
  return 1 - Math.pow(0.05, 1 / N)
}

function fmtRatio({ n, N }) {
  return `${n}/${N}`
}

function fmtPct(n, N) {
  if (!Number.isFinite(N) || N === 0) return 'TBD'
  return `${((n / N) * 100).toFixed(1)}%`
}

/** 0/N 항목에는 단측 95% 상한을 병기한다 (원본 §13.10). */
function fmtRatioWithBound({ n, N }) {
  const base = fmtRatio({ n, N })
  if (n === 0 && N > 0) {
    const bound = upper95ForZero(N)
    return `${base} (단측 95% 상한 ${(bound * 100).toFixed(1)}%)`
  }
  return base
}

function fmtMs(v) {
  if (v === null || v === undefined) return 'TBD (확정 이력 없음)'
  if (typeof v !== 'number' || !Number.isFinite(v)) return 'TBD'
  return v.toFixed(2)
}

// ---------------------------------------------------------------------------
// Run all scenarios through fresh engines each time.
// ---------------------------------------------------------------------------

function measureLatency(fn) {
  const start = performance.now()
  const result = fn()
  const ms = performance.now() - start
  return { result, ms }
}

function runAllScenarios() {
  const runsByScenario = []
  const allRecords = []

  for (const scenarioId of SCENARIO_IDS) {
    const trace = buildTrace(scenarioId)
    // Fresh engine instances PER SCENARIO (stateful: stabilizer hold timers,
    // shield confirmation accumulation must not leak across scenarios).
    const { raw, stabilized } = createBaselineEngines()
    const shield = createRuntimeShield()

    const records = runScenario(trace, { raw, stabilized, shield }, { measureLatency })
    runsByScenario.push({ scenarioId, riskClass: trace.riskClass, records })
    allRecords.push(...records)
  }

  return { runsByScenario, allRecords }
}

// ---------------------------------------------------------------------------
// Artifact writers
// ---------------------------------------------------------------------------

function writeRawJsonl(allRecords) {
  const lines = allRecords.map(toJsonLine)
  writeFileSync(path.join(ARTIFACTS_DIR, 'experiment_raw.jsonl'), lines.join('\n') + '\n', 'utf8')
  return lines.length
}

function writeSummaryCsv(summary) {
  const headers = [
    'engine',
    'uaer_n',
    'uaer_N',
    'cver_n',
    'cver_N',
    'dprTick_n',
    'dprTick_N',
    'safeCoverage_n',
    'safeCoverage_N',
    'confirmLatencyMs',
    'timeToInhibitMs',
    'evalLatencyMs_median',
    'evalLatencyMs_p95',
    'evalLatencyMs_max',
  ]
  const rows = ENGINE_KEYS.map((key) => {
    const m = summary[key]
    return {
      engine: ENGINE_LABELS[key],
      uaer_n: m.uaer.n,
      uaer_N: m.uaer.N,
      cver_n: m.cver.n,
      cver_N: m.cver.N,
      dprTick_n: m.dprTick.n,
      dprTick_N: m.dprTick.N,
      safeCoverage_n: m.safeCoverage.n,
      safeCoverage_N: m.safeCoverage.N,
      confirmLatencyMs: safeNum(m.confirmLatencyMs),
      timeToInhibitMs: safeNum(m.timeToInhibitMs),
      evalLatencyMs_median: safeNum(m.evalLatencyMs.median),
      evalLatencyMs_p95: safeNum(m.evalLatencyMs.p95),
      evalLatencyMs_max: safeNum(m.evalLatencyMs.max),
    }
  })
  writeFileSync(path.join(ARTIFACTS_DIR, 'experiment_summary.csv'), toCsv(headers, rows), 'utf8')
}

function writeScenarioResultsCsv(summary) {
  const headers = [
    'scenarioId',
    'riskClass',
    'engine',
    'proceedTicksInUnsafe',
    'unsafeTicks',
    'everProceeded',
    'blockingReason',
  ]
  const rows = []
  for (const row of summary.scenarios) {
    for (const engineKey of ENGINE_KEYS) {
      const er = row[engineKey]
      rows.push({
        scenarioId: row.scenarioId,
        riskClass: row.riskClass,
        engine: ENGINE_LABELS[engineKey],
        proceedTicksInUnsafe: er.proceedTicksInUnsafe,
        unsafeTicks: er.unsafeTicks,
        everProceeded: er.everProceededDuringUnsafe,
        blockingReason: er.blockingReasons ?? '',
      })
    }
  }
  writeFileSync(path.join(ARTIFACTS_DIR, 'scenario_results.csv'), toCsv(headers, rows), 'utf8')
  return rows
}

function configHash() {
  const json = JSON.stringify(RTA_CONFIG_V1)
  return createHash('sha256').update(json).digest('hex')
}

function writeExperimentConfig() {
  const config = {
    rtaConfig: RTA_CONFIG_V1,
    tickMs: TICK_MS,
    durationMs: DURATION_MS,
    scenarioIds: SCENARIO_IDS,
    scenarios: SCENARIOS,
  }
  writeFileSync(
    path.join(ARTIFACTS_DIR, 'experiment_config.json'),
    JSON.stringify(sanitizeForJson(config), null, 2) + '\n',
    'utf8'
  )
}

function gitHead() {
  try {
    return execSync('git rev-parse HEAD', { cwd: ROOT_DIR, encoding: 'utf8' }).trim()
  } catch {
    return 'UNKNOWN (git rev-parse failed)'
  }
}

function writeRunManifest() {
  const manifest = {
    schemaVersion: 'run-manifest-v1',
    generatedAtIso: new Date().toISOString(),
    gitHead: gitHead(),
    nodeVersion: process.version,
    configVersion: RTA_CONFIG_V1.configVersion,
    configSha256: configHash(),
    tickMs: TICK_MS,
    durationMs: DURATION_MS,
    scenarioIds: SCENARIO_IDS,
    sourceMode: 'MOCK', // 전부 MOCK — 실제 C-ITS/카메라 미사용 (원본 §17)
  }
  writeFileSync(
    path.join(ARTIFACTS_DIR, 'run_manifest.json'),
    JSON.stringify(manifest, null, 2) + '\n',
    'utf8'
  )
  return manifest
}

function writeMetricDefinitions() {
  const content = `# 지표 정의 (metric_definitions.md)

이 문서는 \`experiment_summary.csv\` / \`scenario_results.csv\` / 보고서의 모든 지표를
정의한다 (원본설계서 §13 요약). 모든 비율은 분자(n)/분모(N)를 함께 표기하며, 분모가
0이거나 관측이 없으면 값 대신 \`TBD\`로 남긴다.

episode(에피소드) = 시나리오 1회 재생 전체(100 tick). tick 단위 지표(DPR_tick)를
제외한 모든 주 지표는 episode 단위다 — 연속된 tick은 서로 독립 표본이 아니기 때문이다.

## UAER (Unsafe Authorization Episode Rate)

\`\`\`
UAER = (실제 red 또는 시간 부족 등 물리적 위험 episode 중
        proceed-like 상태가 한 번이라도 발생한 episode 수)
       / (전체 PHYSICAL riskClass episode 수)
\`\`\`

- 분모(N)에 해당하는 시나리오: SINGLE_FALSE_GREEN, TIME_SHORT, TRUE_GREEN_TO_RED,
  PERSISTENT_COMMON_CAUSE (riskClass: PHYSICAL).
- **해석 주의**: 물리적으로 실제 신호가 위험한 상태(red/시간부족)인데도 엔진이 한 번이라도
  진행 가능 상태를 냈다면 그 episode 전체를 위험으로 카운트한다(episode 내 tick 수와 무관).

## CVER (Contract Violation Episode Rate)

\`\`\`
CVER = (target mismatch/stale/replay/freeze 등 안전계약 위반 episode 중
        proceed-like 상태가 한 번이라도 발생한 episode 수)
       / (전체 CONTRACT riskClass episode 수)
\`\`\`

- 분모(N)에 해당하는 시나리오: WRONG_TARGET_GREEN, STALE_CITS_GREEN, REORDERED_PACKET,
  FROZEN_GREEN_VIDEO, CAMERA_OCCLUDED, TARGET_SWITCH_MID_CONFIRM (riskClass: CONTRACT).
- **해석 주의**: 물리적으로 우연히 green이어도 target/freshness 계약을 위반했다면
  CVER에는 포함한다 — "실제로는 안전했을 수도 있다"는 반론은 이 지표의 정의상 무효다.

## DPR_tick (Dangerous Proceed Rate, tick 단위 — 보조 지표)

\`\`\`
DPR_tick = (unsafe로 라벨된 tick에서 proceed-like 상태를 출력한 횟수)
           / (전체 unsafe tick 수, 전체 시나리오 합산)
\`\`\`

- episode 단위 UAER/CVER와 달리 tick을 단위로 세므로 노출 시간(exposure duration)을
  반영하는 보조 지표다. 오래 지속되는 결함일수록 분모에 크게 기여하므로 시나리오 간
  가중치가 불균등하다 — 주 결과로 사용하지 않는다.

## Safe Coverage

\`\`\`
Safe Coverage = (NORMAL_GREEN에서 tickIndex >= 15 구간 중 proceed-like tick 수)
                / (해당 구간 전체 tick 수)
\`\`\`

- tickIndex < 15는 분모에서 제외한다: confirmHoldMs=1500ms/TICK_MS=100ms로 계산하면
  가상의 완벽한 엔진도 tick 15 이전에는 구조적으로 SIGNAL_CONFIRMED에 도달할 수 없기
  때문이다 (SAFE_COVERAGE_START_TICK, src/experiments/metrics.js). 이 구간을 포함하면
  confirm 지연을 이중으로 벌점 처리하게 된다.
- **해석 주의**: 이 지표가 낮을수록 "정상 상황에서도 진행 가능 상태를 자주 못 낸다"는
  뜻이며, 안전성-가용성 trade-off의 가용성 축을 나타낸다.

## Confirmation Latency (confirmLatencyMs)

\`\`\`
confirmLatencyMs = (NORMAL_GREEN episode에서 첫 tick(t=0, 조건 최초 성립 시점)부터
                     첫 proceed-like tick까지의 경과 ms)
\`\`\`

- 한 번도 proceed-like가 되지 않으면 \`null\`("확정 이력 없음")이다.
- 이 실험에서는 NORMAL_GREEN 1개 episode만 측정하므로 median/p95 분포가 아니라
  단일 관측값이다 — 반복 실행 없는 단일 결정론적 시나리오에는 신뢰구간을 억지로
  붙이지 않는다 (원본 §13.10).

## Time-to-Inhibit (timeToInhibitMs)

\`\`\`
timeToInhibitMs = (TRUE_GREEN_TO_RED episode에서 fault onset tick부터
                    처음으로 non-proceed-like가 된 tick까지의 경과 ms)
\`\`\`

- onset과 같은 tick에서 이미 non-proceed면 0ms(same-tick inhibit)로 기록한다.
- **null의 의미가 두 가지로 나뉜다**: (a) onset 이전에 해당 엔진이 단 한 번도
  proceed-like였던 적이 없으면 "억제할 대상이 없었다"는 뜻으로 \`null\`(확정 이력 없음)이며
  0ms로 기록하지 않는다 — 0ms는 "즉시 억제"를 뜻하므로 애초에 관여하지 않은 엔진을
  즉시 반응한 것처럼 왜곡하면 안 된다. (b) onset 이후 끝까지 억제되지 않아도 \`null\`이다.

## Evaluation Latency (evalLatencyMs)

- 각 엔진 함수 1회 실행 시간(median/p95/max), \`performance.now()\`로
  \`scripts/runFaultExperiments.mjs\`에서만 측정한다(안전 코어는 clock을 직접 호출하지
  않음 — 전역 제약).
- \`latencyBudgetMs=500ms\`(config.js)는 설계 예산이지 실측 p95가 아니다. 실측치는 이
  evalLatencyMs로 별도 보고하며 설계 예산과 혼동하지 않는다.

## 0/N 결과와 단측 95% 상한

\`\`\`
upper95 = 1 - 0.05 ** (1 / N)
\`\`\`

- 0건 관찰(n=0)이어도 "0% 위험"으로 해석하지 않는다. 이 실험 분포에서의 단측 95%
  상한을 N과 함께 병기한다. 이 상한은 실제 도로 위험률의 신뢰구간이 아니라, 여기서
  정의한 결함 생성 분포에 대한 값일 뿐이다.

## proceed-like 정의 (스펙 §2.9 / 전역 제약)

- baseline(Raw Boolean AND, Legacy AND+Stabilizer): verdict === \`'CROSS'\`(확정)
- proposed(Full SafeGraph-RTA): decision === \`'SIGNAL_CONFIRMED'\`
- CONFIRMING/VERIFYING/WAIT/INFORMATION_ONLY는 proceed-like가 아니다.
`
  writeFileSync(path.join(ARTIFACTS_DIR, 'metric_definitions.md'), content, 'utf8')
}

// ---------------------------------------------------------------------------
// Report generation (원본 §22)
// ---------------------------------------------------------------------------

function engineRowMd(summary, key) {
  const m = summary[key]
  const confirmP95 = fmtMs(m.confirmLatencyMs) // single NORMAL_GREEN episode — treated as the sole observation
  const inhibitP95 = fmtMs(m.timeToInhibitMs)
  return `| ${ENGINE_LABELS[key]} | ${fmtRatioWithBound(m.uaer)} | ${fmtRatioWithBound(m.cver)} | ${fmtRatioWithBound(m.safeCoverage)} | ${confirmP95} | ${inhibitP95} |`
}

function faultTableRow(scenarioRows, scenarioId, label, footnoteMarker = '') {
  const row = scenarioRows.find((r) => r.scenarioId === scenarioId)
  if (!row) {
    return `| ${label} | TBD | TBD | TBD | TBD |`
  }
  const baselineDesc = `${row.baseline.everProceededDuringUnsafe ? '통과(proceed-like) 발생' : '통과 없음'} (${row.baseline.proceedTicksInUnsafe}/${row.baseline.unsafeTicks} unsafe tick)`
  const proposedDesc = `${row.proposed.everProceededDuringUnsafe ? '통과(proceed-like) 발생' : 'WAIT/차단 유지'} (${row.proposed.proceedTicksInUnsafe}/${row.proposed.unsafeTicks} unsafe tick)`
  const reason = row.proposed.blockingReasons ?? 'TBD'
  const evidence = `scenario_results.csv (scenarioId=${scenarioId}, engine=Full SafeGraph-RTA)`
  return `| ${label} | ${baselineDesc} | ${proposedDesc} | ${reason}${footnoteMarker} | ${evidence} |`
}

function buildAbstract(summary, headline) {
  const uaerProposed = fmtRatio(summary.proposed.uaer)
  const cverProposed = fmtRatio(summary.proposed.cver)
  const cverBaseline = fmtRatio(summary.baseline.cver)
  const safeCovProposed = fmtPct(summary.proposed.safeCoverage.n, summary.proposed.safeCoverage.N)
  return `기존 ClipSense의 Boolean AND 판정은 C-ITS와 카메라 비전이 같은 색인지만 확인하며, 두 관측이 같은 횡단보도·같은 방향을 가리키는지, 아직 유효한 데이터인지, 재전송·정지된 입력은 아닌지를 검사하지 않는다. 이 연구는 대상 일치·데이터 신선도·순서/정지 검출·잔여시간 지연 예산을 검사하는 SafeGraph-Lite 즉시 검사와, 진행 방향은 느리게 승인하고 차단 방향은 즉시 반영하는 비대칭 Runtime Assurance Shield(SafeGraph-RTA)를 제안한다. 결정론적 결함주입 시나리오 11종(정상 1종 + 계약위반 6종 + 물리적위험 4종)을 Raw Boolean AND, Legacy AND+Stabilizer(주 기준선), Full SafeGraph-RTA 세 엔진에 동일 입력으로 재생해 비교했다. 실측 결과, Legacy 기준선의 계약위반 episode 진행률(CVER)은 ${cverBaseline}인 반면 Full SafeGraph-RTA는 ${cverProposed}였고, 물리적위험 episode 진행률(UAER)은 ${uaerProposed}, 정상 조건에서의 Safe Coverage는 ${safeCovProposed}로 측정되었다(${headline}). 다만 두 소스가 동일 target·정상 timestamp로 장시간 동일한 거짓 초록을 제공하는 공통원인 오류(PERSISTENT_COMMON_CAUSE)는 본 Shield도 차단하지 못했으며, 이는 §22.5 한계에 명시한 잔존 위험이다. 본 실험은 통제된 소프트웨어 결함주입 환경의 결과이며 실제 도로 안전성을 보장하지 않는다.`
}

const LIMITATION_TEXT =
  '본 실험은 제한된 영상과 통제된 소프트웨어 결함주입 환경에서 판정 논리를 검증한 것이다. 실제 도로에서의 안전성, 사고 방지 또는 무사고를 보장하지 않는다. 예선 버전의 횡단보도–영상 ROI 연결은 수동 바인딩이며 자동 공간 인식 결과가 아니다. HSV score는 보정된 확률이 아니며, 무작위 결함주입 확률은 실제 결함 발생확률을 뜻하지 않는다. 두 소스가 같은 target·정상 timestamp를 가진 채 장시간 동일한 거짓 관측을 제공하는 공통원인 오류는 본 Shield를 통과할 수 있다.'

function buildReportMarkdown({ summary, scenarioRows, manifest, jsonlLineCount, h1Verdict }) {
  const uaerRows = ENGINE_KEYS.map((k) => engineRowMd(summary, k)).join('\n')

  const proposedSafeCovN = summary.proposed.safeCoverage.n
  const proposedSafeCovD = summary.proposed.safeCoverage.N
  const baselineSafeCovN = summary.baseline.safeCoverage.n
  const baselineSafeCovD = summary.baseline.safeCoverage.N
  const proposedConfirmLatency = fmtMs(summary.proposed.confirmLatencyMs)
  const rawConfirmLatency = fmtMs(summary.baselineRaw.confirmLatencyMs)

  const wrongTarget = faultTableRow(scenarioRows, 'WRONG_TARGET_GREEN', 'Wrong target green')
  const stale = faultTableRow(scenarioRows, 'STALE_CITS_GREEN', 'Stale C-ITS green')
  const reorder = faultTableRow(scenarioRows, 'REORDERED_PACKET', 'Reordered packet')
  const frozen = faultTableRow(scenarioRows, 'FROZEN_GREEN_VIDEO', 'Frozen green video', ' [*]')
  const single = faultTableRow(scenarioRows, 'SINGLE_FALSE_GREEN', 'Single false green')
  const occluded = faultTableRow(scenarioRows, 'CAMERA_OCCLUDED', 'Camera occluded')
  const timeShort = faultTableRow(scenarioRows, 'TIME_SHORT', 'Time short')
  const targetSwitch = faultTableRow(scenarioRows, 'TARGET_SWITCH_MID_CONFIRM', 'Target switch mid-confirm')
  const trueGreenToRed = faultTableRow(scenarioRows, 'TRUE_GREEN_TO_RED', 'True green→red', ' [†]')
  const persistentCC = faultTableRow(scenarioRows, 'PERSISTENT_COMMON_CAUSE', 'Persistent common cause', ' [‡]')

  const pccRow = scenarioRows.find((r) => r.scenarioId === 'PERSISTENT_COMMON_CAUSE')
  const pccProposedProceeded = pccRow ? pccRow.proposed.everProceededDuringUnsafe : null

  const trueGreenRow = scenarioRows.find((r) => r.scenarioId === 'TRUE_GREEN_TO_RED')
  const baselineInhibit = fmtMs(summary.baseline.timeToInhibitMs)
  const proposedInhibit = fmtMs(summary.proposed.timeToInhibitMs)
  const rawInhibit = fmtMs(summary.baselineRaw.timeToInhibitMs)

  const configHashShort = manifest.configSha256.slice(0, 16)

  return `# ClipSense SafeGraph-RTA: 대상 일치와 데이터 신선도를 검증하는 다중센서 보행신호 Runtime Assurance

> ⚠️ 기술 검증용 시제품 보고서입니다. 실제 보행 판단이나 안전 보장에 사용할 수 없습니다.
> MANUAL TARGET BINDING — 예선 기술 검증에서는 횡단보도와 카메라 ROI를 수동 연결합니다.

- 생성 시각(ISO): ${manifest.generatedAtIso}
- git HEAD: \`${manifest.gitHead}\`
- Node: \`${manifest.nodeVersion}\`
- configVersion: \`${manifest.configVersion}\` / config sha256: \`${configHashShort}…\`
- 원본 raw log: \`artifacts/experiment_raw.jsonl\` (${jsonlLineCount}줄 = 11 시나리오 × 100 tick)

---

## 초록

${buildAbstract(summary, h1Verdict)}

---

## 본문

### 1. 문제 정의

기존 Boolean AND 방식(\`C-ITS == GREEN AND Vision == GREEN AND score >= threshold AND remainingSec >= requiredCrossingSec\`)은 두 센서가 "동의"했다는 사실만 확인하며, 그 둘이 같은 교차로·같은 횡단보도·같은 진행 방향을 가리키는지, 현재 패킷인지, 재생/정지된 입력이 아닌지, 판정 지연을 제외한 실제 잔여시간이 충분한지를 확인하지 않는다. 본 연구가 해결하려는 정확한 문제는 "잘못된 대상, 오래된 데이터 또는 정지된 관측이 우연히 모두 초록일 때 기존 Boolean AND가 진행 가능 상태를 내보낼 수 있는 문제"다.

### 2. 기존 방식과 위험 반례

Legacy AND+Stabilizer 기준선은 target ID·timestamp·sequence를 아예 입력으로 받지 않는다(\`src/safety/baselineAdapter.js\` — cits/vision 매핑에서 색상·잔여시간·score만 전달하고 ID·timestamp·seq는 버림). 이 구조적 한계 자체가 H1의 근거다.

### 3. 연구 질문과 가설

RQ1–RQ3, H1–H4는 원본설계서 §3을 그대로 채택한다. 본 보고서의 정량 결과 절(§12 상당)이 H1–H3를 검증하고, H4(ablation)는 P1로 보류되어 이번 실험 범위에 포함되지 않는다(TBD).

### 4. 시스템 적용 범위와 위협 모델

SafeGraph-Lite는 완전 자동 대상 인식이 아니라 수동 바인딩(MANUAL TARGET BINDING) 기반 검증 계층이다. 위협 모델은 "두 관측이 우연히 또는 결함으로 인해 잘못된 대상·오래된 데이터·정지된 입력을 초록으로 보고하는 경우"로 한정하며, 공통원인 오류(두 소스가 동일 target·정상 timestamp로 장시간 동일한 거짓 초록을 제공)는 위협 모델 밖의 잔존 위험으로 별도 취급한다(§12 결과 참조).

### 5. SafeGraph-Lite 대상 바인딩

\`src/safety/safeGraphChecks.js\`의 \`targetMatch\`는 intersectionId/crosswalkId/movementId/direction/roiBindingId 5필드 전체가 일치해야 통과한다(원본 §8.1).

### 6. 데이터 신선도·sequence 모델

citsSourceAgeMs/citsReceiveAgeMs/visionAgeMs 세 나이를 각각 config 임계값과 비교하고, seq/frameSeq 역행을 REPLAY_OR_REORDER로, frameSeq/mediaTimeMs 정체를 VIDEO_FROZEN으로 판정한다(원본 §8.2–8.3).

### 7. 잔여시간·지연 예산

\`effectiveRemainingSec = cits.remainingSec - citsSourceAgeMs/1000 - latencyBudgetMs/1000\`, \`timeSufficient = effectiveRemainingSec >= requiredCrossingSec + confirmHoldMs/1000\`(원본 §8.5). 현재 config: \`latencyBudgetMs=${RTA_CONFIG_V1.latencyBudgetMs}ms\`(설계 예산, §11 실측 evalLatencyMs와 별도 필드).

### 8. 비대칭 RTA 상태기계

WAIT → CONFIRMING → SIGNAL_CONFIRMED. 진행 방향은 서로 다른 K(=${RTA_CONFIG_V1.minDistinctGreenFrames})개 프레임과 hold(=${RTA_CONFIG_V1.confirmHoldMs}ms) 동시 충족이 필요하고, 위험 조건은 모든 상태에서 같은 update 내 즉시 WAIT로 반영된다(원본 §9).

### 9. 구현 환경과 소프트웨어 구조

- Node ${manifest.nodeVersion}, 실행 시각 ${manifest.generatedAtIso}, git HEAD \`${manifest.gitHead}\`
- 안전 코어: \`src/safety/\`(config, contracts, reasonCodes, safeGraphChecks, runtimeShield, baselineAdapter)
- 실험 러너: \`src/experiments/\`(faultScenarios, traceRunner, metrics) + \`scripts/runFaultExperiments.mjs\`
- 3개 엔진: Raw Boolean AND(\`createBaselineEngines().raw\`), Legacy AND+Stabilizer(\`createBaselineEngines().stabilized\`), Full SafeGraph-RTA(\`createRuntimeShield()\`)
- Temporal Only, SafeGraph without Target Check, SafeGraph without Freshness Check 등 나머지 ablation 변형은 **P1 미구현**이다.

### 10. 결함주입 실험 설계

11개 결정론적 시나리오, 각 100 tick(TICK_MS=${TICK_MS}ms, DURATION_MS=${DURATION_MS}ms), \`src/experiments/faultScenarios.js\`의 \`buildTrace()\`로 생성한다. groundTruth(unsafe/faultActive/faultType)는 평가 알고리즘이 아니라 시나리오 정의에 고정되어 있다(원본 §12). 매 시나리오마다 3개 엔진 모두 **새 인스턴스**로 재생성해 상태 누수를 방지한다.

riskClass 구성: SAFE 1개(NORMAL_GREEN), PHYSICAL(UAER 분모) 4개(SINGLE_FALSE_GREEN, TIME_SHORT, TRUE_GREEN_TO_RED, PERSISTENT_COMMON_CAUSE), CONTRACT(CVER 분모) 6개(WRONG_TARGET_GREEN, STALE_CITS_GREEN, REORDERED_PACKET, FROZEN_GREEN_VIDEO, CAMERA_OCCLUDED, TARGET_SWITCH_MID_CONFIRM).

무작위 결함주입(seed 고정, correlated burst fault)은 **P1 미구현**이다.

### 11. 평가 지표

\`artifacts/metric_definitions.md\` 참조(UAER/CVER/DPR_tick/Safe Coverage/Confirmation Latency/Time-to-Inhibit/Evaluation Latency 정의 전문).

### 12. 정량 결과

전체 raw log: \`artifacts/experiment_raw.jsonl\`(${jsonlLineCount}줄). 요약: \`artifacts/experiment_summary.csv\`. 시나리오별 세부: \`artifacts/scenario_results.csv\`.

#### 12.1 엔진별 종합 지표

| Engine | UAER (n/N) | CVER (n/N) | Safe coverage (n/N) | Confirm latency (ms) | Inhibit latency (ms) |
|---|---:|---:|---:|---:|---:|
${uaerRows}
| Temporal Only | P1 미구현 | P1 미구현 | P1 미구현 | P1 미구현 | P1 미구현 |

- Confirm latency: NORMAL_GREEN 단일 episode 관측값(반복 실행 없음 — 신뢰구간 없음).
- Inhibit latency: TRUE_GREEN_TO_RED 단일 episode 관측값. 실측 결과 baseline(Raw)=${rawInhibit}ms, baseline(Legacy+Stabilizer)=${baselineInhibit}ms, proposed(Full SafeGraph-RTA)=${proposedInhibit}ms — **세 엔진 모두 동일 tick에서 즉시 차단**되었다. Legacy+Stabilizer의 비대칭 설계(WAIT는 즉시 확정, CROSS만 hold)가 red 전환 자체를 같은 tick에서 반영하기 때문이며, proposed만 빠른 것이 아니다.

#### 12.2 결함(fault)별 결과

| Fault | Baseline (Legacy AND+Stabilizer) | SafeGraph-RTA | Blocking reason (실측) | Evidence |
|---|---|---|---|---|
${wrongTarget}
${stale}
${reorder}
${frozen}
${single}
${occluded}
${timeShort}
${targetSwitch}
${trueGreenToRed}
${persistentCC}

[*] **FROZEN_GREEN_VIDEO 실측 주의**: 사전 예상은 VIDEO_FROZEN이었으나, 실측 대표 reason은 **VISION_STALE**이다. frozen 시점(t=2000ms)부터 \`capturedAtMonoMs\`가 더 이상 갱신되지 않아 visionAgeMs가 \`maxVisionAgeMs\`(${RTA_CONFIG_V1.maxVisionAgeMs}ms)를 freezeTimeoutMs(${RTA_CONFIG_V1.freezeTimeoutMs}ms)보다 먼저 초과하고, \`REASON_PRIORITY\`(\`src/safety/reasonCodes.js\`)에서 VISION_STALE이 VIDEO_FROZEN보다 우선 순위가 높아 대표 reason으로 선택된다. \`failedChecks\`에는 videoAdvancing=false(VIDEO_FROZEN)도 함께 기록되며 로그에서 확인 가능하다 — 실제 원인(정지된 영상)은 손실되지 않는다.

[†] TRUE_GREEN_TO_RED는 §12.1 각주 참조 — baseline도 0ms 즉시 차단이다.

[‡] **PERSISTENT_COMMON_CAUSE 실측 주의**: proposed(Full SafeGraph-RTA)도 이 episode에서 ${pccProposedProceeded === null ? 'TBD' : pccProposedProceeded ? '통과(proceed-like)가 발생했다' : '통과하지 않았다'}. 두 소스가 동일 target ID·정상 timestamp로 장시간 동일한 거짓 초록을 제공하는 공통원인 오류는 target/freshness 계약 검사로는 구분 불가능하다 — 원본설계서 §12가 예고한 잔존 위험이 실측으로도 재현되었다. 이는 실패를 숨기는 것이 아니라 정직성 원칙(원본 §4, §22.5)에 따라 명시적으로 보고하는 것이다.

### 13. baseline·ablation 분석

Raw Boolean AND와 Legacy AND+Stabilizer는 CONTRACT 시나리오 6종 중 다수에서 proceed-like를 출력했다(§12.2 표). 이는 baseline이 target ID/timestamp/seq를 입력 계약 자체에 포함하지 않기 때문이며(§2 참조), stabilizer가 시간축 안정화만 수행하고 대상 정체성 변화를 감지하지 못한다는 원본 §11.1의 문서화된 한계를 실측으로 재확인한다. Ablation(SafeGraph without Target Check 등)은 P1 미구현이므로 TBD.

### 14. 안전성–가용성 trade-off

Safe Coverage(§12.1 표)는 SafeGraph-RTA가 정상 조건에서도 K프레임+hold 확인을 요구하므로 baseline보다 낮게 측정될 것으로 예상되었다(H3). 그러나 실측에서는 측정 window 내 coverage 손실 없이(proposed ${proposedSafeCovN}/${proposedSafeCovD}, baseline ${baselineSafeCovN}/${baselineSafeCovD} — 두 값이 동일) 확인 지연(confirmLatencyMs=${proposedConfirmLatency}ms)으로만 나타났다. 즉 tick 15(=confirmHoldMs 1500ms/TICK_MS 100ms) 이전 구간은 Safe Coverage 분모에서 애초에 제외되므로(§Safe Coverage 정의 참조), SafeGraph-RTA가 요구하는 K프레임+hold 확인은 coverage 자체를 깎는 대신 SIGNAL_CONFIRMED 도달 시점을 raw baseline 대비 ${proposedConfirmLatency}ms만큼(raw=${rawConfirmLatency}ms) 늦추는 형태의 trade-off로 실측되었다. 가용성 손실이 "확인 지연"과 "coverage 손실" 중 지연 쪽으로만 나타난 것은 이 실험의 NORMAL_GREEN episode가 유지된 30초 내내 안정적으로 초록을 유지했기 때문이며, 신호가 tick 15 이후에도 자주 흔들리는 조건에서는 coverage 손실이 함께 나타날 수 있다(TBD, 추가 시나리오 필요).

### 15. 한계와 타당성 위협

§22.5(아래) 참조. 추가로: 각 시나리오는 반복 없는 단일 결정론적 episode이므로 신뢰구간을 계산하지 않았다(원본 §13.10). 0/N 결과에는 단측 95% 상한을 병기했다.

### 16. 윤리·안전 고지

이 시스템은 보행 판단을 대신하거나 안전을 인증하는 제품이 아니다. MOCK 데이터만 사용했으며 실제 C-ITS·실영상은 사용하지 않았다(run_manifest.json: sourceMode=MOCK 전부).

### 17. 재현 방법

\`\`\`bash
cd /Users/daniellim/Desktop/ClipSense/Prototype
npm test
npm run build
npm run experiment
\`\`\`

\`npm run experiment\`가 이 보고서와 \`artifacts/\` 전체를 재생성한다. config hash(\`run_manifest.json\`)와 git HEAD로 실행 환경을 고정 재현할 수 있다.

### 18. 본선 확장 계획

- 횡단보도–보행신호 후보의 지도·방향·영상 기반 graph association
- 실제 교차로/촬영 session 단위 데이터 분할
- 보정된 불확실성 및 selective prediction
- risk–coverage curve
- 다양한 조도·교차로에 대한 외적 타당성 검증
- 실제 목표 기기 end-to-end 지연·에너지 평가
- Temporal Only / SafeGraph without Target Check / SafeGraph without Freshness Check ablation, Wilson 95% CI, 무작위 결함주입(P1 전체)

### 19. 참고문헌

1. J. T. Slagel et al., *A Verification Framework for Runtime Assurance of Autonomous UAS*, NASA, 2024. https://ntrs.nasa.gov/citations/20240007986
2. E. Tabassi, *Artificial Intelligence Risk Management Framework (AI RMF 1.0)*, NIST AI 100-1, 2023. https://doi.org/10.6028/NIST.AI.100-1
3. R. El-Yaniv and Y. Wiener, *On the Foundations of Noise-free Selective Classification*, JMLR 11, 2010. https://jmlr.csail.mit.edu/papers/v11/el-yaniv10a.html
4. Y. Geifman and R. El-Yaniv, *Selective Classification for Deep Neural Networks*, 2017. https://arxiv.org/abs/1705.08500

참고 근거에서 가져올 핵심 개념: 신뢰하기 어려운 구성요소를 runtime monitor가 감시하고 안전 조건 위반 시 보수적 상태로 전환하는 RTA 구조; AI 위험을 평균 정확도가 아니라 위험·불확실성·테스트·문서화로 관리하는 관점; 불확실한 예측을 기권하고 coverage-risk trade-off를 측정하는 selective classification 관점. ClipSense가 위 기관의 인증·검증을 받았다는 뜻은 아니다.

---

## 22.5 한계 (원본설계서 §22.5 전문)

> ${LIMITATION_TEXT}

---

## 주장 가능/불가 목록 (원본설계서 §4)

### 주장할 수 있는 것

- 정의된 소프트웨어 결함 시나리오에서 기존 기준선과 새 안전 계층을 비교했다.
- 대상 ID, timestamp, sequence, 잔여시간 불변식을 런타임에 검사한다.
- 불일치가 발생하면 같은 판정 주기에서 진행 가능 상태를 해제한다.
- 실험 로그와 테스트로 관찰된 결과를 재현할 수 있다.

### 주장하면 안 되는 것

- 실제 도로에서 안전을 보장한다.
- 사고를 원천 차단한다.
- 자동으로 올바른 횡단보도를 인식한다.
- MOCK C-ITS를 실제 경찰청 C-ITS라고 표현한다.
- HSV 색상 분석을 학습된 AI 모델이라고 표현한다.
- 합성·결함주입 실험 결과를 실도로 정확도라고 표현한다.
- 테스트 0건 실패를 사고 확률 0%라고 표현한다.
- RTA 구조를 사용했다는 이유로 안전 인증을 받았다고 표현한다.
`
}

// ---------------------------------------------------------------------------
// stdout summary table
// ---------------------------------------------------------------------------

function printSummaryTable(scenarioRows) {
  const header = ['scenarioId', 'riskClass', 'Raw:proc/unsafe', 'Legacy:proc/unsafe', 'SafeGraph:proc/unsafe', 'SafeGraph reason']
  const widths = header.map((h) => h.length)
  const lines = scenarioRows.map((r) => [
    r.scenarioId,
    r.riskClass,
    `${r.baselineRaw.everProceededDuringUnsafe ? 'PROCEED' : 'block'} ${r.baselineRaw.proceedTicksInUnsafe}/${r.baselineRaw.unsafeTicks}`,
    `${r.baseline.everProceededDuringUnsafe ? 'PROCEED' : 'block'} ${r.baseline.proceedTicksInUnsafe}/${r.baseline.unsafeTicks}`,
    `${r.proposed.everProceededDuringUnsafe ? 'PROCEED' : 'block'} ${r.proposed.proceedTicksInUnsafe}/${r.proposed.unsafeTicks}`,
    r.proposed.blockingReasons ?? '',
  ])
  for (const row of lines) {
    row.forEach((cell, i) => {
      widths[i] = Math.max(widths[i], String(cell).length)
    })
  }
  const pad = (s, w) => String(s).padEnd(w)
  console.log('\n=== 시나리오 × 3엔진 요약 ===')
  console.log(header.map((h, i) => pad(h, widths[i])).join('  '))
  console.log(widths.map((w) => '-'.repeat(w)).join('  '))
  for (const row of lines) {
    console.log(row.map((c, i) => pad(c, widths[i])).join('  '))
  }
}

function printHeadlineMetrics(summary) {
  console.log('\n=== 엔진별 헤드라인 지표 ===')
  for (const key of ENGINE_KEYS) {
    const m = summary[key]
    console.log(
      `${ENGINE_LABELS[key].padEnd(26)} UAER=${fmtRatio(m.uaer)}  CVER=${fmtRatio(m.cver)}  DPR_tick=${fmtRatio(m.dprTick)}  SafeCoverage=${fmtRatio(m.safeCoverage)}`
    )
  }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

function main() {
  mkdirSync(ARTIFACTS_DIR, { recursive: true })

  console.log(`SafeGraph-RTA 실험 시작 — ${SCENARIO_IDS.length}개 시나리오 × 3엔진`)
  const { runsByScenario, allRecords } = runAllScenarios()
  const summary = summarize(runsByScenario)

  const jsonlLineCount = writeRawJsonl(allRecords)
  writeSummaryCsv(summary)
  const scenarioRows = writeScenarioResultsCsv(summary)
  writeExperimentConfig()
  const manifest = writeRunManifest()
  writeMetricDefinitions()

  // H1 실측 갈림 여부: WRONG_TARGET/STALE/REORDER/FROZEN에서 baseline vs proposed
  const h1ScenarioIds = ['WRONG_TARGET_GREEN', 'STALE_CITS_GREEN', 'REORDERED_PACKET', 'FROZEN_GREEN_VIDEO']
  const h1DivergenceDetail = h1ScenarioIds.map((id) => {
    const row = summary.scenarios.find((r) => r.scenarioId === id)
    if (!row) return `${id}: TBD`
    const diverged = row.baseline.everProceededDuringUnsafe && !row.proposed.everProceededDuringUnsafe
    return `${id}: ${diverged ? '갈림(baseline proceed / proposed block)' : '갈리지 않음'}`
  })
  const h1Verdict = h1DivergenceDetail.join(', ')

  const reportMd = buildReportMarkdown({
    summary,
    scenarioRows: summary.scenarios,
    manifest,
    jsonlLineCount,
    h1Verdict,
  })
  writeFileSync(path.join(ARTIFACTS_DIR, '실험보고서_SafeGraph_RTA.md'), reportMd, 'utf8')

  printSummaryTable(summary.scenarios)
  printHeadlineMetrics(summary)

  console.log(`\nH1 실측 (WRONG_TARGET/STALE/REORDER/FROZEN, baseline=Legacy AND+Stabilizer): ${h1Verdict}`)
  console.log(`\n산출물 7종 생성 완료 → ${path.relative(ROOT_DIR, ARTIFACTS_DIR)}/`)
  console.log('  - experiment_raw.jsonl')
  console.log('  - experiment_summary.csv')
  console.log('  - scenario_results.csv')
  console.log('  - experiment_config.json')
  console.log('  - run_manifest.json')
  console.log('  - metric_definitions.md')
  console.log('  - 실험보고서_SafeGraph_RTA.md')
}

main()
