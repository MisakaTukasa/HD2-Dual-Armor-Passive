"""Build a Bingus Shared Loader API 1 package for HD2 Arsenal."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import uuid
import zipfile


ARCHIVE = "9ba626afa44a3aa3.patch_0"
LUA_TYPE = 0xA14E8DFA2CD117E2
PACKAGE_TYPE = 0xAD9C6D9ED1E5E77A
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
        "description": "v1.2.0 dual armor passive menu with saved language and key settings.",
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


def archive_for(name: str, source: bytes, extra_resources: tuple = ()) -> bytes:
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
    resources = [(resource_hash(name), LUA_TYPE, struct.pack("<II", len(body), 2) + body)]
    resources.extend(extra_resources)
    keys = [(name_id, type_id) for name_id, type_id, _ in resources]
    if len(keys) != len(set(keys)):
        raise ValueError("Duplicate archive resource")
    if extra_resources:
        return resource_archive(tuple((n, t, (p, b"", b"")) for n, t, p in resources))[0]
    type_ids = sorted({type_id for _, type_id, _ in resources})
    table_end = 72 + 32 * len(type_ids) + 80 * len(resources)
    data = bytearray(table_end + (-table_end % 16))
    entries = []
    for index, (name_id, type_id, payload) in enumerate(resources):
        offset = len(data)
        data.extend(payload)
        data.extend(b"\0" * (-len(data) % 16))
        entries.append(struct.pack("<7Q6I", name_id, type_id, offset, 0, 0, 0, 0,
                                   len(payload), 0, 0, 16, 16, index))
    header = struct.pack("<III20sQQ24s", 0xF0000011, len(type_ids), len(resources), b"", len(data), 0, b"")
    types = b"".join(struct.pack("<IIQIIII", 0, 0, type_id,
                                 sum(t == type_id for _, t, _ in resources), 0, 16, 16)
                     for type_id in type_ids)
    tables = header + types + b"".join(entries)
    data[:len(tables)] = tables
    return bytes(data)


def resource_archive(resources: tuple) -> tuple[bytes, bytes, bytes]:
    """Encode native resources with independent main, stream and GPU buffers."""
    if not resources:
        raise ValueError("Empty resource archive")
    keys = [(name, kind) for name, kind, _ in resources]
    if len(keys) != len(set(keys)):
        raise ValueError("Duplicate archive resource")
    resources = tuple(sorted(resources, key=lambda r: (r[1], r[0])))
    types = sorted({kind for _, kind, _ in resources})
    table_end = 72 + 32 * len(types) + 80 * len(resources)
    buffers = [bytearray(table_end + (-table_end % 16)), bytearray(), bytearray()]
    entries = []
    main_memory = gpu_memory = 0
    for index, (name, kind, parts) in enumerate(resources):
        if len(parts) != 3 or not parts[0] or any(not isinstance(p, bytes) for p in parts):
            raise ValueError("Invalid native resource parts")
        offsets = []
        for i, (buffer, part) in enumerate(zip(buffers, parts)):
            alignment = 256 if i == 2 else 16
            buffer.extend(b"\0" * (-len(buffer) % alignment))
            offsets.append(len(buffer))
            buffer.extend(part)
        entries.append(struct.pack("<7Q6I", name, kind, *offsets, main_memory, gpu_memory,
                                   *(len(p) for p in parts), 16, 64, index))
        main_memory += len(parts[0]) + (-len(parts[0]) % 256)
        gpu_memory += len(parts[2]) + (-len(parts[2]) % 256)
    buffers[2].extend(b"\0" * (-len(buffers[2]) % 256))
    header = struct.pack("<III20sQQ24s", 0xF0000011, len(types), len(resources), b"",
                         main_memory, gpu_memory, b"")
    type_table = b"".join(struct.pack("<IIQIIII", 0, 0, kind,
                                      sum(t == kind for _, t, _ in resources), 0, 16, 64)
                          for kind in types)
    tables = header + type_table + b"".join(entries)
    buffers[0][:len(tables)] = tables
    return tuple(bytes(b) for b in buffers)


def font_asset_resources(fonts: dict, asset_dir: Path) -> tuple:
    """Read pinned primary assets from a local extraction, never from the game process."""
    resources = []
    for locale in fonts.values():
        primary = locale["resources"][0]
        for field, kind, checks in (
            ("font", "font", ("sha256", None, None)),
            ("material", "material", ("material_sha256", None, None)),
            ("atlas", "texture", ("atlas_main_sha256", None, "atlas_gpu_sha256")),
        ):
            name = primary[field]
            parts = []
            for suffix, checksum in zip(("main", "stream", "gpu"), checks):
                if checksum is None:
                    parts.append(b"")
                    continue
                path = asset_dir / f"{name}.{kind}.{suffix}"
                if not path.is_file():
                    raise ValueError(f"Missing extracted menu font asset: {path}")
                if path.stat().st_size > 32 * 1024 * 1024:
                    raise ValueError("Extracted menu font asset exceeds size limit")
                payload = path.read_bytes()
                if hashlib.sha256(payload).hexdigest() != primary.get(checksum):
                    raise ValueError(f"Extracted menu font asset checksum mismatch: {path.name}")
                parts.append(payload)
            resources.append((int(name, 16), resource_hash(kind), tuple(parts)))
    if len({(name, kind) for name, kind, _ in resources}) != len(resources):
        raise ValueError("Duplicate extracted menu font asset")
    return tuple(resources)


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
        body = replace_once(body, b"-- @SYSTEM_FONT@", (root / "src/system_font.lua").read_bytes())
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
        strings = json.loads((root / "data/menu_strings.json").read_text(encoding="utf-8"))
        fonts = json.loads((root / "data/menu_fonts.json").read_text(encoding="utf-8"))
        validated_locales(passives, strings, fonts)
        passive_rows = ",\n".join(
            "    {" + str(entry["id"]) + ", "
            + json.dumps(entry["en"], ensure_ascii=False) + ", "
            + json.dumps(entry["zh"], ensure_ascii=False) + ", "
            + json.dumps(entry["zh_tw"], ensure_ascii=False) + "}"
            for entry in passives
        )
        body = replace_once(body, b"-- @PASSIVES@", ("local PASSIVES = {\n" + passive_rows + "\n}").encode("utf-8"))
        locale_rows = []
        for locale, values in strings.items():
            rows = ",\n".join("        " + key + " = " + json.dumps(value, ensure_ascii=False)
                              for key, value in values.items())
            locale_rows.append(f"    {locale} = {{\n{rows}\n    }}")
        font_rows = []
        for locale, values in fonts.items():
            rows = ", ".join('{font = "' + resource["font"] + '", material = "'
                             + resource["material"] + '", atlas = "' + resource["atlas"] + '"}'
                             for resource in values["resources"])
            font_rows.append(f'    {locale} = {{package = "{values["package"]}", {rows}}}')
        locales = "local MENU_STRINGS = {\n" + ",\n".join(locale_rows) + "\n}\n"
        locales += "local MENU_FONTS = {\n" + ",\n".join(font_rows) + "\n}"
        body = replace_once(body, b"-- @MENU_LOCALES@", locales.encode("utf-8"))
    return body


def validated_locales(passives: list[dict], strings: dict, fonts: dict) -> None:
    if set(strings) != {"en", "zh_cn", "zh_tw"} or set(fonts) != {"zh_cn", "zh_tw"}:
        raise ValueError("Expected English, Simplified and Traditional menu locales")
    keys = set(strings["en"])
    for locale, passive_key in (("en", "en"), ("zh_cn", "zh"), ("zh_tw", "zh_tw")):
        if not keys or set(strings[locale]) != keys or any(not re.fullmatch(r"[a-z_]+", k) for k in keys):
            raise ValueError(f"Incomplete menu strings: {locale}")
        values = list(strings[locale].values()) + [entry.get(passive_key) for entry in passives]
        if any(not isinstance(value, str) or not value.strip() or "\0" in value or "\r" in value for value in values):
            raise ValueError(f"Missing or invalid localized text: {locale}")
        if strings[locale]["page"].count("%d") != 2:
            raise ValueError(f"Invalid page format: {locale}")
        if locale != "en":
            if set("".join(values)) - set(fonts[locale]["verified_characters"]):
                raise ValueError(f"Menu characters lack verified font coverage: {locale}")
            resources = fonts[locale]["resources"]
            if (not re.fullmatch(r"[0-9a-f]{16}", fonts[locale].get("package", ""))
                    or not resources or any(not re.fullmatch(r"[0-9a-f]{16}", resource.get(key, ""))
                                    for resource in resources for key in ("font", "material", "atlas"))):
                raise ValueError(f"Invalid menu font resources: {locale}")


def font_package_resources(snapshot: dict, fonts: dict) -> tuple:
    """Extend native localized font manifests while preserving their original dependencies."""
    def pairs(items: list[dict]) -> list[tuple[int, int]]:
        if not isinstance(items, list) or not items:
            raise ValueError("Invalid font package dependencies")
        rows = []
        for item in items:
            if not isinstance(item, dict) or any(not re.fullmatch(r"[0-9a-f]{16}", item.get(k, ""))
                                                 for k in ("type", "name")):
                raise ValueError("Invalid font package dependency hash")
            rows.append((int(item["type"], 16), int(item["name"], 16)))
        if len(rows) != len(set(rows)):
            raise ValueError("Duplicate font package dependency")
        return rows

    required = set(pairs(snapshot["required_resources"]))
    kinds = {"font": resource_hash("font"), "material": resource_hash("material"),
             "atlas": resource_hash("texture")}
    if any(kind not in kinds.values() for kind, _ in required):
        raise ValueError("Unexpected menu font dependency type")
    for locale in fonts.values():
        for resource in locale["resources"][:1]:
            if any((kind, int(resource[key], 16)) not in required for key, kind in kinds.items()):
                raise ValueError("Missing menu font dependency")
        for resource in locale["resources"][1:]:
            if any((kinds[key], int(resource[key], 16)) in required for key in ("font", "atlas")):
                raise ValueError("Backup menu fonts must not be preloaded")
    packages = snapshot["packages"]
    if not isinstance(packages, list) or not 1 <= len(packages) <= 16:
        raise ValueError("Invalid font package list")
    result, names = [], set()
    for package in packages:
        name = package.get("name", "")
        if not re.fullmatch(r"[0-9a-f]{16}", name) or name in names:
            raise ValueError("Invalid or duplicate font package name")
        names.add(name)
        original = pairs(package["items"])
        header_hex = package.get("header_hex", "")
        if not re.fullmatch(r"[0-9a-f]{32}", header_hex) or len(original) > 64:
            raise ValueError("Invalid localized font package header")
        header = bytes.fromhex(header_hex)
        if struct.unpack("<4I", header) != (1, 0, len(original), 0):
            raise ValueError("Unsupported localized font package header")
        original_bytes = header + b"".join(struct.pack("<QQ", *item) for item in original)
        if hashlib.sha256(original_bytes).hexdigest() != package.get("sha256"):
            raise ValueError("Native font package snapshot checksum mismatch")
        merged = sorted(set(original) | required)
        payload = header[:8] + struct.pack("<I", len(merged)) + header[12:]
        payload += b"".join(struct.pack("<QQ", *item) for item in merged)
        result.append((int(name, 16), PACKAGE_TYPE, payload))
    if any(locale["package"] not in names for locale in fonts.values()):
        raise ValueError("Missing localized Chinese font package")
    return tuple(result)


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
