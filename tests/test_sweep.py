"""Every setting, one at a time: write a non-default value into the ini (as MCM would), call the plugin's Apply,
let the script poll, and check that exactly this value changed inside the script and all others are defaults.
Runs with the real MCM plugin DLL of the mod folder loaded in this process. Usage: test_sweep.py
"""
import sys
from pathlib import Path

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "mcm"))
from spec import MOD, Item, Mod  # noqa: E402
from test_e2e import load_plugin, write_ini  # noqa: E402
import test_all as dn  # noqa: E402


def other_value(it: Item) -> tuple[str, object]:
    """A value different from the default, as MCM writes it, and what the script must end up with."""
    if it.kind == "bool":
        return ("0" if it.default else "1"), (not it.default)
    if it.kind == "int":
        v = int(it.hi) if it.default != it.hi else int(it.lo)
        return str(v), v
    if it.kind == "float":
        v = float(it.hi) if abs(it.default - it.hi) > 1e-6 else float(it.lo)
        return f"{v:.{it.decimals}f}", v
    if it.kind == "choice":
        v = next(x for x in it.values if x != it.default)
        return v, v
    if it.kind == "colour":
        return "#123456", (0x12 / 255, 0x34 / 255, 0x56 / 255)
    raise ValueError(it.kind)


def default_value(it: Item) -> object:
    if it.kind == "colour":
        h = it.default.lstrip("#")
        return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return it.default


def read(roots: dict, it: Item) -> object:
    t = roots[it.root]
    for k in it.path:
        t = t[k]
    if it.kind == "colour":
        return (t[1], t[2], t[3])
    return t


def same(a: object, b: object) -> bool:
    if isinstance(a, tuple):
        return all(abs(x - y) < 1e-3 for x, y in zip(a, b))
    if isinstance(a, float) or isinstance(b, float):
        return abs(float(a) - float(b)) < 1e-4
    return a == b


def sweep(mod: Mod, get_roots, run, d: Path, apply) -> int:
    items = [it for s in mod.sections for it in s.items]
    checked = 0
    for it in items:
        raw, want = other_value(it)
        write_ini(d, mod.ini, mod.mod_id, {it.key: raw})
        apply()
        run(0.7)
        roots = get_roots()
        got = read(roots, it)
        assert same(got, want), f"{mod.title}: {it.key}={raw} -> {got!r}, expected {want!r}"
        for other in items:
            if other is it:
                continue
            assert same(read(roots, other), default_value(other)), f"{mod.title}: after {it.key}, {other.key} is not default"
        checked += 1
    # the reset button writes every default
    write_ini(d, mod.ini, mod.mod_id, {it.key: (("1" if it.default else "0") if it.kind == "bool" else
                                                (f"{it.default:.{it.decimals}f}" if it.kind == "float" else str(it.default)))
                                       for it in items})
    apply()
    run(0.7)
    roots = get_roots()
    for it in items:
        assert same(read(roots, it), default_value(it)), f"{mod.title}: reset left {it.key} wrong"
    return checked


def main() -> None:
    # damage numbers
    d, lib2, keep2, _cb2 = load_plugin()
    L = dn.runtime("fallback")
    dn.frames(L, 0.5)

    def dn_roots():
        c, col = L.eval("DamageNumbers.settings()")
        return {"CONFIG": c, "COLOURS": col}

    n = sweep(MOD, dn_roots, lambda s: dn.frames(L, s), d, keep2["apply"])
    errors = [s for s in dn.log_of(L) if ("error" in s.lower() or "failed" in s.lower()) and "ffi setup failed" not in s]
    assert not errors, errors
    print(f"Posh Damage Numbers: {n} settings, each reaches the script and the rest stay default; reset works: ok")
    print("ALL PASSED")


if __name__ == "__main__":
    main()
