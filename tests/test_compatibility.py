"""Exercise compatibility decisions through the expanded production entry."""
import json
from pathlib import Path
import subprocess
import sys
import unittest

from lua_runner import find_lua_dll

RUNNER = Path(__file__).with_name("lua_runner.py")


@unittest.skipUnless(sys.platform == "win32" and find_lua_dll(), "Win64 offline LuaJIT required")
class CompatibilityTests(unittest.TestCase):
    def cases(self, names):
        for name in names:
            with self.subTest(case=name):
                result = subprocess.run([sys.executable, "-B", str(RUNNER), name], input="{}",
                                        capture_output=True, text=True, encoding="utf-8", timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                json.loads(result.stdout)

    def test_build_stamp_is_diagnostic(self):
        self.cases(("compat_unknown_stamp",))

    def test_dynamic_helmet_enumeration(self):
        self.cases(("dynamic_add", "dynamic_remove", "dynamic_reorder", "dynamic_growth", "dynamic_rebind"))

    def test_loaded_pointer_encoding(self):
        self.cases(("address_relative", "address_high", "address_mixed", "address_outside", "address_cross_record",
                    "address_overflow", "address_unaligned", "address_invalid_count", "address_mode_change"))

    def test_malformed_records_never_write(self):
        self.cases(tuple("compat_source_" + name for name in (
            "version", "flags", "size", "count", "body", "pieces", "slot", "duplicate", "short")))

    def test_unreadable_or_unsupported_pe(self):
        self.cases(tuple("compat_pe_" + name for name in ("magic", "offset", "machine", "optional", "size", "short")))

    def test_input_entry_and_owner(self):
        self.cases(("compat_input_move", "compat_input_boundary", "compat_input_multiple", "compat_input_absent",
                    "compat_owner_absent", "compat_owner_short", "compat_input_retry", "compat_live_input_loss"))

    def test_interface_and_rendering_failures(self):
        self.cases(("compat_api_missing", "compat_api_noncallable", "compat_draw_failure", "compat_live_api_loss",
                    "compat_font_resource", "compat_font_material", "compat_font_pointer"))

    def test_readonly_probe(self):
        self.cases(("probe_normal",))

    def test_search_failure_and_unavailable_library(self):
        self.cases(("scan_library_missing", "scan_symbol_missing", "scan_native_error", "scan_boundary", "scan_overlap", "scan_last_record"))
