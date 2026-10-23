"""Targeted static release checks; no WoW runtime emulation."""

import importlib.util
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("outloud_package", ROOT / "tools/package.py")
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)

# Independent fixture of the verified exports in the implementation request.
EXPORTS = {
    "Forever": """
BLOOD_ELF: 1100087 1100258
DWARF: 878772 950080
GNOME: 900914 940356
GOBLIN: 119369 119376
HUMAN: 1000764 1011653
NAGA: 120263 120294
NIGHT_ELF: 921844 974343
ORC: 917116 949470
SKYBORNE: 7478487 7478494
TAUREN: 968705 986648
TROLL: 118798 232863 1018060 1022938
UNDEAD: 959310 997378
""",
    "Retail": """
BLOOD_ELF: 1100087 1100258
BROKEN: 117400 117412
DRAENEI: 1005887 1022598 1593999 1620605
DWARF: 878772 950080 1890763 1890765
EARTHEN: 5548259 5548261
FEL_ORC: 118652 118653
GILNEAN:
GNOME: 900914 940356 2564806 2622502
GOBLIN: 119369 119376
HARANIR: 5422147 5422149
HUMAN:
KUL_TIRAN: 1721003 1793470 1886724
NAGA: 120263 120294
NIGHTBORNE: 1810676 1814471
NIGHT_ELF: 921844 974343
ORC: 917116 949470
PANDAREN: 535052 589715
TAUREN: 233878 968705 986648 1630218 1630402
TROLL: 118798 232863 1018060 1022938
TUSKARR: 122738
UNDEAD: 959310 997378
VISAGE: 4220448 4395382
VOID_ELF: 1733758 1734034
VRYKUL: 122815
VULPERA: 1890759 1890761
WORGEN: 307453 307454
ZANDALARI_TROLL: 1630447 1662187
""",
}


