"""clip_serial: USB 머리줄+JPEG 파싱 (보드 없이)."""
import io
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from clip_serial import SerialCaptureError, read_frame
from clip_snapshot import parse_capture_headers

JPEG = b'\xff\xd8' + b'x' * 100 + b'\xff\xd9'


def stream(data):
    return io.BytesIO(data)


class SerialTests(unittest.TestCase):
    def test_frame_after_boot_log_lines(self):
        data = (b'ESP-ROM:esp32s3\r\nentry 0x40\r\n\nCLIPFRAME 7 abcd1234 1000 1200 %d OV3660\n' % len(JPEG)) + JPEG
        jpeg, headers = read_frame(stream(data), deadline_s=1e12)
        self.assertEqual(jpeg, JPEG)
        meta = parse_capture_headers(headers)
        self.assertEqual((meta.frame_seq, meta.boot_id, meta.capture_uptime_us), (7, 'abcd1234', 1000))
        self.assertEqual(headers['X-Frame-Source'], 'usb-serial')

    def test_board_error_is_reported(self):
        with self.assertRaises(SerialCaptureError) as ctx:
            read_frame(stream(b'\nCLIPERR busy\n'), deadline_s=1e12)
        self.assertEqual(str(ctx.exception), 'busy')

    def test_bad_header_rejected(self):
        for line in (b'\nCLIPFRAME 7 boot x 1200 10 OV3660\n', b'\nCLIPFRAME 7 boot 1 2 0 OV3660\n',
                     b'\nCLIPFRAME 7 boot 1 2\n'):
            with self.assertRaises(SerialCaptureError):
                read_frame(stream(line + JPEG), deadline_s=1e12)

    def test_timeout_when_nothing_arrives(self):
        clock = iter([0, 0.5, 2.0, 3.0])
        with self.assertRaises(TimeoutError):
            read_frame(stream(b''), deadline_s=1.0, clock=lambda: next(clock))

    def test_truncated_body_times_out(self):
        data = b'\nCLIPFRAME 7 boot 1 2 500 OV3660\n' + JPEG[:50]
        ticks = iter(range(100))
        with self.assertRaises(TimeoutError):
            read_frame(stream(data), deadline_s=5, clock=lambda: next(ticks))


if __name__ == '__main__':
    unittest.main()
