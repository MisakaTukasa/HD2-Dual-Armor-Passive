"""Build a Bingus Shared Loader API 1 package for HD2 Arsenal."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import struct
import uuid
import zipfile


ARCHIVE = "9ba626afa44a3aa3.patch_0"
LUA_TYPE = 0xA14E8DFA2CD117E2
PACKAGES = {
    "probe": {
        "resource": "mods/hd2/dual_armor_probe",
        "guid": "994f2dc3-bb66-49e1-8f13-e0361355015e",
        "source": "probe.lua",
        "filename": "HD2-Passive-Probe.zip",
        "title": "HD2 Dual Armor Passive Probe",
        "description": "Read-only compatibility probe for dual armor passive development.",
    },
    "prototype": {
        "resource": "mods/hd2/dual_armor_passive",
        "guid": "573eae16-818f-4ec6-a3ac-756a4357d608",
        "source": "mod.lua",
        "filename": "HD2-Passive-Prototype.zip",
        "title": "HD2 Dual Armor Passive Prototype",
        "description": "Experimental in-game passive menu. Requires a current-build compatibility check.",
    },
    "release": {
        "resource": "mods/hd2/dual_armor_passive",
        "guid": "573eae16-818f-4ec6-a3ac-756a4357d608",
        "source": "mod.lua",
        "filename": "HD2-Dual-Armor-Passive.zip",
        "title": "HD2 Dual Armor Passive",
        "description": "v1.1.0 dual armor passive menu with data compatibility checks.",
    },
    "compatibility": {
        "resource": "mods/hd2/dual_armor_compatibility_probe",
        "guid": "4ab55064-af6c-44f0-9d79-bc3ed8044e76",
        "source": "mod.lua",
        "filename": "HD2-Dual-Armor-Compatibility-Probe.zip",
        "title": "HD2 Dual Armor Compatibility Probe",
        "description": "Read-only dependency probe. Disable the passive addon while collecting baseline evidence.",
    },
}


def resource_hash(name: str) -> int:
    data = name.encode("utf-8")
    mask = (1 << 64) - 1
    mix = 0xC6A4A7935BD1E995
    value = len(data) * mix & mask
    end = len(data) // 8 * 8
    for (word,) in struct.iter_unpack("<Q", data[:end]):
        word = word * mix & mask
        word ^= word >> 47
        value = (value ^ (word * mix & mask)) * mix & mask
    if data[end:]:
        value = (value ^ int.from_bytes(data[end:], "little")) * mix & mask
    value ^= value >> 47
    value = value * mix & mask
    return value ^ (value >> 47)


def archive_for(name: str, source: bytes) -> bytes:
    if not re.fullmatch(r"mods/[A-Za-z0-9_]+/[A-Za-z0-9_]+", name):
        raise ValueError("Invalid addon resource name")
    declaration = f"-- HD2-Addon: {name}\n".encode()
    if source.startswith(declaration):
        body = source
    elif source.startswith(b"-- HD2-Addon:"):
        raise ValueError("Source has a mismatched addon declaration")
    else:
        body = declaration + source
    if body.startswith(b"\xef\xbb\xbf") or b"\0" in body:
        raise ValueError("Addon must be plain UTF-8 Lua")
    body.decode("utf-8")
    payload = struct.pack("<II", len(body), 2) + body
    offset = 192
    data = bytearray(offset)
    data.extend(payload)
    data.extend(b"\0" * (-len(data) % 16))
    header = struct.pack("<III20sQQ24s", 0xF0000011, 1, 1, b"", len(data), 0, b"")
    types = struct.pack("<IIQIIII", 0, 0, LUA_TYPE, 1, 0, 16, 16)
    entry = struct.pack(
        "<7Q6I", resource_hash(name), LUA_TYPE, offset, 0, 0, 0, 0,
        len(payload), 0, 0, 16, 16, 0,
    )
    data[: len(header + types + entry)] = header + types + entry
    return bytes(data)


def replace_once(source: bytes, marker: bytes, replacement: bytes) -> bytes:
    if source.count(marker) != 1:
        raise ValueError(f"Expected exactly one {marker.decode()} marker")
    return source.replace(marker, replacement)


def validated_snapshot(snapshot: dict, source: bytes) -> tuple[list[dict], dict]:
    if not isinstance(snapshot, dict) or not isinstance(snapshot.get("helmet_fields"), list):
        raise ValueError("Invalid helmet snapshot")
    layout_keys = ("record_count", "decrypted_blob_size", "helmet_field_count",
                   "kit_id_delta", "kit_type_delta", "helmet_type")
    layout = {key: snapshot.get(key) for key in layout_keys}
    if any(type(value) is not int for value in layout.values()):
        raise ValueError("Helmet snapshot layout values must be integers")
    fields = snapshot["helmet_fields"]
    if (layout["record_count"] < len(fields) or layout["decrypted_blob_size"] < 32
            or layout["helmet_field_count"] != len(fields) or not fields
            or layout["helmet_type"] < 0 or layout["helmet_type"] > 0xffffffff):
        raise ValueError("Helmet snapshot count or size is invalid")
    header_match = re.search(rb'local HEADER = from_hex\("([0-9a-fA-F]+)"\)', source)
    if not header_match:
        raise ValueError("Armor table header is missing")
    header = bytes.fromhex(header_match.group(1).decode())
    if len(header) != 32 or int.from_bytes(header[:4], "little") != layout["record_count"]:
        raise ValueError("Armor table header and snapshot count disagree")
    read_start = min(0, layout["kit_id_delta"], layout["kit_type_delta"])
    read_size = max(0, layout["kit_id_delta"], layout["kit_type_delta"]) + 4 - read_start
    if read_size > 64:
        raise ValueError("Helmet field read window exceeds the 64-byte runtime buffer")
    layout["field_read_start"] = read_start
    layout["field_read_size"] = read_size
    offsets, kits = set(), set()
    for index, entry in enumerate(fields, 1):
        if not isinstance(entry, dict):
            raise ValueError(f"Helmet field {index} is invalid")
        offset, kit = entry.get("offset"), entry.get("kit_id")
        if type(offset) is not int or type(kit) is not int:
            raise ValueError(f"Helmet field {index} must contain integer offset and kit ID")
        identity = offset + layout["kit_id_delta"]
        kind = offset + layout["kit_type_delta"]
        if (offset % 4 or identity % 4 or kind % 4
                or min(offset, identity, kind) < len(header)
                or max(offset, identity, kind) + 4 > layout["decrypted_blob_size"]
                or not 0 < kit <= 0xffffffff):
            raise ValueError(f"Helmet field {index} is outside the validated table layout")
        if offset in offsets or kit in kits:
            raise ValueError(f"Helmet field {index} has a duplicate offset or kit ID")
        offsets.add(offset)
        kits.add(kit)
    return fields, layout


def render_source(kind: str = "release") -> bytes:
    """Expand the same Lua entry for packaging and isolated runtime tests."""
    package = PACKAGES[kind]
    root = Path(__file__).resolve().parents[1]
    source = root / "src" / package["source"]
    body = source.read_bytes()
    if kind in ("prototype", "release", "compatibility"):
        body = replace_once(body, b"-- @READ_ONLY@", b"local READ_ONLY = " +
                            (b"true" if kind == "compatibility" else b"false"))
        body = replace_once(body, b"-- @COMPATIBILITY@", (root / "src/compatibility.lua").read_bytes())
        body = replace_once(body, b"-- @SEARCH@", (root / "src/search.lua").read_bytes())
        if kind == "compatibility":
            body = replace_once(body, b"-- HD2-Addon: mods/hd2/dual_armor_passive\n",
                                ("-- HD2-Addon: " + package["resource"] + "\n").encode())
        snapshot = json.loads((root / "data" / "helmet_fields_snapshot.json").read_text(encoding="utf-8"))
        fields, layout = validated_snapshot(snapshot, body)
        rows = ",\n".join(
            f"    {{{entry['offset']}, 0x{entry['kit_id']:08x}}}"
            for entry in fields
        )
        constants = (f"local ARMOR_BLOB_SIZE = {layout['decrypted_blob_size']}\n"
                     f"local KIT_ID_DELTA = {layout['kit_id_delta']}\n"
                     f"local KIT_TYPE_DELTA = {layout['kit_type_delta']}\n"
                     f"local HELMET_TYPE = {layout['helmet_type']}\n"
                     f"local FIELD_READ_START = {layout['field_read_start']}\n"
                     f"local FIELD_READ_SIZE = {layout['field_read_size']}\n")
        body = replace_once(body, b"-- @LAYOUT@", constants.encode())
        body = replace_once(body, b"-- @HELMET_FIELDS@", ("local HELMET_FIELDS = {\n" + rows + "\n}").encode())
        passives = json.loads((root / "data" / "passives.json").read_text(encoding="utf-8"))
        ids = [entry["id"] for entry in passives]
        if len(ids) != 32 or ids[0] != 0 or len(ids) != len(set(ids)):
            raise ValueError("Expected 31 distinct armor passives plus None")
        passive_rows = ",\n".join(
            "    {" + str(entry["id"]) + ", "
            + json.dumps(entry["en"], ensure_ascii=False) + ", "
            + json.dumps(entry["zh"], ensure_ascii=False) + "}"
            for entry in passives
        )
        body = replace_once(body, b"-- @PASSIVES@", ("local PASSIVES = {\n" + passive_rows + "\n}").encode("utf-8"))
    return body


def build(output: Path, kind: str = "probe") -> Path:
    package = PACKAGES[kind]
    body = render_source(kind)
    archive = archive_for(package["resource"], body)
    description = package["description"] + " Requires Bingus Shared Loader v15+ / API 1."
    manifest = {
        "Version": 1,
        "Guid": str(uuid.UUID(package["guid"])),
        "Name": package["title"],
        "Description": description,
        "Options": [{"Name": package["title"], "Description": description, "Include": ["Addon"]}],
    }
    files = {
        "manifest.json": (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode(),
        f"Addon/{ARCHIVE}": archive,
        f"Addon/{ARCHIVE}.stream": b"",
        f"Addon/{ARCHIVE}.gpu_resources": b"",
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w") as zf:
        for name, content in sorted(files.items()):
            info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            zf.writestr(info, content)
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", choices=sorted(PACKAGES), default="release")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    output = args.output or Path(__file__).resolve().parents[1] / "dist" / PACKAGES[args.kind]["filename"]
    print(build(output, args.kind))
