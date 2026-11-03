#include <Arduino.h>
#include <SPI.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/task.h>

#if !defined(CONFIG_IDF_TARGET_ESP32)
#error "Select ESP32 Dev Module (original ESP32) for this pin map."
#endif

// ESP32 is the SPI master. The FPGA is the source of all audio samples.
constexpr int PIN_SCLK = 18;
constexpr int PIN_MISO = 19;
constexpr int PIN_MOSI = 23;  // Configured but not connected to the FPGA.
constexpr int PIN_CS = 27;
constexpr int PIN_READY = 25;
constexpr int PIN_ACK = 26;
constexpr uint32_t SPI_HZ = 1'000'000;
constexpr uint32_t SERIAL_BAUD = 1'000'000;

constexpr size_t SAMPLE_COUNT = 1024;
constexpr size_t HEADER_BYTES = 8;
constexpr size_t FRAME_BYTES = HEADER_BYTES + SAMPLE_COUNT * 2;

// These are the two application buffers, C and D.
// Only a buffer's current owner may read/write it.
alignas(4) uint8_t buffers[2][FRAME_BYTES];
QueueHandle_t freeBuffers;
QueueHandle_t readyBuffers;
SPIClass fpgaSpi(VSPI);

// Copy one complete block; acknowledge after SPI finishes.
void receiveOneBlock(uint8_t index) {
  while (digitalRead(PIN_READY) == LOW) {
    vTaskDelay(1);  // Yield one RTOS tick; this does not control ADC sampling.
  }

  fpgaSpi.beginTransaction(SPISettings(SPI_HZ, MSBFIRST, SPI_MODE0));
  digitalWrite(PIN_CS, LOW);
  delayMicroseconds(2);  // Let the FPGA synchronize CS and present the first bit.
  fpgaSpi.transferBytes(nullptr, buffers[index], FRAME_BYTES);
  delayMicroseconds(2);  // Keep CS low after the final clock edge.
  digitalWrite(PIN_CS, HIGH);
  fpgaSpi.endTransaction();

  // The FPGA can reuse its buffer now; the ESP32 already owns a complete copy.
  delayMicroseconds(2);
  digitalWrite(PIN_ACK, HIGH);
  delayMicroseconds(2);
  digitalWrite(PIN_ACK, LOW);
  delayMicroseconds(2);  // Allow READY to settle before the next transaction.
}

void receiveFromFpga(void *) {
  for (;;) {
    uint8_t index;
    xQueueReceive(freeBuffers, &index, portMAX_DELAY);

    receiveOneBlock(index);

    xQueueSend(readyBuffers, &index, portMAX_DELAY);
    // Ownership has moved to loop(); do not touch this buffer here.
  }
}

void setup() {
  // Set idle output levels before starting SPI transfers.
  pinMode(PIN_CS, OUTPUT);
  digitalWrite(PIN_CS, HIGH);
  pinMode(PIN_ACK, OUTPUT);
  digitalWrite(PIN_ACK, LOW);
  pinMode(PIN_READY, INPUT_PULLDOWN);

  Serial.begin(SERIAL_BAUD, SERIAL_8N1);
  Serial.setDebugOutput(false);  // This port carries binary frames only.
  fpgaSpi.begin(PIN_SCLK, PIN_MISO, PIN_MOSI, PIN_CS);

  // Queues pass buffer numbers, not copies of the 2 KB frames.
  freeBuffers = xQueueCreate(2, sizeof(uint8_t));
  readyBuffers = xQueueCreate(2, sizeof(uint8_t));
  configASSERT(freeBuffers != nullptr && readyBuffers != nullptr);
  for (uint8_t i = 0; i < 2; ++i) {
    xQueueSend(freeBuffers, &i, portMAX_DELAY);
  }

  BaseType_t started = xTaskCreatePinnedToCore(
      receiveFromFpga, "FPGA receive", 4096, nullptr, 1, nullptr, 0);
  configASSERT(started == pdPASS);
}

void loop() {
  uint8_t index;
  xQueueReceive(readyBuffers, &index, portMAX_DELAY);

  // Forward the exact frame, including the FPGA sequence number.
  size_t sent = 0;
  while (sent < FRAME_BYTES) {
    size_t written = Serial.write(buffers[index] + sent, FRAME_BYTES - sent);
    sent += written;
    if (written == 0) {
      vTaskDelay(1);
    }
  }
  Serial.flush(true);  // Wait for UART TX completion before freeing the buffer.
  xQueueSend(freeBuffers, &index, portMAX_DELAY);
}
