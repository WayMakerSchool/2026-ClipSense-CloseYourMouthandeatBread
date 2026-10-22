'use strict';
const $ = id => document.getElementById(id);
const labels = {RED: '빨강', GREEN: '초록', NONE: '신호 없음', UNKNOWN: '확인 불가', GREEN_BLINK: '초록 점멸'};
const connections = {starting: '연결 중', connected: '사진 수신 중', same_frame: '같은 사진 · 갱신 대기', stale: '사진 만료 · 대기', unreachable: '클립 연결 불가', timeout: '응답 시간 초과', token_rejected: '토큰 거부 · 설정 후 재실행', bad_headers: '사진 헤더 오류', bad_content_type: 'JPEG 응답 아님', bad_jpeg: 'QVGA JPEG 오류', replay_or_reorder: '프레임 역행 · 대기', http_409: '카메라 사용 중', http_503: '촬영 실패'};
const unknownText = '신호를 확인할 수 없습니다. 기다리세요.';
const apiColors = {GREEN: '초록', RED: '빨강', CLEARANCE: '초록 점멸', UNKNOWN: '확인 불가'};
const newId = () => crypto.randomUUID ? crypto.randomUUID() : Array.from(crypto.getRandomValues(new Uint8Array(16)), n => n.toString(16).padStart(2, '0')).join('');
let running = false, generation = 0, current = null, validUntil = 0, lastGuidance = '';
let lastFrameKey = '', requestController = null, timer = null, voiceEnabled = false;
let speechSerial = 0, activeSpeech = null, latestSpeech = null;
const events = [], records = [];
const session = {id: newId(), startedAt: new Date().toISOString(), origin: location.origin,
  userAgent: navigator.userAgent, platform: navigator.platform, language: navigator.language,
  secureContext: window.isSecureContext, devicePixelRatio, voiceSupport: 'speechSynthesis' in window};
