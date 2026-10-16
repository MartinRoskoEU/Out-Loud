local AddonName, OutLoud = ...

OutLoud.Client = {
    ID = "Retail",
    SavedVariables = "OutLoudRetailDB",
    -- Player narration uses UnitRace's token, independently of NPC model data.
    PlayerRaceFamilies = {
        Worgen = "WORGEN",
        Pandaren = "PANDAREN",
        Nightborne = "NIGHTBORNE",
        HighmountainTauren = "TAUREN",
        VoidElf = "VOID_ELF",
        LightforgedDraenei = "DRAENEI",
        ZandalariTroll = "ZANDALARI_TROLL",
        KulTiran = "KUL_TIRAN",
        DarkIronDwarf = "DWARF",
        Vulpera = "VULPERA",
        Mechagnome = "GNOME",
        EarthenDwarf = "EARTHEN",
        Haranir = "HARANIR",
    },
    -- Blizzard_FrameXML/TalkingHeadUI.xml, Retail 12.1.5.70391.
    -- The native visual atlases/child layout are shared with our independent
    -- template. Do not inherit its live frame, Edit Mode system, or event mixins.
    TalkingHead = {
        point = "TOP",
        offsetY = -60,
        scale = 1,
        strata = "HIGH",
    },
}
