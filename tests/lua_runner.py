"""Run expanded addon code in a standalone Win64 LuaJIT state, never in HD2."""

from __future__ import annotations

import ctypes
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from build import render_source  # noqa: E402


def find_lua_dll() -> Path | None:
    override = os.environ.get("HD2_LUA_DLL")
    if override:
        path = Path(override)
        return path if path.is_file() else None
    if sys.platform != "win32":
        return None
    import winreg

    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as key:
            steam = Path(winreg.QueryValueEx(key, "SteamPath")[0])
    except OSError:
        return None
    import re

    libraries = [steam]
    folders = steam / "steamapps/libraryfolders.vdf"
    if folders.is_file():
        libraries.extend(Path(path.replace("\\\\", "\\")) for path in
                         re.findall(r'"path"\s+"([^"]+)"', folders.read_text(encoding="utf-8")))
    for library in libraries:
        path = library / "steamapps/common/Helldivers 2/bin/lua51.dll"
        if path.is_file():
            return path
    return None


def run(case: str, settings: str | None = None, source: bytes | None = None, fps: int = 60,
        harness: bytes | None = None) -> dict:
    path = find_lua_dll()
    if path is None:
        raise RuntimeError("Win64 LuaJIT DLL not found; set HD2_LUA_DLL to an offline lua51.dll")
    lua = ctypes.CDLL(str(path))
    pointer = ctypes.c_void_p
    lua.luaL_newstate.restype = pointer
    lua.luaL_openlibs.argtypes = [pointer]
    lua.luaL_loadbuffer.argtypes = [pointer, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p]
    lua.lua_pcall.argtypes = [pointer, ctypes.c_int, ctypes.c_int, ctypes.c_int]
    lua.lua_tolstring.argtypes = [pointer, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)]
    lua.lua_tolstring.restype = pointer
    lua.lua_pushlstring.argtypes = [pointer, ctypes.c_char_p, ctypes.c_size_t]
    lua.lua_setfield.argtypes = [pointer, ctypes.c_int, ctypes.c_char_p]
    lua.lua_getfield.argtypes = [pointer, ctypes.c_int, ctypes.c_char_p]
    lua.lua_close.argtypes = [pointer]
    state = lua.luaL_newstate()
    if not state:
        raise RuntimeError("luaL_newstate failed")

    def string_at(index: int) -> bytes | None:
        length = ctypes.c_size_t()
        value = lua.lua_tolstring(state, index, ctypes.byref(length))
        return ctypes.string_at(value, length.value) if value else None

    def set_string(name: str, value: bytes) -> None:
        lua.lua_pushlstring(state, value, len(value))
        lua.lua_setfield(state, -10002, name.encode())  # LUA_GLOBALSINDEX, Lua 5.1

    try:
        lua.luaL_openlibs(state)
        mod_source = source if source is not None else render_source(
            "compatibility" if case.startswith("probe_") else "release")
        if case == "pagination_single":
            start = mod_source.index(b"local PASSIVES = {\n")
            end = mod_source.index(b"\n}", start) + 2
            rows = mod_source[start:end].splitlines()
            mod_source = mod_source[:start] + b"\n".join(rows[:9] + [b"}"]) + mod_source[end:]
        set_string("MOD_SOURCE", mod_source)
        set_string("CASE", case.encode())
        set_string("MEASURE_FPS", str(fps).encode())
        if settings is not None:
            set_string("CONFIG_OVERRIDE", settings.encode())
        snapshot = json.loads((ROOT / "data/helmet_fields_snapshot.json").read_text(encoding="utf-8"))
        records = json.loads((ROOT / "tests/fixtures/armor_records.json").read_text(encoding="utf-8"))
        passives = json.loads((ROOT / "data/passives.json").read_text(encoding="utf-8"))
        rows = ",".join(f"{{{entry['offset']},{entry['kit_id']}}}" for entry in snapshot["helmet_fields"])
        ids = ",".join(str(entry["id"]) for entry in passives)
        record_rows = ",".join("{" + ",".join(map(str, record)) + "}" for record in records)
        fixture = (f"return {{size={snapshot['decrypted_blob_size']}, fields={{{rows}}}, records={{{record_rows}}}, "
                   f"ids={{{ids}}}}}")
        set_string("FIXTURE_SOURCE", fixture.encode())
        body = harness if harness is not None else (ROOT / "tests/offline_runtime.lua").read_bytes()
        body = body.replace(b"-- @SYSTEM_FONT_MOCK@", (ROOT / "tests/offline_system_font.lua").read_bytes())
        result = lua.luaL_loadbuffer(state, body, len(body), b"@tests/offline_runtime.lua")
        if result == 0:
            result = lua.lua_pcall(state, 0, 0, 0)
        if result:
            raise RuntimeError((string_at(-1) or b"unknown Lua error").decode("utf-8", errors="replace"))
        lua.lua_getfield(state, -10002, b"RESULT_INI")
        saved = string_at(-1)
        metrics = {}
        for name in ("reads", "table_reads", "scans", "scan_allocations", "log_opens", "key_resolutions"):
            lua.lua_getfield(state, -10002, ("RESULT_" + name).encode())
            value = string_at(-1)
            metrics[name] = int(value) if value is not None else None
        return {"case": case, "settings": saved.decode() if saved is not None else None, "metrics": metrics}
    finally:
        lua.lua_close(state)


if __name__ == "__main__":
    request = json.loads(sys.stdin.read() or "{}")
    print(json.dumps(run(sys.argv[1], request.get("settings"))))
