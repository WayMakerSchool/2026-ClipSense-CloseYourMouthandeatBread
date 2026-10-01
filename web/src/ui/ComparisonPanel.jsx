function fmtSec(sec) {
  if (!Number.isFinite(sec)) return sec === Infinity ? '∞' : sec === -Infinity ? '-∞' : '—'
  return `${sec.toFixed(1)}초`
}

// proceed-like = baseline CROSS(확정) / proposed SIGNAL_CONFIRMED 뿐
// (global-constraints.md). 두 상태가 동시에 화면에 보이는 순간(특히
// baseline CROSS(초록) vs proposed WAIT(빨강)가 동시 발생하는 순간)이
// SafeGraph-RTA의 존재 이유를 시각적으로 증명하는 시연 핵심 장면이다.
const BASELINE_PROCEED = 'CROSS'
const PROPOSED_PROCEED = 'SIGNAL_CONFIRMED'

/**
 * A/B 비교 패널 (스펙 §2.10 / §15.4):
 * - 좌: 기존 Boolean AND — 비교 전용, 음성 출력 안 함 (stabilized verdict/reason
 *   메인 + raw는 참고 표시)
 * - 우: SafeGraph-RTA — 실제 안내 연결 (decision/state/reason/message/확인
 *   프레임 수/유효잔여 vs 필요시간)
 */
export default function ComparisonPanel({ baselineRaw, baselineStabilized, shield }) {
  const baselineProceeding = baselineStabilized?.verdict === BASELINE_PROCEED
  const proposedProceeding = shield?.decision === PROPOSED_PROCEED
  const divergence = baselineProceeding && !proposedProceeding

  return (
    <section className={`comparison-panel ${divergence ? 'comparison-divergence' : ''}`} aria-label="A/B 비교">
      <div className={`comparison-col comparison-baseline ${baselineProceeding ? 'verdict-proceed' : 'verdict-hold'}`}>
        <div className="comparison-title">기존 Boolean AND</div>
        <div className="comparison-badge">비교 전용, 음성 출력 안 함</div>

        <div className="comparison-main">
          <div className="comparison-verdict">{baselineStabilized?.verdict ?? '—'}</div>
          <div className="comparison-reason">사유: {baselineStabilized?.reason ?? '—'}</div>
        </div>

        <div className="comparison-ref">
          <span className="comparison-ref-label">raw (참고)</span>
          <span>{baselineRaw?.verdict ?? '—'} · {baselineRaw?.reason ?? '—'}</span>
        </div>
      </div>

      <div className={`comparison-col comparison-proposed ${proposedProceeding ? 'verdict-proceed' : 'verdict-hold'}`}>
        <div className="comparison-title">SafeGraph-RTA</div>
        <div className="comparison-badge comparison-badge-live">실제 안내 연결</div>

        <div className="comparison-main">
          <div className="comparison-verdict">{shield?.decision ?? '—'}</div>
          <div className="comparison-state">state: {shield?.state ?? '—'}</div>
          <div className="comparison-reason">사유: {shield?.reason ?? '—'}</div>
          <div className="comparison-message">{shield?.message ?? '—'}</div>
        </div>

        <div className="comparison-detail-grid">
          <span className="kv-key">확인된 서로 다른 프레임 수</span>
          <span className="kv-val">{shield?.confirmation?.distinctGreenFrames ?? 0}</span>
          <span className="kv-key">유효 잔여시간</span>
          <span className="kv-val">{fmtSec(shield?.effectiveRemainingSec)}</span>
          <span className="kv-key">필요 횡단시간</span>
          <span className="kv-val">{fmtSec(shield?.requiredCrossingSec)}</span>
        </div>
      </div>
    </section>
  )
}
