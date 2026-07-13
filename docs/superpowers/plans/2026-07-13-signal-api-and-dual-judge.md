# 보행 신호 데이터 계층 (API + 이중 판단) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 서울 T-Data 실시간 보행신호 API를 표준 판정 객체로 번역하고, 기존 카메라
검출기와 AND 규칙으로 교차검증해 "건너세요/대기/확인불가"를 안전하게 결정하는
데이터 계층을 만든다.

**Architecture:** 순수 Python 3개 모듈. `signal_api`(HTTP→SignalReading 번역),
`vision_adapter`(기존 detector.py 상태→SignalReading), `judge`(두 SignalReading→
Decision, AND/Fail-Safe). 각 모듈은 판정하지 않고 번역만 하거나(앞 둘), 번역된 것만
합성한다(judge). 네트워크·카메라 없이 단위 테스트 가능하도록 순수 함수 경계를 둔다.

**Tech Stack:** Python 3.14, 표준 라이브러리만(urllib, json, dataclasses). 기존
`detector.py` 재사용. 외부 테스트 프레임워크 없음 — 프로젝트 관례(`scripts/test_*.py`
+ `check()` 헬퍼 + `sys.exit(1)`)를 따른다.

## Global Constraints

- **딥러닝 금지, 런타임 인터넷 의존 최소화** — API는 부속, 카메라가 메인. API 실패가
  앱을 죽이면 안 됨(예외를 삼켜 UNKNOWN 반환).
- **정직성 원칙(브리프 4)** — 모르는 상태값·stale·오류·None은 전부 `UNKNOWN`.
  절대 GREEN으로 추측 금지. AND 규칙: 두 소스 모두 GREEN일 때만 WALK.
- **API 키는 환경변수/설정으로만 주입** — 소스코드·저장소 하드코딩 금지.
- **테스트는 pytest 아님** — `python scripts/test_<name>.py` 로 직접 실행, 표준
  라이브러리만, 실패 시 `sys.exit(1)`. 기존 `scripts/test_state_machine.py` 패턴 준수.
- **실측 API 사실(2026-07-13 실제 호출):** 엔드포인트
  `https://t-data.seoul.go.kr/apig/apiman-gateway/tapi/v2xSignalPhaseTimingFusionInformation/1.0`,
  파라미터 `apiKey`/`type=json`/`itstId`, 응답=레코드 배열(래핑 없음), 잔여 단위 1/10초,
  상태 enum `protected-Movement-Allowed`·`permissive-Movement-Allowed`(초록),
  `protected-clearance`·`permissive-clearance`(점멸), `stop-And-Remain`(빨강).

---

## File Structure

- **Create `signals.py`** — 공유 표준 타입. `SignalColor`(상수), `SignalReading`
  (dataclass), `Decision`(상수). 세 모듈이 이걸 import 한다. 가장 먼저 만든다.
- **Create `signal_api.py`** — 서울 T-Data 번역기. HTTP 호출 + JSON→SignalReading.
  순수 파싱 함수(`parse_reading`)와 네트워크 함수(`fetch_reading`)를 분리해
  파싱을 네트워크 없이 테스트한다.
- **Create `vision_adapter.py`** — 기존 `detector.py`의 상태 문자열(STATE_RED 등)을
  `SignalReading(source=VISION)`로 변환하는 얇은 순수 함수.
- **Create `judge.py`** — 두 SignalReading → Decision. AND 규칙 + Fail-Safe + 잔여시간
  충분 판정. 순수 함수, 네트워크·카메라 무관.
- **Create `scripts/test_signals.py`** — SignalReading 타입 기본 동작.
- **Create `scripts/test_signal_api.py`** — 실측 응답 픽스처로 파싱·매핑·안전망 검증.
- **Create `scripts/test_vision_adapter.py`** — 상태 매핑 검증.
- **Create `scripts/test_judge.py`** — 모든 소스 조합에서 WALK가 AND일 때만 나옴을 검증.

---

## Task 1: 공유 표준 타입 `signals.py`

**Files:**
- Create: `signals.py`
- Test: `scripts/test_signals.py`

**Interfaces:**
- Consumes: (없음)
- Produces:
  - 상수 `GREEN="GREEN"`, `RED="RED"`, `CLEARANCE="CLEARANCE"`, `UNKNOWN="UNKNOWN"`
  - 상수 `SRC_API="API"`, `SRC_VISION="VISION"`
  - dataclass `SignalReading(color: str, remain_sec: float|None, source: str,
    fresh_ms: int, raw: str|None=None)`
  - `SignalReading.is_go() -> bool` — color==GREEN 이면 True (편의 메서드)

- [ ] **Step 1: Write the failing test**

Create `scripts/test_signals.py`:

