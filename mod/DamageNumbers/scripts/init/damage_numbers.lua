-- Damage Numbers for Kenshi (KenshiLua script)
--
-- Shows animated damage numbers above characters. The number is the real health lost by the
-- body parts (after armour and blocks), measured from the parts' flesh plus the stun that blunt
-- damage adds (the game splits a heavy hit between the two), so it works for melee, crossbows,
-- turrets, animals and anything else that hurts.
--
-- How it works:
--   * every half second the nearest characters on screen are put on a watch list;
--   * many times a second their body-part health is compared with the previous reading;
--   * a drop spawns a number that pops in, flashes, floats up in an arc and fades out;
--   * hits on the same target within a short window are summed into one growing number;
--   * knockouts, severed limbs and deaths get their own word sprites.
-- Numbers are drawn with images from DamageNumbers_atlas.png so they scale smoothly.
--
-- Everything that touches the game is wrapped in pcall: a failure turns the feature off and is
-- written once to KenshiLua's log, it never stops the game.

local TAG = "[DamageNumbers] "
local log = (KenshiLua and KenshiLua.log) or print

-- Modules next to this script. KenshiLua versions without mod-local require cannot find them, so the mod's
-- folder (a local mod, or the Steam Workshop copy next to the game) is added to package.path and tried again.
local MOD_FOLDERS = { "mods/DamageNumbers/scripts/?.lua", "../../workshop/content/233860/3821781631/scripts/?.lua" }
local function requireLocal(name)
    local ok, mod = pcall(require, name)
    if ok then return mod end
    if package and type(package.path) == "string" then
        for _, f in ipairs(MOD_FOLDERS) do
            if not package.path:find(f, 1, true) then package.path = package.path .. ";" .. f end
        end
        local ok2, mod2 = pcall(require, name)
        if ok2 then
            log(TAG .. name .. " found in the mod folder; a newer KenshiLua finds it by itself")
            return mod2
        end
    end
    log(TAG .. "module " .. name .. " not found, please update KenshiLua: " .. tostring(mod))
    return nil
end

local glyphs = requireLocal("dn_glyphs")
if glyphs == nil then
    log(TAG .. "no number images without dn_glyphs: damage numbers are off")
    return
end
-- without the settings module the defaults below are used and Mod Config Menu changes are not read
local SETTINGS = requireLocal("dn_settings") or {
    apply = function() return {}, false end,
    poll = function() return nil end,
    iniPath = function() return "(no settings module)" end,
    pluginLoaded = function() return false end,
}

-- ===================================================================================
-- SETTINGS
-- ===================================================================================
local CONFIG = {
    enabled = true,
    showOwnSquadDamage = true,   -- numbers when your own people are hurt (red)
    showWords = true,            -- KNOCKOUT / SEVERED / KILLED
    wordsLanguage = "auto",      -- "auto" (follows the game language), "en" or "ru"
    showHealing = false,         -- green +N when a character heals a lot at once
    healingThreshold = 5,        -- minimum health regained within one second to show +N

    maxWatched = 40,             -- how many nearby characters are checked for damage
    sampleInterval = 0.05,       -- seconds between health checks
    scanInterval = 0.5,          -- seconds between rebuilding the watch list
    keepAfterHitSeconds = 6,     -- a character that was hit stays watched this long
    minDamage = 1,               -- smaller drops are ignored
    mergeWindow = 0.22,          -- hits closer than this on one target add up

    numberSizeOfBody = 0.30,     -- number height as a share of the character's height on screen
    minNumberPx = 22,            -- limits at 1080p, scaled with the screen height
    maxNumberPx = 50,
    maxActive = 60,              -- numbers on screen at once (oldest is recycled)
    layer = "Back",              -- MyGUI layer: below game windows, above the world
    fallbackFovDegrees = 45,     -- used only when the exact camera matrices are unavailable
    debug = false,               -- write diagnostics to the log
    showTestNumber = false,      -- with debug: show a -123 test number in the screen centre once
    durationScale = 1.0,         -- how long numbers stay (1 = normal)
    riseScale = 1.0,             -- how high numbers float (0 = in place)
    flash = true,                -- white flash when a number appears
    bigHitShake = true,          -- big hits shake for a moment
}

local COLOURS = {
    light  = { 1.00, 0.96, 0.86 },  -- small hits
    medium = { 1.00, 0.82, 0.25 },  -- solid hits
    heavy  = { 1.00, 0.48, 0.12 },  -- heavy hits
    squad  = { 1.00, 0.25, 0.25 },  -- your own people
    heal   = { 0.43, 0.90, 0.47 },
    KO     = { 0.59, 0.75, 1.00 },
    LIMB   = { 1.00, 0.35, 0.24 },
    DEAD   = { 0.85, 0.10, 0.10 },
}

-- ===================================================================================
-- Small helpers
-- ===================================================================================
local floor, max, min, abs, sqrt, random = math.floor, math.max, math.min, math.abs, math.sqrt, math.random
local warned = {}
local function warnOnce(key, msg)
    if not warned[key] then
        warned[key] = true
        log(TAG .. msg)
    end
end

local debugBudget = 60
local function dlog(msg)
    if CONFIG.debug and debugBudget > 0 then
        debugBudget = debugBudget - 1
        log(TAG .. "debug: " .. msg)
    end
end

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function lerp(a, b, t) return a + (b - a) * t end
local function easeOutCubic(t) local u = 1 - t return 1 - u * u * u end
local function easeOutQuad(t) return 1 - (1 - t) * (1 - t) end
local function easeInQuad(t) return t * t end
local function easeInOutSine(t) return 0.5 - 0.5 * math.cos(math.pi * t) end

local function keyOf(c)
    local ok, k = pcall(function() return tostring(c.handle:toString()) end)
    if ok and k then return k end
    return nil
end

-- A character can be unloaded at any moment, so we never keep the Character object itself.
-- We keep a copy of its handle in a script-owned list and resolve it again when needed;
-- the engine returns nothing for a handle whose character is gone.
local function handleRef(c)
    local ok, ref = pcall(function()
        local list = lektor.new("hand")
        list:push(c.handle)
        return list
    end)
    if ok then return ref end
    warnOnce("handle", "could not copy a character handle: " .. tostring(ref))
    return nil
end

local function resolve(ref)
    if ref == nil then return nil end
    local ok, c = pcall(function() return ref[1]:getCharacter() end)
    if ok then return c end
    return nil
