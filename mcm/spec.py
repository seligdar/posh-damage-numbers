"""Settings of Posh Damage Numbers: structure, defaults and limits. Their texts are in lang/*.txt under the same keys
(label: <Key>, tooltip: <Key>.tip, choice button: <Key>.<value>, section title: section.<id>)."""
from dataclasses import dataclass, field


@dataclass
class Item:
    key: str                       # ini key and text key
    kind: str                      # bool, int, float, choice, colour
    root: str                      # Lua table the value goes to
    path: tuple[str, ...]          # keys inside that table
    default: object
    lo: float = 0
    hi: float = 0
    decimals: int = 2
    values: tuple[str, ...] = ()
    restart: bool = False


@dataclass
class Section:
    id: str
    items: list[Item] = field(default_factory=list)


@dataclass
class Mod:
    mod_id: str                    # MCM page id and ini section
    title: str                     # English mod name (MCM wants it untranslated)
    dll: str
    ini: str
    lua_module: str
    folder: str                    # mod folder, for reading the ini when the plugin is not loaded
    sections: list[Section]
    script_texts: tuple[str, ...]  # texts the script itself shows: lang key script.<name>


def hexcol(r: float, g: float, b: float) -> str:
    return "#%02X%02X%02X" % (round(r * 255), round(g * 255), round(b * 255))



MOD = Mod(
    mod_id='PoshDamageNumbers', title='Posh Damage Numbers', dll='PoshDamageNumbersMCM.dll',
    ini='DamageNumbers.ini', lua_module='dn_settings', folder='DamageNumbers',
    sections=[
        Section('general', [
            Item('Enabled', 'bool', 'CONFIG', ('enabled',), True),
            Item('ShowOwnSquadDamage', 'bool', 'CONFIG', ('showOwnSquadDamage',), True),
            Item('ShowWords', 'bool', 'CONFIG', ('showWords',), True),
            Item('WordsLanguage', 'choice', 'CONFIG', ('wordsLanguage',), 'auto', values=('auto', 'en', 'ru')),
            Item('ShowHealing', 'bool', 'CONFIG', ('showHealing',), False),
            Item('HealingThreshold', 'int', 'CONFIG', ('healingThreshold',), 5, lo=1, hi=50),
            Item('MinDamage', 'int', 'CONFIG', ('minDamage',), 1, lo=1, hi=50),
        ]),
        Section('look', [
            Item('NumberSize', 'float', 'CONFIG', ('numberSizeOfBody',), 0.3, lo=0.1, hi=0.6),
            Item('MinNumberPx', 'int', 'CONFIG', ('minNumberPx',), 22, lo=10, hi=80),
            Item('MaxNumberPx', 'int', 'CONFIG', ('maxNumberPx',), 50, lo=20, hi=140),
            Item('Duration', 'float', 'CONFIG', ('durationScale',), 1.0, lo=0.5, hi=2.5),
            Item('Rise', 'float', 'CONFIG', ('riseScale',), 1.0, lo=0.0, hi=2.5),
            Item('Flash', 'bool', 'CONFIG', ('flash',), True),
            Item('Shake', 'bool', 'CONFIG', ('bigHitShake',), True),
            Item('MergeWindow', 'float', 'CONFIG', ('mergeWindow',), 0.22, lo=0.0, hi=1.0),
        ]),
        Section('colours', [
            Item('ColourLight', 'colour', 'COLOURS', ('light',), '#FFF5DB'),
            Item('ColourMedium', 'colour', 'COLOURS', ('medium',), '#FFD140'),
            Item('ColourHeavy', 'colour', 'COLOURS', ('heavy',), '#FF7A1F'),
            Item('ColourSquad', 'colour', 'COLOURS', ('squad',), '#FF4040'),
            Item('ColourHeal', 'colour', 'COLOURS', ('heal',), '#6EE678'),
            Item('ColourKO', 'colour', 'COLOURS', ('KO',), '#96BFFF'),
            Item('ColourLimb', 'colour', 'COLOURS', ('LIMB',), '#FF593D'),
            Item('ColourDead', 'colour', 'COLOURS', ('DEAD',), '#D91A1A'),
        ]),
        Section('advanced', [
            Item('MaxActive', 'int', 'CONFIG', ('maxActive',), 60, lo=10, hi=150),
            Item('MaxWatched', 'int', 'CONFIG', ('maxWatched',), 40, lo=10, hi=100),
            Item('Layer', 'choice', 'CONFIG', ('layer',), 'Back', values=('Back', 'Popup')),
            Item('Debug', 'bool', 'CONFIG', ('debug',), False),
        ]),
    ],
    script_texts=(),
)