```python
"""signals.py 표준 타입 단위 테스트. 실행: python scripts/test_signals.py"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from signals import (SignalReading, GREEN, RED, CLEARANCE, UNKNOWN,
                     SRC_API, SRC_VISION)

FAILURES = []


def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print(f"[{status}] {name}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(name)


r = SignalReading(color=GREEN, remain_sec=24.1, source=SRC_API, fresh_ms=120)
check("필드 보존", r.color == GREEN and r.remain_sec == 24.1
      and r.source == SRC_API and r.fresh_ms == 120)
check("raw 기본값 None", r.raw is None)
check("is_go: GREEN이면 True", r.is_go() is True)

r2 = SignalReading(color=RED, remain_sec=None, source=SRC_VISION, fresh_ms=0)
check("is_go: RED이면 False", r2.is_go() is False)
check("remain_sec None 허용", r2.remain_sec is None)

r3 = SignalReading(color=UNKNOWN, remain_sec=None, source=SRC_API, fresh_ms=0)
check("is_go: UNKNOWN이면 False", r3.is_go() is False)
check("상수 4색 구분", len({GREEN, RED, CLEARANCE, UNKNOWN}) == 4)

print("=" * 50)
if FAILURES:
    print(f"FAIL {len(FAILURES)}건: {FAILURES}")
    sys.exit(1)
print("signals 단위 테스트 전부 PASS")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/python scripts/test_signals.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'signals'`

- [ ] **Step 3: Write minimal implementation**

Create `signals.py`:

```python
"""보행 신호 판정의 공유 표준 타입.

signal_api / vision_adapter / judge 세 모듈이 이 표현으로만 대화한다.
색 enum은 4-값 고정이며, UNKNOWN은 "모른다"는 1급 상태다 (추측 금지).
"""

from dataclasses import dataclass

# 신호 색 (4-값 고정)
GREEN = "GREEN"          # 건널 수 있음 (보행 초록)
RED = "RED"              # 멈춤 (보행 빨강)
CLEARANCE = "CLEARANCE"  # 초록 점멸 (곧 끝남 — 새로 건너기 시작 금지)
UNKNOWN = "UNKNOWN"      # 확인 불가 (모르는 값/오래된 데이터/오류/신호 없음)

# 판정 출처
SRC_API = "API"
SRC_VISION = "VISION"


@dataclass
class SignalReading:
    """한 소스(API 또는 비전)의 보행 신호 판정 한 건."""
    color: str            # 위 4-값 중 하나
    remain_sec: float | None  # 남은 초. 모르면 None (색과 독립적으로 채워짐)
    source: str           # SRC_API | SRC_VISION
    fresh_ms: int         # 이 값이 몇 ms 전 것인지 (신선도)
    raw: str | None = None    # 디버그용 원문 (예: 'protected-Movement-Allowed')

    def is_go(self) -> bool:
        """이 판정 하나만 볼 때 '초록'인가. (최종 결정은 judge가 함)"""
        return self.color == GREEN
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/python scripts/test_signals.py`
Expected: PASS — "signals 단위 테스트 전부 PASS"

- [ ] **Step 5: Commit**

```bash
git add signals.py scripts/test_signals.py
git commit -m "feat: add shared SignalReading standard type"
```

---

## Task 2: 서울 T-Data 응답 파싱 `signal_api.parse_reading`

이 태스크는 **네트워크 없는 순수 파싱**만 만든다(실측 응답을 픽스처로). HTTP 호출은
Task 3에서 얹는다. 파싱과 네트워크를 나눠야 파싱을 결정적으로 테스트할 수 있다.

**Files:**
- Create: `signal_api.py`
- Test: `scripts/test_signal_api.py`

**Interfaces:**
- Consumes: `signals.SignalReading`, 색 상수 (Task 1)
- Produces:
  - `STATUS_MAP: dict[str, str]` — API enum → 색 상수
  - `parse_reading(records: list[dict], direction: str, now_ms: int,
    stale_ms: int = 2000) -> SignalReading` — 레코드 배열 + 방위 접두사(예:'nt')로
    해당 보행신호를 SignalReading(source=API)으로 번역. 미지/stale/없음 → UNKNOWN.

- [ ] **Step 1: Write the failing test**

Create `scripts/test_signal_api.py`:

