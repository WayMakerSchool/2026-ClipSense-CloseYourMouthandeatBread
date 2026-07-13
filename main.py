"""Clip sense 데모 메인 루프.

영상 파일 또는 웹캠 입력 → ROI 크롭 → 색상 검출 → 상태 머신 → 음성 안내.

사용법:
    python main.py --video data/reference.mp4          # 영상 입력
    python main.py --camera 0                          # 웹캠 입력
    python main.py --video ... --reselect-roi          # ROI 다시 지정
    python main.py --video ... --headless --mute       # 자동 테스트용(창/소리 없음)

디버그 창 단축키: q/ESC = 종료, r = ROI 다시 지정,
                d = (선택) 잔여시간 숫자 영역 지정
"""

import argparse
import json
import sys
import time
from pathlib import Path

import cv2
import numpy as np

from detector import (ColorDetector, SignalStateMachine, VOICE_KEY, RAW_NONE,
                      STATE_RED, STATE_GREEN, STATE_GREEN_BLINK, STATE_UNKNOWN)
from digits import DigitReader

CONFIG_PATH = Path(__file__).resolve().parent / "config.json"

# 종료 코드: run_demo 재시작 루프가 이 값으로 재시작 여부를 판단한다.
# 0=정상 종료, 1=런타임/하드웨어 실패(재시작으로 복구 가능),
# 2=설정/사용법 오류(재시작해도 계속 실패 → 즉시 멈춤)
EXIT_OK = 0
EXIT_RUNTIME = 1
EXIT_CONFIG = 2

STATE_COLOR = {  # BGR (디버그 오버레이용)
    STATE_RED: (60, 60, 230),
    STATE_GREEN: (80, 200, 80),
    STATE_GREEN_BLINK: (80, 230, 230),
    STATE_UNKNOWN: (160, 160, 160),
}

PANEL_W = 960


def load_config(path: Path) -> dict:
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        print(f"오류: 설정 파일이 없습니다: {path}")
        sys.exit(EXIT_CONFIG)
    except json.JSONDecodeError as e:
        print(f"오류: 설정 파일이 손상되었습니다 ({path}, {e.lineno}행). "
              "git 원본으로 복구하거나 백업본으로 교체하세요.")
        sys.exit(EXIT_CONFIG)


def save_config(path: Path, cfg: dict) -> None:
    tmp = path.with_suffix(".json.tmp")  # 원자적 쓰기 (중간 크래시로 손상 방지)
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    tmp.replace(path)


def save_roi(path: Path, cfg: dict, roi: tuple[int, int, int, int],
             frame_shape, source: str) -> None:
    cfg["roi"] = list(roi)
    cfg["roi_frame_size"] = [int(frame_shape[1]), int(frame_shape[0])]  # [w, h]
    cfg["roi_source"] = source  # "video" / "camera:0" — 소스가 다르면 재선택 강제
    save_config(path, cfg)
    print(f"ROI 저장됨: {list(roi)} -> {path}")


def save_digit_roi(path: Path, cfg: dict, droi, frame_shape, source: str) -> None:
    cfg["digit_roi"] = list(droi)
    # 신호 ROI와 같은 좌표계 메타데이터를 별도로 기록해, 이후 해상도/소스가
    # 다른 입력에서 조용히 재사용되지 않게 한다
    cfg["digit_roi_frame_size"] = [int(frame_shape[1]), int(frame_shape[0])]
    cfg["digit_roi_source"] = source
    save_config(path, cfg)


def select_roi(frame: np.ndarray) -> tuple[int, int, int, int] | None:
    print("신호등 영역을 마우스로 드래그한 뒤 Enter/Space를 누르세요 (c = 취소).")
    x, y, w, h = cv2.selectROI("Select signal ROI (drag, then Enter)",
                               frame, showCrosshair=True)
    cv2.destroyWindow("Select signal ROI (drag, then Enter)")
    if w == 0 or h == 0:
        return None
    return int(x), int(y), int(w), int(h)


