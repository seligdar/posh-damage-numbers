-- Fake Kenshi/KenshiLua environment for testing damage_numbers.lua outside the game.
LOG = {}
KenshiLua = { log = function(msg) LOG[#LOG + 1] = msg end }

-- hand / lektor -----------------------------------------------------------------
local Hand = {}
Hand.__index = Hand
function Hand.new(ch) return setmetatable({ ch = ch }, Hand) end
function Hand:toString() return "hand:" .. self.ch.id end
function Hand:getCharacter() if self.ch.alive then return self.ch end return nil end

lektor = { new = function(kind)
    assert(kind == "hand")
    local l = {}
    function l:push(h) self[#self + 1] = Hand.new(h.ch) end
    return l
end }

-- characters ----------------------------------------------------------------------
local Char = {}
Char.__index = Char
CHARS = {}
function newChar(id, x, z, player, robot)
    local parts = {}
    for i = 1, 7 do
        parts[i] = { flesh = 100, maxHealth = function() return 100 end }
    end
    local c = setmetatable({ id = id, alive = true, x = x, y = 0, z = z, player = player, robot = robot,
        lying = false, medical = { anatomy = parts } }, Char)
    c.handle = Hand.new(c)
    CHARS[#CHARS + 1] = c
    return c
end
function Char:getPosition() return { x = self.x, y = self.y, z = self.z } end
function Char:getBoneWorldPosition(name)
    if self.robot then error("no such bone") end
    local h = self.lying and 3 or 17
    if name == "Bip01 Head" then h = h - 1 end
    return { x = self.x, y = self.y + h, z = self.z }
end
function Char:isPlayerCharacter() return self.player end
function Char:isDead() return false end
function Char:getMedical() return self.medical end

-- world / camera --------------------------------------------------------------------
local camera = {
    camera = nil,
    getCameraPos = function() return { x = 0, y = 60, z = 120 } end,
    -- like the real game (seen in the log): facing is horizontal, the camera looks at its centre point
    getFacingDirection = function() return { x = 0, y = 0, z = -1 } end,
    getCenter = function() return { x = 0, y = 6, z = 0 } end,
    -- the game's own test: in front of the camera and inside a 45 degree cone
    isVisible = function(self, pos)
        local dx, dy, dz = pos.x - 0, pos.y - 60, pos.z - 120
        local l = math.sqrt(0.45 * 0.45 + 1)
        local d = (dy * -0.45 + dz * -1) / l
        local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
        return d > 0 and d / dist > math.cos(math.rad(35))
    end,
}
local pi = { camera = camera, getCamera = function() return camera end }
function getPlayerInterface() return pi end
function getGameWorld()
    return { player = pi, getCharacterUpdateList = function()
        local set = {}
        for _, c in ipairs(CHARS) do if c.alive then set[c] = true end end
        return set
    end }
end

-- MyGUI -------------------------------------------------------------------------------
-- ImageBox follows MyGUI 3.2 MyGUI_ImageBox.cpp: the tile size is kept from the first rect,
-- items are cut from the rect by the tile, and nothing is drawn without a selected item.
WIDGETS = {}
local ITEM_NONE = -1
local Widget = {}
Widget.__index = Widget
local function rectEmpty(r) return r.r - r.l <= 0 or r.b - r.t <= 0 end
function Widget:_recalcIndexes()
    self.items = {}
    local r, tile = self.rect, self.tile
    if r.r <= r.l or r.b <= r.t then return end
    if tile.w <= 0 or tile.h <= 0 then return end
    local ch, cv = math.floor((r.r - r.l) / tile.w), math.floor((r.b - r.t) / tile.h)
    local y = r.t
    for v = 1, cv do
        local x = r.l
        for h = 1, ch do
            self.items[#self.items + 1] = { x, y, tile.w, tile.h }
            x = x + tile.w
        end
        y = y + tile.h
    end
end
function Widget:_updateSelectIndex(i)
    self.index = i
    if i == ITEM_NONE or i >= #self.items then
        self.drawTexture, self.uv = "", nil
        return
    end
    self.drawTexture, self.uv = self.texture, self.items[i + 1]
end
function Widget:setImageTexture(t)
    self.texture = t
    if #self.items == 0 then
        self.drawTexture, self.uv = t, { 0, 0, 1024, 512 }
    else
        self:_recalcIndexes()
        self:_updateSelectIndex(self.index)
    end
end
function Widget:setImageTile(w, h)
    self.tile = { w = w, h = h }
    if rectEmpty(self.rect) then self.rect = { l = 0, t = 0, r = w, b = h } end
    if self.index == ITEM_NONE then self.index = 0 end
    self:_recalcIndexes()
    self:_updateSelectIndex(self.index)
end
function Widget:setImageCoord(x, y, w, h)
    self.rect = { l = x, t = y, r = x + w, b = y + h }
    if self.tile.w == 0 and self.tile.h == 0 then self.tile = { w = w, h = h } end
    if self.index == ITEM_NONE then self.index = 0 end
    self:_recalcIndexes()
    self:_updateSelectIndex(self.index)
end
function Widget:setImageIndex(i) self:_updateSelectIndex(i) end
function Widget:setNeedMouseFocus() end
function Widget:setInheritsPick() end
function Widget:setVisible(v) self.visible = v end
function Widget:getVisible() return self.visible end
function Widget:getCoord() local c = self.coord or { 0, 0, 0, 0 } return c[1], c[2], c[3], c[4] end
function Widget:setCoord(x, y, w, h)
    assert(x == math.floor(x) and y == math.floor(y), "non-integer coord")
    self.coord = { x, y, w, h }
end
function Widget:setAlpha(a) assert(a >= 0 and a <= 1.0001, "alpha out of range " .. a) self.alpha = a end
function Widget:setColour(c) self.colour = c end
function Widget:destroy() self.destroyed = true end
-- what the player would actually see from this widget: texture rect drawn, or nil
function Widget:drawn()
    if not self.visible or self.destroyed or (self.alpha or 0) <= 0 then return nil end
    if self.drawTexture == nil or self.drawTexture == "" or self.uv == nil then return nil end
    return self.uv
end
MyGUI = {
    getViewSize = function() return 1920, 1200 end,
    createImageBox = function(skin, l, t, w, h, name, layer)
        local wd = setmetatable({ name = name, layerName = layer, items = {}, index = ITEM_NONE,
            rect = { l = 0, t = 0, r = 0, b = 0 }, tile = { w = 0, h = 0 } }, Widget)
        WIDGETS[#WIDGETS + 1] = wd
        return wd
    end,
    Colour = { new = function(r, g, b, a) return { r, g, b, a } end },
}

-- events --------------------------------------------------------------------------------
HANDLERS = {}
Events = { on = function(name, fn) HANDLERS[name] = fn end }

-- simulated wall clock driven by the test
SIM_TIME = 0
os.clock = function() return SIM_TIME end