```python
"""signal_api 파싱·매핑·안전망 단위 테스트 (네트워크 없음, 실측 픽스처).
실행: python scripts/test_signal_api.py"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from signals import GREEN, RED, CLEARANCE, UNKNOWN, SRC_API
from signal_api import parse_reading, STATUS_MAP

FAILURES = []


def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print(f"[{status}] {name}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(name)


# 실측 응답을 본뜬 레코드 (trsmUtcTime, 방위별 Pdsg 필드).
# 잔여는 1/10초 단위 정수 문자열/숫자로 온다 (실측: 241 = 24.1초).
NOW = 1_783_943_330_618
def rec(**over):
    base = {
        "itstId": "1537", "trsmUtcTime": NOW,
        "ntPdsgStatNm": None, "ntPdsgRmdrCs": None,
        "nePdsgStatNm": "protected-Movement-Allowed", "nePdsgRmdrCs": 241,
        "nwPdsgStatNm": "stop-And-Remain", "nwPdsgRmdrCs": 281,
        "stPdsgStatNm": "protected-clearance", "stPdsgRmdrCs": 33,
    }
    base.update(over)
    return base


# 1) 초록 매핑 + 잔여 1/10초 → 초 변환
r = parse_reading([rec()], "ne", now_ms=NOW)
check("초록 매핑", r.color == GREEN, f"실제 {r.color}")
check("잔여 241→24.1초", r.remain_sec == 24.1, f"실제 {r.remain_sec}")
check("source=API", r.source == SRC_API)
check("raw 원문 보존", r.raw == "protected-Movement-Allowed")

# 2) 빨강 매핑
r = parse_reading([rec()], "nw", now_ms=NOW)
check("빨강 매핑", r.color == RED, f"실제 {r.color}")

# 3) 점멸(clearance) 매핑
r = parse_reading([rec()], "st", now_ms=NOW)
check("clearance→CLEARANCE", r.color == CLEARANCE, f"실제 {r.color}")

# 4) 해당 방위 신호 없음(None) → UNKNOWN
r = parse_reading([rec()], "nt", now_ms=NOW)
check("None 방위 → UNKNOWN", r.color == UNKNOWN, f"실제 {r.color}")
check("None이면 잔여도 None", r.remain_sec is None)

# 5) 처음 보는 상태 문자열 → UNKNOWN (추측 금지), raw 보존
r = parse_reading([rec(nePdsgStatNm="some-New-Phase")], "ne", now_ms=NOW)
check("미지 상태 → UNKNOWN", r.color == UNKNOWN, f"실제 {r.color}")
check("미지여도 raw 보존", r.raw == "some-New-Phase")

# 6) stale (전송시각이 now보다 stale_ms 이상 과거) → UNKNOWN
r = parse_reading([rec()], "ne", now_ms=NOW + 5000, stale_ms=2000)
check("stale → UNKNOWN", r.color == UNKNOWN, f"실제 {r.color}")

# 7) fresh 판정: fresh_ms가 now - trsm 로 계산됨
r = parse_reading([rec()], "ne", now_ms=NOW + 500, stale_ms=2000)
check("fresh_ms 계산", r.color == GREEN and r.fresh_ms == 500,
      f"실제 color={r.color} fresh={r.fresh_ms}")

# 8) 빈 레코드 배열 → UNKNOWN (터지지 않음)
r = parse_reading([], "ne", now_ms=NOW)
check("빈 배열 → UNKNOWN", r.color == UNKNOWN, f"실제 {r.color}")

# 9) 잔여값이 문자열이어도 처리
r = parse_reading([rec(nePdsgRmdrCs="241")], "ne", now_ms=NOW)
check("문자열 잔여 처리", r.remain_sec == 24.1, f"실제 {r.remain_sec}")

# 10) STATUS_MAP은 알려진 5개만, 나머지는 매핑에 없음
check("STATUS_MAP 알려진 값만",
      set(STATUS_MAP) == {"protected-Movement-Allowed", "permissive-Movement-Allowed",
                          "protected-clearance", "permissive-clearance",
                          "stop-And-Remain"},
      f"실제 {sorted(STATUS_MAP)}")

print("=" * 50)
if FAILURES:
    print(f"FAIL {len(FAILURES)}건: {FAILURES}")
    sys.exit(1)
print("signal_api 파싱 단위 테스트 전부 PASS")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/python scripts/test_signal_api.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'signal_api'`

- [ ] **Step 3: Write minimal implementation**

Create `signal_api.py`:

