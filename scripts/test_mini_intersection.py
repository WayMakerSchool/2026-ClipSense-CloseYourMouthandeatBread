"""모의 교차로 HTTP·공유 시계·장애·검출 색상 테스트.

실행: python scripts/test_mini_intersection.py
포트 0의 실제 서버를 같은 프로세스에서 실행한다. 외부 API는 호출하지 않는다.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
from pathlib import Path
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))

import mini_intersection as sim
from signal_api import fetch_reading, parse_reading
from signals import CLEARANCE, GREEN, RED, UNKNOWN

FAILURES: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    print(f"[{'PASS' if cond else 'FAIL'}] {name}" + (f" — {detail}" if not cond else ""))
    if not cond:
        FAILURES.append(name)


def request(base, path, body=None):
    req = urllib.request.Request(base + path, data=body,
                                 headers={"Content-Type": "application/json"})
    try:
        response = urllib.request.urlopen(req, timeout=3)
    except urllib.error.HTTPError as exc:
        response = exc
    with response:
        return response.status, response.read(), response.headers


def state(base):
    return json.loads(request(base, "/state")[1])


def control(base, mode):
    return request(base, "/control", json.dumps({"api": mode}).encode())


def api_path(itst_id="SIM-0001", api_key="test-never-log-me"):
    return sim.API_PATH + "?" + urllib.parse.urlencode({
        "apiKey": api_key, "itstId": itst_id, "type": "json", "numOfRows": 10})


def reading(base, itst_id="SIM-0001", direction="nt"):
    return fetch_reading(itst_id, direction, "test-never-log-me",
                         now_ms=time.time_ns() // 1_000_000, base_url=base + sim.API_PATH)


def test_cycle_and_faults():
    server = sim.MiniIntersection(port=0, listen="127.0.0.1", red=1, green=1, clearance=1)
    server.start()
    base = server.base_url
    try:
        check("시작은 red, 주기는 3000 ms", state(base)["phase"] == "red"
              and state(base)["cycleMs"] == 3000)
        # 경계 직전/직후 HTTP 요청끼리는 다른 상일 수 있으므로, 각 상의 중간에서 비교한다.
        seen, blink = set(), set()
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline and (len(seen) < 3 or len(blink) < 2):
            before = state(base)
            if before["phase"] == "clearance":
                blink.add(before["lampOn"])
            if before["phase"] not in seen and 300 < before["remainMs"] < 800:
                status, body, headers = request(base, api_path())
                records = json.loads(body)
                parsed = parse_reading(records, "nt", now_ms=time.time_ns() // 1_000_000,
                                       itst_id="SIM-0001")
                fetched = reading(base)
                after = state(base)
                if after["phase"] != before["phase"]:
                    continue
                expected = {"red": RED, "green": GREEN, "clearance": CLEARANCE}[before["phase"]]
                check(f"{expected}: JSON 배열·상태·잔여시간 일치",
                      status == 200 and isinstance(records, list) and len(records) == 1
                      and parsed.color == expected and fetched.color == expected
                      and abs(parsed.remain_sec - after["remainMs"] / 1000) < .3
                      and abs(fetched.remain_sec - after["remainMs"] / 1000) < .3,
                      f"{parsed}, {fetched}, {after}")
                rec = records[0]
                check(f"{expected}: SIM 식별·시각·캐시 금지",
                      rec["dataId"] == "SIM" and rec["simulated"] is True
                      and isinstance(rec["ntPdsgRmdrCs"], int)
                      and abs(time.time_ns() // 1_000_000 - rec["trsmUtcTime"]) < 300
                      and headers["Cache-Control"] == "no-store")
                seen.add(before["phase"])
            time.sleep(.02)
        check("짧은 주기의 세 상을 모두 관측", len(seen) == 3, str(seen))
        check("clearance 서버 점멸 켜짐·꺼짐 관측", blink == {False, True})
        # clearance 뒤 실제 red 복귀도 확인한다.
        deadline = time.monotonic() + 3
        while state(base)["phase"] != "red" and time.monotonic() < deadline:
            time.sleep(.02)
        check("clearance 뒤 red 복귀", state(base)["phase"] == "red")

        last = json.loads(request(base, api_path())[1])
        check("freeze 설정", control(base, "freeze")[0] == 200)
        check("freeze는 마지막 레코드 전체 보존", json.loads(request(base, api_path())[1]) == last)
        screen_before = state(base)
        time.sleep(2.15)
        frozen = json.loads(request(base, api_path())[1])
        check("freeze 2초 이후 parse_reading·fetch_reading UNKNOWN",
              frozen == last and reading(base).color == UNKNOWN
              and parse_reading(frozen, "nt", now_ms=time.time_ns() // 1_000_000).color == UNKNOWN)
        check("freeze 중 화면 시계는 계속 진행", state(base)["apiMode"] == "freeze"
              and state(base)["phase"] != screen_before["phase"])
        control(base, "down")
        check("down HTTP 503·UNKNOWN", request(base, api_path())[0] == 503
              and reading(base).color == UNKNOWN and state(base)["apiMode"] == "down")
        control(base, "ok")
        check("ok 복구: 새 레코드·신선한 신호", reading(base).color != UNKNOWN
              and json.loads(request(base, api_path())[1])[0]["trsmUtcTime"] > last[0]["trsmUtcTime"])
        check("apiKey 누락·빈 값·공백 400", all(request(base, path)[0] == 400 for path in (
            sim.API_PATH, api_path(api_key=""), api_path(api_key=" "))))
        check("다른 교차로는 빈 배열·UNKNOWN", json.loads(request(base, api_path("wrong"))[1]) == []
              and reading(base, "wrong").color == UNKNOWN)
        for body in (b'{"api":"bad"}', b'[]', b'null', b'{', b'{"api":[]}'):
            check(f"잘못된 제어 JSON 400: {body!r}", request(base, "/control", body)[0] == 400)
        check("잘못된 제어는 모드 불변", state(base)["apiMode"] == "ok")
        code, body, headers = request(base, "/")
        page = body.decode()
        check("자체 포함 페이지·모의 표기·색상·제어 버튼", code == 200
              and "SIM 모의 교차로 · 도로 신호 아님" in page
              and all(color in page for color in (sim.LAMP_RED, sim.LAMP_GREEN, sim.LAMP_OFF))
              and 'setInterval(poll, 100)' in page and 's.lampOn' in page
              and all(f'data-mode="{mode}"' in page for mode in ("ok", "freeze", "down"))
              and "<script src=" not in page and "<link" not in page)
        check("없는 경로 404", request(base, "/missing")[0] == 404)
    finally:
        server.stop()


def test_configuration_and_logs():
    stdout, stderr = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        server = sim.MiniIntersection(port=0, listen="127.0.0.1", itst_id="CUSTOM", direction="sw")
        server.start()
        try:
            base = server.base_url
            control(base, "freeze")  # 첫 API 요청 전에 고정해도 유효한 레코드가 있어야 한다.
            first = json.loads(request(base, api_path("CUSTOM"))[1])
            control(base, "freeze")
            second = json.loads(request(base, api_path("CUSTOM"))[1])
            configured = (first == second and first[0]["itstId"] == "CUSTOM"
                          and "swPdsgStatNm" in first[0]
                          and reading(base, "CUSTOM", "sw").color == RED)
        finally:
            server.stop()
    check("사용자 교차로·방위 및 첫 요청 전 freeze", configured)
    check("apiKey를 로그에 남기지 않음", "test-never-log-me" not in stdout.getvalue() + stderr.getvalue())
    for duration in (0, -1, float("nan"), float("inf")):
        try:
            server = sim.MiniIntersection(port=0, red=duration)
        except ValueError:
            check(f"비정상 시간 거부: {duration}", True)
        else:
            server.stop()
            check(f"비정상 시간 거부: {duration}", False)


def test_clock_boundaries():
    # 소켓 권한과 무관하게 경계·점멸·벽시계 변경을 검증한다. HTTP 검증은 위에서 별도로 한다.
    with patch.object(sim, "ThreadingHTTPServer"), patch.object(sim.time, "monotonic") as clock:
        clock.return_value = 100
        server = sim.MiniIntersection()
        for elapsed, phase, remain, lamp_on in (
            (0, "red", 20000, True), (20, "green", 12000, True),
            (32, "clearance", 6000, True), (32.5, "clearance", 5500, False),
            (33, "clearance", 5000, True), (38, "red", 20000, True),
        ):
            clock.return_value = 100 + elapsed
            current = server.state()
            check(f"단조 시계 경계 {elapsed}s", current["phase"] == phase
                  and current["remainMs"] == remain and current["lampOn"] == lamp_on)
        clock.return_value = 120
        original = server.state()
        with patch.object(sim.time, "time_ns", return_value=1_000_000_000):
            _, records = server.api_response()
        check("벽시계는 전송시각만 결정, 상은 단조 시계로 결정",
              server.state() == original and records[0]["trsmUtcTime"] == 1000
              and records[0]["ntPdsgStatNm"] == "protected-Movement-Allowed")
        server.control("freeze")
        clock.return_value = 132
        check("freeze 중 API 고정·화면 clearance 진행",
              server.api_response()[1] == records and server.state()["phase"] == "clearance")
        server.control("down")
        check("down 상태 모델 503", server.api_response()[0] == 503)
        server.stop()


def test_lamp_colors():
    try:
        import cv2
    except ImportError:
        print("[SKIP] cv2 없음: 합성 램프 검출")
        return
    import numpy as np
    from detector import ColorDetector, RAW_GREEN, RAW_NONE, RAW_RED

    cfg = json.loads((ROOT / "config.json").read_text())
    for hex_color, expected in ((sim.LAMP_RED, RAW_RED), (sim.LAMP_GREEN, RAW_GREEN),
                                (sim.LAMP_OFF, RAW_NONE)):
        image = np.zeros((240, 320, 3), dtype=np.uint8)
        rgb = tuple(int(hex_color[i:i + 2], 16) for i in (1, 3, 5))
        cv2.circle(image, (160, 120), 72, rgb[::-1], -1)  # 짧은 변의 60% 지름
        result = ColorDetector(cfg).detect(image)
        check(f"페이지 색상 {hex_color}: 합성 320×240 검출 {expected}",
              result.raw == expected, str(result))


def test_signal_layout():
    """Rasterize the page's vmin/SVG geometry at a 640×480 viewport."""
    import cv2
    import numpy as np
    from detector import ColorDetector
    from digits import DigitReader, DIGIT_PATTERNS

    cfg = json.loads((ROOT / "config.json").read_text())
    layout = sim.LAYOUT
    scale = min(640, 480) / 100  # One vmin in pixels.
    hw, hh = layout["housing_width"] * scale, layout["housing_height"] * scale
    group_shift = (layout["countdown_gap"] + layout["countdown_width"]) * scale / 2
    hx, hy = 320 - group_shift - hw / 2, (480 - hh) / 2
    cw, ch = layout["countdown_width"] * scale, layout["countdown_height"] * scale
    cx = hx + hw + layout["countdown_gap"] * scale
    cy = hy + hh * layout["bottom_center"] - ch / 2
    w, h = layout["digit_width"] * scale, layout["digit_height"] * scale
    gap = layout["digit_gap"] * scale
    t = h * layout["segment_thickness_ratio"]
    rects = {
        "a": (t, 0, w-t, t), "b": (w-t, t, w, h/2-t/2),
        "c": (w-t, h/2+t/2, w, h-t), "d": (t, h-t, w-t, h),
        "e": (0, h/2+t/2, t, h-t), "f": (0, t, t, h/2-t/2),
        "g": (t, h/2-t/2, w-t, h/2+t/2),
    }

    def bgr(color):
        return tuple(int(color[i:i+2], 16) for i in (5, 3, 1))

    def rectangle(image, x, y, width, height, color):
        # Half-open pixel bounds approximate SVG filled rectangles.
        cv2.rectangle(image, (round(x), round(y)),
                      (round(x + width)-1, round(y + height)-1), bgr(color), -1)

    def crop(image, x, y, width, height):
        return image[round(y):round(y+height), round(x):round(x+width)]

    check("페이지 숫자 패턴은 digits.DIGIT_PATTERNS와 일치",
          all(set(sim.DIGIT_SEGMENTS[value]) == set(pattern)
              for pattern, value in DIGIT_PATTERNS.items()))
    check("두 자리 셀 종횡비·분리 간격", abs(w/h - .55) < .001 and gap >= .12*w)
    check("페이지 템플릿은 공유 LAYOUT 사용",
          f"const layout = {json.dumps(layout)};" in sim.PAGE
          and "__" not in sim.PAGE)
    off_hsv = cv2.cvtColor(np.uint8([[bgr(sim.LAMP_OFF)]]), cv2.COLOR_BGR2HSV)
    check("꺼진 램프 HSV V < 60", int(off_hsv[0, 0, 2]) < 60)

    for phase, remaining, lamp_on, expected in (
        ("green", 9, True, "GREEN"), ("green", 12, True, "GREEN"),
        ("red", 12, True, "RED"), ("clearance", 9, True, "GREEN"),
        ("clearance", 9, False, "NONE"), ("offline", 12, False, "NONE"),
    ):
        image = np.full((480, 640, 3), bgr(layout["background"]), dtype=np.uint8)
        # Rounded housing, with the same radius as CSS.
        r = round(layout["corner_radius"] * scale)
        rectangle(image, hx+r, hy, hw-2*r, hh, layout["housing_color"])
        rectangle(image, hx, hy+r, hw, hh-2*r, layout["housing_color"])
        for x in (hx+r, hx+hw-r):
            for y in (hy+r, hy+hh-r):
                cv2.circle(image, (round(x), round(y)), r, bgr(layout["housing_color"]), -1)
        rectangle(image, cx, cy, cw, ch, layout["housing_color"])
        for center, color in (
            (layout["top_center"], sim.LAMP_RED if phase == "red" else sim.LAMP_OFF),
            (layout["bottom_center"], sim.LAMP_GREEN if phase == "green" or
             (phase == "clearance" and lamp_on) else sim.LAMP_OFF),
        ):
            cv2.circle(image, (round(hx+hw/2), round(hy+hh*center)),
                       round(layout["lamp_diameter"]*scale/2), bgr(color), -1)
        if phase in ("green", "clearance"):
            for i, char in enumerate(str(remaining).rjust(2)):
                if char == " ":
                    continue
                ox = cx + (cw-2*w-gap)/2 + i*(w+gap)
                oy = cy + (ch-h)/2
                for segment in sim.DIGIT_SEGMENTS[int(char)]:
                    x1, y1, x2, y2 = rects[segment]
                    rectangle(image, ox+x1, oy+y1, x2-x1, y2-y1, sim.LAMP_RED)
        countdown = crop(image, cx, cy, cw, ch)
        value = DigitReader(cfg).read_frame(countdown)
        result = ColorDetector(cfg).detect(crop(image, hx, hy, hw, hh))
        name = f"640×480 {phase} {remaining} lampOn={lamp_on}"
        check(f"{name}: 숫자 판독", value == (remaining if phase in
              ("green", "clearance") else None), repr(value))
        check(f"{name}: 하우징 {expected}", result.raw == expected, str(result))
        if phase == "green" and remaining == 9:
            # Leading cell really is blank, rather than a drawn zero.
            check("한 자리 초는 앞자리 공백", not DigitReader(cfg)._mask(countdown)[:, :round(cw/2)].any())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-sockets", action="store_true", help="소켓 없는 검증만 실행")
    args = parser.parse_args()
    tests = [test_clock_boundaries, test_lamp_colors, test_signal_layout]
    if args.no_sockets:
        print("[SKIP] --no-sockets: test_cycle_and_faults, test_configuration_and_logs")
    else:
        tests[:0] = [test_cycle_and_faults, test_configuration_and_logs]
    for test in tests:
        print(f"\n=== {test.__name__} ===")
        try:
            test()
        except Exception as exc:
            check(f"{test.__name__} 예외 없음", False, repr(exc))
    print("=" * 50)
    if FAILURES:
        print(f"FAIL {len(FAILURES)}건: {FAILURES}")
        sys.exit(1)
    print("모의 교차로 테스트 전부 PASS")


if __name__ == "__main__":
    main()
