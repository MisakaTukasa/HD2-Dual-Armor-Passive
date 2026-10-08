"""Check that malformed armor snapshots cannot produce a release package."""

from copy import deepcopy
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from build import ARCHIVE, PACKAGES, build, render_source, resource_hash, validated_snapshot  # noqa: E402


class SnapshotValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.snapshot = json.loads((ROOT / "data/helmet_fields_snapshot.json").read_text(encoding="utf-8"))
        cls.source = (ROOT / "src/mod.lua").read_bytes()

    def test_current_snapshot_is_accepted(self):
        fields, layout = validated_snapshot(self.snapshot, self.source)
        self.assertEqual(len(fields), 158)
        self.assertEqual(layout["kit_id_delta"], -28)
        self.assertEqual(layout["field_read_start"], -28)
        self.assertEqual(layout["field_read_size"], 44)

    def test_changed_record_count_is_rejected(self):
        snapshot = deepcopy(self.snapshot)
        snapshot["record_count"] += 1
        with self.assertRaisesRegex(ValueError, "header and snapshot count"):
            validated_snapshot(snapshot, self.source)

    def test_duplicate_kit_is_rejected(self):
        snapshot = deepcopy(self.snapshot)
        snapshot["helmet_fields"][1]["kit_id"] = snapshot["helmet_fields"][0]["kit_id"]
        with self.assertRaisesRegex(ValueError, "duplicate"):
            validated_snapshot(snapshot, self.source)

    def test_out_of_bounds_identity_is_rejected(self):
        snapshot = deepcopy(self.snapshot)
        snapshot["helmet_fields"][0]["offset"] = snapshot["decrypted_blob_size"] - 4
        with self.assertRaisesRegex(ValueError, "outside"):
            validated_snapshot(snapshot, self.source)

    def test_oversized_read_window_is_rejected(self):
        snapshot = deepcopy(self.snapshot)
        snapshot["kit_type_delta"] = 40
        with self.assertRaisesRegex(ValueError, "64-byte runtime buffer"):
            validated_snapshot(snapshot, self.source)


class PackageTests(unittest.TestCase):
    def test_packages_contain_the_expanded_plaintext_entry(self):
        workspace_tmp = (ROOT.parent / "TMP").resolve()
        workspace_tmp.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="hd2dap-build-tests-", dir=workspace_tmp) as folder:
            target = Path(folder).resolve()
            self.assertEqual(target.parent, workspace_tmp)
            archives = {}
            for kind, package in PACKAGES.items():
                with self.subTest(kind=kind):
                    output = build(target / package["filename"], kind)
                    with zipfile.ZipFile(output) as zf:
                        self.assertIsNone(zf.testzip())
                        self.assertEqual(len(zf.namelist()), 4)
                        manifest = json.loads(zf.read("manifest.json"))
                        self.assertEqual(manifest["Guid"], package["guid"])
                        self.assertIn("API 1", manifest["Description"])
                        archive = zf.read(f"Addon/{ARCHIVE}")
                        self.assertEqual(int.from_bytes(archive[0:4], "little"), 0xF0000011)
                        self.assertEqual(int.from_bytes(archive[104:112], "little"), resource_hash(package["resource"]))
                        length = int.from_bytes(archive[192:196], "little")
                        self.assertEqual(int.from_bytes(archive[196:200], "little"), 2)
                        body = archive[200:200 + length]
                        self.assertEqual(body, render_source(kind))
                        self.assertTrue(body.startswith(f"-- HD2-Addon: {package['resource']}\n".encode()))
                        self.assertNotIn(b"-- @LAYOUT@", body)
                        self.assertNotIn(b"-- @HELMET_FIELDS@", body)
                        self.assertNotIn(b"-- @PASSIVES@", body)
                        self.assertNotIn(b"-- @READ_ONLY@", body)
                        self.assertNotIn(b"-- @COMPATIBILITY@", body)
                        self.assertNotIn(b"-- @SEARCH@", body)
                        if kind == "compatibility":
                            self.assertIn(b"local READ_ONLY = true", body)
                            self.assertNotEqual(package["guid"], PACKAGES["release"]["guid"])
                        elif kind in ("release", "prototype"):
                            self.assertIn(b"local READ_ONLY = false", body)
                        self.assertNotIn(b"\r", body)
                        self.assertEqual(zf.read(f"Addon/{ARCHIVE}.stream"), b"")
                        self.assertEqual(zf.read(f"Addon/{ARCHIVE}.gpu_resources"), b"")
                        archives[kind] = archive
                    again = build(target / (kind + "-again.zip"), kind)
                    self.assertEqual(output.read_bytes(), again.read_bytes())
            self.assertEqual(archives["release"], archives["prototype"])


if __name__ == "__main__":
    unittest.main()