```python
"""서울 T-Data 실시간 보행신호 API 번역기.

책임: (교차로 레코드, 방위) → SignalReading(source=API). 판단하지 않는다.
정직성: 모르는 상태값·stale·None·오류는 전부 UNKNOWN (GREEN 추측 금지).

실측 사실(2026-07-13 실제 호출):
- 응답은 레코드 배열(header/body 래핑 없음)
- 보행신호 상태: {방위}PdsgStatNm (방위 접두 nt/et/st/wt/ne/se/sw/nw)
- 보행신호 잔여: {방위}PdsgRmdrCs, 단위 1/10초 (241 = 24.1초)
- 전송시각: trsmUtcTime (epoch ms)
"""

from signals import (SignalReading, GREEN, RED, CLEARANCE, UNKNOWN, SRC_API)

# API 상태 enum(SAE J2735) → 우리 색. 화이트리스트: 여기 없는 값은 UNKNOWN.
STATUS_MAP = {
    "protected-Movement-Allowed": GREEN,
    "permissive-Movement-Allowed": GREEN,
    "protected-clearance": CLEARANCE,
    "permissive-clearance": CLEARANCE,
    "stop-And-Remain": RED,
}


def _to_remain_sec(raw_cs) -> float | None:
    """1/10초 단위 잔여값 → 초. 파싱 불가/None이면 None."""
    if raw_cs is None or raw_cs == "":
        return None
    try:
        return round(float(raw_cs) / 10.0, 1)
    except (TypeError, ValueError):
        return None


def parse_reading(records: list[dict], direction: str, now_ms: int,
                  stale_ms: int = 2000) -> SignalReading:
    """레코드 배열 + 방위 접두사(예 'ne') → SignalReading(source=API).

    미지 상태/stale/신호 없음/빈 배열은 전부 color=UNKNOWN으로 안전하게 실패.
    """
    if not records:
        return SignalReading(UNKNOWN, None, SRC_API, fresh_ms=0)

    rec = records[0]
    stat = rec.get(f"{direction}PdsgStatNm")
    rmdr = rec.get(f"{direction}PdsgRmdrCs")

    # 신선도
    trsm = rec.get("trsmUtcTime")
    try:
        fresh_ms = int(now_ms - float(trsm)) if trsm is not None else 0
    except (TypeError, ValueError):
        fresh_ms = 0

    # stale → UNKNOWN (원문은 보존해 디버깅 가능)
    if fresh_ms > stale_ms:
        return SignalReading(UNKNOWN, None, SRC_API, fresh_ms=fresh_ms,
                             raw=str(stat) if stat is not None else None)

    color = STATUS_MAP.get(stat, UNKNOWN)
    remain = _to_remain_sec(rmdr) if color != UNKNOWN else None
    raw = str(stat) if stat is not None else None
    return SignalReading(color, remain, SRC_API, fresh_ms=max(0, fresh_ms), raw=raw)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/python scripts/test_signal_api.py`
Expected: PASS — "signal_api 파싱 단위 테스트 전부 PASS"

- [ ] **Step 5: Commit**

```bash
git add signal_api.py scripts/test_signal_api.py
git commit -m "feat: add Seoul T-Data pedestrian signal response parser"
```

---

## Task 3: HTTP 호출 `signal_api.fetch_reading`

파싱 위에 네트워크 계층을 얹는다. 키는 환경변수. 오류는 전부 삼켜 UNKNOWN.
이 태스크의 자동 테스트는 "네트워크 없이 오류 경로가 UNKNOWN을 내는가"만 검증한다
(실서버 호출은 수동 통합 확인).

**Files:**
- Modify: `signal_api.py` (함수 추가)
- Test: `scripts/test_signal_api.py` (오류 경로 케이스 추가)

**Interfaces:**
- Consumes: `parse_reading` (Task 2)
- Produces:
  - `fetch_reading(itst_id: str, direction: str, api_key: str, *,
    now_ms: int, base_url: str = ..., timeout: float = 5.0,
    opener=None) -> SignalReading` — API 호출 후 parse_reading 위임. 네트워크·
    HTTP·JSON 오류는 모두 잡아 `SignalReading(UNKNOWN, None, SRC_API, fresh_ms=0)`.
    `opener`는 테스트 주입용(기본 None이면 urllib 사용).

- [ ] **Step 1: Write the failing test (오류 경로 케이스 추가)**

`scripts/test_signal_api.py`의 `print("=" * 50)` 바로 위에 추가:

```python
# --- Task 3: fetch_reading 오류 경로 (네트워크 없이 opener 주입) ---
from signal_api import fetch_reading

def raising_opener(url, timeout):
    raise OSError("network down")

r = fetch_reading("1537", "ne", "dummy-key", now_ms=NOW, opener=raising_opener)
check("네트워크 오류 → UNKNOWN", r.color == UNKNOWN and r.source == SRC_API,
      f"실제 {r.color}")

class FakeResp:
    def __init__(self, body): self._body = body
    def read(self): return self._body.encode("utf-8")
    def __enter__(self): return self
    def __exit__(self, *a): return False

def bad_json_opener(url, timeout):
    return FakeResp("<html>error</html>")

r = fetch_reading("1537", "ne", "dummy-key", now_ms=NOW, opener=bad_json_opener)
check("JSON 파싱 실패 → UNKNOWN", r.color == UNKNOWN, f"실제 {r.color}")

import json as _json
def ok_opener(url, timeout):
    return FakeResp(_json.dumps([{
        "itstId": "1537", "trsmUtcTime": NOW,
        "nePdsgStatNm": "protected-Movement-Allowed", "nePdsgRmdrCs": 241,
    }]))

r = fetch_reading("1537", "ne", "dummy-key", now_ms=NOW, opener=ok_opener)
check("정상 응답 → 파싱 위임(GREEN)", r.color == GREEN and r.remain_sec == 24.1,
      f"실제 {r.color}/{r.remain_sec}")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/python scripts/test_signal_api.py`
