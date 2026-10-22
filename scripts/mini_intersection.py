"""한 단조 시계로 화면·T-Data 응답을 만드는 모의 교차로(실제 도로 신호 아님).

실행: python scripts/mini_intersection.py --port 8765
휴대폰에서 http://노트북의핫스팟IP:8765/ 를 연다. 서버는 Python 표준 라이브러리만 쓴다.
"""

from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import threading
import time
from urllib.parse import parse_qs, urlsplit

API_PATH = "/tapi/v2xSignalPhaseTimingFusionInformation/1.0"
DIRECTIONS = ("nt", "et", "st", "wt", "ne", "se", "sw", "nw")
LAMP_RED = "#ff0000"
LAMP_GREEN = "#00e000"
LAMP_OFF = "#262626"
STATUSES = {
    "red": "stop-And-Remain",
    "green": "protected-Movement-Allowed",
    "clearance": "protected-clearance",
}

# Lengths are vmin; center_x is viewport %, lamp centers are housing fractions.
# Shared by the HTML and the camera regression renderer.
LAYOUT = {
    "background": "#808080",
    "housing_color": "#101010",
    "center_x": 42,
    "housing_width": 35,
    "housing_height": 70,
    "corner_radius": 1,
    "lamp_diameter": 26,
    "top_center": 0.25,
    "bottom_center": 0.75,
    "countdown_gap": 4,
    "countdown_width": 34,
    "countdown_height": 22,
    "digit_width": 9.9,
    "digit_height": 18,
    # 자릿수 간격이 좁으면 QVGA JPEG 색 번짐으로 두 자리가 붙는다(숫자 폭의 80%).
    "digit_gap": 8,
    "segment_thickness_ratio": 0.125,
}
# Same a–g order and rectangular geometry as digits.draw_seven_segment.
DIGIT_SEGMENTS = ("abcdef", "bc", "abged", "abgcd", "fgbc",
                  "afgcd", "afgedc", "abc", "abcdefg", "abcdfg")