function event(type, detail = {}) {
  events.push({at: new Date().toISOString(), type, ...detail});
  if (events.length > 5000) events.shift();
}
function time(value) {
  return value ? new Date(value).toLocaleTimeString('ko-KR', {hour12: false}) : '—';
}
function speechStatus(text) { $('speechStatus').textContent = text; }
function canUseFrame() {
  return running && current?.frame && performance.now() < validUntil && !document.hidden;
}
function cancelSpeech() {
  speechSerial++;
  activeSpeech = null;
  if ('speechSynthesis' in window) window.speechSynthesis.cancel();
  $('heard').disabled = true;
}
function speak(text) {
  cancelSpeech();
  lastGuidance = text;
  if (!voiceEnabled) return;
  if (!('speechSynthesis' in window)) {
    speechStatus('음성 미지원 · 실제 소리 확인 불가');
    event('speech_unavailable');
    return;
  }
  const serial = speechSerial;
  const utterance = new SpeechSynthesisUtterance(text);
  const voices = window.speechSynthesis.getVoices();
  const korean = voices.find(v => /^ko(?:-|_)/i.test(v.lang));
  if (korean) utterance.voice = korean;
  utterance.lang = 'ko-KR';
  utterance.rate = 1;
  const entry = {id: newId(), text, requestedAt: new Date().toISOString(),
    frameKey: canUseFrame() ? lastFrameKey : null,
    voice: korean ? {name: korean.name, lang: korean.lang, localService: korean.localService} : null,
    startedAt: null, endedAt: null, heardAt: null, error: null};
  latestSpeech = entry;
  activeSpeech = utterance; // 브라우저 GC 동안 발화 참조 유지
  speechStatus('음성 재생 요청 · 소리 확인 전');
  $('heard').disabled = true;
  event('speech_requested', {...entry});
  const watchdog = setTimeout(() => {
    if (serial === speechSerial && !entry.startedAt) {
      entry.error = 'start_timeout';
      speechStatus('음성 시작 안 됨 · 다시 듣기와 기기 음량 확인');
      event('speech_timeout', {speechId: entry.id});
      cancelSpeech();
    }
  }, 7000);
  utterance.onstart = () => {
    if (serial !== speechSerial) return;
    clearTimeout(watchdog);
    entry.startedAt = new Date().toISOString();
    speechStatus('음성 재생 중 · 실제 소리를 확인하세요');
    event('speech_started', {speechId: entry.id, text});
  };
  utterance.onend = () => {
    if (serial !== speechSerial) return;
    clearTimeout(watchdog);
    entry.endedAt = new Date().toISOString();
    activeSpeech = null;
    speechStatus('재생 종료 · 실제 청취 확인 전');
    $('heard').disabled = !entry.startedAt;
    event('speech_ended', {speechId: entry.id, text});
  };
  utterance.onerror = e => {
    if (serial !== speechSerial) return;
    clearTimeout(watchdog);
    entry.error = e.error;
    $('heard').disabled = true;
    speechStatus(`음성 오류: ${e.error} · 소리 미확인`);
    event('speech_error', {speechId: entry.id, error: e.error});
  };
  window.speechSynthesis.speak(utterance);
}
function clearFrame(message) {
  $('frame').hidden = true;
  $('frame').removeAttribute('src');
  $('overlay').hidden = true;
  $('empty').hidden = false;
  $('empty').textContent = message;
  $('reading').textContent = '확인 불가';
  $('reading').dataset.color = 'UNKNOWN';
  $('stable').textContent = '유효한 최신 사진 없음';
  $('detectorReason').textContent = '판독 보류 · 새 사진을 기다립니다.';
  $('source').textContent = '현재 유효한 사진 없음';
  $('sourceTag').textContent = '유효한 사진 없음';
  $('sequence').textContent = '프레임 —';
  $('rtt').textContent = '—';
  $('record').disabled = true;
  $('decision').textContent = '확인 불가 · 대기';
  $('decision').dataset.walk = 'false';
  $('guidance').textContent = unknownText;
}
function invalidate(message, announce = true) {
  validUntil = 0;
  clearFrame(message);
  if (announce && lastGuidance !== unknownText) speak(unknownText);
}
function renderApi(api) {
  if (!api || !api.configured) {
    $('apiStatus').textContent = '신호 API 미연결. 초록 판독만으로 보행을 허용하지 않습니다.';
    return;
  }
  const parts = [api.label, `교차로 ${api.itstId}`];
  if (api.color === null) parts.push('아직 받지 못함');
  else {
    parts.push(apiColors[api.color] || api.color);
    if (api.remainSec !== null) parts.push(`남은 ${api.remainSec.toFixed(1)}초`);
    parts.push(`${(api.freshMs / 1000).toFixed(1)}초 전 정보`);
  }
  $('apiStatus').textContent = parts.join(' · ');
}
function render(data, sentAt) {
  current = data;
  renderApi(data.api);
  $('clipOrigin').textContent = data.clipOrigin;
  $('received').textContent = time(data.lastReceivedAt);
  $('connection').textContent = connections[data.connection] || data.connection;
  $('connection').dataset.ok = String(data.connection === 'connected');
  const fraction = data.rules.roiFraction;
  $('rules').textContent = `${data.rules.version} · 중앙 ${fraction * 100}% · 연속 ${data.rules.config.debounce_frames}장 · 만료 ${data.rules.staleMs}ms · config SHA-256 ${data.rules.sha256['config.json']}`;
  // 서버 잔여 신선도에서 브라우저 왕복 전체를 추가로 차감한다.
  validUntil = sentAt + data.validForMs;
  $('age').textContent = data.ageMs === null ? '—' : `${data.ageMs + Math.ceil(performance.now() - sentAt)} ms`;
  if (!canUseFrame()) {
    invalidate(connections[data.connection] || '사진을 받을 수 없습니다.');
    return;
  }
  const frame = data.frame;
  const key = `${frame.bootId}:${frame.seq}`;
  if (key !== lastFrameKey || $('frame').hidden) {
    lastFrameKey = key;
    $('frame').src = `data:image/jpeg;base64,${frame.jpeg}`;
    $('frame').hidden = false;
    $('empty').hidden = true;
    $('overlay').hidden = false;
    const ctx = $('overlay').getContext('2d');
    ctx.clearRect(0, 0, 320, 240);
    const boxColors = {'신호등': '#f3df89', '램프': '#ffffff', '숫자': '#7fd8ff', ROI: '#f3df89'};
    ctx.lineWidth = 1.5; ctx.font = '10px sans-serif';
    for (const box of frame.boxes || [{label: 'ROI', rect: frame.roi}]) {
      ctx.strokeStyle = ctx.fillStyle = boxColors[box.label] || '#f3df89';
      ctx.strokeRect(...box.rect);
      ctx.fillText(box.label, box.rect[0] + 2, Math.max(10, box.rect[1] - 3));
    }
    event('frame', {frameKey: key, jpegSha256: frame.jpegSha256, source: frame.source,
      raw: frame.raw, stable: frame.stable, decision: data.decision, guidance: data.guidance,
      ageMs: data.ageMs, receivedAt: frame.receivedAt});
  }
  $('source').textContent = frame.source.label;
  $('sourceTag').textContent = frame.source.label;
  $('sequence').textContent = `프레임 #${frame.seq}`;
  $('rtt').textContent = `${frame.rttMs} ms`;
  $('reading').textContent = labels[frame.raw] || frame.raw;
  $('reading').dataset.color = frame.raw;
  const digitText = frame.digits !== null && frame.digits !== undefined ? ` · 숫자 ${frame.digits}초` :
    frame.boxes && frame.boxes.some(b => b.label === '숫자') ? ' · 숫자 판독 불가' : '';
  $('stable').textContent = `연속 판독 확정: ${labels[frame.stable] || frame.stable}${digitText}`;
  $('detectorReason').textContent = frame.detectorReason ? `보류 근거: ${frame.detectorReason}` : `빨강 면적 ${(frame.red.area_ratio * 100).toFixed(2)}% · 초록 면적 ${(frame.green.area_ratio * 100).toFixed(2)}%`;
  $('guidance').textContent = data.guidance;
  $('decision').textContent = data.decision === 'WALK' ? '건너세요' : data.decision === 'WAIT' ? '기다리세요' : '확인 불가 · 대기';
  $('decision').dataset.walk = String(data.decision === 'WALK');
  $('record').disabled = false;
  if (lastGuidance !== data.guidance) speak(data.guidance);
}
async function poll(gen) {
  if (!running || generation !== gen || document.hidden) return;
  const sent = performance.now();
  const controller = new AbortController();
  requestController = controller;
  const timeout = setTimeout(() => controller.abort(), 1500);
  try {
    const response = await fetch('/api/frame', {cache: 'no-store', signal: controller.signal});
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const data = await response.json();
    if (running && generation === gen && !document.hidden) render(data, sent);
  } catch (e) {
    if (running && generation === gen && !document.hidden) {
      $('connection').textContent = '웹 연결 끊김 · 대기';
      $('connection').dataset.ok = 'false';
      invalidate('웹 서버에 연결할 수 없습니다.');
      event('web_error', {error: e.message});
    }
  } finally {
    clearTimeout(timeout);
    if (requestController === controller) requestController = null;
    if (running && generation === gen && !document.hidden) timer = setTimeout(() => poll(gen), 250);
  }
}
function start() {
  if (running) return;
  running = voiceEnabled = true;
  generation++;
  $('start').disabled = true;
  $('stop').disabled = false;
  $('repeat').disabled = false;
  event('start');
  speak(unknownText); // 사용자 클릭 안에서 발화를 요청한다.
  poll(generation);
}
function stop() {
  running = false; generation++;
  clearTimeout(timer); requestController?.abort();
  cancelSpeech(); voiceEnabled = false;
  invalidate('중지했습니다. 시작을 눌러 다시 연결하세요.', false);
  $('start').disabled = false; $('stop').disabled = true; $('repeat').disabled = true;
  $('connection').textContent = '중지'; $('connection').dataset.ok = 'false';
  speechStatus('중지 · 재시작 후 소리 다시 확인');
  event('stop');
}
setInterval(() => {
  if (running && validUntil && performance.now() >= validUntil) {
    $('connection').textContent = '사진 만료 · 대기';
    $('connection').dataset.ok = 'false';
    invalidate('사진이 2초 이상 갱신되지 않았습니다.');
    event('browser_frame_expired');
  }
}, 100);
document.addEventListener('visibilitychange', () => {
  if (!running) return;
  generation++; clearTimeout(timer); requestController?.abort();
  if (document.hidden) {
    cancelSpeech(); invalidate('화면을 다시 열면 최신 사진을 확인합니다.', false);
    speechStatus('화면 숨김 · 음성 중지');
    event('hidden');
  } else {
    lastGuidance = '';
    event('visible');
    poll(generation);
  }
});
$('frame').addEventListener('error', () => {
  invalidate('사진을 표시할 수 없습니다.');
  event('image_decode_error');
});
$('start').addEventListener('click', start);
$('stop').addEventListener('click', stop);
$('repeat').addEventListener('click', () => speak(canUseFrame() ? current.guidance : unknownText));
$('heard').addEventListener('click', () => {
  if (!latestSpeech?.startedAt || !latestSpeech.endedAt || latestSpeech.error) return;
  latestSpeech.heardAt = new Date().toISOString();
  speechStatus('사용자 실제 청취 확인 · 영상에도 소리를 남겨주세요');
  $('heard').disabled = true;
  event('heard_confirmed', {speechId: latestSpeech.id, text: latestSpeech.text, frameKey: latestSpeech.frameKey});
});
$('record').addEventListener('click', () => {
  if (!canUseFrame()) return;
  const {jpeg, ...metadata} = current.frame;
  const spoken = latestSpeech && latestSpeech.text === current.guidance ? structuredClone(latestSpeech) : null;
  const row = {at: new Date().toISOString(), expected: $('scene').value, note: $('note').value,
    frame: metadata, ageMs: current.ageMs + Math.ceil(performance.now() - (validUntil - current.validForMs)),
    decision: current.decision, decisionReason: current.decisionReason, guidance: current.guidance,
    speech: spoken};
  records.push(row);
  $('noRecords')?.remove();
  const tr = document.createElement('tr');
  const values = [time(row.at), `${labels[row.expected]} · ${metadata.source.label}`,
    `${labels[metadata.raw]} / ${labels[metadata.stable]}`,
    `${row.decision} · ${row.guidance}`,
    spoken?.heardAt ? `청취 확인 ${time(spoken.heardAt)}` : '청취 미확인'];
  for (const value of values) {const td = document.createElement('td'); td.textContent = value; tr.append(td);}
  $('records').append(tr);
  event('recorded', {index: records.length - 1});
});
$('export').addEventListener('click', () => {
  event('export');
  const content = {schema: 'clipsense-web-evidence-v1', session,
    exportedAt: new Date().toISOString(), rules: current?.rules || null,
    clipOrigin: current?.clipOrigin || null, note: $('note').value, records, events,
    verification: {hardware: '현장 별도 확인', audibleSpeech: '사용자 청취 확인과 소리 포함 영상으로 확인',
      video: '별도 녹화 필요', studentExplanation: '두 학생 직접 설명 필요'}};
  const url = URL.createObjectURL(new Blob([JSON.stringify(content, null, 2)], {type: 'application/json'}));
  const a = document.createElement('a'); a.href = url; a.download = `clipsense-${session.id}.json`; a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
});
$('browserOrigin').textContent = location.origin;
if ('speechSynthesis' in window) {
  window.speechSynthesis.getVoices();
  window.speechSynthesis.addEventListener('voiceschanged', () => {
    event('voices_ready', {languages: window.speechSynthesis.getVoices().map(v => v.lang)});
  });
}
