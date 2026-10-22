"""Targeted static native TTS control checks; no addon or WoW API execution."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
PAGE = (ROOT / "UI/SettingsPage.lua").read_text(encoding="utf-8")
CONTROL = PAGE.split("function SettingsPage:CreateTTSSeparatorSoundControl(anchor)", 1)[1].split(
    "function SettingsPage:RefreshTTSVolume()", 1
)[0]
CHECKBOX = PAGE.split("function SettingsPage:CreateCheckbox(", 1)[1].split(
    "function SettingsPage:CreateSourceCheckboxes", 1
)[0]


class SeparatorSettingChecks(unittest.TestCase):
    def test_shared_control_loaded_by_both_clients(self):
        for toc in ("OutLoud_Forever.toc", "OutLoud_Mainline.toc"):
            with self.subTest(toc=toc):
                lines = (ROOT / toc).read_text(encoding="utf-8").splitlines()
                self.assertEqual(lines.count(r"UI\SettingsPage.lua"), 1)
        self.assertIn("self:CreateTTSSeparatorSoundControl(self.SpeechRateDescription)", PAGE)

    def test_current_native_value_on_creation_and_display(self):
        self.assertIn("local setting = Enum.TtsBoolSetting.PlaySoundSeparatingChatLineBreaks", CONTROL)
        self.assertIn("function() return C_TTSSettings.GetSetting(setting) end", CONTROL)
        self.assertIn("button:Init(getValue(), nil)", CHECKBOX)
        self.assertRegex(CHECKBOX, re.compile(
            r'button:SetScript\("OnShow", function\(\)\s*'
            r'button:SetValue\(getValue\(\)\)\s*end\)'
        ))

    def test_only_user_toggle_writes_native_boolean_without_inversion(self):
        self.assertIn("function(value) C_TTSSettings.SetSetting(setting, value) end", CONTROL)
        self.assertRegex(CHECKBOX, re.compile(
            r'button:RegisterCallback\(SettingsCheckboxMixin.Event.OnValueChanged, '
            r'function\(_, value\)\s*setValue\(value\)\s*end, self\)'
        ))
        writers = []
        for folder in ("Core", "UI", "Clients"):
            for path in (ROOT / folder).rglob("*.lua"):
                if re.search(r"C_TTSSettings\s*\.\s*SetSetting\s*\(", path.read_text(encoding="utf-8")):
                    writers.append(path.relative_to(ROOT).as_posix())
        self.assertEqual(writers, ["UI/SettingsPage.lua"])
        self.assertEqual(PAGE.count("C_TTSSettings.SetSetting("), 1)
        self.assertNotIn("OutLoud.Database", CONTROL)
        self.assertNotIn("PlaySoundSeparatingChatLineBreaks", (ROOT / "Core/Database.lua").read_text())
        self.assertNotIn("TTSSeparatorSound", (ROOT / "Core/Database.lua").read_text())

    def test_label_description_and_native_style(self):
        self.assertIn('"SettingsCheckboxTemplate"', CHECKBOX)
        self.assertIn('self:CreateCheckbox(anchor, "TTS Separator Sound"', CONTROL)
        self.assertIn("If you hear a short notification sound after each spoken line, "
                      "disable this option to turn it off.", CONTROL)
        self.assertIn("This affects WoW's global TTS behavior.", CONTROL)
        self.assertIn('"GameFontNormal"', CHECKBOX)
        self.assertIn('"GameFontHighlightSmall"', CONTROL)
        self.assertIn("button:SetHitRectInsets(0, -(5 + label:GetStringWidth()), 0, 0)", CHECKBOX)

    def test_description_wraps_and_extends_scroll_content(self):
        layout = PAGE.split("function SettingsPage:UpdateScrollLayout()", 1)[1].split(
            "function SettingsPage:UpdateVoiceWidths", 1
        )[0]
        self.assertIn("self.TTSSeparatorSoundDescription:SetWidth(descriptionWidth)", layout)
        self.assertIn("local lastDescription = self.TTSVolumeDescription or self.TTSSeparatorSoundDescription", layout)
        self.assertIn('description:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 21, -5)', CONTROL)
        self.assertIn("description:SetWordWrap(true)", CONTROL)

    def test_retail_compatibility_requires_both_native_accessors(self):
        client = (ROOT / "Core/Client.lua").read_text(encoding="utf-8")
        for accessor in ("GetSetting", "SetSetting"):
            self.assertIn(f'{{ "C_TTSSettings.{accessor}", C_TTSSettings and C_TTSSettings.{accessor} }}', client)


class VolumeSettingChecks(unittest.TestCase):
    def test_shared_native_slider_and_display_refresh(self):
        control = PAGE.split("function SettingsPage:CreateTTSVolumeControl(anchor)", 1)[1].split(
            "function SettingsPage:CreateReadingSection(anchor)", 1
        )[0]
        for toc in ("OutLoud_Forever.toc", "OutLoud_Mainline.toc"):
            lines = (ROOT / toc).read_text(encoding="utf-8").splitlines()
            self.assertEqual(lines.count(r"UI\SettingsPage.lua"), 1)
            self.assertEqual(lines.count(r"Core\TTS.lua"), 1)
        self.assertIn('"MinimalSliderWithSteppersTemplate"', control)
        self.assertIn('label:SetText("TTS Volume")', control)
        self.assertIn('control:Init(OutLoud.TTS:GetSpeechVolume() or 100, 0, 100, 100,', control)
        self.assertIn('string.format("%d%%", value)', control)
        self.assertIn('control:HookScript("OnShow", function() self:RefreshTTSVolume() end)', control)
        self.assertIn('self:OnTTSVolumeChanged(value)', control)
        self.assertIn("Adjusts narration volume. Also changes the World of Warcraft "
                      "Text-to-Speech volume setting.", control)

    def test_volume_description_wraps_and_extends_scroll_content(self):
        layout = PAGE.split("function SettingsPage:UpdateScrollLayout()", 1)[1].split(
            "function SettingsPage:UpdateVoiceWidths", 1
        )[0]
        self.assertIn("self:CreateTTSVolumeControl(self.TTSSeparatorSoundDescription)", PAGE)
        self.assertIn("self.TTSVolumeDescription:SetWidth(descriptionWidth)", layout)
        self.assertIn("local lastDescription = self.TTSVolumeDescription or", layout)

    def test_only_slider_handler_writes_native_volume(self):
        writers = []
        for folder in ("Core", "UI", "Clients"):
            for path in (ROOT / folder).rglob("*.lua"):
                if re.search(r"C_TTSSettings\s*\.\s*SetSpeechVolume\s*\(", path.read_text(encoding="utf-8")):
                    writers.append(path.relative_to(ROOT).as_posix())
        self.assertEqual(writers, ["UI/SettingsPage.lua"])
        self.assertEqual(PAGE.count("C_TTSSettings.SetSpeechVolume("), 1)
        handler = PAGE.split("function SettingsPage:OnTTSVolumeChanged(value)", 1)[1].split(
            "function SettingsPage:CreateTTSVolumeControl", 1
        )[0]
        self.assertIn("if self.SyncingTTSVolume then return end", handler)
        self.assertIn("C_TTSSettings.SetSpeechVolume(value)", handler)
        self.assertNotIn("volume", (ROOT / "Core/Database.lua").read_text().lower())


if __name__ == "__main__":
    unittest.main()
