"""Check that malformed armor snapshots cannot produce a release package."""

from copy import deepcopy
import json
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from build import validated_snapshot  # noqa: E402


class SnapshotValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.snapshot = json.loads((ROOT / "data/helmet_fields_snapshot.json").read_text(encoding="utf-8"))
        cls.source = (ROOT / "src/mod.lua").read_bytes()

    def test_current_snapshot_is_accepted(self):
        fields, layout = validated_snapshot(self.snapshot, self.source)
        self.assertEqual(len(fields), 158)
        self.assertEqual(layout["kit_id_delta"], -28)

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


if __name__ == "__main__":
    unittest.main()
