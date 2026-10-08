"""Exercise production Lua against isolated input, I/O and memory fixtures."""

import json
from pathlib import Path
import subprocess
import sys
import unittest

from lua_runner import find_lua_dll


RUNNER = Path(__file__).with_name("lua_runner.py")


@unittest.skipUnless(sys.platform == "win32" and find_lua_dll(), "Win64 offline LuaJIT required")
class RuntimeTests(unittest.TestCase):
    def run_case(self, case, settings=None):
        process = subprocess.run(
            [sys.executable, "-B", str(RUNNER), case],
            input=json.dumps({"settings": settings}), capture_output=True, text=True,
            encoding="utf-8", timeout=30,
        )
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        return json.loads(process.stdout)

    def test_hotkey_configuration(self):
        for case in ("settings_missing", "settings_valid", "settings_invalid", "settings_version",
                     "settings_duplicate", "settings_read_error", "settings_large", "settings_permission"):
            with self.subTest(case=case):
                self.run_case(case)
        for key in ("F1", "F12", " f10 "):
            with self.subTest(key=key):
                self.run_case("settings_override", f"settings_version=1\nmenu_hotkey={key}\n")
        for key in ("f0", "f13", "f01", "ctrl+f10", "a"):
            with self.subTest(key=key):
                self.run_case("settings_reject", f"settings_version=1\nmenu_hotkey={key}\n")

    def test_capture_and_restart(self):
        result = self.run_case("capture_save")
        self.assertEqual(result["settings"], "settings_version=1\nmenu_hotkey=f1\n")
        self.run_case("settings_override", result["settings"])
        for case in ("capture_wait", "capture_cancel", "capture_multiple", "capture_close",
                     "capture_focus", "capture_scene", "capture_blocks_apply", "hotkey_hold",
                     "hotkey_reset", "scene_gate"):
            with self.subTest(case=case):
                self.run_case(case)

    def test_hotkey_save_failures(self):
        for case in ("settings_save_open", "settings_save_write", "settings_save_close", "settings_save_replace"):
            with self.subTest(case=case):
                self.run_case(case)

    def test_memory_transactions(self):
        for case in ("apply_success", "apply_clear", "reject_kit", "reject_type", "reject_passive",
                     "reject_short", "reject_header", "reject_page", "reject_before_write",
                     "rollback_readback", "rollback_runtime", "rollback_config", "rollback_protect",
                     "protected_write", "startup_locate", "source_reset", "source_recovery"):
            with self.subTest(case=case):
                self.run_case(case)

    def test_runtime_scanning(self):
        for case in ("scan_cached", "scan_unique", "scan_multiple", "scan_absent", "scan_lazy_reuse", "scan_short"):
            with self.subTest(case=case):
                self.run_case(case)

    def test_maintenance_and_logging(self):
        for case in ("timer60", "timer144", "timer240", "timer_gap", "timer_fallback", "runtime_retry",
                     "log_idle", "log_merge", "log_retry", "log_retry_write", "log_retry_close", "log_dedup",
                     "input_cache", "pointer_reads"):
            with self.subTest(case=case):
                self.run_case(case)

    def test_callback_and_loader_compatibility(self):
        for case in ("callback_values", "callback_prior_error", "callback_module_error", "shutdown",
                     "loader_legacy", "loader_v19", "ffi_aliases", "zh_ui", "font_fallback",
                     "native_back_error", "native_game_menu_error"):
            with self.subTest(case=case):
                self.run_case(case)

    def test_scene_change_blocks_operations(self):
        for case in ("scene_grace_enter", "scene_grace_mouse", "scene_grace_reset", "scene_grace_capture",
                     "scene_grace_navigation", "scene_grace_close", "scene_grace_escape", "scene_grace_recovery"):
            with self.subTest(case=case):
                self.run_case(case)

    def test_runtime_identity_changes(self):
        for case in ("runtime_scan_changed", "runtime_before_write_changed"):
            with self.subTest(case=case):
                self.run_case(case)

    def test_deferred_gui_cleanup(self):
        for case in ("gui_deferred_cleanup", "gui_removed_world", "gui_failed_cleanup", "gui_consumer_cleanup"):
            with self.subTest(case=case):
                self.run_case(case)

    def test_restore_failure_log_recovery(self):
        for case in ("log_restore_dedup", "log_restore_recovery"):
            with self.subTest(case=case):
                self.run_case(case)


if __name__ == "__main__":
    unittest.main()
