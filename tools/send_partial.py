#!/usr/bin/env python3
"""Stream a partial bitstream (.bin) to the shell's UART -> ICAP loader.

The shell's UART -> ICAP loader listens at 2,000,000 baud (MEGA65 R6:
the TE0790 serial port; Wukong: the onboard USB serial).  No flow control is needed: ICAP consumes words far
faster than the UART can deliver them.  The loader is gated on the
bitstream sync word, so an interrupted upload never corrupts the
running shell — just send the file again.

Usage:
    python3 send_partial.py config_b_pblock_RM_partial.bin --port /dev/ttyUSB1

On the R6 the TE0790 enumerates as two ports; the UART is the second
one (e.g. /dev/ttyUSB1 on Linux, the higher COMx on Windows).
"""

import argparse
import sys
import time

try:
    import serial
    from serial.tools import list_ports
except ImportError:
    print("pyserial is required:  pip install pyserial", file=sys.stderr)
    sys.exit(1)

BIT_MAGIC = bytes.fromhex("00090ff00ff00ff00ff0")  # .bit header field 1
SYNC_WORD = bytes.fromhex("aa995566")
CHUNK = 65536


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Send a partial bitstream to the running DFX shell")
    ap.add_argument("binfile", help="partial bitstream in raw .bin format")
    ap.add_argument("--port", help="serial port (TE0790 UART channel)")
    ap.add_argument("--baud", type=int, default=2_000_000,
                    help="must match the shell's loader (default: 2000000)")
    args = ap.parse_args()

    if not args.port:
        print("--port is required.  Detected serial ports:", file=sys.stderr)
        for p in list_ports.comports():
            print(f"  {p.device}  ({p.description})", file=sys.stderr)
        print("The TE0790's UART is usually the second of its two ports.",
              file=sys.stderr)
        return 1

    with open(args.binfile, "rb") as f:
        data = f.read()

    if data.startswith(BIT_MAGIC):
        print("error: this is a .bit file (it has a header). The loader "
              "needs the raw .bin — use the *_partial.bin from the same "
              "release.", file=sys.stderr)
        return 1
    if SYNC_WORD not in data[:4096]:
        print("error: no bitstream sync word found — this doesn't look "
              "like a partial .bin.", file=sys.stderr)
        return 1
    if "partial" not in args.binfile.lower():
        print("warning: filename doesn't contain 'partial' — full-device "
              ".bin files cannot be loaded this way. Continuing anyway...",
              file=sys.stderr)

    with serial.Serial(args.port, args.baud) as port:
        t0 = time.monotonic()
        sent = 0
        while sent < len(data):
            sent += port.write(data[sent:sent + CHUNK])
            dt = time.monotonic() - t0
            rate = sent / dt if dt > 0 else 0
            eta = (len(data) - sent) / rate if rate > 0 else 0
            print(f"\r{sent * 100 // len(data):3d}%  "
                  f"{sent}/{len(data)} bytes  "
                  f"{rate / 1000:6.0f} kB/s  ETA {eta:4.0f}s", end="",
                  flush=True)
        port.flush()
        dt = time.monotonic() - t0

    print(f"\nsent {len(data)} bytes in {dt:.2f}s "
          f"({len(data) / dt / 1000:.0f} kB/s)")
    print("The new core should appear once the monitor re-syncs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
