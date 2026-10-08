"""Native and fallback paths must produce the same ordered positions."""
from pathlib import Path
import sys
import unittest

from lua_runner import find_lua_dll, run

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == "win32" and find_lua_dll(), "Win64 offline LuaJIT required")
class SearchTests(unittest.TestCase):
    def test_production_search_equivalence(self):
        for case in ("search_native", "search_missing_library", "search_missing_symbol"):
            with self.subTest(case=case):
                run(case, source=(ROOT / "src/search.lua").read_bytes(),
                    harness=(ROOT / "tests/offline_search.lua").read_bytes())
