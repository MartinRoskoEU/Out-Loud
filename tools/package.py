"""Offline, deterministic client packages. Never tags, uploads, or publishes."""

import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
# These root TOCs serve both junction-based development and release packages.
# Use explicit client suffixes; there is no unsuffixed fallback TOC.
TOCS = {"Forever": "OutLoud_Forever.toc", "Retail": "OutLoud_Mainline.toc"}
SAVED_VARIABLES = {"Forever": "OutLoudDB", "Retail": "OutLoudRetailDB"}
# Display classifications verified on CurseForge, not guessed API flavor IDs.
CLASSIFICATION = {
    "Forever": {
        "flavor": "Forever", "gameVersion": "1.60.1",
        "source": "https://www.curseforge.com/wow/addons/foreverforge",
    },
    "Retail": {
        "flavor": "Retail", "gameVersion": "12.1.5",
        "source": "https://www.curseforge.com/wow/addons/deadly-boss-mods",
    },
}


def read_source(root, path):
    """Normalize text line endings so Windows and Unix checkouts package alike."""
    source = (root / path).resolve()
    source.relative_to(root.resolve())  # Reject source symlinks outside the repository.
    return source.read_text(encoding="utf-8-sig").replace("\r\n", "\n").encode("utf-8")


def safe_path(value):
    path = PurePosixPath(value.replace("\\", "/"))
    if path.is_absolute() or ".." in path.parts or ":" in str(path) or not path.parts:
        raise ValueError(f"Unsafe package path: {value}")
    return str(path)


def parse_toc(text):
    metadata, files = {}, []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("##"):
            key, value = line[2:].split(":", 1)
            if key.strip() in metadata:
                raise ValueError(f"Duplicate TOC metadata: {key}")
            metadata[key.strip()] = value.strip()
        elif line and not line.startswith("#"):
            files.append(safe_path(line))
    if len(files) != len(set(files)):
        raise ValueError("Duplicate TOC load entries")
    return metadata, files


def validate_toc(client, metadata, files):
    if not re.fullmatch(r"\d+\.\d+\.\d+", metadata.get("Version", "")):
        raise ValueError("Version must be a public major.minor.patch number")
    if metadata.get("SavedVariables") != SAVED_VARIABLES[client]:
        raise ValueError(f"Incorrect {client} SavedVariables")
    version = CLASSIFICATION[client]["gameVersion"].split(".")
    interface = str(int(version[0]) * 10000 + int(version[1]) * 100 + int(version[2]))
    if metadata.get("Interface") != interface:
        raise ValueError(f"TOC Interface must match the documented {client} game version")
    if metadata.get("Title") != "Out Loud":
        raise ValueError("Addon identity must remain Out Loud")
    required = [
        "Core/Namespace.lua", f"Clients/{client}/Config.lua", "Core/Client.lua",
        f"Clients/{client}/VoiceMappings.lua", "Core/NPCInspection.lua",
        "Core/VoiceSelection.lua", "Core/Database.lua", "Core/TTSDiagnostics.lua",
        "Core/TTS.lua", "Core/Narration.lua", "UI/Controls/ComboBox.lua",
        "UI/Controls/VoiceRow.lua", "UI/SettingsPage.lua", "UI/TalkingHead.xml",
        "UI/TalkingHead.lua", "UI/QuestIntegration.lua", "UI/QuestLogIntegration.lua",
        "UI/GossipIntegration.lua", "UI/ItemTextIntegration.lua", "Core/Init.lua",
    ]
    if files != required:
        raise ValueError(f"Unexpected {client} load configuration/order")


def package_files(client, root=ROOT):
    toc = TOCS[client]
    toc_bytes = read_source(root, toc)
    metadata, files = parse_toc(toc_bytes.decode("utf-8"))
    validate_toc(client, metadata, files)
    entries = {PurePosixPath(toc).name: toc_bytes, "README.md": read_source(root, "README.md")}

    def include(path):
        if path in entries:
            return
        entries[path] = read_source(root, path)
        if path.endswith(".xml"):
            tree = ET.fromstring(entries[path])
            for element in tree.iter():
                if element.tag.rsplit("}", 1)[-1] in ("Script", "Include") and "file" in element.attrib:
                    include(safe_path(str(PurePosixPath(path).parent / element.attrib["file"].replace("\\", "/"))))

    for path in files:
        include(path)
    config = entries[f"Clients/{client}/Config.lua"].decode("utf-8")
    if f'SavedVariables = "{metadata["SavedVariables"]}"' not in config:
        raise ValueError("TOC/config SavedVariables disagreement")
    if f'ID = "{client}"' not in config:
        raise ValueError("TOC/config client disagreement")
    for path in entries:
        if path.startswith("Clients/") and not path.startswith(f"Clients/{client}/"):
            raise ValueError("Other client's implementation would enter package")
    return metadata, {"OutLoud/" + path: data for path, data in entries.items()}


def make_zip(entries):
    output = io.BytesIO()
    # Stored entries avoid dependence on the installed zlib version. Both small
    # packages have fixed timestamps, permissions, ordering, and no host paths.
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as archive:
        for path, data in sorted(entries.items()):
            info = zipfile.ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data)
    result = output.getvalue()
    validate_zip(result, entries)
    return result


def validate_zip(data, expected):
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        if archive.testzip() is not None or archive.namelist() != sorted(expected):
            raise ValueError("ZIP integrity/content validation failed")
        for name in archive.namelist():
            if safe_path(name) != name or not name.startswith("OutLoud/"):
                raise ValueError("ZIP must contain only the OutLoud directory")
            if archive.read(name) != expected[name]:
                raise ValueError(f"Packaged bytes differ: {name}")


def build(client, output, root=ROOT):
    metadata, entries = package_files(client, root)
    data = make_zip(entries)
    # A second independent serialization catches accidental build nondeterminism.
    if data != make_zip(entries):
        raise ValueError("Release build is not reproducible")
    name = f"OutLoud-{client}-{metadata['Version']}"
    output.mkdir(parents=True, exist_ok=True)
    (output / (name + ".zip")).write_bytes(data)
    manifest = {
        "addon": "OutLoud", "client": client, "version": metadata["Version"],
        "tag": f"{client.lower()}/v{metadata['Version']}",
        "toc": PurePosixPath(TOCS[client]).name, "interface": metadata["Interface"],
        "savedVariables": metadata["SavedVariables"],
        "curseForge": {**CLASSIFICATION[client], "verifiedOn": "2026-10-17",
                      "upload": "manual; select the matching flavor and game version on one project"},
        "sha256": hashlib.sha256(data).hexdigest(),
        "files": {path: hashlib.sha256(content).hexdigest() for path, content in sorted(entries.items())},
    }
    (output / (name + ".manifest.json")).write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")
    return output / (name + ".zip")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client", choices=["all", *TOCS], default="all")
    args = parser.parse_args()
    for client in TOCS if args.client == "all" else [args.client]:
        print(build(client, ROOT / "dist"))


if __name__ == "__main__":
    main()
