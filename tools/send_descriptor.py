#!/usr/bin/env python3
"""Send a load descriptor: tell the shell to stream a partial from the SD
card into the ICAP loader — from a raw LBA (Stage A2) or by following a
FAT32 cluster chain after self-mount (Stage B).

Frame (14 bytes): "M65D" + mode/part + start (4, BE) + length (4, BE) +
XOR checksum of the 9 payload bytes. mode/part: [7:4] mode (0 raw,
1 FAT32 chain), [3:0] partition (0 = first FAT32 MBR slot, 1..4 =
explicit slot; chain mode only).

The shell echoes single status bytes on TX: 'A' accepted, 'N' rejected,
'D' done, 'E' + code + r1 on failure. Codes >= 0x80 are walker-level
(mount/chain), below that the SD engine's FSM state.
"""

import argparse
import os
import sys
import time

import serial

# Mirrors sd_st_t in rtl/common/sd_sector.vhdl (diag = 'pos of the state).
SD_STATES = [
    "S_IDLE", "S_POWER_UP", "S_SEND_CLOCKS", "S_CMD_LEAD", "S_CMD_SEND",
    "S_CMD_RESP", "S_INIT_CHK0", "S_INIT_TRAIL8", "S_INIT_ACMD41",
    "S_INIT_ACMD_CHK", "S_INIT_TRAIL58", "S_READY", "S_RD_TOKEN",
    "S_RD_DATA", "S_RD_CRC", "S_RD_DESEL", "S_FAIL",
]

# Walker-level codes (fat32_walker.vhdl).
WALKER_CODES = {
    0x80: "MBR signature bad",
    0x81: "no matching FAT32 partition",
    0x82: "VBR invalid (not a FAT32 volume)",
    0x83: "chain ended before length (premature EOC)",
    0x84: "bad / out-of-bounds cluster",
}


def code_name(code: int) -> str:
    if code >= 0x80:
        return WALKER_CODES.get(code, f"walker ?0x{code:02x}")
    if code < len(SD_STATES):
        return f"SD engine {SD_STATES[code]}"
    return f"?0x{code:02x}"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="/dev/ttyUSB0")
    ap.add_argument("--baud", type=int, default=115200)
    group = ap.add_mutually_exclusive_group(required=True)
    group.add_argument("--lba", type=lambda s: int(s, 0),
                       help="raw mode: start sector on the card")
    group.add_argument("--cluster", type=lambda s: int(s, 0),
                       help="FAT32 mode: start cluster of the file "
                            "(see fat32_locate.py)")
    ap.add_argument("--partition", type=int, default=0,
                    help="FAT32 mode: 0 = first FAT32 MBR slot (default), "
                         "1..4 = explicit slot")
    lgroup = ap.add_mutually_exclusive_group(required=True)
    lgroup.add_argument("--length", type=lambda s: int(s, 0),
                        help="byte count to stream")
    lgroup.add_argument("--file",
                        help="take the byte count from this file's size")
    ap.add_argument("--timeout", type=float, default=30.0,
                    help="seconds to wait for the done/error echo")
    args = ap.parse_args()

    if not 0 <= args.partition <= 4:
        ap.error("--partition must be 0..4")

    length = args.length if args.length is not None else os.path.getsize(args.file)

    if args.lba is not None:
        mode, start = 0, args.lba
        print(f"descriptor: raw lba={start}, length={length} B "
              f"({(length + 511) // 512} sectors)")
    else:
        mode, start = 1, args.cluster
        part = args.partition or "auto"
        print(f"descriptor: FAT32 cluster={start}, partition={part}, "
              f"length={length} B")

    payload = bytes([(mode << 4) | args.partition]) \
        + start.to_bytes(4, "big") + length.to_bytes(4, "big")
    csum = 0
    for b in payload:
        csum ^= b
    frame = b"M65D" + payload + bytes([csum])

    with serial.Serial(args.port, args.baud, timeout=0.5) as port:
        port.reset_input_buffer()
        t0 = time.monotonic()
        port.write(frame)
        port.flush()

        deadline = t0 + args.timeout
        pending_diag = 0
        diag = []
        while time.monotonic() < deadline:
            data = port.read(1)
            if not data:
                continue
            b = data[0]
            if pending_diag:
                diag.append(b)
                pending_diag -= 1
                if pending_diag == 0:
                    print(f"load error: {code_name(diag[0])} "
                          f"(code 0x{diag[0]:02x}, r1/raw 0x{diag[1]:02x})")
                    return 1
            elif b == ord("A"):
                print("descriptor accepted, SD load running...")
            elif b == ord("N"):
                print("shell rejected the frame (checksum/mode/partition)",
                      file=sys.stderr)
                return 1
            elif b == ord("D"):
                dt = time.monotonic() - t0
                print(f"SD load done in {dt:.2f}s "
                      f"({length / dt / 1000:.0f} kB/s incl. card init)")
                return 0
            elif b == ord("E"):
                pending_diag = 2
            else:
                print(f"unexpected echo byte 0x{b:02x}", file=sys.stderr)

    print("timed out waiting for completion echo", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
