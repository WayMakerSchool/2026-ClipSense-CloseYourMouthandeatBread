"""main.py 설정 사전검증 단위 테스트. 실행: python scripts/test_main_config.py"""

import copy
import json
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import main as main_module

validate_config = main_module.validate_config

CFG = json.loads((ROOT / "config.json").read_text(encoding="utf-8"))
FAILURES = []


def check(name, cond, detail=""):
    print(f"[{'PASS' if cond else 'FAIL'}] {name}"
          + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(name)


def rejected(mutator) -> bool:
    cfg = copy.deepcopy(CFG)
    mutator(cfg)
    try:
        validate_config(cfg)
    except ValueError:
        return True
    return False


try:
    validate_config(copy.deepcopy(CFG))
except ValueError as exc:
    check("기본 config 통과", False, str(exc))
else:
    check("기본 config 통과", True)

# helper는 dict 복사 전제이므로 비-dict 입력은 직접 확인한다.
try:
    validate_config([])
except ValueError:
    check("최상위 비객체 거부", True)
else:
    check("최상위 비객체 거부", False)

check("필수 hsv 키 누락 거부", rejected(lambda c: c.pop("hsv")))
check("역전 HSV 범위 거부",
      rejected(lambda c: c["hsv"]["red"][0].update(
          {"lower": [20, 55, 45], "upper": [10, 255, 255]})))
check("면적 임계 역전 거부",
      rejected(lambda c: c.update({"min_area_ratio": 0.8,
                                   "max_area_ratio": 0.6})))
check("0 morph kernel 거부", rejected(lambda c: c.update({"morph_kernel": 0})))
check("0 debounce 거부", rejected(lambda c: c.update({"debounce_frames": 0})))
check("잘못된 ROI 폭 거부", rejected(lambda c: c.update({"roi": [0, 0, 0, 10]})))
check("안정화 표가 창보다 큰 설정 거부",
      rejected(lambda c: c["digits"].update(
          {"stable_window": 3, "stable_votes": 4})))

# 기본 config.json은 추적 가능한 임계값 템플릿으로 유지하고, 기기별 ROI만
# ignored config.local.json에 쓰는지 검증한다.
original_local_path = main_module.LOCAL_CONFIG_PATH
try:
    with tempfile.TemporaryDirectory() as tmp_dir:
        main_module.LOCAL_CONFIG_PATH = Path(tmp_dir) / "config.local.json"
        local_cfg = copy.deepcopy(CFG)
        local_cfg["roi"] = [10, 20, 30, 40]
        local_cfg["roi_source"] = "camera:0"
        local_cfg["min_area_ratio"] = 0.123  # 로컬 상태 파일에 들어가면 안 됨
        saved = main_module.save_config(main_module.CONFIG_PATH, local_cfg)
        payload = json.loads(saved.read_text(encoding="utf-8"))
        merged = main_module.load_config(main_module.CONFIG_PATH)
        check("기기별 ROI는 config.local.json에 저장", saved == main_module.LOCAL_CONFIG_PATH)
        check("로컬 설정에는 런타임 좌표만 저장", "min_area_ratio" not in payload)
        check("기본 설정 + 로컬 ROI 병합", merged["roi"] == [10, 20, 30, 40])
        check("로컬 파일이 HSV 임계값을 덮지 않음",
              merged["min_area_ratio"] == CFG["min_area_ratio"])
finally:
    main_module.LOCAL_CONFIG_PATH = original_local_path

print("=" * 50)
if FAILURES:
    print(f"FAIL {len(FAILURES)}건: {FAILURES}")
    sys.exit(1)
print("main 설정 검증 테스트 전부 PASS")