Expected: FAIL — `ImportError: cannot import name 'fetch_reading'`

- [ ] **Step 3: Write minimal implementation (signal_api.py에 추가)**

`signal_api.py` 상단 import에 추가:

```python
import json
import urllib.parse
import urllib.request
```

파일 끝에 추가:

```python
DEFAULT_BASE_URL = ("https://t-data.seoul.go.kr/apig/apiman-gateway/tapi/"
                    "v2xSignalPhaseTimingFusionInformation/1.0")


def _default_opener(url: str, timeout: float):
    req = urllib.request.Request(url, headers={"User-Agent": "clipsense/1.0"})
    return urllib.request.urlopen(req, timeout=timeout)


def fetch_reading(itst_id: str, direction: str, api_key: str, *,
                  now_ms: int, base_url: str = DEFAULT_BASE_URL,
                  timeout: float = 5.0, opener=None) -> SignalReading:
    """서울 T-Data를 호출해 해당 교차로·방위 보행신호를 SignalReading으로.

    네트워크·HTTP·JSON 오류는 전부 삼켜 UNKNOWN을 반환한다 (앱을 죽이지 않음).
    opener(url, timeout)를 주입하면 네트워크 없이 테스트 가능.
    api_key는 호출자가 환경변수/설정에서 읽어 넘긴다 (여기서 하드코딩 안 함).
    """
    opener = opener or _default_opener
    params = urllib.parse.urlencode({
        "apiKey": api_key, "type": "json", "itstId": itst_id, "numOfRows": "10",
    })
    url = f"{base_url}?{params}"
    try:
        with opener(url, timeout) as resp:
            body = resp.read()
        records = json.loads(body)
        if not isinstance(records, list):
            return SignalReading(UNKNOWN, None, SRC_API, fresh_ms=0)
        return parse_reading(records, direction, now_ms=now_ms)
    except Exception:
        # 네트워크/HTTP/JSON/기타 — 정직하게 UNKNOWN (조용히 실패)
        return SignalReading(UNKNOWN, None, SRC_API, fresh_ms=0)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/python scripts/test_signal_api.py`
Expected: PASS — "signal_api 파싱 단위 테스트 전부 PASS"

- [ ] **Step 5: Commit**

```bash
git add signal_api.py scripts/test_signal_api.py
git commit -m "feat: add HTTP fetch layer with fail-safe UNKNOWN on errors"
```

---

## Task 4: 비전 어댑터 `vision_adapter.py`

기존 `detector.py`의 상태 문자열을 표준 SignalReading으로 번역하는 얇은 순수 함수.
검출 알고리즘은 건드리지 않는다.

**Files:**
- Create: `vision_adapter.py`
- Test: `scripts/test_vision_adapter.py`

**Interfaces:**
- Consumes: `signals` 상수, `detector`의 STATE_* 상수
- Produces:
  - `to_reading(state: str, remain_sec: float|None = None,
    fresh_ms: int = 0) -> SignalReading` — detector 상태(STATE_RED/GREEN/
    GREEN_BLINK/UNKNOWN) → SignalReading(source=VISION). GREEN_BLINK→CLEARANCE.

- [ ] **Step 1: Write the failing test**

Create `scripts/test_vision_adapter.py`:

```python
"""vision_adapter 상태 매핑 단위 테스트. 실행: python scripts/test_vision_adapter.py"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from signals import GREEN, RED, CLEARANCE, UNKNOWN, SRC_VISION
from detector import STATE_RED, STATE_GREEN, STATE_GREEN_BLINK, STATE_UNKNOWN
from vision_adapter import to_reading

FAILURES = []


def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print(f"[{status}] {name}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(name)


check("RED 매핑", to_reading(STATE_RED).color == RED)
check("GREEN 매핑", to_reading(STATE_GREEN).color == GREEN)
check("GREEN_BLINK→CLEARANCE", to_reading(STATE_GREEN_BLINK).color == CLEARANCE)
check("UNKNOWN 매핑", to_reading(STATE_UNKNOWN).color == UNKNOWN)

r = to_reading(STATE_GREEN, remain_sec=12.0, fresh_ms=100)
check("source=VISION", r.source == SRC_VISION)
check("잔여·신선도 보존", r.remain_sec == 12.0 and r.fresh_ms == 100)
check("잔여 기본 None", to_reading(STATE_RED).remain_sec is None)

# 모르는 상태 문자열(방어): 매핑에 없으면 UNKNOWN
check("미지 상태 → UNKNOWN", to_reading("SOMETHING_ELSE").color == UNKNOWN)

print("=" * 50)
if FAILURES:
    print(f"FAIL {len(FAILURES)}건: {FAILURES}")
    sys.exit(1)
print("vision_adapter 단위 테스트 전부 PASS")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/python scripts/test_vision_adapter.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'vision_adapter'`

- [ ] **Step 3: Write minimal implementation**

Create `vision_adapter.py`:

