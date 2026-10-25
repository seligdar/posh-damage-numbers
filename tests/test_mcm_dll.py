"""Load the mod's MCM plugin DLL (mod/<folder>/<dll>) in a fake MCM (ctypes), record what MCM_Describe builds, and
check it against mcm/spec.py and lang/*.txt.

Checks: every row arrives with the right ini key, default and limits; labels, tooltips, choice buttons, section
titles and the info line come from the lang file of the game language (settings.cfg in the working directory),
a language without a lang file gets English; Apply bumps Posh_SettingsVersion; Posh_IniPath points next to the DLL.
"""
import ctypes as C
import os
import shutil
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE.parent / "mcm"))
from gen_mcm import load_langs  # noqa: E402
from spec import MOD  # noqa: E402

CS = C.c_char_p
VP = C.c_void_p
APPLY = C.CFUNCTYPE(None)


class Api(C.Structure):
    pass


P = C.POINTER(Api)
F_BEGIN = C.CFUNCTYPE(None, P, CS, CS, CS, VP)
F_SECTION = C.CFUNCTYPE(None, P, CS)
F_TOGGLE = C.CFUNCTYPE(None, P, CS, CS, CS, CS, C.c_int, C.c_uint)
F_INT = C.CFUNCTYPE(None, P, CS, CS, CS, CS, C.c_int, C.c_int, C.c_int, C.c_uint)
F_NUM = C.CFUNCTYPE(None, P, CS, CS, CS, CS, C.c_float, C.c_float, C.c_float, C.c_int, C.c_uint)
F_CHOICE = C.CFUNCTYPE(None, P, CS, CS, CS, CS, CS, C.POINTER(CS), C.POINTER(CS), C.c_int, C.c_uint)
F_TEXT = C.CFUNCTYPE(None, P, CS, CS, CS, CS, CS, C.c_uint)
F_INFO = C.CFUNCTYPE(None, P, CS)
F_ANY = VP
Api._fields_ = [("version", C.c_int), ("impl", VP), ("beginMod", F_BEGIN), ("section", F_SECTION),
                ("toggle", F_TOGGLE), ("integer", F_INT), ("number", F_NUM), ("choice", F_CHOICE),
                ("text", F_TEXT), ("hotkey", F_TEXT), ("colour", F_TEXT), ("info", F_INFO)] + \
               [(n, F_ANY) for n in ("toggleFn", "integerFn", "numberFn", "choiceFn", "textFn", "colourFn",
                                     "hotkeyFn", "action", "customArea", "defaultValue", "rows")]

DLL = HERE.parent / "mod" / MOD.folder / MOD.dll


def describe(dll_path: Path, language: str) -> tuple[list, object]:
    """Rows: (kind, section, key, label, tip, ...values) for settings, ("section", title), ("info", text)."""
    rows: list = []
    keep: dict = {}
    d = lambda b: b.decode("utf-8") if b is not None else None

    def begin(api, mid, title, ini, apply):
        keep["apply"] = C.cast(apply, APPLY)
        rows.append(("begin", d(mid), d(title), d(ini)))

    def choice(api, sec, key, label, tip, default, values, labels, n, flags):
        rows.append(("choice", d(sec), d(key), d(label), d(tip), d(default),
                     tuple(d(values[i]) for i in range(n)), tuple(d(labels[i]) for i in range(n)), flags))

    cb = dict(
        beginMod=F_BEGIN(begin),
        section=F_SECTION(lambda api, t: rows.append(("section", d(t)))),
        toggle=F_TOGGLE(lambda api, s, k, l, t, df, f: rows.append(("bool", d(s), d(k), d(l), d(t), df, f))),
        integer=F_INT(lambda api, s, k, l, t, df, lo, hi, f: rows.append(("int", d(s), d(k), d(l), d(t), df, lo, hi, f))),
        number=F_NUM(lambda api, s, k, l, t, df, lo, hi, dec, f: rows.append(
            ("float", d(s), d(k), d(l), d(t), round(df, 4), round(lo, 4), round(hi, 4), f))),
        choice=F_CHOICE(choice),
        text=F_TEXT(lambda *a: rows.append(("text",))),
        hotkey=F_TEXT(lambda *a: rows.append(("hotkey",))),
        colour=F_TEXT(lambda api, s, k, l, t, df, f: rows.append(("colour", d(s), d(k), d(l), d(t), d(df), f))),
        info=F_INFO(lambda api, t: rows.append(("info", d(t)))),
    )
    api = Api(version=6, impl=None, **cb)
    work = Path(tempfile.mkdtemp())
    (work / "settings.cfg").write_text(f"Blood=1\nlanguage={language}\nmusic=1\n", encoding="ascii")
    old = os.getcwd()
    os.chdir(work)
    try:
        lib = C.CDLL(str(dll_path))
        lib.MCM_Describe(C.byref(api))
    finally:
        os.chdir(old)
        shutil.rmtree(work)
    return rows, (lib, keep, cb)


