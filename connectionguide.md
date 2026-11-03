# Hardware Connection Guide
## ESP32 + DE10-Lite FPGA + Audio Input

This guide explains the hardware connections for the ESP32 DTMF Detector project.

## 1. System Connection Overview

The system consists of:

- DE10-Lite FPGA: Audio sampling and SPI data transmission.
- ESP32: Receives audio samples from the FPGA and forwards them to the PC.
- Audio input module: Supplies the analog audio signal.
- PC: Receives serial data and performs FFT and DTMF detection using Python.

```text
   Microphone / Audio Source
             |
             | Analog OUT
             v
      +--------------+
      |  DE10-Lite   |
      |     FPGA     |
      |              |
      | ADC Sampling |
      | 16 kHz       |
      +--------------+
             |
             | SPI
             |
      +--------------+
      |     ESP32    |
      |              |
      | SPI Receiver |
      | Serial TX    |
      +--------------+
             |
             | USB
             |
             v
      +--------------+
      |      PC      |
      | Python GUI   |
      | FFT + DTMF   |
      +--------------+
```

## 2. Audio Input to DE10-Lite

The FPGA uses the onboard MAX 10 ADC.

The supplied VHDL selects ADC1 channel 1, which corresponds to Arduino analog input A0 on the DE10-Lite.

| Audio module | DE10-Lite |
|---|---|
| Analog OUT | Arduino A0 (JP8) |
| GND | GND |
| VCC | Suitable power supply for the audio module |

**Important:**
- The DE10-Lite analog front-end supports input signals up to 5.0 V and scales them for the FPGA ADC.
- Keep the audio signal within the 0–5 V input range.
- The ADC is unipolar. An audio waveform must be biased above 0 V so its negative portions are not clipped.
- Check the audio module's required supply voltage before connecting VCC.

## 3. DE10-Lite to ESP32 Connections

The ESP32 communicates with the FPGA through SPI.

Connect the following pins:

| ESP32 | DE10-Lite JP1 | FPGA Signal | FPGA Pin |
|---|---|---|---|
| GPIO 18 | Pin 3 | GPIO[2] / SCLK | PIN_V9 |
| GPIO 19 | Pin 4 | GPIO[3] / MISO | PIN_W9 |
| GPIO 27 | Pin 5 | GPIO[4] / CS | PIN_V8 |
| GPIO 25 | Pin 6 | GPIO[5] / READY | PIN_W8 |
| GPIO 26 | Pin 7 | GPIO[6] / ACK | PIN_V7 |
| GND | Pin 12 or 30 | GND | GND |

### Signal Directions

| Signal | Direction |
|---|---|
| SCLK | ESP32 → FPGA |
| MISO | FPGA → ESP32 |
| CS | ESP32 → FPGA |
| READY | FPGA → ESP32 |
| ACK | ESP32 → FPGA |

**MOSI is not connected.** The FPGA only sends audio data to the ESP32.

### SPI Configuration

| Parameter | Value |
|---|---|
| SPI Master | ESP32 |
| SPI Slave | FPGA |
| SPI Mode | Mode 0 |
| SPI Clock | 1 MHz |
| Bit Order | MSB First |

## 4. ESP32 to PC Connection

Connect the ESP32 to the PC using a USB cable.

The ESP32 forwards the audio frames through USB serial.

| Parameter | Value |
|---|---|
| Interface | USB Serial |
| Baud Rate | 1,000,000 |
| Data Format | 8N1 |
| Serial Port (Linux) | /dev/ttyUSB0 or /dev/ttyACM0 |

Select the correct serial port in the Python GUI.

## 5. Complete Connection Summary

| Connection | Purpose |
|---|---|
| Audio OUT → FPGA A0 | Analog audio input |
| Audio GND → FPGA GND | Audio ground |
| ESP32 GPIO 18 → FPGA SCLK | SPI clock |
| ESP32 GPIO 19 ← FPGA MISO | Audio data |
| ESP32 GPIO 27 → FPGA CS | SPI chip select |
| ESP32 GPIO 25 ← FPGA READY | Data-ready handshake |
| ESP32 GPIO 26 → FPGA ACK | Data acknowledgment |
| ESP32 GND ↔ FPGA GND | Common ground |
| ESP32 USB → PC | Serial communication |

## 6. Electrical Precautions

1. Connect the grounds of the audio module, FPGA, and ESP32 together.
2. The DE10-Lite JP1 GPIO signals use 3.3 V logic.
3. Do not apply 5 V directly to ESP32 GPIO pins.
4. Do not connect the DE10-Lite 5 V or 3.3 V supply outputs directly to the ESP32 power outputs.
5. Power the boards separately through their appropriate power connections.
6. Verify the audio module's output voltage before connecting it to A0.

## 7. Data Transmission Flow

1. The DE10-Lite ADC continuously acquires analog audio.
2. The FPGA resamples and produces 1024 samples per block at 16 kHz.
3. The FPGA asserts READY when a block is available.
4. The ESP32 detects READY and starts an SPI transaction.
5. The FPGA transmits the audio frame through MISO.
6. The ESP32 asserts ACK after receiving the complete frame.
7. The ESP32 forwards the frame to the PC through USB serial.
8. Python receives the samples, calculates the FFT, and detects the DTMF digit.

---

**Hardware:** Terasic DE10-Lite + ESP32  
**Software:** Python DTMF Detector