```python
"""기존 카메라 검출기(detector.py) 상태 → 표준 SignalReading 번역.

검출 알고리즘은 바꾸지 않는다. 상태 문자열 표현만 표준화한다.
GREEN_BLINK(초록 점멸)는 CLEARANCE로 매핑한다.
"""

from signals import (SignalReading, GREEN, RED, CLEARANCE, UNKNOWN, SRC_VISION)
from detector import (STATE_RED, STATE_GREEN, STATE_GREEN_BLINK, STATE_UNKNOWN)

_STATE_MAP = {
    STATE_RED: RED,
    STATE_GREEN: GREEN,
    STATE_GREEN_BLINK: CLEARANCE,
    STATE_UNKNOWN: UNKNOWN,
}


def to_reading(state: str, remain_sec: float | None = None,
               fresh_ms: int = 0) -> SignalReading:
    """detector 상태 → SignalReading(source=VISION). 미지 상태는 UNKNOWN."""
    color = _STATE_MAP.get(state, UNKNOWN)
    return SignalReading(color, remain_sec, SRC_VISION, fresh_ms=fresh_ms)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/python scripts/test_vision_adapter.py`
Expected: PASS — "vision_adapter 단위 테스트 전부 PASS"

- [ ] **Step 5: Commit**

```bash
git add vision_adapter.py scripts/test_vision_adapter.py
git commit -m "feat: add vision detector -> SignalReading adapter"
```

---

## Task 5: 이중 판단 엔진 `judge.py`

두 SignalReading → Decision. AND 규칙 + Fail-Safe + 잔여시간 충분 판정. 안전 핵심.

**Files:**
- Create: `judge.py`
- Test: `scripts/test_judge.py`

**Interfaces:**
- Consumes: `signals.SignalReading`, 색 상수 (Task 1)
- Produces:
  - 상수 `WALK="WALK"`, `WAIT="WAIT"`, `UNKNOWN_DECISION="UNKNOWN"`
  - `decide(api: SignalReading|None, vision: SignalReading|None, *,
    need_sec: float = 7.0, stale_ms: int = 2000,
    allow_single_source: bool = True) -> str` — 최종 결정.

- [ ] **Step 1: Write the failing test**

Create `scripts/test_judge.py`:

```python
"""judge 이중 판단 단위 테스트. WALK는 오직 AND 만족일 때만.
실행: python scripts/test_judge.py"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from signals import SignalReading, GREEN, RED, CLEARANCE, UNKNOWN, SRC_API, SRC_VISION
from judge import decide, WALK, WAIT, UNKNOWN_DECISION

FAILURES = []


def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print(f"[{status}] {name}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(name)


def api(color, remain=30.0, fresh=100):
    return SignalReading(color, remain, SRC_API, fresh_ms=fresh)

def vis(color, remain=None, fresh=100):
    return SignalReading(color, remain, SRC_VISION, fresh_ms=fresh)


# 1) 둘 다 초록 + 잔여충분 + fresh → WALK
check("둘 다 초록 → WALK",
      decide(api(GREEN, 30), vis(GREEN)) == WALK)

# 2) 불일치는 전부 WAIT (핵심 안전 규칙)
check("API초록·비전빨강 → WAIT", decide(api(GREEN), vis(RED)) == WAIT)
check("API빨강·비전초록 → WAIT", decide(api(RED), vis(GREEN)) == WAIT)
check("API초록·비전점멸 → WAIT", decide(api(GREEN), vis(CLEARANCE)) == WAIT)
check("API점멸·비전초록 → WAIT", decide(api(CLEARANCE), vis(GREEN)) == WAIT)

# 3) 둘 다 빨강 → WAIT
check("둘 다 빨강 → WAIT", decide(api(RED), vis(RED)) == WAIT)

# 4) 잔여시간 부족 → WAIT (둘 다 초록이어도)
check("잔여 부족 → WAIT",
      decide(api(GREEN, 3.0), vis(GREEN), need_sec=7.0) == WAIT)

# 5) 잔여 정보가 아예 없으면(둘 다 None) 보수적으로 WAIT
check("잔여 정보 없음 → WAIT",
      decide(api(GREEN, None), vis(GREEN, None), need_sec=7.0) == WAIT)

# 6) 한쪽만 stale이면 → WAIT
check("한쪽 stale → WAIT",
      decide(api(GREEN, 30, fresh=5000), vis(GREEN), stale_ms=2000) == WAIT)

# 7) 둘 다 UNKNOWN → UNKNOWN_DECISION
check("둘 다 UNKNOWN → 확인불가",
      decide(api(UNKNOWN, None), vis(UNKNOWN, None)) == UNKNOWN_DECISION)

# 8) 단일 소스(비전만, API=None) 허용 시: 비전 초록+잔여충분 → WALK
check("비전 단독 초록 → WALK (allow)",
      decide(None, vis(GREEN, 30), allow_single_source=True) == WALK)

# 9) 단일 소스 비허용 시: 비전만 있으면 → WAIT
check("단일 소스 비허용 → WAIT",
      decide(None, vis(GREEN, 30), allow_single_source=False) == WAIT)

# 10) 단일 소스라도 빨강이면 WAIT
check("비전 단독 빨강 → WAIT",
      decide(None, vis(RED), allow_single_source=True) == WAIT)

# 11) 둘 다 None → UNKNOWN_DECISION (입력 자체가 없음)
check("둘 다 None → 확인불가",
      decide(None, None) == UNKNOWN_DECISION)

# 12) 단일 소스 초록인데 잔여 없음 → WAIT (보수)
check("단일 소스 초록·잔여없음 → WAIT",
      decide(None, vis(GREEN, None), allow_single_source=True) == WAIT)

print("=" * 50)
if FAILURES:
    print(f"FAIL {len(FAILURES)}건: {FAILURES}")
    sys.exit(1)
print("judge 단위 테스트 전부 PASS")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/python scripts/test_judge.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'judge'`

