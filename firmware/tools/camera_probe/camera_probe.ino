// 카메라 진단: XIAO ESP32S3 Sense 카메라 커넥터에 어떤 센서가 붙어 있는지 알아본다.
// 1) XCLK(20MHz)를 켜고 2) SCCB(I2C) 주소를 훑고 3) 응답한 주소에서 칩 ID 레지스터를 읽는다.
#include <Wire.h>

const int PIN_XCLK = 10, PIN_SDA = 40, PIN_SCL = 39;

int read8(uint8_t addr, uint8_t reg) {
  Wire.beginTransmission(addr); Wire.write(reg);
  if (Wire.endTransmission(false) != 0) return -1;
  if (Wire.requestFrom(addr, (uint8_t)1) != 1) return -1;
  return Wire.read();
}
int read16reg(uint8_t addr, uint16_t reg) {
  Wire.beginTransmission(addr); Wire.write(reg >> 8); Wire.write(reg & 0xFF);
  if (Wire.endTransmission(false) != 0) return -1;
  if (Wire.requestFrom(addr, (uint8_t)1) != 1) return -1;
  return Wire.read();
}

void probe() {
  Serial.println("=== camera_probe ===");
  int found = 0;
  for (uint8_t a = 0x08; a < 0x78; a++) {
    Wire.beginTransmission(a);
    if (Wire.endTransmission() == 0) {
      found++;
      Serial.printf("I2C 응답 주소 0x%02X\n", a);
      Serial.printf("  8bit  ID(0x0A,0x0B) = %02X %02X\n", read8(a, 0x0A) & 0xFF, read8(a, 0x0B) & 0xFF);
      Serial.printf("  16bit ID(0x300A,0x300B) = %02X %02X\n", read16reg(a, 0x300A) & 0xFF, read16reg(a, 0x300B) & 0xFF);
      Serial.printf("  16bit ID(0x3107,0x3108) = %02X %02X\n", read16reg(a, 0x3107) & 0xFF, read16reg(a, 0x3108) & 0xFF);
    }
  }
  if (!found) Serial.println("I2C 응답 없음 (센서가 전기적으로 연결되지 않음)");
  Serial.println("참고: OV3660=36 60 (0x3C) · OV5640=56 40 (0x3C) · OV2640=26 42 (0x30)");
}

void setup() {
  Serial.begin(115200);
  delay(2500);
  bool ok = ledcAttach(PIN_XCLK, 20000000, 1);
  ledcWrite(PIN_XCLK, 1);
  Serial.printf("XCLK 20MHz 시작: %s (실제 %lu Hz)\n", ok ? "성공" : "실패", (unsigned long)ledcReadFreq(PIN_XCLK));
  delay(100);
  pinMode(PIN_SDA, INPUT); pinMode(PIN_SCL, INPUT);
  Serial.printf("SDA=%d SCL=%d (풀업이 있으면 둘 다 1)\n", digitalRead(PIN_SDA), digitalRead(PIN_SCL));
  Wire.begin(PIN_SDA, PIN_SCL, 50000);
  probe();
}
void loop() { delay(5000); probe(); }
