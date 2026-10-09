"""Check that malformed armor snapshots cannot produce a release package."""

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import sys
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from build import (ARCHIVE, LUA_TYPE, PACKAGE_TYPE, PACKAGES, build, font_package_resources,
                   font_asset_resources, resource_archive, render_source, resource_hash,
                   validated_locales, validated_snapshot)  # noqa: E402


def fixture_assets():
    fonts = json.loads((ROOT / "data/menu_fonts.json").read_text(encoding="utf-8"))
    resources = []
    for language, locale in fonts.items():
        p = locale["resources"][0]
        for field, kind, checks in (
            ("font", "font", ("sha256", None, None)),
            ("material", "material", ("material_sha256", None, None)),
            ("atlas", "texture", ("atlas_main_sha256", None, "atlas_gpu_sha256")),
        ):
            parts = tuple((language + field + str(i)).encode() * (i + 1) if c else b""
                          for i, c in enumerate(checks))
            for checksum, part in zip(checks, parts):
                if checksum:
                    p[checksum] = hashlib.sha256(part).hexdigest()
            resources.append((int(p[field], 16), resource_hash(kind), parts))
    return fonts, tuple(resources)


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
                        type_count, file_count = struct.unpack_from("<II", archive, 4)
                        table_start = 72 + 32 * type_count
                        entries = {}
                        previous_memory_end = 0
                        for index in range(file_count):
                            row = table_start + 80 * index
                            name_id, type_id, offset = struct.unpack_from("<QQQ", archive, row)
                            size = struct.unpack_from("<I", archive, row + 56)[0]
                            if file_count > 1:
                                memory_offset = struct.unpack_from("<Q", archive, row + 40)[0]
                                self.assertEqual(memory_offset % 256, 0)
                                self.assertGreaterEqual(memory_offset, previous_memory_end)
                                previous_memory_end = memory_offset + size
                                self.assertLessEqual(previous_memory_end, struct.unpack_from("<Q", archive, 32)[0])
                            self.assertEqual(struct.unpack_from("<I", archive, row + 76)[0], index)
                            self.assertGreaterEqual(offset, table_start + 80 * file_count)
                            self.assertLessEqual(offset + size, len(archive))
                            self.assertEqual(offset % 16, 0)
                            self.assertNotIn((name_id, type_id), entries)
                            entries[name_id, type_id] = archive[offset:offset + size]
                        lua = entries.pop((resource_hash(package["resource"]), LUA_TYPE))
                        length, flags = struct.unpack_from("<II", lua)
                        self.assertEqual(flags, 2)
                        self.assertEqual(length, len(lua) - 8)
                        body = lua[8:]
                        self.assertEqual(entries, {})
                        self.assertEqual(body, render_source(kind))
                        self.assertTrue(body.startswith(f"-- HD2-Addon: {package['resource']}\n".encode()))
                        self.assertNotIn(b"-- @LAYOUT@", body)
                        self.assertNotIn(b"-- @HELMET_FIELDS@", body)
                        self.assertNotIn(b"-- @PASSIVES@", body)
                        self.assertNotIn(b"-- @MENU_LOCALES@", body)
                        self.assertNotIn(b"-- @READ_ONLY@", body)
                        self.assertNotIn(b"-- @COMPATIBILITY@", body)
                        self.assertNotIn(b"-- @SEARCH@", body)
                        self.assertNotIn(b"-- @SYSTEM_FONT@", body)
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


class FontAssetTests(unittest.TestCase):
    def test_local_extraction_checksums_and_missing_assets(self):
        fonts, assets = fixture_assets()
        with tempfile.TemporaryDirectory(prefix="hd2dap-font-assets-", dir=ROOT.parent / "TMP") as folder:
            target = Path(folder)
            for name, kind, parts in assets:
                label = next(k for k in ("font", "material", "texture") if resource_hash(k) == kind)
                for suffix, part in zip(("main", "stream", "gpu"), parts):
                    if part:
                        (target / f"{name:016x}.{label}.{suffix}").write_bytes(part)
            self.assertEqual(font_asset_resources(fonts, target), assets)
            first = target / f"{assets[0][0]:016x}.font.main"
            first.write_bytes(b"wrong version")
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                font_asset_resources(fonts, target)
            first.unlink()
            with self.assertRaisesRegex(ValueError, "Missing extracted"):
                font_asset_resources(fonts, target)

    def test_resource_archive_rejects_duplicates_and_bad_parts(self):
        _, assets = fixture_assets()
        with self.assertRaisesRegex(ValueError, "Duplicate archive"):
            resource_archive((assets[0], assets[0]))
        with self.assertRaisesRegex(ValueError, "Invalid native"):
            resource_archive(((1, 2, (b"", b"", b"gpu")),))