- [ ] **Step 3: Write minimal implementation**

Create `judge.py`:

```python
"""이중 판단 엔진: API + 비전 → WALK / WAIT / UNKNOWN.

안전 핵심 (브리프 Fail-Safe):
- WALK는 두 소스가 모두 GREEN + 잔여시간 충분 + 둘 다 fresh일 때만.
- 하나라도 불일치/부족/stale → WAIT.
- 두 소스 모두 UNKNOWN 또는 입력 없음 → UNKNOWN_DECISION.
- 단일 소스만 가용할 때는 allow_single_source로 정책 제어(서울 밖 카메라 단독).
"""

from signals import SignalReading, GREEN, UNKNOWN

WALK = "WALK"
WAIT = "WAIT"
UNKNOWN_DECISION = "UNKNOWN"


def _usable(r: SignalReading | None, stale_ms: int) -> bool:
    """이 판정을 판단에 쓸 수 있는가 (존재 + UNKNOWN 아님 + fresh)."""
    return r is not None and r.color != UNKNOWN and r.fresh_ms <= stale_ms


def _remain_ok(readings: list[SignalReading], need_sec: float) -> bool:
    """가용한 잔여시간 중 가장 짧은 것이 need_sec 이상인가.
    잔여 정보가 하나도 없으면 보수적으로 False (충분함을 증명 못 하므로)."""
    remains = [r.remain_sec for r in readings if r.remain_sec is not None]
    if not remains:
        return False
    return min(remains) >= need_sec


def decide(api: SignalReading | None, vision: SignalReading | None, *,
           need_sec: float = 7.0, stale_ms: int = 2000,
           allow_single_source: bool = True) -> str:
    """최종 보행 결정. 기본은 AND(둘 다 초록)일 때만 WALK."""
    api_ok = _usable(api, stale_ms)
    vis_ok = _usable(vision, stale_ms)

    # 둘 다 못 씀 → 확인 불가
    if not api_ok and not vis_ok:
        return UNKNOWN_DECISION

    # 두 소스 다 가용: AND 규칙
    if api_ok and vis_ok:
        both_green = api.color == GREEN and vision.color == GREEN
        if both_green and _remain_ok([api, vision], need_sec):
            return WALK
        return WAIT

    # 단일 소스만 가용
    if not allow_single_source:
        return WAIT
    single = api if api_ok else vision
    if single.color == GREEN and _remain_ok([single], need_sec):
        return WALK
    return WAIT
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/python scripts/test_judge.py`
Expected: PASS — "judge 단위 테스트 전부 PASS"

- [ ] **Step 5: Commit**

```bash
git add judge.py scripts/test_judge.py
git commit -m "feat: add dual-source AND judge with fail-safe"
```

---

## Task 6: 단위 테스트 러너 신설 + 수동 통합 확인

`scripts/run_pipeline_test.py`는 합성 영상 파이프라인 검증 전용이라 단위 테스트를
끼워넣기에 맞지 않는다(성격이 다름). 데이터 계층 단위 테스트 4개를 묶는 **별도의
작은 러너**를 신설하고, 실서버 1회 수동 확인 절차를 남긴다.

**Files:**
- Create: `scripts/run_unit_tests.py` (신규 단위 테스트 4개를 순차 서브프로세스 실행)
- Create: `scripts/probe_signal_api_live.py` (실서버 수동 확인, 키는 환경변수)

**Interfaces:**
- Consumes: 전부 (Task 1-5)
- Produces: (없음 — 러너·수동 스크립트)

- [ ] **Step 1: 단위 테스트 러너 작성**

Create `scripts/run_unit_tests.py`:

