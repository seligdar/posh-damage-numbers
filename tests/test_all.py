"""End-to-end checks of damage_numbers.lua in LuaJIT against a fake game that follows MyGUI's ImageBox rules.

Scenarios: fallback projection, exact Ogre projection (fake camera with the real vtable check),
exact projection with broken matrices, exact projection that disagrees with the game's visibility,
widget reuse with glyphs of different widths, words, unloaded characters, debug test number.
"""
import sys
from pathlib import Path

from lupa import luajit21 as lj

here = Path(__file__).parent
scripts = here.parent / "mod" / "DamageNumbers" / "scripts"
SRC = (scripts / "init" / "damage_numbers.lua").read_text(encoding="utf-8")
GLYPH_RECTS = set()
WORD_RECTS = set()           # KO / DEAD / LIMB pictures (both languages), the rest are digits and signs
for line in (scripts / "dn_glyphs.lua").read_text(encoding="utf-8").splitlines():
    if line.strip().startswith('["'):
        nums = dict(kv.split(" = ") for kv in line.split("{")[1].split("}")[0].strip().split(", "))
        rect = (int(nums["x"]), int(nums["y"]), int(nums["w"]), int(nums["h"]))
        GLYPH_RECTS.add(rect)
        if len(line.split('"')[1]) > 1:
            WORD_RECTS.add(rect)

FAKE_OGRE = r'''
local ffi = require("ffi")
pcall(ffi.cdef, "typedef struct { float m[16]; } DN_Matrix4;")
pcall(ffi.cdef, "typedef struct { float x, y, z; } DN_Vector3;")
local function norm(x, y, z) local l = math.sqrt(x*x + y*y + z*z) return x/l, y/l, z/l end
local cx, cy, cz = 0, 60, 120
local fx, fy, fz = norm(0, -0.45, -1)
local rx, ry, rz = norm(-fz, 0, fx)
local ux, uy, uz = ry*fz - rz*fy, rz*fx - rx*fz, rx*fy - ry*fx
VIEW = ffi.new("DN_Matrix4")
local v = { rx, ry, rz, -(rx*cx + ry*cy + rz*cz),  ux, uy, uz, -(ux*cx + uy*cy + uz*cz),
            -fx, -fy, -fz, (fx*cx + fy*cy + fz*cz),  0, 0, 0, 1 }
for i = 1, 16 do VIEW.m[i-1] = v[i] end
PROJ = ffi.new("DN_Matrix4")
local t, a, n, f = math.tan(math.rad(45) / 2), 1920 / 1200, 1, 10000
local p = { 1/(a*t), 0, 0, 0,  0, 1/t, 0, 0,  0, 0, (f+n)/(n-f), 2*f*n/(n-f),  0, 0, -1, 0 }
for i = 1, 16 do PROJ.m[i-1] = p[i] end
FAKE_VTBL = ffi.new("uint8_t[64]")
FAKECAM = ffi.new("uintptr_t[2]")
FAKECAM[0] = ffi.cast("uintptr_t", FAKE_VTBL)
OGREPOS = ffi.new('DN_Vector3', {0, 0, 0})
DN_TEST_OGRE = { DN_getViewMatrix = function() return VIEW end, DN_getProjMatrix = function() return PROJ end, DN_getDerivedPosition = function() return OGREPOS end }
'''