end

-- ===================================================================================
-- Screen and camera projection
-- ===================================================================================
local W, H, resScale = 1920, 1080, 1.0

local function updateViewSize()
    local ok, a, b = pcall(function() return MyGUI.getViewSize() end)
    if not (ok and type(a) == "number") then
        ok, a, b = pcall(function() return MyGUI.RenderManager.getInstance():getViewSize() end)
        if ok and type(a) ~= "number" and a then a, b = a.width, a.height end
    end
    if ok and type(a) == "number" and a > 0 and b and b > 0 then
        W, H = a, b
        resScale = H / 1080
    end
end

local function cameraClass()
    local ok, cam = pcall(function()
        local pi = (getPlayerInterface and getPlayerInterface()) or getGameWorld().player
        if pi == nil then return nil end
        local okGet, c = pcall(function() return pi:getCamera() end)
        if okGet and c then return c end
        return pi.camera
    end)
    if ok then return cam end
    return nil
end

-- Exact projection through Ogre's own camera matrices (LuaJIT ffi).
-- Kenshi's Ogre view matrix may not carry the camera position (the camera can sit at the origin of
-- its render space), so three ways of projecting are kept and checked against the game's own
-- visibility test, and the one that agrees with the game is used:
--   "rp"   rotation from Ogre's view matrix + camera position from the game + Ogre's projection;
--   "full" Ogre's full view matrix + Ogre's projection;
--   "fb"   no ffi: camera position looking at the camera's centre point, field of view from Ogre if known.
local ffiProj = nil
do
    local okFfi, ffi = pcall(require, "ffi")
    if not okFfi or not ffi then
        ffi = rawget(_G, "ffi") or (package and package.loaded and package.loaded.ffi)
    end
    if ffi then
        local okDef = pcall(ffi.cdef, [[
            typedef struct { float m[16]; } DN_Matrix4;
            typedef struct { float x, y, z; } DN_Vector3;
            const DN_Matrix4* DN_getViewMatrix(const void* cam) __asm__("?getViewMatrix@Camera@Ogre@@UEBAAEBVMatrix4@2@XZ");
            const DN_Matrix4* DN_getProjMatrix(const void* cam) __asm__("?getProjectionMatrix@Frustum@Ogre@@UEBAAEBVMatrix4@2@XZ");
            const DN_Vector3* DN_getDerivedPosition(const void* cam) __asm__("?getDerivedPosition@Camera@Ogre@@QEBAAEBVVector3@2@XZ");
            void* GetModuleHandleA(const char* name);
            void* GetProcAddress(void* module, const char* name);
        ]])
        if not okDef then
            -- a reload of this script: the declarations already exist, keep going
            okDef = pcall(function() return ffi.typeof("DN_Matrix4") end)
        end
        local okLib, ogre = pcall(ffi.load, "OgreMain_x64")
        if okDef and okLib then
            local okInfo, vtbl = pcall(function()
                local mod = ffi.C.GetModuleHandleA("OgreMain_x64.dll")
                if mod == nil then error("OgreMain_x64.dll is not loaded") end
                local sym = ffi.C.GetProcAddress(mod, "??_7Camera@Ogre@@6BMovableObject@1@@")
                if sym == nil then error("Ogre::Camera vtable symbol not found") end
                return tonumber(ffi.cast("uintptr_t", sym))
            end)
            if okInfo then
                ffiProj = { ffi = ffi, ogre = ogre, cameraVtable = vtbl, checkedPtr = nil }
            else
                warnOnce("ffi-module", "Ogre camera class not identified, using fallback projection: " .. tostring(vtbl))
            end
        else
            warnOnce("ffi-setup", "ffi setup failed (" .. tostring(okDef) .. "/" .. tostring(okLib and "lib" or ogre) .. "), using fallback projection")
        end
    else
        warnOnce("ffi-missing", "LuaJIT ffi not available, using fallback projection")
    end
end

local MRP, MFULL = {}, {}     -- projection * view, row-major, 1-based: rotation+game position / full Ogre view
local exactUsable = ffiProj ~= nil
local projMode = "none"       -- "rp", "full", "fb" or "none"
local preferred = exactUsable and "rp" or "fb"
local camPos = { x = 0, y = 0, z = 0 }
local fb = { fx = 0, fy = 0, fz = 1, rx = 1, ry = 0, rz = 0, ux = 0, uy = 1, uz = 0, t = 0.414, aspect = nil }
local fbReady = false
local ogreFov = nil           -- { t = tan(fovY / 2), aspect } read from Ogre's projection matrix

local function isCameraPointer(ptr)
    if ffiProj.checkedPtr == ptr then return true end
    local ok, same = pcall(function()
        local vt = tonumber(ffiProj.ffi.cast("uintptr_t*", ptr)[0])
        return vt == ffiProj.cameraVtable
    end)
    if ok and same then
        ffiProj.checkedPtr = ptr
        return true
    end
    return false
end

-- view: rotation rows of unit length, bottom row 0 0 0 1; projection: perspective bottom row 0 0 -1 0
local function matricesLookRight(v, p)
    if abs(v[12]) > 1e-3 or abs(v[13]) > 1e-3 or abs(v[14]) > 1e-3 or abs(v[15] - 1) > 1e-3 then return false end
    for r = 0, 2 do
        local l = v[r * 4] ^ 2 + v[r * 4 + 1] ^ 2 + v[r * 4 + 2] ^ 2
        if abs(l - 1) > 1e-2 then return false end
    end
    if abs(p[12]) > 1e-3 or abs(p[13]) > 1e-3 or abs(p[14] + 1) > 1e-3 or abs(p[15]) > 1e-3 then return false end
    return p[0] > 0 and p[5] > 0
end

local function disableExact(reason)
    if exactUsable then
        exactUsable = false
        preferred = "fb"
        log(TAG .. "exact projection switched off: " .. reason)
    end
end

local function norm3(x, y, z)
    local l = sqrt(x * x + y * y + z * z)
    if l < 1e-6 then return nil end
    return x / l, y / l, z / l
end

