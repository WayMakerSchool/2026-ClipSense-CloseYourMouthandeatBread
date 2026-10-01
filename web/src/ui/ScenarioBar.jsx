import { SCENARIOS, SCENARIO_IDS } from '../experiments/faultScenarios.js'

/**
 * 시나리오 바 v2 (스펙 §2.10): 11개 결함주입 시나리오 버튼(동일 buildTrace를
 * 재생 — 단일 진실 원천) + 카메라 라이브 모드 버튼 + 오디오 활성화 토글.
 */
export default function ScenarioBar({
  mode,
  setMode,
  scenarioId,
  setScenarioId,
  audioEnabled,
  setAudioEnabled,
}) {
  return (
    <section className="scenario-bar" aria-label="시연 시나리오">
      <div className="row">
        <span className="row-label">모드</span>
        <button className={mode === 'SCENARIO' ? 'on' : ''} onClick={() => setMode('SCENARIO')}>
          시나리오 재생
        </button>
        <button className={mode === 'CAMERA' ? 'on' : ''} onClick={() => setMode('CAMERA')}>
          카메라 라이브
        </button>
        <button
          className={audioEnabled ? 'on audio-on' : ''}
          onClick={() => setAudioEnabled(!audioEnabled)}
          aria-pressed={audioEnabled}
        >
          {audioEnabled ? '🔊 오디오 활성화됨' : '🔈 오디오 활성화'}
        </button>
      </div>
      <div className="row row-scenarios">
        <span className="row-label">결함주입 시나리오 (11)</span>
        {SCENARIO_IDS.map((id) => (
          <button
            key={id}
            className={mode === 'SCENARIO' && scenarioId === id ? 'on' : ''}
            onClick={() => { setScenarioId(id); setMode('SCENARIO') }}
            title={SCENARIOS[id].description}
          >
            {SCENARIOS[id].label}
          </button>
        ))}
      </div>
    </section>
  )
}
