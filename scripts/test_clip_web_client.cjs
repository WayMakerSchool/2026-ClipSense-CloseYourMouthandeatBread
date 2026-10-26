// 브라우저 API를 대체한 제어 흐름 검사. 실제 소리/브라우저 실측은 별도다.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const crypto = require('node:crypto').webcrypto;
const elements = new Map();
class Element {
  constructor() {this.textContent = ''; this.dataset = {}; this.hidden = false; this.disabled = false; this.handlers = {}; this.value = ''; this.children = [];}
  addEventListener(name, fn) {this.handlers[name] = fn;}
  removeAttribute(name) {delete this[name];}
  getContext() {return {clearRect() {}, strokeRect() {}, fillText() {}};}
  append(child) {this.children.push(child);}
  remove() {}
  click() {this.handlers.click?.();}
}
const get = id => {if (!elements.has(id)) elements.set(id, new Element()); return elements.get(id);};
let now = 0, requests = [], utterances = [], interval = null;
const visibility = {};
const document = {hidden: false, getElementById: get, createElement: () => new Element(),
  addEventListener: (name, fn) => {visibility[name] = fn;}};
const context = vm.createContext({document, navigator: {userAgent: 'unit-test', language: 'ko-KR'},
  location: {origin: 'http://test'}, crypto, devicePixelRatio: 1, performance: {now: () => now},
  window: {isSecureContext: false, speechSynthesis: {cancel() {}, getVoices: () => [],
    speak: u => utterances.push(u), addEventListener() {}}},
  SpeechSynthesisUtterance: class {constructor(text) {this.text = text;}},
  setTimeout: () => 1, clearTimeout() {}, setInterval: fn => {interval = fn;},
  fetch: (path, options) => new Promise(resolve => requests.push({path, options, resolve})),
  AbortController, structuredClone, Date, Blob, URL});
vm.runInContext(fs.readFileSync(require('node:path').join(__dirname, '../web_clip/app.js'), 'utf8'), context);
const fixture = {connection: 'connected', clipOrigin: 'http://sim', lastReceivedAt: new Date().toISOString(),
  ageMs: 10, validForMs: 1990, decision: 'WAIT', decisionReason: 'api_unavailable',
  guidance: '초록불로 판독했습니다. 실제 남은 시간을 확인할 수 없습니다. 기다리세요.',
  rules: {roiFraction: .25, version: 'test', config: {debounce_frames: 8}, staleMs: 2000, sha256: {'config.json': 'test'}},
  frame: {jpeg: 'AA==', seq: 1, bootId: 'boot', source: {kind: 'sim', label: 'SIM'},
    raw: 'GREEN', stable: 'GREEN', roi: [120, 90, 80, 60], red: {area_ratio: 0}, green: {area_ratio: .1}, rttMs: 1}};
const flush = () => new Promise(resolve => setImmediate(resolve));
async function respond(req, data) {req.resolve({ok: true, json: async () => data}); await flush();}
(async () => {
  get('start').click();
  assert.equal(utterances.length, 1, '사용자 클릭에서 음성 요청');
  const oldRequest = requests.shift();
  get('stop').click();
  get('start').click();
  const newRequest = requests.shift();
  await respond(oldRequest, fixture);
  assert.equal(get('frame').hidden, true, '중지 전 응답이 재시작 화면을 덮지 않음');
  await respond(newRequest, fixture);
  assert.equal(get('frame').hidden, false);
  assert.equal(get('source').textContent, 'SIM');
  assert.equal(get('decision').textContent, '기다리세요');
  const speech = utterances.at(-1);
  speech.onstart(); speech.onend();
  assert.equal(get('heard').disabled, false);
  get('heard').click();
  assert.match(get('speechStatus').textContent, /실제 청취 확인/);
  now = 2100;
  interval();
  assert.equal(get('frame').hidden, true, '서버 응답이 없어도 브라우저가 사진 만료');
  assert.equal(get('record').disabled, true);
  assert.match(get('guidance').textContent, /확인할 수 없습니다/);
  assert.match(utterances.at(-1).text, /확인할 수 없습니다/);
  assert.equal(get('heard').disabled, true, '만료 전 안내의 청취 버튼 무효화');
  document.hidden = true; visibility.visibilitychange();
  assert.equal(get('frame').hidden, true);
  get('stop').click();
  assert.equal(get('start').disabled, false);
  // 실제 음성 엔진이 없는 브라우저도 무음 상태를 명시한다.
  delete context.window.speechSynthesis;
  get('start').click();
  assert.match(get('speechStatus').textContent, /음성 미지원/);
  console.log('PASS: 재시작 응답 격리 · 브라우저 만료 · 대기 안내 · 음성 이벤트/청취 구분 · 미지원 브라우저');
})().catch(e => {console.error(e); process.exitCode = 1;});
