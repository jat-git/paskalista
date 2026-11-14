-- Paskalista: personal grudge list, shared and merged across your group.
--
-- Every character keeps its own list (SavedVariablesPerCharacter). Entries are
-- linked to the character itself via its GUID (survives renames), plus name,
-- class, race and level. When you are in a group, every member running the
-- addon broadcasts their list and everyone sees the combined list.

local ADDON, ns = ...

local PREFIX     = "PASKA"
local PROTO      = "1"
local FS         = "^"    -- field separator inside an entry
local ES         = "~"    -- entry separator inside a message
local MAX_MSG    = 250    -- addon message hard limit is 255 bytes
local MAX_REASON = 100   -- comment length (bytes)
local MAX_NAME   = 60

ns.PREFIX = PREFIX
ns.MAX_REASON = MAX_REASON
ns.remote = {}            -- [senderFullName] = { [key] = entry }

local db                  -- PaskalistaCharDB
local myFullName
local combinedCache       -- rebuilt lazily
local alerted = {}        -- [guid or lowername] = true, reset when leaving group
local wasInGroup = false

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffff7f00Paskalista:|r " .. tostring(msg))
end
ns.Print = Print

-- Midnight-era API can hand out "secret" values (e.g. unit names inside
-- instances during combat). Addons may not inspect them, so treat as unknown.
local function Readable(v)
    if v == nil then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end
ns.Readable = Readable

