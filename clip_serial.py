"""USB 케이블로 클립 사진 받기 — 펌웨어 serviceSerialCapture()의 짝.

호스트가 'C' 한 바이트를 보내면 보드가
  "\\nCLIPFRAME <seq> <bootId> <captureUs> <responseUs> <len> <sensor>\\n" + JPEG len바이트
또는 "\\nCLIPERR <이유>\\n"을 보낸다. 머리줄 값을 HTTP /capture 응답 헤더 형태로 바꿔 돌려주므로
clip_web.ClipFeed가 Wi-Fi 사진과 똑같이 검사(프레임 번호·부팅·사진 나이)하고 판독한다.
"""
from __future__ import annotations

import time
from email.message import Message

MAX_JPEG = 512 * 1024


class SerialCaptureError(Exception):
    """보드가 CLIPERR로 답했거나 응답이 잘못됐다."""


def read_frame(stream, deadline_s: float, clock=time.monotonic):
    """stream(readline/read 지원)에서 사진 한 장을 읽어 (jpeg, headers)를 돌려준다."""
    while True:
        if clock() > deadline_s:
            raise TimeoutError('serial_timeout')
        line = stream.readline()
        if not line:
            continue
        text = line.decode('ascii', 'replace').strip()
        if text.startswith('CLIPERR'):
            raise SerialCaptureError(text.split(' ', 1)[-1])
        if not text.startswith('CLIPFRAME '):
            continue  # 부팅 로그 등 다른 줄은 건너뛴다
        parts = text.split(' ')
        if len(parts) != 7:
            raise SerialCaptureError('bad_header')
        _, seq, boot, cap_us, resp_us, length, sensor = parts
        if not all(v.isdigit() for v in (seq, cap_us, resp_us, length)):
            raise SerialCaptureError('bad_header')
        size = int(length)
        if not 0 < size <= MAX_JPEG:
            raise SerialCaptureError('bad_length')
        data = bytearray()
        while len(data) < size:
            if clock() > deadline_s:
                raise TimeoutError('serial_timeout')
            chunk = stream.read(size - len(data))
            if chunk:
                data.extend(chunk)
        headers = Message()
        for key, value in {'Content-Type': 'image/jpeg', 'X-Frame-Seq': seq, 'X-Boot-Id': boot,
                           'X-Capture-Uptime-Us': cap_us, 'X-Response-Uptime-Us': resp_us,
                           'X-Camera-Sensor': sensor, 'X-Frame-Source': 'usb-serial'}.items():
            headers[key] = value
        return bytes(data), headers


class SerialClip:
    """포트를 열어 두고 요청마다 사진 한 장을 받는다. 뽑히면 다음 요청에서 다시 연다."""

    def __init__(self, port: str, timeout_s: float = 1.5):
        self.port, self.timeout_s, self.ser = port, timeout_s, None

    def _open(self):
        import serial
        # 기본 설정(DTR·RTS 켬)으로 연다. DTR·RTS를 끈 채 열면 ESP32-S3 USB 직렬이 칩을
        # 리셋한다(rst:0x15 USB_UART_CHIP_RESET, 10/22 실측).
        return serial.Serial(self.port, 115200, timeout=0.2)

    def capture(self):
        try:
            if self.ser is None:
                self.ser = self._open()
            self.ser.reset_input_buffer()
            self.ser.write(b'C')
            return read_frame(self.ser, time.monotonic() + self.timeout_s)
        except (OSError, TimeoutError, SerialCaptureError):
            self.close()
            raise
        except Exception as exc:  # serial.SerialException 등
            self.close()
            raise OSError(str(exc)) from exc

    def close(self):
        if self.ser is not None:
            try:
                self.ser.close()
            except Exception:
                pass
            self.ser = None