-- camera position from the game; it looks at its centre point (Kenshi's orbit camera)
local function updateFallback(cc)
    local ok = pcall(function()
        local pos = cc:getCameraPos()
        local fx, fy, fz = nil, nil, nil
        local okC, centre = pcall(function() return cc:getCenter() end)
        if okC and centre then fx, fy, fz = norm3(centre.x - pos.x, centre.y - pos.y, centre.z - pos.z) end
        if fx == nil then
            local f = cc:getFacingDirection()
            fx, fy, fz = norm3(f.x, f.y, f.z)
        end
        local rx, ry, rz = -fz, 0, fx                      -- forward x world up
        local rl = sqrt(rx * rx + rz * rz)
        if rl < 1e-4 then rx, rz, rl = 1, 0, 1 end
        rx, rz = rx / rl, rz / rl
        local ux, uy, uz = ry * fz - rz * fy, rz * fx - rx * fz, rx * fy - ry * fx
        camPos.x, camPos.y, camPos.z = pos.x, pos.y, pos.z
        fb.fx, fb.fy, fb.fz, fb.rx, fb.ry, fb.rz, fb.ux, fb.uy, fb.uz = fx, fy, fz, rx, ry, rz, ux, uy, uz
        if ogreFov then
            fb.t, fb.aspect = ogreFov.t, ogreFov.aspect
        else
            fb.t, fb.aspect = math.tan(math.rad(CONFIG.fallbackFovDegrees) / 2), nil
        end
    end)
    fbReady = ok
    return ok
end

local function multiply(out, p, r00, r01, r02, t0, r10, r11, r12, t1, r20, r21, r22, t2)
    local v = { r00, r01, r02, t0, r10, r11, r12, t1, r20, r21, r22, t2, 0, 0, 0, 1 }
    for r = 0, 3 do
        for c = 0, 3 do
            out[r * 4 + c + 1] = p[r * 4] * v[c + 1] + p[r * 4 + 1] * v[4 + c + 1] + p[r * 4 + 2] * v[8 + c + 1] + p[r * 4 + 3] * v[12 + c + 1]
        end
    end
end

local currentCamera = nil
local cameraDumped = false
local function updateCamera()
    local cc = cameraClass()
    currentCamera = cc
    if cc == nil then projMode = "none" return false end
    local fbOk = updateFallback(cc)
    local exactOk = false
    if exactUsable then
        local ok, err = pcall(function()
            local ptr = ffiProj.ffi.cast("const void*", cc.camera)
            if ptr == nil or not isCameraPointer(ptr) then error("the camera field is not an Ogre::Camera") end
            local v = ffiProj.ogre.DN_getViewMatrix(ptr).m
            local p = ffiProj.ogre.DN_getProjMatrix(ptr).m
            if not matricesLookRight(v, p) then error("camera matrices have an unexpected shape") end
            ogreFov = { t = 1 / p[5], aspect = p[5] / p[0] }
            multiply(MFULL, p, v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10], v[11])
            local cx, cy, cz = camPos.x, camPos.y, camPos.z
            multiply(MRP, p,
                v[0], v[1], v[2], -(v[0] * cx + v[1] * cy + v[2] * cz),
                v[4], v[5], v[6], -(v[4] * cx + v[5] * cy + v[6] * cz),
                v[8], v[9], v[10], -(v[8] * cx + v[9] * cy + v[10] * cz))
            if CONFIG.debug and not cameraDumped then
                cameraDumped = true
                local d = ffiProj.ogre.DN_getDerivedPosition(ptr)
                local okC, centre = pcall(function() return cc:getCenter() end)
                local okF, f = pcall(function() return cc:getFacingDirection() end)
                dlog(string.format("camera: view=[%.3f %.3f %.3f %.1f | %.3f %.3f %.3f %.1f | %.3f %.3f %.3f %.1f] proj p0=%.3f p5=%.3f ogrePos=(%.1f,%.1f,%.1f) gamePos=(%.1f,%.1f,%.1f) centre=%s facing=%s yaw=%s pitch=%s",
                    v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10], v[11], p[0], p[5], d.x, d.y, d.z, cx, cy, cz,
                    okC and centre and string.format("(%.1f,%.1f,%.1f)", centre.x, centre.y, centre.z) or "?",
                    okF and f and string.format("(%.2f,%.2f,%.2f)", f.x, f.y, f.z) or "?", tostring(cc.yaw), tostring(cc.pitch)))
            end
        end)
        if ok then exactOk = true else disableExact(tostring(err)) end
    end
    if preferred ~= "fb" and exactOk then
        projMode = preferred
    elseif fbOk then
        projMode = "fb"
    else
        projMode = "none"
    end
    if projMode == "none" then warnOnce("camera", "camera data unavailable") end
    return projMode ~= "none"
end

local function projectMatrix(M, x, y, z)
    local cw = M[13] * x + M[14] * y + M[15] * z + M[16]
    if cw <= 1e-3 then return nil end
    local cx = M[1] * x + M[2] * y + M[3] * z + M[4]
    local cy = M[5] * x + M[6] * y + M[7] * z + M[8]
    return (cx / cw * 0.5 + 0.5) * W, (0.5 - cy / cw * 0.5) * H
end

local function projectFallback(x, y, z)
    if not fbReady then return nil end
    local dx, dy, dz = x - camPos.x, y - camPos.y, z - camPos.z
    local zc = dx * fb.fx + dy * fb.fy + dz * fb.fz
    if zc <= 1e-2 then return nil end
    local xc = dx * fb.rx + dy * fb.ry + dz * fb.rz
    local yc = dx * fb.ux + dy * fb.uy + dz * fb.uz
    local aspect = fb.aspect or W / H
    return W * 0.5 + (xc / zc) / (fb.t * aspect) * W * 0.5, H * 0.5 - (yc / zc) / fb.t * H * 0.5
end

local function projectWith(mode, x, y, z)
    if mode == "rp" then return projectMatrix(MRP, x, y, z) end
    if mode == "full" then return projectMatrix(MFULL, x, y, z) end
    if mode == "fb" then return projectFallback(x, y, z) end
    return nil
end

-- world point -> screen pixels; nil when behind the camera
local function project(x, y, z)
    return projectWith(projMode, x, y, z)
end

local function onScreen(sx, sy, margin)
    return sx ~= nil and sx > -margin and sx < W + margin and sy > -margin and sy < H + margin
end

