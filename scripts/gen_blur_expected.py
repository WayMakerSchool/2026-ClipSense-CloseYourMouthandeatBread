"""OpenCV GaussianBlur 기대값 생성 — Dart gaussianBlur5x5/gaussianBlur3x3 수치 동등성 테스트용.

실행:
    .venv/bin/python scripts/gen_blur_expected.py > app/test/vision/blur_expected.dart

출력: image_ops_test.dart가 import하는 Dart 상수 파일(수정 금지, 재생성만).
  - 입력 BGR 이미지(고정 시드 LCG — numpy 버전과 무관하게 항상 같은 값)
  - cv2.GaussianBlur(img, (5,5), 0) 결과 (BORDER_REFLECT_101 기본)
  - cv2.GaussianBlur(img, (3,3), 0) 결과

케이스: 9x7(본), 2x2·1x4·1x1(경계 반사가 커널보다 작은 이미지) — 픽셀 단위 일치 검증.

참고(재현 근거): sigma=0이면 OpenCV는 ksize 5 → [1,4,6,4,1]/16, ksize 3 → [1,2,1]/4 고정
커널을 쓰고, 8비트 입력은 고정소수점 경로라 결과는 정수 2D 합성곱 후
(sum + S/2) // S (S = 256 또는 16) 반올림과 완전히 같다 — 이 스크립트가 그 사실을
난수 이미지로 먼저 검증(assert)한 뒤 기대값을 출력한다.
"""

from __future__ import annotations

import cv2
import numpy as np

CASES = [
    # (Dart 상수 이름 조각, width, height)
    ("Main", 9, 7),
    ("Tiny2x2", 2, 2),
    ("Col1x4", 1, 4),
    ("One1x1", 1, 1),
]


def lcg_bytes(n: int, seed: int) -> list[int]:
    """고정 시드 LCG(Numerical Recipes 상수)로 0~255 값 n개."""
    state = seed & 0xFFFFFFFF
    out = []
    for _ in range(n):
        state = (1664525 * state + 1013904223) & 0xFFFFFFFF
        out.append((state >> 24) & 0xFF)
    return out


def make_image(w: int, h: int, seed: int) -> np.ndarray:
    vals = lcg_bytes(w * h * 3, seed)
    return np.array(vals, dtype=np.uint8).reshape(h, w, 3)


def reference_blur(img: np.ndarray, weights: list[int]) -> np.ndarray:
    """정수 2D 합성곱 + BORDER_REFLECT_101 + (sum+S/2)//S. Dart 구현과 같은 식."""
    h, w, c = img.shape
    k = len(weights)
    r = k // 2
    s = sum(weights) ** 2

    def reflect(i: int, n: int) -> int:
        if n == 1:
            return 0
        while i < 0 or i >= n:
            if i < 0:
                i = -i
            if i >= n:
                i = 2 * (n - 1) - i
        return i

    src = img.astype(np.int64)
    out = np.zeros_like(src)
    for y in range(h):
        for x in range(w):
            acc = np.zeros(c, dtype=np.int64)
            for dy in range(-r, r + 1):
                yy = reflect(y + dy, h)
                for dx in range(-r, r + 1):
                    xx = reflect(x + dx, w)
                    acc += src[yy, xx] * (weights[dy + r] * weights[dx + r])
            out[y, x] = (acc + s // 2) // s
    return out.astype(np.uint8)


def self_check() -> None:
    """난수 이미지로 reference_blur == cv2.GaussianBlur 를 먼저 확인한다."""
    rng = np.random.default_rng(0)
    for _ in range(30):
        h, w = (int(v) for v in rng.integers(1, 12, size=2))
        img = rng.integers(0, 256, size=(h, w, 3), dtype=np.uint8)
        assert np.array_equal(cv2.GaussianBlur(img, (5, 5), 0), reference_blur(img, [1, 4, 6, 4, 1]))
        assert np.array_equal(cv2.GaussianBlur(img, (3, 3), 0), reference_blur(img, [1, 2, 1]))


def dart_list(name: str, values: list[int], per_line: int = 21) -> str:
    lines = [f"const {name} = <int>["]
    for i in range(0, len(values), per_line):
        chunk = ", ".join(str(v) for v in values[i:i + per_line])
        lines.append(f"  {chunk},")
    lines.append("];")
    return "\n".join(lines)


def main() -> None:
    self_check()
    print("// scripts/gen_blur_expected.py 가 생성한 파일 — 손으로 고치지 말고 재생성한다.")
    print(f"// cv2 {cv2.__version__} GaussianBlur((5,5),0) / ((3,3),0) 기대값, BORDER_REFLECT_101.")
    print("// 입력은 고정 시드 LCG(seed 20260827)로 만든 BGR 픽셀.")
    print("library;")
    for name, w, h in CASES:
        img = make_image(w, h, seed=20260827)
        blur5 = cv2.GaussianBlur(img, (5, 5), 0)
        blur3 = cv2.GaussianBlur(img, (3, 3), 0)
        assert np.array_equal(blur5, reference_blur(img, [1, 4, 6, 4, 1]))
        assert np.array_equal(blur3, reference_blur(img, [1, 2, 1]))
        print()
        print(f"// {name}: {w}x{h} BGR")
        print(f"const int blur{name}W = {w};")
        print(f"const int blur{name}H = {h};")
        print(dart_list(f"blur{name}Input", img.flatten().tolist()))
        print(dart_list(f"blur{name}Expected5x5", blur5.flatten().tolist()))
        print(dart_list(f"blur{name}Expected3x3", blur3.flatten().tolist()))


if __name__ == "__main__":
    main()
