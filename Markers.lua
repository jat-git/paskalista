-- Visual markers for players on your or your group's Paskalista.
-- Purely local icons (never raid target marks, which addons may not set
-- automatically under Midnight/Forever rules).
--
-- Shown on: nameplates, target & focus frames, party frames, compact
-- party/raid frames, and in front of their chat messages.

local ADDON, ns = ...

local ICON = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull"
local R, G, B = 1, 0.25, 0.25
local CHAT_ICON = "|T" .. ICON .. ":0:0:0:0:64:64:0:64:0:64:255:64:64|t "

local markers = setmetatable({}, { __mode = "k" })   -- [frame] = texture
local Readable = ns.Readable

local function Enabled()
    return not ns.db or ns.db.markers ~= false
end

local function IsForbidden(f)
    return f and f.IsForbidden and f:IsForbidden()
end

-- Is this unit on anyone's list (own or group)?
function ns.ListingForUnit(unit)
    unit = Readable(unit)
    if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then return nil end
    if UnitIsUnit(unit, "player") then return nil end
    local guid = Readable(UnitGUID(unit))
    local name = ns.UnitFull(unit)
    if not guid and not name then return nil end
    return ns.FindListing(guid, name)
end

local function GetMarker(frame, size, point, relPoint, x, y)
    local tex = markers[frame]
    if not tex then
        tex = frame:CreateTexture(nil, "OVERLAY", nil, 7)
        tex:SetTexture(ICON)
        tex:SetVertexColor(R, G, B)
        markers[frame] = tex
    end
    tex:SetSize(size, size)
    tex:ClearAllPoints()
    tex:SetPoint(point, frame, relPoint, x, y)
    return tex
end

-- Show/hide a marker on `frame` depending on whether `unit` is listed.
local function Apply(frame, unit, size, point, relPoint, x, y)
    if not frame or IsForbidden(frame) then return end
    local listed = Enabled() and unit and ns.ListingForUnit(unit)
    if listed then
        GetMarker(frame, size, point, relPoint, x, y):Show()
    elseif markers[frame] then
        markers[frame]:Hide()
    end
end

---------------------------------------------------------------------------
-- Nameplates
---------------------------------------------------------------------------

local function UpdateNameplate(unit)
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if not plate or IsForbidden(plate) then return end
    Apply(plate, unit, 22, "BOTTOM", "TOP", 0, 4)
end

local function UpdateAllNameplates()
    for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
        if not IsForbidden(plate) then
            local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
            if unit then UpdateNameplate(unit) end
        end
    end
end

---------------------------------------------------------------------------
-- Target / focus frames
---------------------------------------------------------------------------

local function Portrait(frame)
    if not frame then return nil end
    local c = frame.TargetFrameContainer
    return (c and c.Portrait) or frame.portrait or frame.Portrait or frame
end

local function UpdateTarget()
    local p = Portrait(TargetFrame)
    if p then Apply(p, "target", 26, "CENTER", "TOP", 0, 0) end
end

local function UpdateFocus()
    local p = Portrait(FocusFrame)
    if p then Apply(p, "focus", 26, "CENTER", "TOP", 0, 0) end
end

---------------------------------------------------------------------------
-- Party frames & compact party/raid frames
---------------------------------------------------------------------------

local function UpdatePartyFrames()
    if not PartyFrame or IsForbidden(PartyFrame) then return end
    local function upd(f)
        if f and not IsForbidden(f) and f.unit then
            local anchor = f.Portrait or f.portrait or f
            Apply(anchor, f.unit, 18, "CENTER", "TOPLEFT", 4, -4)
        end
    end
    if PartyFrame.PartyMemberFramePool then
        for f in PartyFrame.PartyMemberFramePool:EnumerateActive() do upd(f) end
    else
        for i = 1, 4 do upd(PartyFrame["MemberFrame" .. i]) end
    end
end

local function UpdateCompactFrame(frame)
    if not frame or IsForbidden(frame) then return end
    local unit = Readable(frame.displayedUnit or frame.unit)
    if not unit or unit:find("nameplate", 1, true) then return end  -- nameplates handled above
    Apply(frame, unit, 16, "TOPRIGHT", "TOPRIGHT", -2, -2)
end

local function UpdateAllCompactFrames()
    for _, container in ipairs({ CompactPartyFrame, CompactRaidFrameContainer }) do
        if container and not IsForbidden(container) and container.GetChildren then
            local function walk(f)
                for _, child in ipairs({ f:GetChildren() }) do
                    if not IsForbidden(child) then
                        if child.displayedUnit or child.unit then
                            UpdateCompactFrame(child)
                        else
                            walk(child)
                        end
                    end
                end
            end
            walk(container)
        end
    end
end

---------------------------------------------------------------------------
-- Chat: skull before messages from listed players
---------------------------------------------------------------------------

local function ChatFilterImpl(self, event, msg, author, a3, a4, a5, a6, a7, a8, a9, a10, a11, guid, ...)
    if not Enabled() then return false end
    local m, who, g = Readable(msg), Readable(author), Readable(guid)
    if not m or not who then return false end
    local full = ns.FullName(who)
    if full and ns.MyName() and full:lower() == ns.MyName():lower() then return false end
    if not ns.FindListing(g, full) then return false end
    return false, CHAT_ICON .. m, author, a3, a4, a5, a6, a7, a8, a9, a10, a11, guid, ...
end

-- Never let an error here break the chat frame.
-- (WoW runs Lua 5.1: no table.pack; pass results through varargs instead.)
local function PassResults(ok, ...)
    if not ok then return false end
    return ...
end

local function ChatFilter(...)
    return PassResults(pcall(ChatFilterImpl, ...))
end

local function SetupChat()
    local add = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
    if not add then return end
    for _, e in ipairs({
        "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_WHISPER", "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
        "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER",
        "CHAT_MSG_CHANNEL", "CHAT_MSG_GUILD", "CHAT_MSG_EMOTE",
    }) do
        add(e, ChatFilter)
    end
end

---------------------------------------------------------------------------
-- Refresh plumbing
---------------------------------------------------------------------------

local pending = false
function ns.RefreshMarkers()
    if pending then return end
    pending = true
    C_Timer.After(0.2, function()
        pending = false
        UpdateAllNameplates()
        UpdateTarget()
        UpdateFocus()
        UpdatePartyFrames()
        UpdateAllCompactFrames()
    end)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(self, event, unit)
    if event == "PLAYER_LOGIN" then
        self:RegisterEvent("NAME_PLATE_UNIT_ADDED")
        self:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
        self:RegisterEvent("PLAYER_TARGET_CHANGED")
        self:RegisterEvent("PLAYER_FOCUS_CHANGED")
        self:RegisterEvent("GROUP_ROSTER_UPDATE")
        if CompactUnitFrame_UpdateName then
            hooksecurefunc("CompactUnitFrame_UpdateName", UpdateCompactFrame)
        end
        SetupChat()
        ns.RefreshMarkers()
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        UpdateNameplate(unit)
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        local plate = C_NamePlate.GetNamePlateForUnit(unit)
        if plate and markers[plate] then markers[plate]:Hide() end
    elseif event == "PLAYER_TARGET_CHANGED" then
        UpdateTarget()
    elseif event == "PLAYER_FOCUS_CHANGED" then
        UpdateFocus()
    elseif event == "GROUP_ROSTER_UPDATE" then
        ns.RefreshMarkers()
    end
end)