def runtime(mode: str, debug: bool = False):
    L = lj.LuaRuntime(unpack_returned_tuples=True)
    L.execute(f"package.path = [[{scripts.as_posix()}/?.lua;]] .. package.path")
    L.execute((here / "mock_env.lua").read_text(encoding="utf-8"))
    code = SRC.replace("debug = false,", f"debug = {'true' if debug else 'false'},").replace("showTestNumber = false,", f"showTestNumber = {'true' if debug else 'false'},")
    if mode != "fallback":
        L.execute(FAKE_OGRE)
        L.execute("getPlayerInterface().camera.camera = FAKECAM")
        code = code.replace('pcall(ffi.load, "OgreMain_x64")', "pcall(function() return DN_TEST_OGRE end)")
        code = code.replace('ffi.C.GetModuleHandleA("OgreMain_x64.dll")', "ffi.C.GetModuleHandleA(nil)")
        code = code.replace('ffi.C.GetProcAddress(mod, "??_7Camera@Ogre@@6BMovableObject@1@@")', "ffi.cast('void*', FAKE_VTBL)")
        if mode == "broken":
            L.execute("PROJ.m[14] = 0.5")                        # not a perspective matrix
        if mode == "relative":
            L.execute("VIEW.m[3] = 0 VIEW.m[7] = 0 VIEW.m[11] = 0")   # camera-relative view, as in the game log
        if mode == "disagree":
            # rotate the view 180 degrees around the vertical axis: still a valid matrix, but wrong
            L.execute("for i = 0, 3 do VIEW.m[i] = -VIEW.m[i]; VIEW.m[8 + i] = -VIEW.m[8 + i] end")
    L.execute('A = newChar("a", 0, 0, false)\nB = newChar("b", 9, -6, true)\nR = newChar("r", -10, 10, false, true)')
    # settings come from the mod's ini (written by MCM in the game); a debug run gets Debug=1 there
    import os, tempfile
    work = Path(tempfile.mkdtemp())
    (work / "mods" / "DamageNumbers").mkdir(parents=True)
    if debug:
        (work / "mods" / "DamageNumbers" / "DamageNumbers.ini").write_text("[PoshDamageNumbers]" + chr(10) + "Debug=1" + chr(10), encoding="utf-8")
    old_cwd = os.getcwd()
    os.chdir(work)
    try:
        L.execute(code)
    finally:
        os.chdir(old_cwd)
    return L


def frames(L, seconds: float) -> None:
    frame = L.eval("HANDLERS['MyGUI::Gui::eventFrameStart']")
    for _ in range(int(seconds * 60)):
        L.execute("SIM_TIME = SIM_TIME + 1/60")
        frame(999)          # a wrong event argument must not matter: the script measures time itself


def drawn(L) -> list:
    out = []
    for w in L.eval("WIDGETS").values():
        uv = w.drawn(w)
        if uv is not None:
            out.append((tuple(uv.values()), tuple(w.coord.values())))
    return out


def check_drawn_exact(L, expected_count: int, label: str) -> None:
    d = drawn(L)
    bad = [uv for uv, _ in d if uv not in GLYPH_RECTS]
    assert not bad, f"{label}: widgets draw wrong parts of the atlas: {bad}"
    assert len(d) == expected_count, f"{label}: expected {expected_count} drawn glyphs, got {len(d)}"
    for uv, (x, y, w, h) in d:
        assert -60 < x < 1980 and -60 < y < 1260, f"{label}: glyph off screen at {x},{y}"


def log_of(L) -> list:
    return list(L.eval("LOG").values())


failures = 0
def scenario(name, fn):
    global failures
    try:
        fn()
        print(f"PASS  {name}")
    except AssertionError as e:
        failures += 1
        print(f"FAIL  {name}: {e}")


def basic(mode):
    def run():
        L = runtime(mode)
        frames(L, 0.6)
        L.execute("A.medical.anatomy[2].flesh = 88")          # -12
        frames(L, 0.3)
        check_drawn_exact(L, 3, "first hit")
        frames(L, 1.5)                                         # fades out, widgets go back to the pool
        assert not drawn(L), "everything faded"
        L.execute("A.medical.anatomy[3].flesh = 93")          # -7 reuses pooled widgets of other widths
        frames(L, 0.3)
        check_drawn_exact(L, 2, "reused widgets, narrower glyph")
        frames(L, 1.5)
        L.execute("A.medical.anatomy[4].flesh = 12")          # -88: wide glyphs into the same widgets
        frames(L, 0.3)
        check_drawn_exact(L, 3, "reused widgets, wider glyphs")
        L.execute("A.medical.unconcious = true")            # knocked out: seen in the frame loop
        frames(L, 0.3)
        check_drawn_exact(L, 4, "number plus KO word")
        L.execute("A.alive = false")
        frames(L, 3)
        assert not drawn(L), "all gone after the character was unloaded"
        errors = [l for l in log_of(L) if "error" in l.lower() or "switched off" in l]
        assert not errors, f"log errors: {errors}"
        mode_used = L.eval("DamageNumbers.status()")
        want = "projection=fb" if mode == "fallback" else "projection=rp"
        assert want in mode_used, f"{want} expected, status: {mode_used}"
    return run