class ReleaseChecks(unittest.TestCase):
    def test_direct_development_tocs(self):
        # Each client has an explicit root TOC. Reject the old fallback and
        # Standard TOCs so incorrect selection cannot be hidden by a fallback.
        self.assertEqual(package.TOCS, {
            "Forever": "OutLoud_Forever.toc", "Retail": "OutLoud_Mainline.toc",
        })
        self.assertEqual({path.name for path in ROOT.glob("*.toc")},
                         {"OutLoud_Forever.toc", "OutLoud_Mainline.toc"})
        self.assertEqual(list((ROOT / "Clients").rglob("*.toc")), [],
                         "Client TOCs must have a single authoritative root source")
        for client, toc in package.TOCS.items():
            metadata, files = package.parse_toc((ROOT / toc).read_text())
            package.validate_toc(client, metadata, files)
            expected_interface, expected_saved = {
                "Forever": ("16001", "OutLoudDB"),
                "Retail": ("120105", "OutLoudRetailDB"),
            }[client]
            self.assertEqual(metadata["Interface"], expected_interface)
            self.assertEqual(metadata["SavedVariables"], expected_saved)
            expected_character_saved = {
                "Forever": "OutLoudCharacterDB", "Retail": "OutLoudRetailCharacterDB",
            }[client]
            self.assertEqual(metadata["SavedVariablesPerCharacter"], expected_character_saved)
            config = (ROOT / f"Clients/{client}/Config.lua").read_text()
            self.assertIn(f'SavedVariablesPerCharacter = "{expected_character_saved}"', config)
            self.assertEqual(metadata["Notes"],
                             f"Text-to-speech addon for World of Warcraft: {client}")
            self.assertEqual(metadata["LoadSavedVariablesFirst"], "1")
            self.assertEqual(metadata["IconTexture"],
                             r"Interface\AddOns\OutLoud\assets\OutLoud-64.png")
            self.assertTrue(all((ROOT / path).is_file() for path in files))
            self.assertEqual([path for path in files if path.startswith("Clients/")],
                             [f"Clients/{client}/Config.lua", f"Clients/{client}/VoiceMappings.lua"])

    def test_exact_verified_exports(self):
        for client, export in EXPORTS.items():
            expected_families, expected_models = set(), {}
            for line in export.strip().splitlines():
                family, models = line.split(":")
                expected_families.add(family)
                for model in models.split():
                    expected_models[int(model)] = family
            source = (ROOT / f"Clients/{client}/VoiceMappings.lua").read_text()
            families = re.findall(r'^    ([A-Z_]+) = "([A-Z_]+)",$', source, re.M)
            self.assertTrue(all(key == value for key, value in families))
            self.assertEqual(len(families), len(expected_families), "No duplicate family keys")
            self.assertEqual({key for key, _ in families}, expected_families)
            models = re.findall(r"\[(\d+)\] = VoiceMappings\.Families\.([A-Z_]+),", source)
            self.assertEqual(len(models), len(expected_models), "No duplicate model keys")
            self.assertEqual({int(key): value for key, value in models}, expected_models)

    def test_client_load_order_contents_and_determinism(self):
        for client in package.TOCS:
            with self.subTest(client=client):
                metadata, entries = package.package_files(client)
                self.assertRegex(metadata["Version"], r"^\d+\.\d+\.\d+$")
                first = package.make_zip(entries)
                self.assertEqual(first, package.make_zip(dict(reversed(list(entries.items())))))
                self.assertEqual([p for p in entries if p.endswith(".toc")],
                                 ["OutLoud/" + Path(package.TOCS[client]).name])
                self.assertIn(f"OutLoud/Clients/{client}/Config.lua", entries)
                self.assertIn("OutLoud/Core/TTSDiagnostics.lua", entries)
                self.assertIn("OutLoud/UI/TalkingHead.xml", entries)
                icon_path = "OutLoud/assets/OutLoud-64.png"
                icon_bytes = (ROOT / "assets/OutLoud-64.png").read_bytes()
                self.assertEqual(entries[icon_path], icon_bytes)
                self.assertFalse(any("Tests/" in p or "DevResources/" in p or "tools/" in p for p in entries))
                other = "Retail" if client == "Forever" else "Forever"
                self.assertFalse(any(p.startswith(f"OutLoud/Clients/{other}/") for p in entries))
                with tempfile.TemporaryDirectory() as temporary:
                    archive = package.build(client, Path(temporary))
                    self.assertEqual(archive.name, f"OutLoud-{client}-{metadata['Version']}.zip")
                    self.assertEqual(archive.read_bytes(), first)
                    with zipfile.ZipFile(archive) as contents:
                        self.assertEqual(contents.read(icon_path), icon_bytes)
                    manifest = json.loads(archive.with_suffix(".manifest.json").read_text())
                    self.assertEqual(manifest["toc"], package.TOCS[client])
                    self.assertEqual(manifest["version"], metadata["Version"])
                    self.assertEqual(manifest["savedVariables"], metadata["SavedVariables"])
                    self.assertEqual(manifest["sha256"], hashlib.sha256(first).hexdigest())
                    self.assertEqual(manifest["files"], {
                        path: hashlib.sha256(data).hexdigest() for path, data in entries.items()
                    })

    def test_shared_runtime_is_identical(self):
        _, forever = package.package_files("Forever")
        _, retail = package.package_files("Retail")
        shared = set(forever) & set(retail)
        self.assertGreater(len(shared), 15)
        for path in shared:
            self.assertEqual(forever[path], retail[path], path)

    def test_versions_and_settings_are_independent(self):
        # A small source fixture stays under this repository and is automatically
        # removed. It changes TOC metadata only, never the working checkout.
        (ROOT / "dist").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / "dist") as temporary:
            fixture = Path(temporary)
            for client in package.TOCS:
                _, entries = package.package_files(client)
                for path, data in entries.items():
                    target = fixture / path.removeprefix("OutLoud/")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(data)
            _, retail_before = package.package_files("Retail", fixture)
            forever_version = package.package_files("Forever", fixture)[0]["Version"]
            retail_version = package.package_files("Retail", fixture)[0]["Version"]
            toc = fixture / package.TOCS["Forever"]
            toc.write_text(toc.read_text().replace("## Version: " + forever_version, "## Version: 9.8.7"))
            forever_metadata, _ = package.package_files("Forever", fixture)
            retail_metadata, retail_after = package.package_files("Retail", fixture)
            self.assertEqual(forever_metadata["Version"], "9.8.7")
            self.assertEqual(retail_metadata["Version"], retail_version)
            self.assertEqual(package.make_zip(retail_before), package.make_zip(retail_after))
            _, forever_before = package.package_files("Forever", fixture)
            retail_toc = fixture / package.TOCS["Retail"]
            retail_toc.write_text(retail_toc.read_text().replace("## Version: " + retail_version, "## Version: 9.8.6"))
            self.assertEqual(package.package_files("Forever", fixture)[0]["Version"], "9.8.7")
            self.assertEqual(package.package_files("Retail", fixture)[0]["Version"], "9.8.6")
            _, forever_after = package.package_files("Forever", fixture)
            self.assertEqual(package.make_zip(forever_before), package.make_zip(forever_after))
            retail_toc.write_text(retail_toc.read_text().replace("OutLoudRetailDB", "OutLoudDB"))
            with self.assertRaisesRegex(ValueError, "SavedVariables"):
                package.package_files("Retail", fixture)

    def test_invalid_load_configurations_are_rejected(self):
        for client in package.TOCS:
            metadata, files = package.parse_toc((ROOT / package.TOCS[client]).read_text())
            with self.assertRaises(ValueError):
                package.validate_toc(client, metadata, list(reversed(files)))
            with self.assertRaises(ValueError):
                package.validate_toc(client, metadata, files + ["Clients/Other/Config.lua"])
            with self.assertRaises(ValueError):
                package.validate_toc(client, metadata, [p for p in files if "TTSDiagnostics" not in p])
            with self.assertRaisesRegex(ValueError, "IconTexture"):
                package.validate_toc(client, {**metadata, "IconTexture": "missing.png"}, files)
        for path in ("../private", "C:/private", "/private"):
            with self.assertRaises(ValueError):
                package.safe_path(path)


if __name__ == "__main__":
    unittest.main(verbosity=2)