def clamp_roi(roi, frame_shape) -> tuple[int, int, int, int] | None:
    """ROI를 프레임과의 교집합으로 자른다 (음수 좌표는 잘라내고 밀지 않음)."""
    fh, fw = frame_shape[:2]
    x, y, w, h = (int(v) for v in roi)
    x1, y1 = max(0, x), max(0, y)
    x2, y2 = min(fw, x + w), min(fh, y + h)
    if x2 - x1 <= 0 or y2 - y1 <= 0:
        return None
    return x1, y1, x2 - x1, y2 - y1


def build_debug_panel(frame, res, state, roi, t, voice_off=False,
                      roi_hint=False, digit_roi=None,
                      digit_value=None) -> np.ndarray:
    x, y, w, h = roi
    disp = frame.copy()
    color = STATE_COLOR[state]
    cv2.rectangle(disp, (x, y), (x + w, y + h), color, 2)
    if digit_roi:
        dx, dy, dw, dh = digit_roi
        cv2.rectangle(disp, (dx, dy), (dx + dw, dy + dh), (200, 200, 60), 2)

    scale = PANEL_W / disp.shape[1]
    disp = cv2.resize(disp, (PANEL_W, int(disp.shape[0] * scale)))

    cv2.rectangle(disp, (0, 0), (PANEL_W, 74), (25, 25, 25), -1)
    cv2.putText(disp, f"STATE: {state}", (12, 34),
                cv2.FONT_HERSHEY_SIMPLEX, 1.1, color, 2)
    if res.reason:  # 신뢰도 낮음 → 판정 보류 사유 표시 (정직 상태의 근거)
        cv2.putText(disp, f"({res.reason})", (330, 34),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, (100, 160, 255), 2)
    if voice_off:
        cv2.putText(disp, "VOICE OFF!", (PANEL_W - 200, 34),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2)
    if digit_roi:
        label = str(digit_value) if digit_value is not None else "--"
        cv2.putText(disp, f"TIME: {label}", (PANEL_W - 200, 62),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, (200, 200, 60), 2)
    if roi_hint:
        cv2.putText(disp, "ROI too tight - press 'r', drag 2-3x larger",
                    (12, 100), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 100, 255), 2)
    cv2.putText(disp,
                f"t={t:6.1f}s  bright={res.brightness:5.1f}  "
                f"red={res.red.area_ratio * 100:4.1f}% "
                f"circ={res.red.circularity:.2f} | "
                f"green={res.green.area_ratio * 100:4.1f}% "
                f"circ={res.green.circularity:.2f}",
                (12, 62), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (220, 220, 220), 1)

    half = PANEL_W // 2
    mask_h = max(1, int(h * (half / max(w, 1))))
    mask_h = min(mask_h, 300)

    def mask_panel(mask, label, lit):
        m = cv2.cvtColor(mask, cv2.COLOR_GRAY2BGR)
        m = cv2.resize(m, (half, mask_h), interpolation=cv2.INTER_NEAREST)
        cv2.putText(m, label, (10, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.7,
                    (0, 255, 0) if lit else (128, 128, 128), 2)
        return m

    masks = np.hstack([
        mask_panel(res.red_mask, f"RED mask ({res.red.area_ratio * 100:.1f}%)",
                   res.red.valid),
        mask_panel(res.green_mask, f"GREEN mask ({res.green.area_ratio * 100:.1f}%)",
                   res.green.valid),
    ])
    return np.vstack([disp, masks])


def main() -> int:
    parser = argparse.ArgumentParser(description="Clip sense 보행 신호 안내 데모")
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument("--video", help="입력 영상 파일 경로")
    src.add_argument("--camera", type=int, help="웹캠 인덱스 (예: 0)")
    parser.add_argument("--roi", help="ROI 직접 지정: x,y,w,h (config보다 우선)")
    parser.add_argument("--reselect-roi", action="store_true",
                        help="저장된 ROI를 무시하고 다시 드래그로 지정")
    parser.add_argument("--headless", action="store_true",
                        help="디버그 창 없이 실행 (자동 테스트용)")
    parser.add_argument("--mute", action="store_true",
                        help="음성 재생 대신 로그만 출력 (자동 테스트용)")
    parser.add_argument("--max-seconds", type=float, default=0,
                        help="지정 시간 후 자동 종료 (0=무제한, 테스트용)")
    parser.add_argument("--digit-roi",
                        help="잔여시간 숫자 영역 x,y,w,h (config보다 우선, 선택 기능)")
    parser.add_argument("--config", default=str(CONFIG_PATH))
    args = parser.parse_args()

    cfg_path = Path(args.config)
    cfg = load_config(cfg_path)

    is_video = args.video is not None
    cap = cv2.VideoCapture(args.video if is_video else args.camera)
    if not cap.isOpened():
        print(f"오류: 입력을 열 수 없습니다: {args.video or args.camera}")
        if not is_video:
            print("웹캠이 연결돼 있는지, 시스템 설정 > 개인정보 보호 및 보안 > "
                  "카메라에서 터미널(또는 실행 앱)에 권한이 있는지 확인하세요.")
        return EXIT_RUNTIME

    if not is_video:
        # 1080p 원본 대신 720p 요청 (처리 속도·ROI 선택 창 크기 안정화)
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
        # 워밍업: 자동 노출이 안정될 때까지 첫 프레임들이 검거나 어두움
        # (실측: 첫 프레임 평균 밝기 0.0 → 1초 뒤 ~148)
        warm_until = time.monotonic() + 1.5
        while time.monotonic() < warm_until:
            cap.read()

    fps = cap.get(cv2.CAP_PROP_FPS)
    if not fps or fps <= 0 or fps > 240:
        fps = 30.0

    ok, first = cap.read()
    if not ok:
        print("오류: 첫 프레임을 읽을 수 없습니다.")
        return EXIT_RUNTIME

    # ROI 결정: CLI > (reselect 아니면) config > 드래그 선택
    roi_source = "video" if is_video else f"camera:{args.camera}"
    roi = None
    if args.roi:
        try:
            roi = tuple(int(v) for v in args.roi.split(","))
        except ValueError:
            roi = ()
        if len(roi) != 4:
            print("오류: --roi 형식은 x,y,w,h (정수 4개) 입니다.")
            return EXIT_CONFIG
    elif cfg.get("roi") and not args.reselect_roi:
        saved_size = cfg.get("roi_frame_size")
        saved_source = cfg.get("roi_source")
        cur_size = [first.shape[1], first.shape[0]]
        # 저장 당시와 해상도가 다르거나 소스(영상↔카메라)가 다르면
        # ROI 좌표가 무의미한 영역을 가리킨다 — 조용히 재사용하면 안 됨
        mismatch = None
        if saved_size and saved_size != cur_size:
            mismatch = f"해상도 불일치 (저장 {saved_size} vs 현재 {cur_size})"
        elif saved_source and saved_source != roi_source:
            mismatch = f"입력 소스 불일치 (저장 '{saved_source}' vs 현재 '{roi_source}')"
        if mismatch:
            print(f"경고: 저장된 ROI 재사용 불가 — {mismatch}. ROI를 다시 지정하세요.")
            if args.headless:
                return EXIT_CONFIG
            # 숫자 ROI도 좌표계가 바뀌었으니 함께 무효 (메타데이터까지)
            cfg["digit_roi"] = None
            cfg.pop("digit_roi_frame_size", None)
            cfg.pop("digit_roi_source", None)
            roi = select_roi(first)
            if roi:
                save_roi(cfg_path, cfg, roi, first.shape, roi_source)
        else:
            roi = tuple(cfg["roi"])
    elif not args.headless:
        roi = select_roi(first)
        if roi:
            save_roi(cfg_path, cfg, roi, first.shape, roi_source)

    if roi is None:
        print("오류: ROI가 없습니다. 창 모드에서 드래그로 지정하거나 --roi를 넘기세요.")
        return EXIT_CONFIG
    roi = clamp_roi(roi, first.shape)
    if roi is None:
        print("오류: ROI가 프레임 범위를 벗어났습니다.")
        return EXIT_CONFIG

    # (선택) 잔여시간 숫자 ROI: CLI > config. 실행 중 'd' 키로도 지정 가능
    digit_roi = None
    cur_size = [first.shape[1], first.shape[0]]
    if args.digit_roi:
        try:
            digit_roi = tuple(int(v) for v in args.digit_roi.split(","))
        except ValueError:
            digit_roi = ()
        if len(digit_roi) != 4:
            print("오류: --digit-roi 형식은 x,y,w,h (정수 4개) 입니다.")
            return EXIT_CONFIG
    elif cfg.get("digit_roi"):
        # config의 숫자 ROI는 저장 당시와 좌표계(해상도/소스)가 같을 때만 재사용
        d_size = cfg.get("digit_roi_frame_size")
        d_source = cfg.get("digit_roi_source")
        if (d_size and d_size != cur_size) or (d_source and d_source != roi_source):
            print("경고: 저장된 숫자 ROI가 현재 입력과 좌표계가 달라 무시합니다 "
                  "('d' 키로 다시 지정 가능).")
        else:
            digit_roi = tuple(cfg["digit_roi"])
    if digit_roi:
        clamped = clamp_roi(digit_roi, first.shape)
        if clamped is None:
            # 사용자가 숫자 ROI를 지정했는데 프레임 밖이면 조용히 끄지 않고 알림
            print(f"경고: 숫자 ROI {list(digit_roi)}가 프레임 범위를 벗어나 "
                  "비활성화됩니다.")
        digit_roi = clamped
    digit_reader = DigitReader(cfg) if digit_roi else None

    detector = ColorDetector(cfg)
    sm = SignalStateMachine(cfg)

    voice = None
    voice_error = None
    if not args.mute:
        try:
            from voice import VoicePlayer
            voice = VoicePlayer(cooldown=cfg["voice_cooldown_seconds"])
        except Exception as e:  # noqa: BLE001 - 부스에서 음성 없이라도 계속 동작
            voice_error = str(e)
            print(f"경고: 음성 초기화 실패 — 무음으로 계속합니다.\n  {e}")

    print(f"입력: {'영상 ' + args.video if is_video else '카메라 ' + str(args.camera)}"
          f"  {first.shape[1]}x{first.shape[0]}  fps={fps:.1f}  ROI={list(roi)}")

    frame_idx = 0
    t0 = time.monotonic()
    transitions = []
    cam_fails = 0
    too_large_streak = 0
    last_digit = None

    def announce(tr) -> None:
        key = VOICE_KEY[tr.new]
        # 전환 안내는 안전상 반드시 재생 (쿨다운 우회, force)
        played = voice.play(key, force=True) if voice else False
        transitions.append(tr)
        print(f"TRANSITION t={tr.t:.2f} from={tr.old} to={tr.new} "
              f"voice={key} played={played if voice else 'muted'}")

    try:
        while True:
            if is_video and frame_idx == 0:
                frame = first
                ok = True
            else:
                ok, frame = cap.read()
            if not ok:
                if is_video:
                    print("영상 끝.")
                    break
                cam_fails += 1
                if cam_fails >= 100:  # 약 10초 연속 실패 → 종료 (재시작 루프가 복구)
                    print("오류: 카메라 프레임을 계속 읽지 못했습니다. 종료합니다.")
                    return EXIT_RUNTIME
                if cam_fails == 1:
                    print("경고: 카메라 프레임 읽기 실패. 재시도 중...")
                t = time.monotonic() - t0
                if args.max_seconds and t >= args.max_seconds:
                    print(f"지정 시간 {args.max_seconds:.0f}초 경과. 종료.")
                    break
                # 카메라가 죽어 있는 동안에도 상태 머신은 굴러가야 한다 —
                # 마지막 안내(예: '초록')가 유지된 채 침묵하면 안 되므로
                # 판정 보류 NONE을 공급해 1.5초 후 UNKNOWN 안내가 나가게 함
                tr = sm.update(t, RAW_NONE, "camera_fail")
                if tr is not None:
                    announce(tr)
                # 카메라 공백 동안 stale한 잔여시간이 남지 않게 투표 창을 비운다
                if digit_reader is not None:
                    digit_reader.read(None)
                if not args.headless:
                    k = cv2.waitKey(50) & 0xFF  # 창 이벤트 유지 + 종료 허용
                    if k in (ord("q"), 27):
                        print("종료 (q/ESC).")
                        break
                    time.sleep(0.05)
                else:
                    time.sleep(0.1)
                continue
            cam_fails = 0

            t = frame_idx / fps if is_video else time.monotonic() - t0
            if args.max_seconds and t >= args.max_seconds:
                print(f"지정 시간 {args.max_seconds:.0f}초 경과. 종료.")
                break
            x, y, w, h = roi
            res = detector.detect(frame[y:y + h, x:x + w])
            tr = sm.update(t, res.raw, res.reason)
            if tr is not None:
                announce(tr)

            digit_value = None
            if digit_reader is not None:
                dx, dy, dw, dh = digit_roi
                digit_value = digit_reader.read(frame[dy:dy + dh, dx:dx + dw])
                # 실제 숫자 값이 바뀔 때만 로그. None↔값 깜빡임(종횡비 경계의
                # '4'류)은 로그 스팸이 되므로 새 숫자값일 때만 찍는다.
                if digit_value is not None and digit_value != last_digit:
                    print(f"DIGITS t={t:.2f} value={digit_value}")
                    last_digit = digit_value

            # ROI가 등에 너무 타이트하면 blob_too_large로 조용히 UNKNOWN에
            # 갇힌다 — 지속되면 원인을 명시적으로 알려준다
            too_large_streak = (too_large_streak + 1
                                if res.reason == "blob_too_large" else 0)
            if too_large_streak == 30:
                print("경고: 검출된 불빛이 ROI 대부분을 덮고 있습니다. "
                      "ROI를 더 넓게(등 크기의 2~3배) 다시 지정하세요 ('r' 키).")

            if not args.headless:
                panel = build_debug_panel(frame, res, sm.state, roi, t,
                                          voice_off=bool(voice_error),
                                          roi_hint=too_large_streak >= 30,
                                          digit_roi=digit_roi,
                                          digit_value=digit_value)
                cv2.imshow("Clip sense - debug", panel)
                if is_video:  # 처리 시간을 반영해 실제 재생 속도를 fps에 맞춤
                    target = t0 + (frame_idx + 1) / fps
                    delay_ms = max(1, int((target - time.monotonic()) * 1000))
                else:
                    delay_ms = 1
                k = cv2.waitKey(delay_ms) & 0xFF
                if k in (ord("q"), 27):  # q 또는 ESC (한글 IME 대비)
                    print("종료 (q/ESC).")
                    break
                if k == ord("r"):
                    new_roi = select_roi(frame)
                    if is_video:
                        # ROI 선택 동안 멈춘 벽시계 기준을 재보정
                        # (안 하면 밀린 프레임을 최고 속도로 몰아서 재생)
                        t0 = time.monotonic() - (frame_idx + 1) / fps
                    if new_roi:
                        new_roi = clamp_roi(new_roi, frame.shape)
                    if new_roi:
                        roi = new_roi
                        save_roi(cfg_path, cfg, roi, frame.shape, roi_source)
                        sm = SignalStateMachine(cfg)   # 이력 초기화
                        detector = ColorDetector(cfg)  # 밝기 EMA도 새 ROI 기준으로
                    elif not is_video:
                        # 취소해도 벽시계는 흘렀다 — 이력을 정리하지 않으면
                        # 재개 직후 none_duration이 점프해 가짜 UNKNOWN이 나감
                        sm.resume()
                if k == ord("d"):  # (선택) 잔여시간 숫자 영역 지정
                    print("잔여시간 숫자 영역을 드래그하세요 (c=취소).")
                    droi = select_roi(frame)
                    if is_video:
                        t0 = time.monotonic() - (frame_idx + 1) / fps
                    else:
                        sm.resume()  # 선택 중 흐른 벽시계 보정
                    if droi:
                        droi = clamp_roi(droi, frame.shape)
                    if droi:
                        digit_roi = droi
                        save_digit_roi(cfg_path, cfg, droi, frame.shape, roi_source)
                        print(f"숫자 ROI 저장됨: {list(droi)}")
                        digit_reader = DigitReader(cfg)
                        last_digit = None

            frame_idx += 1
    finally:
        cap.release()
        cv2.destroyAllWindows()
        if voice:
            voice.close()

    print(f"SUMMARY frames={frame_idx} transitions={len(transitions)}")
    for tr in transitions:
        print(f"  t={tr.t:7.2f}  {tr.old:>11} -> {tr.new}")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
