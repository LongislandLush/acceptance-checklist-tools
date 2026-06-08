# Acceptance Checklist Tools

Standalone test scripts for validating acceptance checklist items on production hardware.

## Purpose

This repository stores test utilities used to verify specific acceptance checklist items.  
The scripts are intended to run from a PC or laptop and communicate with production hardware through external test interfaces such as RS-485.

These tools do not replace the production firmware and should not be flashed into the MCU.

## Test Environment

- Hardware: Production control board
- Firmware: Production release firmware
- Interface: USB to RS-485 dongle
- Host OS: Windows
- Shell: PowerShell

## Available Tests

| Checklist ID | Test Name | Script | Status |
|---|---|---|---|
| ARCH-14 | Packet Fragmentation | `ARCH-14_Packet_Fragmentation/arch14_packet_fragmentation_test.ps1` | Available |

## ARCH-14 Packet Fragmentation

This test verifies that the MCU Modbus RTU parser correctly handles an incomplete frame.

The script sends:

1. One complete Modbus Function 03 request as baseline.
2. The first half of the same request.
3. Waits 500 ms.
4. Sends the second half of the request.
5. Sends one complete request again to verify recovery.

Expected behavior:

- The MCU responds to the complete baseline request.
- The MCU does not respond to the incomplete first half.
- The MCU ignores the delayed second half.
- The MCU responds normally to the next complete valid request.

## Run Example

```powershell
powershell -ExecutionPolicy Bypass -File .\ARCH-14_Packet_Fragmentation\arch14_packet_fragmentation_test.ps1 -Port COM6
```
If the board uses 8N1 instead of 8E1:
```powershell
powershell -ExecutionPolicy Bypass -File .\ARCH-14_Packet_Fragmentation\arch14_packet_fragmentation_test.ps1 -Port COM6 -Parity None
```
## PASS Criteria

The test passes when the final output shows:

```powershell
RESULT: PASS
```
For ARCH-14, this means the MCU ignored the delayed split frame and remained responsive to the next valid Modbus request.

## Notes

- Confirm the correct COM port before running the test.
- Only one application can use the COM port at a time.
- If baseline communication fails, check wiring, COM port, baud rate, parity, slave ID, and board power first.