class LocaleValidationTests(unittest.TestCase):
    def setUp(self):
        self.passives = json.loads((ROOT / "data/passives.json").read_text(encoding="utf-8"))
        self.strings = json.loads((ROOT / "data/menu_strings.json").read_text(encoding="utf-8"))
        self.fonts = json.loads((ROOT / "data/menu_fonts.json").read_text(encoding="utf-8"))

    def test_current_locales_have_verified_coverage(self):
        validated_locales(self.passives, self.strings, self.fonts)
        self.assertEqual(self.passives[2]["zh_tw"], "偵察兵")

    def test_missing_passive_translation_is_rejected(self):
        del self.passives[2]["zh_tw"]
        with self.assertRaisesRegex(ValueError, "localized text: zh_tw"):
            validated_locales(self.passives, self.strings, self.fonts)

    def test_missing_menu_translation_is_rejected(self):
        del self.strings["zh_cn"]["key_waiting"]
        with self.assertRaisesRegex(ValueError, "Incomplete menu strings: zh_cn"):
            validated_locales(self.passives, self.strings, self.fonts)

    def test_unverified_character_is_rejected(self):
        self.strings["zh_tw"]["title"] += "𠀀"
        with self.assertRaisesRegex(ValueError, "verified font coverage: zh_tw"):
            validated_locales(self.passives, self.strings, self.fonts)

    def test_invalid_font_resource_is_rejected(self):
        for key in ("font", "material", "atlas"):
            with self.subTest(key=key):
                resource = self.fonts["zh_cn"]["resources"][0]
                original = resource[key]
                resource[key] = "not-a-hash"
                with self.assertRaisesRegex(ValueError, "Invalid menu font resources: zh_cn"):
                    validated_locales(self.passives, self.strings, self.fonts)
                resource[key] = original

    def test_invalid_font_package_is_rejected(self):
        self.fonts["zh_tw"]["package"] = "not-a-hash"
        with self.assertRaisesRegex(ValueError, "Invalid menu font resources: zh_tw"):
            validated_locales(self.passives, self.strings, self.fonts)


class FontPackageTests(unittest.TestCase):
    def setUp(self):
        self.snapshot = json.loads((ROOT / "data/font_packages.json").read_text(encoding="utf-8"))
        self.fonts = json.loads((ROOT / "data/menu_fonts.json").read_text(encoding="utf-8"))

    def test_preserves_native_dependencies_and_preloads_primary_fonts_only(self):
        resources = font_package_resources(self.snapshot, self.fonts)
        self.assertEqual(len(resources), 6)
        required = {(int(r["type"], 16), int(r["name"], 16)) for r in self.snapshot["required_resources"]}
        self.assertEqual(len(required), 6)
        for locale in self.fonts.values():
            self.assertIn((resource_hash("font"), int(locale["resources"][0]["font"], 16)), required)
            self.assertNotIn((resource_hash("font"), int(locale["resources"][1]["font"], 16)), required)
        for native, (name, kind, payload) in zip(self.snapshot["packages"], resources):
            self.assertEqual(name, int(native["name"], 16))
            self.assertEqual(kind, PACKAGE_TYPE)
            original = {(int(r["type"], 16), int(r["name"], 16)) for r in native["items"]}
            items = list(struct.iter_unpack("<QQ", payload[16:]))
            self.assertEqual(struct.unpack_from("<I", payload, 8)[0], len(items))
            self.assertEqual(items, sorted(original | required))
            self.assertEqual(len(items), len(set(items)))
            self.assertEqual(payload[:8] + payload[12:16], bytes.fromhex(native["header_hex"])[:8] + b"\0" * 4)

    def test_changed_native_snapshot_is_rejected(self):
        self.snapshot["packages"][0]["items"][0]["name"] = "0123456789abcdef"
        with self.assertRaisesRegex(ValueError, "snapshot checksum"):
            font_package_resources(self.snapshot, self.fonts)

    def test_missing_primary_font_dependency_is_rejected(self):
        primary = self.fonts["zh_cn"]["resources"][0]["font"]
        self.snapshot["required_resources"] = [r for r in self.snapshot["required_resources"] if r["name"] != primary]
        with self.assertRaisesRegex(ValueError, "Missing menu font dependency"):
            font_package_resources(self.snapshot, self.fonts)

    def test_duplicate_resource_reference_is_rejected(self):
        self.snapshot["required_resources"].append(self.snapshot["required_resources"][0])
        with self.assertRaisesRegex(ValueError, "Duplicate font package dependency"):
            font_package_resources(self.snapshot, self.fonts)

    def test_non_font_resource_type_is_rejected(self):
        self.snapshot["required_resources"][0]["type"] = f"{LUA_TYPE:016x}"
        with self.assertRaisesRegex(ValueError, "Unexpected menu font dependency type"):
            font_package_resources(self.snapshot, self.fonts)

    def test_duplicate_package_is_rejected(self):
        self.snapshot["packages"].append(self.snapshot["packages"][0])
        with self.assertRaisesRegex(ValueError, "duplicate font package name"):
            font_package_resources(self.snapshot, self.fonts)

    def test_backup_font_preloading_is_rejected(self):
        backup = self.fonts["zh_cn"]["resources"][1]
        for key, kind in (("font", "font"), ("atlas", "texture")):
            with self.subTest(resource=key):
                snapshot = deepcopy(self.snapshot)
                snapshot["required_resources"].append({"type": f"{resource_hash(kind):016x}", "name": backup[key]})
                with self.assertRaisesRegex(ValueError, "Backup menu fonts must not be preloaded"):
                    font_package_resources(snapshot, self.fonts)


if __name__ == "__main__":
    unittest.main()
