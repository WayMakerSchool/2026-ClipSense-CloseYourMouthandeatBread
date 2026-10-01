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
