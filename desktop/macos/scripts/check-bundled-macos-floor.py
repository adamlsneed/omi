#!/usr/bin/env python3
"""Reject bundled native code built for a newer macOS than the app advertises."""

import mmap
import os
from pathlib import Path
import plistlib
import struct
import sys

THIN = {
    b"\xce\xfa\xed\xfe": ("<", 28),
    b"\xcf\xfa\xed\xfe": ("<", 32),
    b"\xfe\xed\xfa\xce": (">", 28),
    b"\xfe\xed\xfa\xcf": (">", 32),
}
FAT = {
    b"\xca\xfe\xba\xbe": (">", 20),
    b"\xbe\xba\xfe\xca": ("<", 20),
    b"\xca\xfe\xba\xbf": (">", 32),
    b"\xbf\xba\xfe\xca": ("<", 32),
}


def versions(data, start=0, end=None):
    end = len(data) if end is None else end

    def require(condition):
        if not condition:
            raise ValueError("malformed Mach-O or archive")

    def unpack(fmt, offset):
        require(start <= offset and offset + struct.calcsize(fmt) <= end)
        return struct.unpack_from(fmt, data, offset)

    magic = data[start : start + 4]
    if magic in FAT:
        endian, width = FAT[magic]
        (count,) = unpack(endian + "I", start + 4)
        require(count > 0 and start + 8 + count * width <= end)
        result = []
        for index in range(count):
            entry = start + 8 + index * width
            offset, size = unpack(endian + ("QQ" if width == 32 else "II"), entry + 8)
            require(offset >= 8 + count * width and size > 0 and start + offset + size <= end)
            slice_start = start + offset
            require(data[slice_start : slice_start + 4] in THIN or data[slice_start : slice_start + 8] == b"!<arch>\n")
            targets = versions(data, slice_start, slice_start + size)
            require(targets)
            result.extend(targets)
        return result
    if data[start : start + 8] == b"!<arch>\n":
        offset = start + 8
        result = []
        while offset < end:
            require(offset + 60 <= end and data[offset + 58 : offset + 60] == b"`\n")
            name = data[offset : offset + 16].decode("ascii").strip()
            size = int(data[offset + 48 : offset + 58])
            body = offset + 60
            require(size >= 0 and body + size <= end)
            name_size = int(name[3:]) if name.startswith("#1/") else 0
            require(0 <= name_size <= size)
            result.extend(versions(data, body + name_size, body + size))
            offset = body + size + size % 2
        return result
    if magic not in THIN:
        return []
    endian, header = THIN[magic]
    filetype, count, commands_size = unpack(endian + "III", start + 12)
    offset = start + header
    require(offset + commands_size <= end)
    commands_end = offset + commands_size
    result = []
    for _ in range(count):
        command, size = unpack(endian + "II", offset)
        require(size >= 8 and offset + size <= commands_end)
        if command == 0x32:  # LC_BUILD_VERSION
            require(size >= 24)
            platform, minimum = unpack(endian + "II", offset + 8)
            require(platform == 1)  # macOS
            result.append(minimum)
        elif command == 0x24:  # LC_VERSION_MIN_MACOSX
            require(size >= 16)
            result.append(unpack(endian + "I", offset + 8)[0])
        offset += size
    require(offset == commands_end)
    if not result and filetype != 1:  # Archive object files may have no deployment command.
        raise ValueError("Mach-O has no macOS deployment target")
    return result


def display(version):
    return f"{version >> 16}.{(version >> 8) & 255}.{version & 255}"


def main():
    app = Path(sys.argv[1])
    with (app / "Contents/Info.plist").open("rb") as handle:
        declared = plistlib.load(handle)["LSMinimumSystemVersion"]
    parts = [int(part) for part in declared.split(".")]
    if not 1 <= len(parts) <= 3 or any(part < 0 or part > 255 for part in parts):
        raise ValueError("invalid LSMinimumSystemVersion")
    parts += [0] * (3 - len(parts))
    floor = (parts[0] << 16) | (parts[1] << 8) | parts[2]
    checked, errors = 0, []

    def walk_error(error):
        raise error

    for directory, _, files in os.walk(app / "Contents", onerror=walk_error):
        for filename in files:
            path = Path(directory) / filename
            if path.is_symlink():
                continue  # The real bundle member is inspected once; dependency audit checks links.
            with path.open("rb") as handle:
                if handle.read(4) not in THIN.keys() | FAT.keys():
                    continue
                with mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as data:
                    try:
                        targets = versions(data)
                        if not targets:
                            raise ValueError("no macOS deployment target in native container")
                        checked += 1
                        if max(targets) > floor:
                            errors.append(f"{path}: minimum macOS {display(max(targets))} exceeds app {declared}")
                    except (ValueError, struct.error) as error:
                        errors.append(f"{path}: {error}")
    if not checked and not errors:
        errors.append("no Mach-O files found in bundle")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        print(
            "Rebuild native dependencies for the app's declared macOS version before signing. "
            "Select compatible WebP with PKG_CONFIG_PATH and PCRE2 with OMI_PCRE2_DYLIB.",
            file=sys.stderr,
        )
        return 1
    print(f"macOS deployment floor passed: {checked} native files, app minimum {declared}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, IndexError, plistlib.InvalidFileException) as error:
        print(f"macOS deployment floor audit failed: {error}", file=sys.stderr)
        sys.exit(1)