PAGE = """<!doctype html>
<html lang="ko"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ClipSense 모의 교차로</title>
<style>
:root { color-scheme: dark; __LAYOUT_CSS__ }
* { box-sizing: border-box; }
body { margin:0; background:__BACKGROUND__; color:#fff; font-family:system-ui,sans-serif; }
#housing { position:fixed; left:__CENTER_X__%; top:50%; transform:translate(-50%,-50%);
 width:var(--housing-width); height:var(--housing-height);
 border-radius:var(--corner-radius); background:__HOUSING_COLOR__; }
.lamp { position:absolute; left:50%; transform:translate(-50%,-50%);
 width:var(--lamp-diameter); height:var(--lamp-diameter); border-radius:50%; background:__OFF__; }
#top-lamp { top:__TOP_CENTER__%; }
#bottom-lamp { top:__BOTTOM_CENTER__%; }
#count { position:fixed;
 left:calc(__CENTER_X__% + var(--housing-width) / 2 + var(--countdown-gap));
 top:calc(50% + var(--housing-height) * __BOTTOM_OFFSET__);
 transform:translateY(-50%); width:var(--countdown-width); height:var(--countdown-height);
 background:__HOUSING_COLOR__; }
#count svg { display:block; width:100%; height:100%; }
#label { position:fixed; top:10px; left:10px; font-size:12px; color:#ddd; }
#controls { position:fixed; bottom:8px; right:8px; font-size:12px; }
button { padding:5px 8px; background:#222; color:#ddd; border:1px solid #666; }
button[aria-pressed="true"] { outline:1px solid white; }
</style>
<div id="label">SIM 모의 교차로 · 도로 신호 아님</div>
<div id="housing" role="img" aria-label="신호 확인 중">
 <div id="top-lamp" class="lamp"></div><div id="bottom-lamp" class="lamp"></div>
</div>
<div id="count" role="img" aria-label="잔여시간 표시 없음"><svg xmlns="http://www.w3.org/2000/svg"></svg></div>
<div id="controls">API <span id="mode">…</span>
<button data-mode="ok">ok</button><button data-mode="freeze">freeze</button>
<button data-mode="down">down</button></div>
<script>
const layout = __LAYOUT_JSON__;
const patterns = __PATTERNS_JSON__;
const housing = document.getElementById('housing');
const topLamp = document.getElementById('top-lamp'), bottomLamp = document.getElementById('bottom-lamp');
const count = document.getElementById('count'), svg = count.querySelector('svg');
svg.setAttribute('viewBox', `0 0 ${layout.countdown_width} ${layout.countdown_height}`);
const w = layout.digit_width, h = layout.digit_height;
const t = h * layout.segment_thickness_ratio;
const segments = {
  a:[t,0,w-t,t], b:[w-t,t,w,h/2-t/2], c:[w-t,h/2+t/2,w,h-t],
  d:[t,h-t,w-t,h], e:[0,h/2+t/2,t,h-t], f:[0,t,t,h/2-t/2],
  g:[t,h/2-t/2,w-t,h/2+t/2]
};
function drawCountdown(value) {
  svg.replaceChildren();
  count.setAttribute('aria-label', value === null ? '잔여시간 표시 없음' : `${value}초`);
  if (value === null) return;
  const chars = String(value).padStart(2, ' ');
  const x = (layout.countdown_width - 2*w - layout.digit_gap)/2;
  const y = (layout.countdown_height - h)/2;
  [...chars].forEach((ch, i) => {
    if (ch === ' ') return;
    for (const name of patterns[Number(ch)]) {
      const [x1,y1,x2,y2] = segments[name];
      const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
      rect.setAttribute('x', x + i*(w + layout.digit_gap) + x1);
      rect.setAttribute('y', y + y1);
      rect.setAttribute('width', x2-x1);
      rect.setAttribute('height', y2-y1);
      rect.setAttribute('fill', '__RED__');
      svg.appendChild(rect);
    }
  });
}
let busy = false;
async function poll() {
  if (busy) return;
  busy = true;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 800);
  try {
    const r = await fetch('/state', {cache:'no-store', signal:controller.signal});
    if (!r.ok) throw new Error('state');
    const s = await r.json();
    topLamp.style.background = s.phase === 'red' ? '__RED__' : '__OFF__';
    bottomLamp.style.background = (s.phase === 'green' ||
      (s.phase === 'clearance' && s.lampOn)) ? '__GREEN__' : '__OFF__';
    housing.setAttribute('aria-label', s.phase);
    drawCountdown((s.phase === 'green' || s.phase === 'clearance') ?
      Math.max(0, Math.min(99, Math.ceil(s.remainMs / 1000))) : null);
    document.getElementById('mode').textContent = s.apiMode;
    document.querySelectorAll('button').forEach(b =>
      b.setAttribute('aria-pressed', String(b.dataset.mode === s.apiMode)));
  } catch (_) {
    topLamp.style.background = bottomLamp.style.background = '__OFF__';
    housing.setAttribute('aria-label', '서버 연결 끊김');
    drawCountdown(null);
  } finally { clearTimeout(timer); busy = false; }
}
document.querySelectorAll('button').forEach(b => b.onclick = async () => {
  try {
    const r = await fetch('/control', {method:'POST',
      headers:{'Content-Type':'application/json'}, body:JSON.stringify({api:b.dataset.mode})});
    if (!r.ok) throw new Error('control');
    await poll();
  } catch (_) { document.getElementById('mode').textContent = '연결 오류'; }
});
poll(); setInterval(poll, 100);
</script></html>
"""
_PAGE_VALUES = {
    "LAYOUT_CSS": " ".join(f"--{key.replace('_', '-')}:{LAYOUT[key]}vmin;" for key in (
        "housing_width", "housing_height", "corner_radius", "lamp_diameter",
        "countdown_gap", "countdown_width", "countdown_height")),
    "LAYOUT_JSON": json.dumps(LAYOUT),
    "PATTERNS_JSON": json.dumps(DIGIT_SEGMENTS),
    "BACKGROUND": LAYOUT["background"], "HOUSING_COLOR": LAYOUT["housing_color"],
    "CENTER_X": LAYOUT["center_x"],
    "TOP_CENTER": LAYOUT["top_center"] * 100,
    "BOTTOM_CENTER": LAYOUT["bottom_center"] * 100,
    "BOTTOM_OFFSET": LAYOUT["bottom_center"] - 0.5,
    "RED": LAMP_RED, "GREEN": LAMP_GREEN, "OFF": LAMP_OFF,
}
for _key, _value in _PAGE_VALUES.items():
    PAGE = PAGE.replace(f"__{_key}__", str(_value))


