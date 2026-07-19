#!/usr/bin/env python3
"""Find a file's start cluster + size on a FAT32 card/image — the host-side
stand-in for the dirent lookup that the menu RM firmware does in the real
system (DESIGN.md: shell follows chains, the requester passes cluster+size).

Reads the block device (needs read permission, e.g. sudo) or a raw image
file. Walks the root directory only (cores live in the root for now),
matching the 8.3 short name; long file names are skipped structurally.

Prints the descriptor parameters and a ready-to-run send_descriptor.py
command. Also useful as a reference model: its MBR/VBR interpretation is
the same one fat32_walker.vhdl implements (first-FAT32-slot auto select,
FAT copy #0, cluster chain via 28-bit entries).
"""

import argparse
import struct
import sys


def rd_sector(f, lba):
    f.seek(lba * 512)
    d = f.read(512)
    if len(d) != 512:
        raise IOError(f"short read at lba {lba}")
    return d


def to83(name: str) -> bytes:
    """'CONFIGB.BIN' -> b'CONFIGB BIN' (11 bytes, upper-cased)."""
    name = name.upper()
    if "." in name:
        base, ext = name.rsplit(".", 1)
    else:
        base, ext = name, ""
    if len(base) > 8 or len(ext) > 3:
        raise ValueError(f"{name!r} is not a valid 8.3 name")
    return base.ljust(8).encode() + ext.ljust(3).encode()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("device", help="block device (/dev/sdX) or raw image")
    ap.add_argument("name", help="file name in the root directory (8.3)")
    ap.add_argument("--partition", type=int, default=0,
                    help="0 = first FAT32 MBR slot (default), 1..4 = explicit")
    args = ap.parse_args()

    want = to83(args.name)

    with open(args.device, "rb") as f:
        mbr = rd_sector(f, 0)
        if mbr[510:512] != b"\x55\xaa":
            print("MBR signature bad", file=sys.stderr)
            return 1

        part_lba = None
        for e in range(4):
            off = 446 + 16 * e
            ptype = mbr[off + 4]
            lba = struct.unpack_from("<I", mbr, off + 8)[0]
            if args.partition:
                if e == args.partition - 1:
                    part_lba = lba
                    break
            elif ptype in (0x0B, 0x0C):
                part_lba = lba
                args.partition = e + 1
                break
        if part_lba is None:
            print("no matching partition", file=sys.stderr)
            return 1

        vbr = rd_sector(f, part_lba)
        bps = struct.unpack_from("<H", vbr, 11)[0]
        spc = vbr[13]
        reserved = struct.unpack_from("<H", vbr, 14)[0]
        nfats = vbr[16]
        fatsz16 = struct.unpack_from("<H", vbr, 22)[0]
        fatsz = struct.unpack_from("<I", vbr, 36)[0]
        root_clus = struct.unpack_from("<I", vbr, 44)[0]
        if vbr[510:512] != b"\x55\xaa" or bps != 512 or fatsz16 != 0 \
           or fatsz == 0 or nfats == 0 or spc == 0 or (spc & (spc - 1)):
            print("VBR invalid (not a FAT32 volume?)", file=sys.stderr)
            return 1

        fat_begin = part_lba + reserved
        data_begin = fat_begin + nfats * fatsz

        def fat_entry(cluster):
            sec = rd_sector(f, fat_begin + cluster // 128)
            return struct.unpack_from("<I", sec, (cluster % 128) * 4)[0] \
                & 0x0FFFFFFF

        # walk the root directory chain
        cluster = root_clus
        while 2 <= cluster < 0x0FFFFFF0:
            for s in range(spc):
                d = rd_sector(f, data_begin + (cluster - 2) * spc + s)
                for e in range(16):
                    ent = d[32 * e:32 * e + 32]
                    if ent[0] == 0x00:      # end of directory
                        print(f"{args.name}: not found in root directory",
                              file=sys.stderr)
                        return 1
                    if ent[0] == 0xE5 or ent[11] == 0x0F \
                       or ent[11] & 0x08:   # deleted / LFN / volume label
                        continue
                    if ent[0:11] == want:
                        start = (struct.unpack_from("<H", ent, 20)[0] << 16) \
                            | struct.unpack_from("<H", ent, 26)[0]
                        size = struct.unpack_from("<I", ent, 28)[0]
                        print(f"{args.name}: cluster {start}, {size} bytes "
                              f"(partition slot {args.partition})")
                        print("send with:")
                        print(f"  python3 scripts/send_descriptor.py "
                              f"--cluster {start} --length {size} "
                              f"--partition {args.partition}")
                        return 0
            cluster = fat_entry(cluster)

    print(f"{args.name}: not found in root directory", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
