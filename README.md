# Posh Damage Numbers

Animated floating damage numbers for Kenshi.

Steam Workshop: https://steamcommunity.com/sharedfiles/filedetails/?id=3821781631
Goes well with [Posh Nameplates](https://github.com/seligdar/posh-nameplates).

## Requirements

- [RE_Kenshi](https://www.nexusmods.com/kenshi/mods/847) 0.3.3 or newer
- [KenshiLua](https://www.nexusmods.com/kenshi/mods/2068), enabled in the launcher
- Optional: [Mod Config Menu](https://steamcommunity.com/sharedfiles/filedetails/?id=3813761584) for the settings in game

To install without the Workshop, copy `mod/DamageNumbers` into `Kenshi/mods`.

## Translating

The settings page in Mod Config Menu takes its texts from `lang/`. To add a language:

1. Copy `lang/en.txt` to `lang/<code>.txt`, where `<code>` is the first two letters of `language=` in Kenshi's
   `settings.cfg` (`zh_CN` gives `zh.txt`).
2. Translate the text after ` = ` on each line and keep the key before it. Lines you leave out stay English.
3. Open a pull request. The texts are compiled into the settings plugin, so we rebuild it and publish the update.

Mod Config Menu draws with the game's fonts, so the characters — – « » … № come out as boxes; the build rejects them.

The words KNOCKOUT, SEVERED and KILLED over characters are pictures in `gui/gfx/DamageNumbers_atlas.png`, drawn by
`tools/make_atlas.py` (English and Russian today). For another language, write the three words in the pull request
and we draw them into the atlas.

## Layout

- `mod/DamageNumbers` is the mod as it goes to the Workshop: `scripts/init/damage_numbers.lua` is the mod itself,
  `scripts/dn_glyphs.lua` and the atlas come from `tools/make_atlas.py`, `PoshDamageNumbersMCM.dll` and
  `scripts/dn_settings.lua` are generated.
- `mcm/spec.py` lists the settings (ini keys, defaults, limits); `mcm/gen_mcm.py` turns it and `lang/*.txt` into
  the Mod Config Menu plugin source and the Lua settings module.
- `tests/` runs the script in LuaJIT against a fake game and loads the real plugin DLL in a fake Mod Config Menu.
- `workshop/` holds the Workshop description and preview.

## Building and testing

Building the plugin needs Visual Studio 2022 and the `sdk` folder of Mod Config Menu (set `MCM_SDK` if it is not in
the default Steam Workshop folder):

    mcm\build.bat

The atlas: `python tools/make_atlas.py <Kenshi>/data/gui/fonts/Exo2-Bold.ttf <out_dir>`, then copy
`DamageNumbers_atlas.png` to `gui/gfx` and `dn_glyphs.lua` to `scripts`.

Tests need Python 3 with `lupa` and `Pillow`:

    cd tests
    python test_all.py
    python test_mcm_dll.py
    python test_e2e.py
    python test_sweep.py