class MiniIntersection:
    """포트 0과 start/stop으로 테스트에서도 사용할 수 있는 서버."""

    def __init__(self, *, port: int = 8765, listen: str = "0.0.0.0",
                 itst_id: str = "SIM-0001", direction: str = "nt",
                 red: float = 20, green: float = 12, clearance: float = 6):
        durations = (red, green, clearance)
        if any(not math.isfinite(d) or d <= 0 for d in durations):
            raise ValueError("각 신호 시간은 유한한 양수여야 합니다")
        if direction not in DIRECTIONS:
            raise ValueError("지원하지 않는 방위")
        self.itst_id, self.direction = itst_id, direction
        self.durations = durations
        self.cycle = sum(durations)
        if not math.isfinite(self.cycle):
            raise ValueError("주기 합계가 너무 큽니다")
        self._lock = threading.RLock()
        self._mode = "ok"
        self._last_record = None
        self._thread = None
        self._server = ThreadingHTTPServer((listen, port), _Handler)
        self._server.intersection = self
        self._started = time.monotonic()

    @property
    def base_url(self) -> str:
        host, port = self._server.server_address[:2]
        return f"http://{'127.0.0.1' if host == '0.0.0.0' else host}:{port}"

    def state(self) -> dict:
        with self._lock:
            offset = (time.monotonic() - self._started) % self.cycle
            for phase, duration in zip(STATUSES, self.durations):
                if offset < duration:
                    return {"phase": phase, "remainMs": int((duration - offset) * 1000),
                            "cycleMs": round(self.cycle * 1000), "apiMode": self._mode,
                            "itstId": self.itst_id, "direction": self.direction,
                            "lampOn": phase != "clearance" or int(offset * 2) % 2 == 0}
                offset -= duration

    def _record(self) -> dict:
        state = self.state()
        return {"itstId": self.itst_id, "trsmUtcTime": time.time_ns() // 1_000_000,
                f"{self.direction}PdsgStatNm": STATUSES[state["phase"]],
                f"{self.direction}PdsgRmdrCs": state["remainMs"] // 100,
                "dataId": "SIM", "simulated": True}

    def api_response(self) -> tuple[int, object]:
        with self._lock:
            if self._mode == "down":
                return 503, {"error": "simulated API outage"}
            if self._mode == "ok":
                self._last_record = self._record()
            return 200, [dict(self._last_record)]

    def control(self, mode: str) -> dict:
        with self._lock:
            # 첫 API 요청 전 freeze도 즉시 오래되기 시작하는 레코드를 갖는다.
            if mode == "freeze" and self._last_record is None:
                self._last_record = self._record()
            self._mode = mode
            return self.state()

    def start(self) -> None:
        self._started = time.monotonic()
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        if self._thread is not None:
            self._server.shutdown()
            self._thread.join()
        self._server.server_close()


class _Handler(BaseHTTPRequestHandler):
    # 기본 로그에는 쿼리(apiKey)가 포함된다. 오류 로그까지 모두 생략한다.
    def log_message(self, format, *args):
        pass

    def _send(self, status: int, value, *, html: bool = False) -> None:
        body = (value if html else json.dumps(value, ensure_ascii=False)).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8" if html else
                         "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlsplit(self.path)
        sim = self.server.intersection
        if url.path == "/":
            self._send(200, PAGE, html=True)
        elif url.path == "/state":
            self._send(200, sim.state())
        elif url.path == API_PATH:
            params = parse_qs(url.query)
            if not params.get("apiKey", [""])[0].strip():
                self._send(400, {"error": "non-empty apiKey required"})
            elif params.get("itstId", [""])[0] != sim.itst_id:
                self._send(200, [])
            else:
                self._send(*sim.api_response())
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if urlsplit(self.path).path != "/control":
            self._send(404, {"error": "not found"})
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 4096:
                raise ValueError("invalid body size")
            body = json.loads(self.rfile.read(size))
            if not isinstance(body, dict) or body.get("api") not in ("ok", "freeze", "down"):
                raise ValueError("invalid mode")
        except (ValueError, UnicodeError):
            self._send(400, {"error": "expected JSON api: ok, freeze, or down"})
            return
        self._send(200, self.server.intersection.control(body["api"]))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--listen", default="0.0.0.0")
    parser.add_argument("--itst-id", default="SIM-0001")
    parser.add_argument("--direction", choices=DIRECTIONS, default="nt")
    for name, default in (("red", 20), ("green", 12), ("clearance", 6)):
        parser.add_argument(f"--{name}", type=float, default=default)
    args = parser.parse_args()
    try:
        sim = MiniIntersection(**vars(args))
    except (ValueError, OverflowError, OSError) as exc:
        parser.error(str(exc))
    sim.start()
    print(f"SIM 모의 교차로 · 도로 신호 아님: {sim.base_url}/", flush=True)
    print(f"같은 핫스팟의 휴대폰: http://<노트북 IP>:{sim._server.server_port}/", flush=True)
    print(f"API base_url: {sim.base_url}{API_PATH}", flush=True)
    try:
        sim._thread.join()
    except KeyboardInterrupt:
        pass
    finally:
        sim.stop()


if __name__ == "__main__":
    main()
