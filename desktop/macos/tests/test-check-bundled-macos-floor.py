#!/usr/bin/env python3
import plistlib
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/check-bundled-macos-floor.py"


def macho(major=14, minor=0, legacy=False):
    version = (major << 16) | (minor << 8)
    command = (
        struct.pack("<IIII", 0x24, 16, version, 0) if legacy else struct.pack("<IIIIII", 0x32, 24, 1, version, 0, 0)
    )
    return struct.pack("<IIIIIIII", 0xFEEDFACF, 0x100000C, 0, 6, 1, len(command), 0, 0) + command


def fat(*slices):
    offset = 8 + 20 * len(slices)
    entries = []
    for item in slices:
        entries.append(struct.pack(">IIIII", 0x100000C, 0, offset, len(item), 0))
        offset += len(item)
    return struct.pack(">II", 0xCAFEBABE, len(slices)) + b"".join(entries) + b"".join(slices)


def archive(item):
    header = f"object.o/       {0:<12}{0:<6}{0:<6}{'100644':<8}{len(item):<10}`\n".encode()
    assert len(header) == 60
    return b"!<arch>\n" + header + item + (b"\n" if len(item) % 2 else b"")


class BundleFloorTests(unittest.TestCase):
    def check_bundle(self, payload, expected, name="Frameworks/library.dylib", declared="14.0"):
        with tempfile.TemporaryDirectory() as tmp:
            contents = Path(tmp) / "Test.app/Contents"
            contents.mkdir(parents=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps({"LSMinimumSystemVersion": declared}))
            path = contents / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload)
            result = subprocess.run(["python3", str(SCRIPT), str(contents.parent)], text=True, capture_output=True)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
            return result.stdout + result.stderr

    def test_current_and_legacy_deployment_commands_pass(self):
        self.check_bundle(fat(macho(14), macho(10, 13, True)), 0)

    def test_newer_slice_fails_with_path_and_actual_floor(self):
        output = self.check_bundle(fat(macho(14), macho(26)), 1)
        self.assertIn("library.dylib", output)
        self.assertIn("26.0", output)

    def test_bundled_executables_and_nested_node_libraries_are_checked(self):
        for name in ["Resources/ffmpeg", "Resources/agent/node_modules/vendor/libpcre2-8.0.dylib"]:
            with self.subTest(name=name):
                self.check_bundle(macho(27), 1, name)

    def test_static_framework_archive_is_inspected(self):
        self.check_bundle(fat(archive(macho(14)), archive(macho(14))), 0)
        self.check_bundle(fat(archive(macho(26))), 1)

    def test_unknown_universal_slice_is_rejected(self):
        self.check_bundle(fat(macho(14), b"not-a-mach-o-slice"), 1)

    def test_corrupt_macho_is_rejected(self):
        self.check_bundle(macho(14)[:40], 1)

    def test_missing_deployment_metadata_is_rejected(self):
        self.check_bundle(struct.pack("<IIIIIIII", 0xFEEDFACF, 0x100000C, 0, 6, 0, 0, 0, 0), 1)

    def test_release_prepares_and_audits_before_signing_and_checks_nested_signatures(self):
        # Source inspection: static release wiring cannot execute publishing/signing in a unit test.
        script = (SCRIPT.parents[1] / "release.sh").read_text()
        steps = [
            './scripts/prepare-desktop-bundle-native-deps.sh "$APP_BUNDLE"',
            'step "Signing"',
            'step "Signing nested Mach-O under Resources (node native modules, dylibs)"',
            'sign --entitlements Desktop/Omi-Release.entitlements --sign "$SIGN_IDENTITY" "$APP_BUNDLE"',
            './scripts/check-desktop-bundle-signatures.sh "$APP_BUNDLE"',
            './scripts/audit-desktop-bundle-deps.sh "$APP_BUNDLE"',
        ]
        positions = [script.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))

    def test_declared_floor_is_used(self):
        self.check_bundle(macho(14, 1), 1)
        self.check_bundle(macho(14, 1), 0, declared="14.1")


if __name__ == "__main__":
    unittest.main()