```python
"""데이터 계층 단위 테스트를 한 번에 실행. 실행: python scripts/run_unit_tests.py

각 test_*.py는 실패 시 sys.exit(1)로 끝나는 독립 스크립트다. 여기서는
서브프로세스로 순차 실행하고, 하나라도 실패하면 전체를 1로 종료한다.
파이프라인 영상 검증(run_pipeline_test.py)과는 별개다.
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TESTS = [
    "test_signals.py",
    "test_signal_api.py",
    "test_vision_adapter.py",
    "test_judge.py",
    "test_detector.py",
    "test_state_machine.py",
    "test_digits.py",
    "test_voice.py",
]

failed = []
for name in TESTS:
    path = ROOT / "scripts" / name
    if not path.exists():
        print(f"[SKIP] {name} (없음)")
        continue
    print(f"--- {name} ---")
    proc = subprocess.run([sys.executable, str(path)], cwd=ROOT)
    if proc.returncode != 0:
        failed.append(name)

print("=" * 50)
if failed:
    print(f"FAIL: {failed}")
    sys.exit(1)
print("단위 테스트 러너 — 전부 PASS")
```

- [ ] **Step 2: 러너 실행**

Run: `.venv/bin/python scripts/run_unit_tests.py`
Expected: 신규 4개 + 기존 단위 테스트 전부 PASS. 마지막 줄 "전부 PASS".

- [ ] **Step 3: 실서버 수동 확인 스크립트 작성**

Create `scripts/probe_signal_api_live.py`:

```python
"""서울 T-Data 실서버 1회 수동 확인. 키는 환경변수 TDATA_KEY.
실행: TDATA_KEY=... python scripts/probe_signal_api_live.py [itstId] [방위]
자동 테스트 아님 — 실동작 대조용. 응답의 색·잔여가 실제 신호와 맞는지 눈으로 확인.
"""
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from signal_api import fetch_reading

key = os.environ.get("TDATA_KEY", "").strip()
if not key:
    print("환경변수 TDATA_KEY가 필요합니다.")
    sys.exit(1)

itst = sys.argv[1] if len(sys.argv) > 1 else "1537"
direction = sys.argv[2] if len(sys.argv) > 2 else "ne"
now_ms = int(time.time() * 1000)

r = fetch_reading(itst, direction, key, now_ms=now_ms)
print(f"교차로 {itst} 방위 {direction}: color={r.color} "
      f"remain={r.remain_sec} fresh_ms={r.fresh_ms} raw={r.raw!r}")
```

- [ ] **Step 4: (선택) 실서버 확인**

키가 있으면 수동 확인:
Run: `TDATA_KEY=<키> .venv/bin/python scripts/probe_signal_api_live.py 1537 ne`
Expected: `color=` 가 GREEN/RED/CLEARANCE/UNKNOWN 중 하나로 출력.

- [ ] **Step 5: Commit**

```bash
git add scripts/run_unit_tests.py scripts/probe_signal_api_live.py
git commit -m "test: add unit-test runner + live API probe script"
```

---

## Self-Review

**1. Spec coverage (설계 §5 대비):**
- §5.1 signal_api 번역기 → Task 2·3 ✅ (색 매핑 화이트리스트, stale, None, 오류→UNKNOWN, 키 환경변수)
- §5.2 vision 어댑터 → Task 4 ✅ (GREEN_BLINK→CLEARANCE, 기존 로직 미변경)
- §5.3 judge AND 규칙 → Task 5 ✅ (불일치→WAIT, 잔여충분, stale, 단일소스 정책)
- §4 표준 데이터 구조 SignalReading → Task 1 ✅
- §6 테스트 전략(픽스처·조합·목킹) → Task 2·5 테스트 ✅, 통합 수동 → Task 6 ✅
- §7 오픈이슈(단일소스 정책) → `allow_single_source` 파라미터로 노출 ✅
- 범위 밖(앱/GPS/피드백/하드웨어) → 계획에 없음 ✅

**2. Placeholder scan:** "TBD/TODO/적절히 처리" 없음. 모든 코드 스텝에 실제 코드
포함. Task 6은 `run_pipeline_test.py`(영상 검증 전용)에 끼워넣지 않고 별도
`run_unit_tests.py`를 신설하도록 확정 — 실제 파일 구조 확인 후 반영함. ✅

**3. Type consistency:**
- `SignalReading(color, remain_sec, source, fresh_ms, raw)` — Task 1 정의와
  Task 2·3·4·5 사용 시그니처 일치 ✅
- 색 상수 `GREEN/RED/CLEARANCE/UNKNOWN` — 전 태스크 동일 import ✅
- `parse_reading(records, direction, now_ms, stale_ms)` — Task 2 정의 = Task 3 호출 ✅
- `decide(api, vision, *, need_sec, stale_ms, allow_single_source)` — Task 5 정의 =
  test 호출 일치 ✅
- Decision 상수: `judge.py`는 `UNKNOWN_DECISION`으로 명명(색 `UNKNOWN`과 충돌 회피) ✅

이상 없음.