def broken_matrices():
    L = runtime("broken")
    frames(L, 0.6)
    L.execute("A.medical.anatomy[2].flesh = 70")
    frames(L, 0.3)
    check_drawn_exact(L, 3, "numbers still shown through the fallback")
    assert any("unexpected shape" in l for l in log_of(L)), log_of(L)


def disagreeing_exact():
    L = runtime("disagree")
    frames(L, 8)                                               # several cross-checks every 2 s
    assert any("projection switched from rp to fb" in l for l in log_of(L)), log_of(L)
    L.execute("A.medical.anatomy[2].flesh = 70")
    frames(L, 0.3)
    check_drawn_exact(L, 3, "numbers visible after switching to the fallback")


def debug_test_number():
    L = runtime("ogre", debug=True)
    frames(L, 1.0)
    d = drawn(L)
    assert len(d) == 4, f"test number -123 should be drawn, got {len(d)}"
    xs = [c[0] for _, c in d]
    assert 800 < min(xs) < 960 < max(xs) < 1100, f"test number centred, x={xs}"
    assert any("camera: view=" in l for l in log_of(L)), "camera dump in debug log"


def words_from_frame_loop():
    """KO, SEVERED and KILLED come from the state read in the frame loop. KenshiLua runs event handlers on the
    thread that fires them and the game fires knockouts, amputations, deaths and hits on its worker threads, so
    the only handler may be the frame one (two threads in Lua crash lua51.dll)."""
    L = runtime("fallback")
    events = sorted(L.eval("(function() local t = {} for k in pairs(HANDLERS) do t[#t + 1] = k end return t end)()").values())
    assert events == ["MyGUI::Gui::eventFrameStart"], events
    words = lambda: sum(1 for uv, _ in drawn(L) if uv in WORD_RECTS)
    L.execute("C = newChar('c', -6, 0, false); C.medical.unconcious = true")   # already down when first seen
    frames(L, 1.0)
    assert words() == 0, "a character already knocked out when first watched gets no word"
    L.execute("A.medical.unconcious = true")
    frames(L, 0.3)
    assert words() == 1, f"KO word expected, {words()} drawn"
    frames(L, 2.5)
    assert words() == 0, "the word fades"
    L.execute("A.medical.unconcious = false")
    frames(L, 0.5)
    L.execute("A.medical.unconcious = true")
    frames(L, 0.3)
    assert words() == 1, "knocked out again: the word again"
    frames(L, 2.5)
    L.execute("A.medical.anatomy[5].flesh = -60")             # not cut yet: -60 > -(100 - 0)
    frames(L, 0.3)
    assert words() == 0, "a badly hurt arm is not a severed one"
    frames(L, 2.5)
    L.execute("A.medical.anatomy[5].flesh = -150")            # -150 <= -100: the game cuts it off
    frames(L, 0.3)
    assert words() == 1, "SEVERED word expected"
    frames(L, 2.5)
    L.execute("A.medical.anatomy[6].fleshStun = 30; A.medical.anatomy[6].wearDamage = 20; A.medical.anatomy[6].flesh = -50")
    frames(L, 0.3)                                            # -50 - 30 + 0 = -80 <= -(100 - 20)
    assert words() == 1, "stun and wear count like the game's own check"
    frames(L, 2.5)
    L.execute("A.medical.anatomy[1].flesh = -300")            # the head is fatal, never 'severed'
    frames(L, 0.3)
    assert words() == 0, "no SEVERED word for the head"
    L.execute("A.dead = true")
    frames(L, 0.3)
    assert words() == 1, "KILLED word expected"
    frames(L, 3)
    errors = [l for l in log_of(L) if "error" in l.lower()]
    assert not errors, errors


if __name__ == "__main__":
    scenario("fallback projection", basic("fallback"))
    scenario("exact Ogre projection", basic("ogre"))
    scenario("camera-relative Ogre view (as in the game)", basic("relative"))
    scenario("broken matrices fall back", broken_matrices)
    scenario("exact path disagreeing with the game falls back", disagreeing_exact)
    scenario("debug test number", debug_test_number)
    scenario("words from the frame loop, no game event handlers", words_from_frame_loop)
    print("FAILURES:", failures)
    sys.exit(1 if failures else 0)