def main() -> None:
    _keys, langs = load_langs(MOD)
    by_code = {l.code: l.texts for l in langs}
    # each language in a fresh copy: the DLL decides the language once per process
    cases = [("en_GB", "en"), ("ru_RU", "ru"), ("de_DE", "en")]
    cases += [(f"{code}_XX", code) for code in by_code if code not in ("en", "ru")]
    if "zh" not in by_code:
        cases.append(("zh_CN", "en"))
    for language, code in cases:
        texts = by_code[code]
        copy_dir = Path(tempfile.mkdtemp()) / "mod"
        copy_dir.mkdir()
        dll = copy_dir / MOD.dll
        shutil.copy(DLL, dll)
        rows, (lib, keep, cb) = describe(dll, language)
        begin = rows[0]
        assert begin[:3] == ("begin", MOD.mod_id, MOD.title), begin
        assert Path(begin[3]) == copy_dir / MOD.ini, (begin[3], copy_dir / MOD.ini)
        lib.Posh_IniPath.restype = C.c_char_p
        assert Path(lib.Posh_IniPath().decode()) == copy_dir / MOD.ini
        assert ("info", texts["info"]) in rows, "info line"
        expected = [it for s in MOD.sections for it in s.items]
        got = [r for r in rows if r[0] in ("bool", "int", "float", "choice", "colour")]
        assert len(got) == len(expected), (len(got), len(expected))
        for it, r in zip(expected, got):
            assert r[0] == it.kind and r[1] == MOD.mod_id and r[2] == it.key, (it.key, r)
            assert r[3] == texts[it.key], (language, it.key, r[3])
            assert r[4] == texts.get(f"{it.key}.tip"), (language, it.key, r[4])
            if it.kind == "bool":
                assert r[5] == (1 if it.default else 0)
            elif it.kind == "int":
                assert r[5:8] == (it.default, it.lo, it.hi), (it.key, r)
            elif it.kind == "float":
                assert abs(r[5] - it.default) < 1e-4 and abs(r[6] - it.lo) < 1e-4 and abs(r[7] - it.hi) < 1e-4, (it.key, r)
            elif it.kind == "choice":
                assert r[5] == it.default and r[6] == it.values, (it.key, r)
                assert r[7] == tuple(texts[f"{it.key}.{v}"] for v in it.values), (language, it.key, r[7])
            elif it.kind == "colour":
                assert r[5] == it.default, (it.key, r)
        sections = [r[1] for r in rows if r[0] == "section"]
        assert sections == [texts[f"section.{s.id}"] for s in MOD.sections], sections
        lib.Posh_SettingsVersion.restype = C.c_int
        v0 = lib.Posh_SettingsVersion()
        keep["apply"]()
        keep["apply"]()
        assert lib.Posh_SettingsVersion() == v0 + 2, "Apply must bump the counter"
        print(f"{MOD.title} [{language} -> {code}.txt]: {len(got)} rows with labels and tips, {len(sections)} sections, "
              f"ini {Path(begin[3]).name}, counter {v0} -> {v0 + 2}: ok")
    print("ALL PASSED")


if __name__ == "__main__":
    main()