local function Trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Byte-limited truncate that never cuts a UTF-8 character in half.
local function Utf8Truncate(s, maxBytes)
    if #s <= maxBytes then return s end
    local out, len = {}, 0
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if len + #ch > maxBytes then break end
        out[#out + 1] = ch
        len = len + #ch
    end
    return table.concat(out)
end

local function Sanitize(s, maxBytes)
    s = tostring(s or "")
    s = s:gsub("[%^~|\r\n\t]", " ")
    return Utf8Truncate(Trim(s), maxBytes or MAX_REASON)
end
ns.Sanitize = Sanitize

local function Split(s, sep)
    local out, start = {}, 1
    while true do
        local i = s:find(sep, start, true)
        if not i then
            out[#out + 1] = s:sub(start)
            return out
        end
        out[#out + 1] = s:sub(start, i - 1)
        start = i + 1
    end
end

local function MyRealm()
    local r = GetNormalizedRealmName and GetNormalizedRealmName()
    if not r or r == "" then
        r = (GetRealmName() or ""):gsub("[%s%-]", "")
    end
    return r
end

local function FullName(name, realm)
    name = Readable(name)
    if not name or name == "" then return nil end
    if name:find("-", 1, true) then return name end
    realm = Readable(realm)
    if not realm or realm == "" then realm = MyRealm() end
    return name .. "-" .. realm
end
ns.FullName = FullName

local function UnitFull(unit)
    local n, r = UnitFullName(unit)
    n = Readable(n)
    if not n or n == "" or n == UNKNOWNOBJECT then return nil end
    return FullName(n, r)
end
ns.UnitFull = UnitFull

local function ShortName(full)
    if not full then return "?" end
    return Ambiguate and Ambiguate(full, "none") or full
end
ns.ShortName = ShortName

local function IsPlayerGUID(guid)
    return type(guid) == "string" and guid:sub(1, 7) == "Player-"
end

function ns.ClassColored(text, classToken)
    local c = classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
    if c and c.colorStr then
        return "|c" .. c.colorStr .. text .. "|r"
    end
    return text
end

function ns.PlayerLink(full, classToken)
    local display = ShortName(full)
    return ns.ClassColored("|Hplayer:" .. full .. "|h[" .. display .. "]|h", classToken)
end

local function KeyFor(guid, name)
    if guid and guid ~= "" then return guid end
    return "N:" .. name:lower()
end

local function MarkDirty()
    combinedCache = nil
    if ns.RefreshUI then ns.RefreshUI() end
    if ns.RefreshMarkers then ns.RefreshMarkers() end
end

---------------------------------------------------------------------------
-- Player info capture ("linking" an entry to a real character)
---------------------------------------------------------------------------

-- Build an info table from a live unit token.
function ns.InfoFromUnit(unit)
    if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then return nil end
    local name = UnitFull(unit)
    if not name then return nil end
    local _, classToken = UnitClass(unit)
    local race = UnitRace(unit)
    local level = UnitLevel(unit)
    return {
        guid  = Readable(UnitGUID(unit)),
        name  = name,
        class = Readable(classToken),
        race  = Readable(race),
        level = Readable(level),
    }
end

-- Build an info table from a GUID (works for anyone the client has cached).
function ns.InfoFromGUID(guid, fallbackName)
    guid = Readable(guid)
    if not IsPlayerGUID(guid) then return nil end
    local _, classToken, _, race, _, name, realm = GetPlayerInfoByGUID(guid)
    name = Readable(name)
    local full = (name and name ~= "") and FullName(name, realm) or fallbackName
    if not full then return nil end
    return { guid = guid, name = full, class = Readable(classToken), race = Readable(race) }
end

-- Try to find a live unit for a full name (group, target, mouseover, focus).
local function FindUnitByName(full)
    local lower = full:lower()
    local units = { "target", "mouseover", "focus" }
    if IsInRaid() then
        for i = 1, 40 do units[#units + 1] = "raid" .. i end
    else
        for i = 1, 4 do units[#units + 1] = "party" .. i end
    end
    for _, u in ipairs(units) do
        if UnitExists(u) and UnitIsPlayer(u) then
            local n = UnitFull(u)
            if n and n:lower() == lower then return u end
        end
    end
end

---------------------------------------------------------------------------
-- Own list
---------------------------------------------------------------------------

local function FindOwn(guid, name)
    if guid and db.entries[guid] then return db.entries[guid], guid end
    if name then
        local lower = name:lower()
        local k = "N:" .. lower
        if db.entries[k] then return db.entries[k], k end
        for key, e in pairs(db.entries) do
            if e.name:lower() == lower then return e, key end
        end
    end
end
ns.FindOwn = FindOwn

local function Serialize(e)
    return table.concat({
        e.guid or "", e.name, e.class or "", e.race or "",
        tostring(e.level or 0), tostring(e.added or 0), e.reason or "",
    }, FS)
end

local function Deserialize(s)
    local f = Split(s, FS)
    if #f < 7 then return nil end
    local name = Sanitize(f[2], MAX_NAME)
    if name == "" then return nil end
    local guid = f[1] ~= "" and f[1] or nil
    if guid and not IsPlayerGUID(guid) then guid = nil end
    local e = {
        guid   = guid,
        name   = name,
        class  = f[3] ~= "" and f[3] or nil,
        race   = f[4] ~= "" and Sanitize(f[4], 30) or nil,
        level  = tonumber(f[5]),
        added  = tonumber(f[6]),
        reason = Sanitize(f[7], MAX_REASON),
    }
    if e.level == 0 then e.level = nil end
    e.key = KeyFor(e.guid, e.name)
    return e
end

-- Forward declarations for comms
local SendMsg, QueueFullSync

-- Add or update an entry in your own list.
-- info: { guid?, name, class?, race?, level? }
function ns.AddEntry(info, reason, replaceComment)
    if not info or not info.name then
        Print("No player to add.")
        return
    end
    if info.name:lower() == (myFullName or ""):lower() then
        Print("You can't put yourself on the list.")
        return
    end
    reason = Sanitize(reason, MAX_REASON)

    local existing, oldKey = FindOwn(info.guid, info.name)
    local e = existing or { added = time() }
    e.guid   = info.guid or e.guid
    e.name   = info.name
    e.class  = info.class or e.class
    e.race   = info.race or e.race
    e.level  = info.level or e.level
    if replaceComment or reason ~= "" or not existing then e.reason = reason end
    e.key    = KeyFor(e.guid, e.name)
    if oldKey and oldKey ~= e.key then
        db.entries[oldKey] = nil
        SendMsg("R" .. oldKey)
    end
    db.entries[e.key] = e

    Print((existing and "Updated " or "Added ") .. ns.PlayerLink(e.name, e.class)
        .. (e.reason ~= "" and (": " .. e.reason) or "")
        .. (e.guid and "" or " |cff999999(not linked yet; will link when seen)|r"))
    SendMsg("A" .. Serialize(e))
    MarkDirty()
end

function ns.RemoveEntry(key)
    local e = db.entries[key]
    if not e then return end
    db.entries[key] = nil
    Print("Removed " .. ns.PlayerLink(e.name, e.class) .. ".")
    SendMsg("R" .. key)
    MarkDirty()
end

function ns.RemoveByName(name)
    local _, key = FindOwn(nil, name)
    if key then ns.RemoveEntry(key) else Print(name .. " is not on your list.") end
end

-- Add by name: resolve to a live unit if possible so the entry gets linked.
function ns.AddByName(name, reason)
    name = Sanitize(name, MAX_NAME)
    if name == "" then return end
    name = name:sub(1, 1):upper() .. name:sub(2)
    local full = FullName(name)
    local unit = FindUnitByName(full)
    local info = unit and ns.InfoFromUnit(unit) or { name = full }
    ns.AddEntry(info, reason)
end

function ns.AddTarget(reason)
    local info = ns.InfoFromUnit("target")
    if not info then
        Print("Target a player first (or give a name).")
        return
    end
    ns.AddEntry(info, reason)
end

-- Called whenever we see a live player unit: keeps linked entries up to date
-- (renames, level, class) and links name-only entries to their GUID.
function ns.TouchUnit(unit)
    if not db or not unit or not UnitIsPlayer(unit) then return end
    local info = ns.InfoFromUnit(unit)
    if not info or not info.guid then return end
    local e, key = FindOwn(info.guid, nil)
    if not e then
        e, key = FindOwn(nil, info.name)
        if e and e.guid and e.guid ~= info.guid then e = nil end  -- different char, same name
    end
    if not e then return end

    local changed = false
    if not e.guid then
        e.guid = info.guid
        db.entries[key] = nil
        e.key = info.guid
        db.entries[e.key] = e
        SendMsg("R" .. key)
        changed = true
        Print("Linked " .. ns.PlayerLink(info.name, info.class) .. " to their character.")
    end
    if e.name ~= info.name then
        Print(ns.PlayerLink(e.name, e.class) .. " is now known as " .. ns.PlayerLink(info.name, info.class) .. ".")
        e.name = info.name
        changed = true
    end
    if info.class and e.class ~= info.class then e.class = info.class; changed = true end
    if info.race and e.race ~= info.race then e.race = info.race; changed = true end
    if info.level and info.level > 0 and e.level ~= info.level then e.level = info.level; changed = true end
    if changed then
        SendMsg("A" .. Serialize(e))
        MarkDirty()
    end
end

function ns.OwnEntries()
    local list = {}
    for _, e in pairs(db.entries) do list[#list + 1] = e end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    return list
end

function ns.MyName() return myFullName end

---------------------------------------------------------------------------
-- Combined (group) list
---------------------------------------------------------------------------

-- Returns array of merged records:
-- { guid, name, class, race, level, sources = { {by, reason, added, own, key} } }
-- plus lookup tables byGuid / byName.
function ns.GetCombined()
    if combinedCache then return combinedCache end
    local list, byGuid, byName = {}, {}, {}

    local function merge(e, by, own)
        local m = (e.guid and byGuid[e.guid]) or byName[e.name:lower()]
        if m and m.guid and e.guid and m.guid ~= e.guid then m = nil end
        if not m then
            m = { sources = {} }
            list[#list + 1] = m
        end
        if e.guid and not m.guid then m.guid = e.guid end
        if own or not m.name then m.name = e.name end
        m.class = m.class or e.class
        m.race  = m.race or e.race
        if e.level and (not m.level or e.level > m.level) then m.level = e.level end
        if m.guid then byGuid[m.guid] = m end
        byName[m.name:lower()] = m
        byName[e.name:lower()] = m
        m.sources[#m.sources + 1] = { by = by, reason = e.reason, added = e.added, own = own, key = e.key }
    end

    for _, e in pairs(db.entries) do merge(e, myFullName, true) end
    for sender, entries in pairs(ns.remote) do
        for _, e in pairs(entries) do merge(e, sender, false) end
    end

    table.sort(list, function(a, b)
        if #a.sources ~= #b.sources then return #a.sources > #b.sources end
        return a.name:lower() < b.name:lower()
    end)
    combinedCache = { list = list, byGuid = byGuid, byName = byName }
    return combinedCache
end

function ns.FindListing(guid, name)
    local c = ns.GetCombined()
    if guid and c.byGuid[guid] then return c.byGuid[guid] end
    if name then
        local m = c.byName[name:lower()]
        -- name match only counts if the record isn't linked to a different character
        if m and (not m.guid or not guid or m.guid == guid) then return m end
    end
end

---------------------------------------------------------------------------
-- Importing other players' entries into your own list
---------------------------------------------------------------------------

-- Copy one remote entry into your own list. Returns true if something was added.
local function ImportOne(e, sender, quiet)
    if myFullName and e.name:lower() == myFullName:lower() then return false end
    if FindOwn(e.guid, e.name) then return false end
    local copy = {
        guid = e.guid, name = e.name, class = e.class, race = e.race, level = e.level,
        reason = e.reason or "", added = time(), via = sender,
    }
    copy.key = KeyFor(copy.guid, copy.name)
    db.entries[copy.key] = copy
    SendMsg("A" .. Serialize(copy))
    if not quiet then
        Print("Copied " .. ns.PlayerLink(copy.name, copy.class) .. " from " .. ShortName(sender) .. "'s list.")
    end
    return true
end

-- Copy a single listing (merged record from the group view) into your list.
function ns.ImportRecord(m)
    if not m then return end
    for _, s in ipairs(m.sources) do
        if s.own then Print(ShortName(m.name) .. " is already on your list."); return end
    end
    local s = m.sources[1]
    local e = s and ns.remote[s.by] and ns.remote[s.by][s.key]
    if e then ImportOne(e, s.by) ; MarkDirty() end
end

-- Copy everything from one group member's list (sender = full name), or from
-- every member when sender is nil.
function ns.ImportFrom(sender)
    local added, senders = 0, 0
    for who, entries in pairs(ns.remote) do
        if not sender or who:lower() == sender:lower() then
            senders = senders + 1
            for _, e in pairs(entries) do
                if ImportOne(e, who, true) then added = added + 1 end
            end
        end
    end
    if sender and senders == 0 then
        Print("No shared list from " .. ShortName(sender) .. " (are they grouped with you and running Paskalista?).")
        return
    end
    Print("Copied " .. added .. " new player(s) into your list" .. (sender and (" from " .. ShortName(sender)) or " from the group") .. ".")
    if added > 0 then MarkDirty() end
end

function ns.Senders()
    local list = {}
    for who, entries in pairs(ns.remote) do
        local n = 0
        for _ in pairs(entries) do n = n + 1 end
        list[#list + 1] = { name = who, count = n }
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

function ns.SharingCount()
    local n = 0
    for _ in pairs(ns.remote) do n = n + 1 end
    return n
end

---------------------------------------------------------------------------
-- Comms
---------------------------------------------------------------------------

local queue = {}
local pumping = false
local R = Enum and Enum.SendAddonMessageResult

local function GroupChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
end

local function Pump()
    if #queue == 0 then pumping = false; return end
    local chan = GroupChannel()
    if not chan then wipe(queue); pumping = false; return end

    -- Midnight/Forever: chat (incl. addon messages) is locked during encounters etc.
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        C_Timer.After(5, Pump)
        return
    end

    local ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, queue[1], chan)
    local delay = 0.3
    if not ok then
        delay = 3                                    -- unexpected error, retry later
    elseif res == true or res == nil or res == 0 or (R and res == R.Success) then
        table.remove(queue, 1)
    elseif R and (res == R.NotInGroup or res == R.InvalidChatType or res == R.InvalidMessage) then
        table.remove(queue, 1)                       -- unrecoverable for this message
    elseif R and res == R.AddOnMessageLockdown then
        delay = 10                                   -- comms locked (encounter/M+); wait it out
    else
        delay = 1.5                                  -- throttled
    end
    C_Timer.After(delay, Pump)
end

SendMsg = function(msg)
    if not GroupChannel() then return end
    queue[#queue + 1] = msg
    if not pumping then
        pumping = true
        C_Timer.After(0.1, Pump)
    end
end

local fullSyncPending = false
QueueFullSync = function()
    if fullSyncPending or not GroupChannel() then return end
    fullSyncPending = true
    C_Timer.After(2 + math.random() * 2, function()   -- jitter avoids everyone bursting at once
        fullSyncPending = false
        if not GroupChannel() then return end
        -- drop stale queued list messages; the full sync supersedes them
        for i = #queue, 1, -1 do
            local t = queue[i]:sub(1, 1)
            if t == "A" or t == "E" or t == "B" or t == "R" then table.remove(queue, i) end
        end
        local entries = ns.OwnEntries()
        SendMsg("B" .. PROTO .. FS .. #entries)
        local buf = "E"
        for _, e in ipairs(entries) do
            local s = Serialize(e)
            if #buf + #s + 1 > MAX_MSG then
                SendMsg(buf)
                buf = "E"
            end
            buf = (buf == "E") and (buf .. s) or (buf .. ES .. s)
        end
        if buf ~= "E" then SendMsg(buf) end
    end)
end
ns.QueueFullSync = QueueFullSync

function ns.RequestSync()
    if not GroupChannel() then
        Print("You are not in a group.")
        return
    end
    SendMsg("H" .. PROTO)
    QueueFullSync()
end

local function OnAddonMessage(prefix, text, channel, sender)
    if Readable(prefix) ~= PREFIX then return end
    text, sender = Readable(text), Readable(sender)
    if not text or not sender or text == "" then return end
    sender = FullName(sender)
    if sender == myFullName then return end

    local t, body = text:sub(1, 1), text:sub(2)
    if t == "H" then
        if body == PROTO then QueueFullSync() end
    elseif t == "B" then
        local f = Split(body, FS)
        if f[1] ~= PROTO then return end
        ns.remote[sender] = {}
    elseif t == "E" or t == "A" then
        local store = ns.remote[sender]
        if not store then store = {}; ns.remote[sender] = store end
        for _, s in ipairs(t == "E" and Split(body, ES) or { body }) do
            local e = Deserialize(s)
            if e then store[e.key] = e end
        end
    elseif t == "R" then
        local store = ns.remote[sender]
        if store then store[body] = nil end
    else
        return
    end
    MarkDirty()
    if ns.ScheduleGroupCheck then ns.ScheduleGroupCheck() end
end

---------------------------------------------------------------------------
-- Group roster tracking & alerts
---------------------------------------------------------------------------

local function GroupUnits()
    local units = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do units[#units + 1] = "raid" .. i end
    else
        for i = 1, GetNumSubgroupMembers() do units[#units + 1] = "party" .. i end
    end
    return units
end

---------------------------------------------------------------------------
-- Party chat announcements: "<Name> is on my paskalista, reason: <comment>"
---------------------------------------------------------------------------

local chatQueue, chatPumping = {}, false

local function ChatPump()
    if #chatQueue == 0 then chatPumping = false; return end
    local chan = GroupChannel()
    if not chan then wipe(chatQueue); chatPumping = false; return end
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        C_Timer.After(5, ChatPump)     -- encounter / M+ lockdown: wait
        return
    end
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    local ok = pcall(send, table.remove(chatQueue, 1), chan)
    C_Timer.After(ok and 1 or 3, ChatPump)
end

local function SayInGroup(text)
    if not GroupChannel() then
        Print("You are not in a group.")
        return
    end
    chatQueue[#chatQueue + 1] = text
    if not chatPumping then
        chatPumping = true
        C_Timer.After(0.5, ChatPump)
    end
end

-- Announce one of YOUR entries to the group.
function ns.Announce(e)
    if not e then return end
    local text = ShortName(e.name) .. " is on my paskalista"
    if e.reason and e.reason ~= "" then
        text = text .. ", reason: " .. e.reason
    else
        text = text .. "."
    end
    SayInGroup(text)
end

function ns.AnnounceByName(name)
    local e = FindOwn(nil, name)
    if e then ns.Announce(e) else Print(ShortName(name) .. " is not on your list.") end
end

-- Announce every player on your list who is currently in the group.
function ns.AnnounceGroup()
    if not IsInGroup() then Print("You are not in a group."); return end
    local n = 0
    for _, u in ipairs(GroupUnits()) do
        if UnitExists(u) and not UnitIsUnit(u, "player") then
            local e = FindOwn(Readable(UnitGUID(u)), UnitFull(u))
            if e then ns.Announce(e); n = n + 1 end
        end
    end
    if n == 0 then Print("Nobody in your group is on your list.") end
end

local checkPending = false
function ns.ScheduleGroupCheck()
    if checkPending then return end
    checkPending = true
    C_Timer.After(1, function()
        checkPending = false
        if not IsInGroup() then return end
        for _, u in ipairs(GroupUnits()) do
            if UnitExists(u) and not UnitIsUnit(u, "player") then
                ns.TouchUnit(u)
                local guid, name = Readable(UnitGUID(u)), UnitFull(u)
                local m = name and ns.FindListing(guid, name)
                local akey = guid or (name and name:lower())
                if m and akey and not alerted[akey] then
                    alerted[akey] = true
                    local who = {}
                    for _, s in ipairs(m.sources) do
                        who[#who + 1] = (s.own and "you" or ShortName(s.by))
                            .. ((s.reason and s.reason ~= "") and (" (" .. s.reason .. ")") or "")
                    end
                    Print("|cffff4040Warning:|r " .. ns.PlayerLink(name, m.class)
                        .. " is in your group. Listed by " .. table.concat(who, ", ") .. ".")
                    PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959, "Master")
                    -- auto-announce our own entries once per group
                    local own = FindOwn(guid, name)
                    if own and db.autoAnnounce ~= false and not db.announced[akey] then
                        db.announced[akey] = true
                        ns.Announce(own)
                    end
                end
            end
        end
    end)
end

local function OnRosterUpdate()
    if not IsInGroup() then
        wipe(db.announced)   -- also clears stale state from logging out in a group
        if wasInGroup then
            wipe(ns.remote)
            wipe(alerted)
            wipe(queue)
            wipe(chatQueue)
            wasInGroup = false
            MarkDirty()
        end
        return
    end

    -- forget lists from people who left
    local present = {}
    for _, u in ipairs(GroupUnits()) do
        local n = UnitFull(u)
        if n then present[n] = true end
    end
    local removed = false
    for sender in pairs(ns.remote) do
        if not present[sender] then ns.remote[sender] = nil; removed = true end
    end
    if removed then MarkDirty() end

    if not wasInGroup then
        -- we just joined (or reloaded in a group): ask for lists and share ours
        wasInGroup = true
        SendMsg("H" .. PROTO)
        QueueFullSync()
    end
    ns.ScheduleGroupCheck()
end

---------------------------------------------------------------------------
-- Tooltip: show listing on player tooltips
---------------------------------------------------------------------------

local function OnUnitTooltip(tt, data)
    if not db or not tt.GetUnit then return end
    local _, unit = tt:GetUnit()
    unit = Readable(unit)
    local guid = data and Readable(data.guid)
    if not guid and unit then guid = Readable(UnitGUID(unit)) end
    if not IsPlayerGUID(guid) then return end
    local name = unit and UnitFull(unit)
    local m = ns.FindListing(guid, name)
    if not m then return end
    if unit then ns.TouchUnit(unit) end
    tt:AddLine("|cffff4040Paskalista|r")
    for _, s in ipairs(m.sources) do
        local who = s.own and "You" or ShortName(s.by)
        local reason = (s.reason and s.reason ~= "") and s.reason or "no comment"
        tt:AddLine("  " .. who .. ": " .. reason, 1, 0.6, 0.6, true)
    end
end

---------------------------------------------------------------------------
-- Right-click menus on players (unit frames, chat names, group, etc.)
---------------------------------------------------------------------------

StaticPopupDialogs["PASKALISTA_REASON"] = {
    text = "Comment on %s\n(e.g. \"stole my loot\"):",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = 1,
    maxLetters = MAX_REASON,
    OnShow = function(self, data)
        local eb = self.GetEditBox and self:GetEditBox() or self.editBox
        eb:SetText((data and data.reason) or "")
        eb:SetFocus()
    end,
    OnAccept = function(self, data)
        local eb = self.GetEditBox and self:GetEditBox() or self.editBox
        if data and data.info then ns.AddEntry(data.info, eb:GetText(), true) end
    end,
    EditBoxOnEnterPressed = function(eb, data)
        local parent = eb:GetParent()
        data = data or parent.data
        if data and data.info then ns.AddEntry(data.info, eb:GetText(), true) end
        parent:Hide()
    end,
    EditBoxOnEscapePressed = function(eb) eb:GetParent():Hide() end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    preferredIndex = 3,
}

function ns.PromptAdd(info)
    if not info or not info.name then return end
    local own = FindOwn(info.guid, info.name)
    StaticPopup_Show("PASKALISTA_REASON", ns.ClassColored(ShortName(info.name), info.class), nil,
        { info = info, reason = own and own.reason })
end

local function InfoFromMenuContext(ctx)
    if not ctx then return nil end
    local unit = Readable(ctx.unit)
    if unit and UnitExists(unit) then
        if not UnitIsPlayer(unit) then return nil end
        return ns.InfoFromUnit(unit)
    end
    local guid
    if ctx.playerLocation and ctx.playerLocation.GetGUID then
        local ok, g = pcall(ctx.playerLocation.GetGUID, ctx.playerLocation)
        if ok then guid = Readable(g) end
    end
    if not guid and ctx.lineID and C_ChatInfo.GetChatLineSenderGUID then
        local ok, g = pcall(C_ChatInfo.GetChatLineSenderGUID, ctx.lineID)
        if ok then guid = Readable(g) end
    end
    guid = guid or Readable(ctx.guid)
    local name = ctx.name and FullName(ctx.name, ctx.server)
    local info = ns.InfoFromGUID(guid, name)
    if info then return info end
    if name then return { name = name, guid = IsPlayerGUID(guid) and guid or nil } end
end

local function SetupMenus()
    if not (Menu and Menu.ModifyMenu) then return end
    local tags = {
        "MENU_UNIT_PLAYER", "MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER", "MENU_UNIT_RAID",
        "MENU_UNIT_TARGET", "MENU_UNIT_FOCUS", "MENU_UNIT_FRIEND", "MENU_UNIT_ENEMY_PLAYER",
        "MENU_UNIT_COMMUNITIES_GUILD_MEMBER", "MENU_UNIT_COMMUNITIES_MEMBER", "MENU_UNIT_GUILD",
    }
    for _, tag in ipairs(tags) do
        Menu.ModifyMenu(tag, function(owner, root, ctx)
            local ok, info = pcall(InfoFromMenuContext, ctx)
            if not ok or not info or not info.name then return end
            if myFullName and info.name:lower() == myFullName:lower() then return end
            root:CreateDivider()
            root:CreateTitle("Paskalista")
            local own, key = FindOwn(info.guid, info.name)
            if own then
                root:CreateButton("Edit comment...", function() ns.PromptAdd(info) end)
                root:CreateButton("Remove from Paskalista", function() ns.RemoveEntry(key) end)
            else
                root:CreateButton("Add to Paskalista...", function() ns.PromptAdd(info) end)
            end
        end)
    end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local function PrintList(records, title)
    Print(title .. " (" .. #records .. ")")
    for _, m in ipairs(records) do
        local parts = {}
        for _, s in ipairs(m.sources) do
            parts[#parts + 1] = (s.own and "you" or ShortName(s.by))
                .. ((s.reason and s.reason ~= "") and (": " .. s.reason) or "")
        end
        DEFAULT_CHAT_FRAME:AddMessage("  " .. ns.PlayerLink(m.name, m.class)
            .. (m.level and (" " .. m.level) or "") .. " - " .. table.concat(parts, "; "))
    end
end

local function Help()
    Print("commands:")
    DEFAULT_CHAT_FRAME:AddMessage("  /paska - open/close the window")
    DEFAULT_CHAT_FRAME:AddMessage("  /paska add [comment] - add your current target")
    DEFAULT_CHAT_FRAME:AddMessage("  /paska addname <Name[-Realm]> [comment] - add by name")
    DEFAULT_CHAT_FRAME:AddMessage("  /paska remove <Name[-Realm]> - remove from your list")
    DEFAULT_CHAT_FRAME:AddMessage("  /paska list - print your list")
    DEFAULT_CHAT_FRAME:AddMessage("  /paska group - print the combined group list")
    DEFAULT_CHAT_FRAME:AddMessage("  /paska sync - re-share lists with your group")
    DEFAULT_CHAT_FRAME:AddMessage("  /paska announce [Name] - say in group chat that a player (or everyone listed in the group) is on your list")
    DEFAULT_CHAT_FRAME:AddMessage("  /paska markers - toggle skull markers on nameplates, unit frames and chat (now: "
        .. (db.markers ~= false and "on" or "off") .. ")")
    DEFAULT_CHAT_FRAME:AddMessage("  /paska auto - toggle automatic group announcement (now: "
        .. (db.autoAnnounce ~= false and "on" or "off") .. ")")
    DEFAULT_CHAT_FRAME:AddMessage("  /paska import <Name> - copy a group member's list into yours")
    DEFAULT_CHAT_FRAME:AddMessage("  /paska import all - copy every shared list into yours")
    DEFAULT_CHAT_FRAME:AddMessage("  Or right-click any player (unit frame / chat name) > Add to Paskalista")
end

SLASH_PASKALISTA1 = "/paska"
SLASH_PASKALISTA2 = "/paskalista"
SLASH_PASKALISTA3 = "/grudge"
SlashCmdList.PASKALISTA = function(msg)
    msg = Trim(msg or "")
    local cmd, rest = msg:match("^(%S+)%s*(.-)$")
    cmd = cmd and cmd:lower() or ""
    if cmd == "" then
        if ns.ToggleUI then ns.ToggleUI() end
    elseif cmd == "add" then
        ns.AddTarget(rest)
    elseif cmd == "addname" then
        local name, reason = rest:match("^(%S+)%s*(.-)$")
        if name then ns.AddByName(name, reason) else Help() end
    elseif cmd == "remove" or cmd == "del" then
        if rest ~= "" then ns.RemoveByName(FullName(rest)) else Help() end
    elseif cmd == "list" then
        local recs = {}
        for _, e in ipairs(ns.OwnEntries()) do
            recs[#recs + 1] = { name = e.name, class = e.class, level = e.level,
                sources = { { own = true, reason = e.reason } } }
        end
        PrintList(recs, "Your list")
    elseif cmd == "group" then
        PrintList(ns.GetCombined().list, "Combined group list, " .. ns.SharingCount() .. " member(s) sharing")
    elseif cmd == "announce" then
        if rest == "" then ns.AnnounceGroup()
        else ns.AnnounceByName(FullName(rest:sub(1, 1):upper() .. rest:sub(2))) end
    elseif cmd == "markers" then
        db.markers = (db.markers == false)
        Print("Markers " .. (db.markers and "ON" or "OFF") .. ".")
        if ns.RefreshMarkers then ns.RefreshMarkers() end
    elseif cmd == "auto" then
        db.autoAnnounce = (db.autoAnnounce == false)
        Print("Automatic group announcement " .. (db.autoAnnounce and "ON" or "OFF") .. ".")
    elseif cmd == "sync" then
        ns.RequestSync()
    elseif cmd == "import" then
        if rest == "" then Help()
        elseif rest:lower() == "all" then ns.ImportFrom(nil)
        else ns.ImportFrom(FullName(rest:sub(1, 1):upper() .. rest:sub(2))) end
    else
        Help()
    end
end

function Paskalista_OnAddonCompartmentClick()
    if ns.ToggleUI then ns.ToggleUI() end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(self, event, a1, a2, a3, a4)
    if event == "ADDON_LOADED" then
        if a1 ~= ADDON then return end
        PaskalistaCharDB = PaskalistaCharDB or {}
        db = PaskalistaCharDB
        db.entries = db.entries or {}
        db.version = 1
        db.announced = db.announced or {}   -- who we've announced in the current group
        ns.db = db
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        if TooltipDataProcessor and Enum.TooltipDataType then
            TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnUnitTooltip)
        end
        SetupMenus()
        self:UnregisterEvent("ADDON_LOADED")
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:RegisterEvent("GROUP_ROSTER_UPDATE")
        self:RegisterEvent("CHAT_MSG_ADDON")
        self:RegisterEvent("PLAYER_TARGET_CHANGED")
        self:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
    elseif event == "PLAYER_ENTERING_WORLD" then
        myFullName = UnitFull("player") or myFullName
        OnRosterUpdate()
    elseif event == "GROUP_ROSTER_UPDATE" then
        OnRosterUpdate()
    elseif event == "CHAT_MSG_ADDON" then
        OnAddonMessage(a1, a2, a3, a4)
    elseif event == "PLAYER_TARGET_CHANGED" then
        ns.TouchUnit("target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        ns.TouchUnit("mouseover")
    end
end)
