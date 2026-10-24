#!/usr/bin/env python3
"""Run the real installer against offline release fixtures in an isolated PATH."""
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

INSTALLER = Path(__file__).resolve().parents[1] / "install.sh"
ASSET = "omnicode-linux-x86_64.tar.gz"


class Installer(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.download_tmp = self.root / "download tmp"
        self.download_tmp.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("mktemp", "rm", "mkdir", "tar", "gzip", "install", "awk", "cp", "sha256sum", "mv"):
            (self.bin / name).symlink_to(shutil.which(name))
        self.script("uname", 'case "$1" in -s) echo Linux;; -m) echo x86_64;; esac\n')
        self.script("curl", '''url="$2"
out="$4"
case "$url" in
    */SHA256SUMS) cp "$FIXTURES/SHA256SUMS" "$out" ;;
    *) cp "$FIXTURES/archive" "$out" ;;
esac
''')
        self.release(b"#!/bin/sh\necho fixture-version\n")
        self.dest = self.root / "install with spaces"
        self.dest.mkdir()
        self.existing = self.dest / "omnicode"
        self.existing.write_text("existing binary")

    def release(self, body):
        with tarfile.open(self.root / "archive", "w:gz") as archive:
            info = tarfile.TarInfo("omnicode")
            info.size = len(body)
            info.mode = 0o755
            archive.addfile(info, io.BytesIO(body))
        self.digest = hashlib.sha256((self.root / "archive").read_bytes()).hexdigest()
        self.manifest(f"{self.digest}  {ASSET}\n")

    def script(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\nset -eu\n" + body)
        path.chmod(0o755)

    def manifest(self, text):
        (self.root / "SHA256SUMS").write_text(text)

    def run_installer(self):
        result = subprocess.run(["/bin/sh", str(INSTALLER)], text=True, capture_output=True,
                              env={"PATH": str(self.bin), "HOME": str(self.root),
                                   "INSTALL_DIR": str(self.dest), "FIXTURES": str(self.root),
                                   "TMPDIR": str(self.download_tmp)},
                              timeout=10)
        self.assertEqual(list(self.download_tmp.iterdir()), [])
        return result

    def assert_rejected(self):
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.existing.read_text(), "existing binary")
        self.assertEqual(list(self.dest.iterdir()), [self.existing])

    def test_verified_install_with_spaces(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("fixture-version", result.stdout)
        self.assertTrue(os.access(self.existing, os.X_OK))
        self.assertEqual(self.existing.stat().st_mode & 0o777, 0o755)
        self.assertEqual(list(self.dest.iterdir()), [self.existing])

    def test_failed_staging_copy_preserves_existing_binary(self):
        (self.bin / "install").unlink()
        self.script("install", 'for arg do dest="$arg"; done\nprintf partial > "$dest"\nexit 1\n')
        self.assert_rejected()

    def test_termination_during_staging_preserves_binary_and_cleans_up(self):
        (self.bin / "install").unlink()
        self.script("install", 'kill -TERM "$PPID"\nexit 0\n')
        self.assert_rejected()

    def test_failed_version_check_preserves_existing_binary(self):
        self.release(b"#!/bin/sh\nexit 7\n")
        self.assert_rejected()

    def test_failed_final_rename_preserves_existing_binary(self):
        (self.bin / "mv").unlink()
        self.script("mv", "exit 1\n")
        self.assert_rejected()

    def test_replaces_links_without_modifying_their_targets(self):
        for kind in ("symlink", "hardlink", "directory symlink"):
            with self.subTest(kind=kind):
                self.existing.unlink()
                target = self.root / (kind + " target")
                if kind == "directory symlink":
                    target.mkdir()
                    (target / "marker").write_text("keep directory")
                    self.existing.symlink_to(target)
                else:
                    target.write_text("keep target")
                    if kind == "symlink":
                        self.existing.symlink_to(target)
                    else:
                        os.link(target, self.existing)
                result = self.run_installer()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(self.existing.is_symlink())
                if kind == "directory symlink":
                    self.assertEqual([p.name for p in target.iterdir()], ["marker"])
                else:
                    self.assertEqual(target.read_text(), "keep target")
                self.assertEqual(list(self.dest.iterdir()), [self.existing])

    def test_directory_destination_is_rejected_without_nested_install(self):
        self.existing.unlink()
        self.existing.mkdir()
        marker = self.existing / "marker"
        marker.write_text("keep directory")
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(marker.read_text(), "keep directory")
        self.assertEqual(list(self.existing.iterdir()), [marker])
        self.assertEqual(list(self.dest.iterdir()), [self.existing])

    def test_checksum_download_failure(self):
        (self.root / "SHA256SUMS").unlink()
        self.assert_rejected()

    def test_missing_checksum_tool(self):
        (self.bin / "sha256sum").unlink()
        self.assert_rejected()

    def test_bad_manifests(self):
        for manifest in ("", f"{'0' * 64}  {ASSET}\n", f"invalid  {ASSET}\n",
                         f"{self.digest}  {ASSET}\n" * 2,
                         f"{self.digest}  other.tar.gz\n",
                         f"{self.digest}  {ASSET} extra\n"):
            with self.subTest(manifest=manifest):
                self.manifest(manifest)
                self.assert_rejected()

    def test_corrupted_archive(self):
        with (self.root / "archive").open("ab") as archive:
            archive.write(b"tampered")
        self.assert_rejected()


if __name__ == "__main__":
    unittest.main()