-- Compare the projections with the game's own visibility test on a real character.
-- When the one in use keeps missing a character the game sees, switch to one that agrees.
local misses = 0
local function crossCheck(pos)
    if projMode == "none" or currentCamera == nil then return end
    local okV, gameSees = pcall(function() return currentCamera:isVisible(pos) end)
    if not okV or not gameSees then return end
    local sees, txt = {}, {}
    for _, mode in ipairs({ "rp", "full", "fb" }) do
        local available = mode == "fb" or exactUsable
        local sx, sy = nil, nil
        if available then sx, sy = projectWith(mode, pos.x, pos.y, pos.z) end
        sees[mode] = available and onScreen(sx, sy, 0)
        txt[#txt + 1] = string.format("%s=(%s,%s)", mode, tostring(sx and floor(sx)), tostring(sy and floor(sy)))
    end
    dlog("cross-check: using " .. projMode .. " " .. table.concat(txt, " "))
    if sees[projMode] then
        misses = 0
        return
    end
    misses = misses + 1
    if misses < 3 then return end
    for _, mode in ipairs({ "rp", "full", "fb" }) do
        if sees[mode] then
            log(TAG .. "projection switched from " .. projMode .. " to " .. mode .. " (it agrees with the game)")
            preferred, projMode, misses = mode, mode, 0
            return
        end
    end
end

-- ===================================================================================
-- Character anchors (top of the head) and on-screen size
-- ===================================================================================
local headBone = {}           -- per character key: bone name that works, or false
local typicalHeight = nil     -- standing height, learned from characters with a head bone
local HEAD_BONES = { "Bip01 HeadNub", "Bip01 Head" }

local function learnHeight(height)
    if height <= 0 then return end
    if typicalHeight == nil then
        typicalHeight = height
    elseif height > typicalHeight * 1.3 then
        typicalHeight = lerp(typicalHeight, height, 0.25)   -- the first sample was probably lying down
    elseif height > typicalHeight * 0.7 then
        typicalHeight = lerp(typicalHeight, height, 0.03)
    end
end

-- Character::getBoneWorldPosition and Character::getAppearance use Character::animation (+0x448) with no null
-- check, and the game crashes on a character without one (pcall cannot catch that). KenshiLua gives the field
-- as a light userdata, so a null one is not nil: its address is compared through ffi.
local ffiForChecks = nil
do
    local ok, f = pcall(require, "ffi")
    if ok then ffiForChecks = f end
end
local function hasAnimation(c)
    local a = c.animation
    if a == nil or ffiForChecks == nil then return false end
    return ffiForChecks.cast("uintptr_t", a) ~= 0
end

-- returns the point just above the head (x, y, z) and the feet position
local function anchorOf(c, key)
    local okF, feet = pcall(function() return c:getPosition() end)
    if not okF or feet == nil then return nil end
    local bone = headBone[key]
    local head = nil
    if bone ~= false and hasAnimation(c) then
        for _, name in ipairs(bone and { bone } or HEAD_BONES) do
            local ok, p = pcall(function() return c:getBoneWorldPosition(name) end)
            if ok and p and p.y and abs(p.y - feet.y) > 1e-3 then
                head, headBone[key] = p, name
                break
            end
        end
        if head == nil then headBone[key] = false end
    end
    if head then
        local height = head.y - feet.y
        learnHeight(height)
        return head.x, head.y + abs(height) * 0.14, head.z, feet
    end
    return feet.x, feet.y + (typicalHeight or 18) * 1.12, feet.z, feet
end

-- ===================================================================================
-- Health reading
-- ===================================================================================
-- flesh and stun of every body part; blunt damage goes partly into stun, which wears off later
local function readParts(c, out, stun)
    local med = c.medical
    if med == nil then med = c:getMedical() end
    local parts = med.anatomy
    local n = 0
    for _, p in ipairs(parts) do
        n = n + 1
        out[n] = p.flesh
        stun[n] = p.fleshStun or 0
    end
    for i = n + 1, #out do out[i] = nil end
    for i = n + 1, #stun do stun[i] = nil end
    return n, parts
end

-- ===================================================================================
-- Word sprites follow the game language (settings.cfg: language=ru_RU); English otherwise
-- ===================================================================================
local function wordsInRussian()
    if CONFIG.wordsLanguage ~= "auto" then return CONFIG.wordsLanguage == "ru" end
    local ok, lang = pcall(function()
        local f = io.open("settings.cfg", "r")
        if not f then return nil end
        local text = f:read("*a")
        f:close()
        return text:match("^language=(%a+)") or text:match("\nlanguage=(%a+)")
    end)
    return ok and type(lang) == "string" and lang:lower():sub(1, 2) == "ru"
end
local RUSSIAN_WORDS = wordsInRussian()   -- read again when the setting changes (see applySettingChanges)
local function wordGlyph(word)
    if RUSSIAN_WORDS then return word end
    return word .. "_EN"
end

-- ===================================================================================
-- Widgets: pooled image boxes, one per glyph
-- ===================================================================================
local GLYPH = glyphs.glyphs
local DIGIT_H = GLYPH["0"].h
local widgetSerial = 0
local freeWidgets = {}
local widgetsOk = true

local function newWidget()
    widgetSerial = widgetSerial + 1
    local w = MyGUI.createImageBox("ImageBox", 0, 0, 1, 1, "DamageNumbers_" .. widgetSerial, CONFIG.layer)
    w:setImageTexture(glyphs.texture)
    pcall(function() w:setNeedMouseFocus(false) end)
    pcall(function() w:setInheritsPick(false) end)
    w:setVisible(false)
    return w
end

local function takeWidget()
    local w = table.remove(freeWidgets)
    if w then return w end
    local ok, nw = pcall(newWidget)
    if ok and nw then return nw end
    widgetsOk = false
    warnOnce("widgets", "could not create image widgets: " .. tostring(nw))
    return nil
end

local function releaseWidget(w)
    pcall(function() w:setVisible(false) end)
    freeWidgets[#freeWidgets + 1] = w
end

local colourCache = {}
local function colourOf(r, g, b)
    local qr, qg, qb = floor(r * 63 + 0.5), floor(g * 63 + 0.5), floor(b * 63 + 0.5)
    local key = qr * 4096 + qg * 64 + qb
    local col = colourCache[key]
    if col == nil then
        col = MyGUI.Colour.new(qr / 63, qg / 63, qb / 63, 1)
        colourCache[key] = col
    end
    return col
end

-- ===================================================================================
-- Floating numbers
-- ===================================================================================
local active = {}            -- list of floaters
local lastFloater = {}       -- target key -> most recent damage floater
local lastSide = {}          -- target key -> -1 / 1, alternates so numbers do not stack

local function setGlyphs(f, keys)
    for i = #f.widgets, 1, -1 do
        if i > #keys then releaseWidget(f.widgets[i]) f.widgets[i] = nil end
    end
    for i, k in ipairs(keys) do
        local w = f.widgets[i] or takeWidget()
        if w == nil then return false end
        f.widgets[i] = w
        local g = GLYPH[k]
        w:setImageTile(g.w, g.h)
        w:setImageCoord(g.x, g.y, g.w, g.h)
        w:setImageIndex(0)
    end
    f.keys = keys
    return true
end

local function digitsOf(prefix, value)
    local keys = { prefix }
    for ch in tostring(value):gmatch("%d") do keys[#keys + 1] = ch end
    return keys
end

local function severityColour(ratio)
    if ratio < 0.12 then
        return lerp(COLOURS.light[1], COLOURS.medium[1], ratio / 0.12),
               lerp(COLOURS.light[2], COLOURS.medium[2], ratio / 0.12),
               lerp(COLOURS.light[3], COLOURS.medium[3], ratio / 0.12)
    end
    local t = clamp((ratio - 0.12) / 0.25, 0, 1)
    return lerp(COLOURS.medium[1], COLOURS.heavy[1], t),
           lerp(COLOURS.medium[2], COLOURS.heavy[2], t),
           lerp(COLOURS.medium[3], COLOURS.heavy[3], t)
end

local function recycleOldest()
    local f = table.remove(active, 1)
    if f then
        for _, w in ipairs(f.widgets) do releaseWidget(w) end
        if lastFloater[f.key] == f then lastFloater[f.key] = nil end
    end
end

local function spawn(ref, key, kind, value, ratio, squad)
    if not widgetsOk or ref == nil then return end
    if #active >= CONFIG.maxActive then recycleOldest() end
    local f = { widgets = {}, ref = ref, key = key, kind = kind, age = 0, value = value }
    local side = -(lastSide[key] or 1)
    lastSide[key] = side
    f.side = side
    f.jitter = (random() - 0.5) * 0.35
    if kind == "word" then
        if not setGlyphs(f, { wordGlyph(value) }) then return end
        local col = COLOURS[value]
        f.r, f.g, f.b = col[1], col[2], col[3]
        f.size = 1.05
        f.life = 1.7 * CONFIG.durationScale
        f.rise = 0.9 * CONFIG.riseScale
        f.lift = 1.15     -- start above damage numbers
        f.big = value ~= "KO"
        f.side = 0
    else
        local prefix = kind == "heal" and "+" or "-"
        if not setGlyphs(f, digitsOf(prefix, value)) then return end
        if kind == "heal" then
            f.r, f.g, f.b = COLOURS.heal[1], COLOURS.heal[2], COLOURS.heal[3]
        elseif squad then
            f.r, f.g, f.b = COLOURS.squad[1], COLOURS.squad[2], COLOURS.squad[3]
        else
            f.r, f.g, f.b = severityColour(ratio)
        end
        f.size = 0.86 + clamp(ratio, 0, 1) * 0.7
        f.big = ratio >= 0.3
        f.life = (f.big and 1.35 or 1.05) * CONFIG.durationScale
        f.rise = 1.25 * CONFIG.riseScale
        f.lift = 0
        lastFloater[key] = f
    end
    active[#active + 1] = f
end

local function spawnTest()
    local f = { widgets = {}, key = "test", kind = "test", age = 0, value = 123, side = 0, jitter = 0 }
    if not setGlyphs(f, digitsOf("-", 123)) then return end
    f.r, f.g, f.b = COLOURS.medium[1], COLOURS.medium[2], COLOURS.medium[3]
    f.size, f.life, f.rise, f.lift, f.big = 1.4, 6, 0.3, 0, false
    f.fixedX, f.fixedY = W * 0.5, H * 0.38
    active[#active + 1] = f
    dlog("test number spawned at screen centre")
end

local function addToFloater(f, value, ratio, squad)
    f.value = f.value + value
    setGlyphs(f, digitsOf("-", f.value))
    local grow = clamp(ratio, 0, 1)
    f.size = min(1.75, max(f.size, 0.86 + grow * 0.7) + 0.06)
    if not squad then f.r, f.g, f.b = severityColour(max(grow, (f.size - 0.86) / 0.7)) end
    f.big = f.big or ratio >= 0.3
    f.age = 0.05                         -- re-pop from the middle of the pop
    f.life = max(f.life, (f.big and 1.35 or 1.05) * CONFIG.durationScale)
end

local function onDamage(c, ref, key, dmg, ratio)
    dlog(string.format("damage %.1f (ratio %.2f) on %s", dmg, ratio, key))
    local squad = false
    pcall(function() squad = c:isPlayerCharacter() end)
    if squad and not CONFIG.showOwnSquadDamage then return end
    local value = floor(dmg + 0.5)
    if value < CONFIG.minDamage then return end
    local f = lastFloater[key]
    if f and f.kind == "dmg" and f.age < CONFIG.mergeWindow + 0.05 then
        addToFloater(f, value, ratio, squad)
    else
        spawn(ref, key, "dmg", value, ratio, squad)
    end
end

-- per-frame animation
local function animate(f, dt)
    f.age = f.age + dt
    local t, life = f.age, f.life
    if t >= life then return false end

    local c = f.ref and resolve(f.ref)
    local sx, sy, bodyPx
    if f.fixedX then
        sx, sy, bodyPx = f.fixedX, f.fixedY, 160 * resScale
    elseif c then
        local ax, ay, az, feet = anchorOf(c, f.key)
        if ax then
            sx, sy = project(ax, ay, az)
            if sx then
                local _, footY = project(feet.x, feet.y, feet.z)
                local _, topY = project(feet.x, feet.y + (typicalHeight or 18), feet.z)
                if footY and topY then bodyPx = abs(footY - topY) end
            end
        end
    end
    if sx == nil then
        if f.lastX == nil then return false end
        sx, sy, bodyPx = f.lastX, f.lastY, f.lastBody
    end
    f.lastX, f.lastY, f.lastBody = sx, sy, bodyPx

    -- base size follows the character's size on screen
    bodyPx = bodyPx or 160 * resScale
    local px = clamp(bodyPx * CONFIG.numberSizeOfBody, CONFIG.minNumberPx * resScale, CONFIG.maxNumberPx * resScale) * f.size

    -- pop: grow past full size, settle, shrink a little while fading
    local s
    if t < 0.10 then
        s = lerp(0.35, 1.28, easeOutCubic(t / 0.10))
    elseif t < 0.24 then
        s = lerp(1.28, 1.0, easeInOutSine((t - 0.10) / 0.14))
    else
        s = 1.0
    end
    local fadeStart = life * 0.62
    local alpha = 1
    if t < 0.05 then alpha = t / 0.05 end
    if t > fadeStart then
        local k = (t - fadeStart) / (life - fadeStart)
        alpha = 1 - easeInQuad(k)
        s = s * (1 - 0.12 * k)
    end
    local h = px * s

    -- motion: float up with an ease, drift sideways in an arc
    local k = t / life
    local dy = -px * f.rise * easeOutQuad(k) - px * f.lift
    local dx = (f.side * 0.55 + f.jitter) * px * easeOutCubic(min(1, k * 1.25))
    if f.big and CONFIG.bigHitShake and t < 0.18 then
        local amp = (1 - t / 0.18) * 4 * resScale
        dx = dx + (random() * 2 - 1) * amp
        dy = dy + (random() * 2 - 1) * amp
    end

    -- colour: brief white flash, then the real colour
    local r, g, b = f.r, f.g, f.b
    if CONFIG.flash and t < 0.12 then
        local q = t / 0.12
        r, g, b = lerp(1, r, q), lerp(1, g, q), lerp(1, b, q)
    end
    local flashing = CONFIG.flash and t < 0.14
    local col = (flashing or not f.coloured) and colourOf(r, g, b) or nil
    if not flashing then f.coloured = true end

    -- layout glyphs centred on the anchor
    local scale = h / DIGIT_H
    local total = 0
    for i, key in ipairs(f.keys) do
        local gdef = GLYPH[key]
        total = total + gdef.w * scale - (i < #f.keys and gdef.overlap * scale or 0)
    end
    local x = sx + dx - total * 0.5
    local y = sy + dy - h * 0.5
    if x > W + 50 or x + total < -50 or y > H + 50 or y + h < -50 then
        if CONFIG.debug and not f.offscreenReported then
            f.offscreenReported = true
            dlog(string.format("floater %s off screen at (%.0f, %.0f)", f.kind, x, y))
        end
        for _, w in ipairs(f.widgets) do w:setVisible(false) end
        return true
    end
    if CONFIG.debug and not f.reported and t > 0.3 then
        f.reported = true
        local w1 = f.widgets[1]
        local okC, cx, cy, cw, ch = pcall(function() return w1:getCoord() end)
        local okL, layer = pcall(function() return w1.layerName end)
        local okV, vis = pcall(function() return w1:getVisible() end)
        dlog(string.format("floater %s value=%s anchor=(%.0f,%.0f) px=%.1f alpha=%.2f first glyph coord=%s,%s,%s,%s layer=%s visible=%s",
            f.kind, tostring(f.value), sx, sy, px, alpha, tostring(okC and cx), tostring(okC and cy), tostring(okC and cw),
            tostring(okC and ch), tostring(okL and layer), tostring(okV and vis)))
    end
    for i, key in ipairs(f.keys) do
        local gdef = GLYPH[key]
        local w = f.widgets[i]
        local ww, wh = floor(gdef.w * scale + 0.5), floor(gdef.h * scale + 0.5)
        w:setCoord(floor(x + 0.5), floor(y + (h - gdef.h * scale) * 0.5 + 0.5), ww, wh)
        w:setAlpha(alpha)
        if col then w:setColour(col) end
        w:setVisible(true)
        x = x + gdef.w * scale - gdef.overlap * scale
    end
    return true
end

-- ===================================================================================
-- Watch list and damage detection
-- ===================================================================================
local watched = {}           -- key -> { ref, parts = {flesh...}, n, heal, healT }
local hitUntil = {}          -- key -> time until which a hit character stays watched
local clock = 0

local function watch(c, key)
    local w = watched[key]
    if w then return w end
    local ref = handleRef(c)
    if ref == nil then return nil end
    w = { ref = ref, parts = {}, stun = {}, n = 0, heal = 0, healT = 0, dt = 0, slow = false }
    local ok, n = pcall(readParts, c, w.parts, w.stun)
    if not ok then return nil end
    w.n = n
    -- a body that is already dead when first watched never gets a number
    local okD, dead = pcall(function() return c:isDead() end)
    w.deadShown = okD and dead == true
    watched[key] = w
    return w
end

-- Characters beyond maxWatched are read every SLOW_EVERY-th sample: their hits still get numbers (hits closer
-- together than that add up into one), at a fifth of the cost.
local SLOW_EVERY = 5
local SLOW_WATCH_FACTOR = 3       -- up to this many times maxWatched more characters are read that way
local scanList = {}
local testShown, probeTimer, checkTimer = false, 0, 0
local function rescan()
    local world = getGameWorld()
    if world == nil then return end
    local okSet, set = pcall(function() return world:getCharacterUpdateList() end)
    if not okSet or set == nil then warnOnce("scan", "character list unavailable") return end
    for i = #scanList, 1, -1 do scanList[i] = nil end
    for c in pairs(set) do
        local key = keyOf(c)
        -- a corpse never gets a number again, so it gives its watch slot to the living; one that is watched
        -- and has not had its killing blow sampled yet stays until it has
        local okD, dead = pcall(function() return c:isDead() end)
        if key and okD and dead == true and not (watched[key] and not watched[key].deadShown) then key = nil end
        if key then
            local okP, pos = pcall(function() return c:getPosition() end)
            if okP and pos then
                -- the game's own visibility test decides who is on screen; our projection only sorts
                local x, y = project(pos.x, pos.y, pos.z)
                local seen = nil
                if currentCamera then
                    local okV, v = pcall(function() return currentCamera:isVisible(pos) end)
                    if okV then seen = v end
                end
                if seen == nil then seen = onScreen(x, y, 0.2 * W) end
                if seen or (hitUntil[key] and hitUntil[key] > clock) then
                    local d = math.huge
                    if onScreen(x, y, 0.2 * W) then d = (x - W * 0.5) ^ 2 + (y - H * 0.5) ^ 2 end
                    -- a fight on screen comes first; one out of view (behind the camera, elsewhere in the loaded
                    -- world) is still watched for a while, but only after everyone on screen
                    if seen and hitUntil[key] and hitUntil[key] > clock then d = -1 end
                    scanList[#scanList + 1] = { c = c, key = key, d = d }
                end
            end
        end
    end
    table.sort(scanList, function(a, b) return a.d < b.d end)
    checkTimer = (checkTimer or 0) - CONFIG.scanInterval
    if checkTimer <= 0 and scanList[1] and projMode ~= "none" then
        checkTimer = 2
        local okPos, epos = pcall(function() return scanList[1].c:getPosition() end)
        if okPos and epos then crossCheck(epos) end
    end
    if CONFIG.debug then
        if CONFIG.showTestNumber and not testShown and #scanList > 0 then
            testShown = true
            spawnTest()
        end
        probeTimer = (probeTimer or 0) - CONFIG.scanInterval
        if probeTimer <= 0 and scanList[1] then
            probeTimer = 10
            local e = scanList[1]
            local okPos, epos = pcall(function() return e.c:getPosition() end)
            if okPos and epos then crossCheck(epos) end
            local ax, ay, az, feet = anchorOf(e.c, e.key)
            local sx, sy = nil, nil
            if ax then sx, sy = project(ax, ay, az) end
            dlog(string.format("probe: %d on screen, %d watched, nearest %s anchor screen=(%s,%s) world=(%.1f,%.1f,%.1f) typicalHeight=%s mode=%s",
                #scanList, min(#scanList, CONFIG.maxWatched), e.key, tostring(sx and floor(sx)), tostring(sy and floor(sy)),
                ax or 0, ay or 0, az or 0, tostring(typicalHeight), projMode))
        end
    end
    -- the first maxWatched (fighters first, then nearest the screen centre) are read every sample, the rest of
    -- the screen less often
    local keep = {}
    for i = 1, min(#scanList, CONFIG.maxWatched * (1 + SLOW_WATCH_FACTOR)) do
        local e = scanList[i]
        keep[e.key] = true
        local w = watch(e.c, e.key)
        if w then w.slow = i > CONFIG.maxWatched end
    end
    for key in pairs(watched) do
        if not keep[key] then watched[key] = nil end
    end
    for key in pairs(headBone) do
        if not keep[key] and not lastFloater[key] then headBone[key] = nil end
    end
end

local current, currentStun = {}, {}
local sampleTick = 0
local function sample(dt)
    sampleTick = sampleTick + 1
    for key, w in pairs(watched) do
        w.dt = w.dt + dt
        if not w.slow or sampleTick % SLOW_EVERY == 0 then
            local wdt = w.dt
            w.dt = 0
            local c = resolve(w.ref)
            if c == nil then
                watched[key] = nil
            else
                local ok, n, parts = pcall(readParts, c, current, currentStun)
                if not ok then
                    watched[key] = nil
                elseif n ~= w.n then
                    w.n = n
                    for i = 1, n do w.parts[i], w.stun[i] = current[i], currentStun[i] end
                    for i = n + 1, #w.parts do w.parts[i], w.stun[i] = nil, nil end
                else
                    local dmg, worst, worstIdx, healed = 0, 0, nil, 0
                    for i = 1, n do
                        local d = w.parts[i] - current[i]         -- flesh lost (negative: healed)
                        local s = currentStun[i] - w.stun[i]      -- stun gained (negative: wearing off)
                        local hit = (d > 0 and d or 0) + (s > 0 and s or 0)
                        if hit > 0 then
                            dmg = dmg + hit
                            if hit > worst then worst, worstIdx = hit, i end
                        end
                        if d < 0 then healed = healed - d end
                        w.parts[i], w.stun[i] = current[i], currentStun[i]
                    end
                    if dmg >= CONFIG.minDamage * 0.5 then
                        local dead = false
                        pcall(function() dead = c:isDead() end)
                        -- the blow that kills is shown like any hit; after that the body is quiet
                        if not w.deadShown then
                            w.deadShown = dead
                            local ratio = 0.2
                            pcall(function()
                                local mh = parts[worstIdx]:maxHealth()
                                if mh and mh > 0 then ratio = dmg / mh end
                            end)
                            onDamage(c, w.ref, key, dmg, ratio)
                        end
                        hitUntil[key] = clock + CONFIG.keepAfterHitSeconds
                    end
                    if CONFIG.showHealing then
                        w.heal = w.heal + healed
                        w.healT = w.healT + wdt
                        if w.healT >= 1 then
                            if w.heal >= CONFIG.healingThreshold then
                                spawn(w.ref, key, "heal", floor(w.heal + 0.5), 0, false)
                            end
                            w.heal, w.healT = 0, 0
                        end
                    end
                end
            end
        end
    end
end

-- ===================================================================================
-- Game events
-- ===================================================================================
local function onScreenWord(c, word)
    if not CONFIG.enabled or not CONFIG.showWords or c == nil then return end
    local key = keyOf(c)
    if key == nil then return end
    local ax, ay, az = anchorOf(c, key)
    if ax == nil or project(ax, ay, az) == nil then return end
    spawn(handleRef(c), key, "word", word, 1, false)
end

local function safeOn(event, fn)
    local ok, err = pcall(function() Events.on(event, fn) end)
    if not ok then warnOnce("event " .. event, "could not subscribe to " .. event .. ": " .. tostring(err)) end
end

-- a character in a fight is watched before onlookers when more than maxWatched are on screen
local function markFighting(c)
    if c == nil then return end
    local key = keyOf(c)
    if key == nil then return end
    hitUntil[key] = clock + CONFIG.keepAfterHitSeconds
    watch(c, key)
end

-- both sides of a melee exchange are fighting: the attacker is watched too, so a crossbow bolt into him
-- (no event of its own) still gets its number in a big battle
safeOn("Character::_NV_hitByMeleeAttack", function(self, cutDir, damage, attacker)
    if not CONFIG.enabled then return end
    markFighting(self)
    pcall(markFighting, attacker)
end)

safeOn("MedicalSystem::knockout", function(self)
    pcall(function() onScreenWord(self.me, "KO") end)
end)

safeOn("MedicalSystem::amputate", function(self)
    pcall(function() onScreenWord(self.me, "LIMB") end)
end)

safeOn("Character::declareDead", function(self)
    pcall(function() onScreenWord(self, "DEAD") end)
end)

-- ===================================================================================
-- Frame loop
-- ===================================================================================
local sampleTimer, scanTimer, sizeTimer = 0, 0, 0
local errors = 0
local announced = false

-- Frame time comes from our own wall clock (os.clock is wall time on Windows); the event's
-- argument is only a fallback, because its unit is not documented.
local lastWall = nil
local frameLogs = 0
local function frameTime(arg)
    local now = os.clock()
    local dt
    if lastWall and now > lastWall then dt = now - lastWall end
    lastWall = now
    if dt == nil then dt = tonumber(arg) or 0.016 end
    if frameLogs < 5 then
        frameLogs = frameLogs + 1
        dlog(string.format("frame time: event argument=%s measured=%.4f", tostring(arg), dt))
    end
    return clamp(dt, 0, 0.1)
end

local function frame(time)
    local dt = frameTime(time)
    clock = clock + dt
    sizeTimer = sizeTimer - dt
    if sizeTimer <= 0 then updateViewSize() sizeTimer = 2 end
    if not updateCamera() then return end
    if not announced then
        announced = true
        log(TAG .. string.format("running: projection=%s screen=%dx%d", projMode, W, H))
    end

    scanTimer = scanTimer - dt
    if scanTimer <= 0 then rescan() scanTimer = CONFIG.scanInterval end
    sampleTimer = sampleTimer - dt
    if sampleTimer <= 0 then sample(CONFIG.sampleInterval - sampleTimer) sampleTimer = CONFIG.sampleInterval end

    local i = 1
    while i <= #active do
        local f = active[i]
        local ok, alive = pcall(animate, f, dt)
        if ok and alive then
            i = i + 1
        else
            if not ok then warnOnce("animate", "animation error: " .. tostring(alive)) end
            for _, w in ipairs(f.widgets) do releaseWidget(w) end
            if lastFloater[f.key] == f then lastFloater[f.key] = nil end
            table.remove(active, i)
        end
    end
end

-- Settings (ini written by ModConfigMenu): read once now, then follow changes.
local SETTING_ROOTS = { CONFIG = CONFIG, COLOURS = COLOURS }
local function clearFloaters()
    for _, f in ipairs(active) do
        for _, w in ipairs(f.widgets) do releaseWidget(w) end
    end
    for i = #active, 1, -1 do active[i] = nil end
    for k in pairs(lastFloater) do lastFloater[k] = nil end
end

local function applySettingChanges(changed)
    local set = {}
    for _, k in ipairs(changed) do set[k] = true end
    if set.WordsLanguage then RUSSIAN_WORDS = wordsInRussian() end
    if set.Layer then
        for _, w in ipairs(freeWidgets) do pcall(function() w:destroy() end) end
        freeWidgets = {}
    end
    if set.Enabled and not CONFIG.enabled then clearFloaters() end
    if #changed > 0 then log(TAG .. "settings changed: " .. table.concat(changed, ", ")) end
end

do
    local ok, changed, found = pcall(SETTINGS.apply, SETTING_ROOTS)
    if not ok then
        warnOnce("settings", "settings could not be read: " .. tostring(changed))
    else
        RUSSIAN_WORDS = wordsInRussian()
        log(TAG .. "settings from " .. SETTINGS.iniPath() .. (found and "" or " (not written yet: defaults)")
            .. (SETTINGS.pluginLoaded() and "" or ", MCM plugin not loaded"))
    end
end

local lastPollWall = nil
local function pollSettings()
    local now = os.clock()
    local dt = lastPollWall and now - lastPollWall or 0
    lastPollWall = now
    local ok, changed = pcall(SETTINGS.poll, dt, SETTING_ROOTS)
    if not ok then warnOnce("settings-poll", "settings poll failed: " .. tostring(changed)) return end
    if changed then applySettingChanges(changed) end
end

safeOn("MyGUI::Gui::eventFrameStart", function(time)
    pollSettings()
    if not CONFIG.enabled then return end
    local ok, err = pcall(frame, time)
    if not ok then
        errors = errors + 1
        warnOnce("frame" .. tostring(err), "frame error: " .. tostring(err))
        if errors > 200 then
            CONFIG.enabled = false
            log(TAG .. "too many errors, damage numbers switched off for this session")
        end
    end
end)

-- ===================================================================================
-- Console commands (KenshiLua console, Ctrl+Shift+L): DamageNumbers.status() / test() / hit(n) / layer("Popup")
-- ===================================================================================
local api = {}
function api.status()
    local okL, layerOfFirst = pcall(function()
        local f = active[1]
        return f and f.widgets[1] and f.widgets[1].layerName
    end)
    local n = 0
    for _ in pairs(watched) do n = n + 1 end
    return string.format("projection=%s screen=%dx%d watched=%d active=%d pooled=%d typicalHeight=%s layer=%s widgetLayer=%s enabled=%s",
        projMode, W, H, n, #active, #freeWidgets, tostring(typicalHeight), CONFIG.layer, tostring(okL and layerOfFirst), tostring(CONFIG.enabled))
end
function api.test()
    spawnTest()
    return api.status()
end
function api.hit(value)
    value = tonumber(value) or 37
    local best, bestD = nil, math.huge
    for key, w in pairs(watched) do
        local c = resolve(w.ref)
        if c then
            local ax, ay, az = anchorOf(c, key)
            local sx, sy = nil, nil
            if ax then sx, sy = project(ax, ay, az) end
            if sx then
                local d = (sx - W * 0.5) ^ 2 + (sy - H * 0.5) ^ 2
                if d < bestD then best, bestD = { ref = w.ref, key = key, sx = sx, sy = sy }, d end
            end
        end
    end
    if best == nil then return "no watched character on screen" end
    spawn(best.ref, best.key, "dmg", value, 0.25, false)
    return string.format("spawned -%d above %s at screen (%.0f, %.0f)", value, best.key, best.sx, best.sy)
end
function api.layer(name)
    CONFIG.layer = tostring(name)
    for _, w in ipairs(freeWidgets) do pcall(function() w:destroy() end) end
    freeWidgets = {}
    return "new widgets will use layer " .. CONFIG.layer
end
-- the live settings tables (for checks from the console)
function api.settings() return CONFIG, COLOURS end
rawset(_G, "DamageNumbers", api)

log(TAG .. "loaded (ffi projection " .. (ffiProj and "ready" or "unavailable") .. ", words " .. (RUSSIAN_WORDS and "ru" or "en") .. ")")
