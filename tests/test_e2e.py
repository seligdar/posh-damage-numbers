"""End to end: the real MCM plugin DLL from the mod folder is loaded into this process (as RE_Kenshi would), the
script runs in LuaJIT against the fake game, the ini is rewritten as MCM would and Apply is called; the script must
follow. Usage: test_e2e.py
"""
import shutil
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))
from test_mcm_dll import DLL, describe  # noqa: E402
from spec import MOD  # noqa: E402
import test_all as dn  # noqa: E402

def load_plugin():
    d = Path(tempfile.mkdtemp()) / MOD.folder
    d.mkdir()
    shutil.copy(DLL, d / MOD.dll)
    _rows, (lib, keep, cb) = describe(d / MOD.dll, "en_GB")
    return d, lib, keep, cb


def write_ini(d: Path, ini: str, section: str, values: dict) -> None:
    text = f"[{section}]\n" + "".join(f"{k}={v}\n" for k, v in values.items())
    (d / ini).write_text(text, encoding="utf-8")


def damage_numbers() -> None:
    d, lib, keep, _cb = load_plugin()
    L = dn.runtime("fallback")
    logs = dn.log_of(L)
    assert any(str(d / "DamageNumbers.ini") in s for s in logs), logs
    dn.frames(L, 0.6)
    L.execute("A.medical.anatomy[2].flesh = 88")
    dn.frames(L, 0.3)
    assert len(dn.drawn(L)) == 3, dn.drawn(L)
    dn.frames(L, 2.0)
    assert not dn.drawn(L)
    print("damage numbers: plugin found, numbers with defaults: ok")

    write_ini(d, "DamageNumbers.ini", "PoshDamageNumbers", {"Enabled": 0})
    keep["apply"]()
    dn.frames(L, 1.0)
    L.execute("A.medical.anatomy[3].flesh = 80")
    dn.frames(L, 0.5)
    assert not dn.drawn(L), "no numbers while switched off"
    print("damage numbers: switched off from MCM: ok")

    write_ini(d, "DamageNumbers.ini", "PoshDamageNumbers", {"Enabled": 1, "Duration": "2.50"})
    keep["apply"]()
    dn.frames(L, 1.0)
    L.execute("A.medical.anatomy[4].flesh = 70")
    dn.frames(L, 2.0)
    assert dn.drawn(L), "a 2.5x longer number must still be on screen after 2 s"
    print("damage numbers: duration from MCM: ok")
    errors = [s for s in dn.log_of(L) if ("error" in s.lower() or "failed" in s.lower()) and "ffi setup failed" not in s]
    assert not errors, errors


if __name__ == "__main__":
    damage_numbers()
    print("ALL PASSED")
