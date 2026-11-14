-- Paskalista window: "My list" and "Group" (combined) tabs.

local ADDON, ns = ...

local ROW_H = 22
local frame, scrollBox, tabMine, tabGroup, statusText, importBtn
local currentTab = "mine"

---------------------------------------------------------------------------
-- Data for the list
---------------------------------------------------------------------------

local function BuildItems()
    if currentTab == "mine" then
        local items = {}
        for _, e in ipairs(ns.OwnEntries()) do
            items[#items + 1] = {
                guid = e.guid, name = e.name, class = e.class, race = e.race, level = e.level,
                sources = { { by = ns.MyName(), reason = e.reason, added = e.added, own = true, key = e.key, via = e.via } },
            }
        end
        return items
    end
    return ns.GetCombined().list
end

local function OwnSource(m)
    for _, s in ipairs(m.sources) do
        if s.own then return s end
    end
end

---------------------------------------------------------------------------
-- Row behaviour
---------------------------------------------------------------------------

local function InsertLink(link)
    if ChatEdit_InsertLink then return ChatEdit_InsertLink(link) end
    if ChatFrameUtil and ChatFrameUtil.InsertLink then return ChatFrameUtil.InsertLink(link) end
end

local function Whisper(name)
    if ChatFrame_SendTell then ChatFrame_SendTell(name)
    elseif ChatFrameUtil and ChatFrameUtil.SendTell then ChatFrameUtil.SendTell(name) end
end

local function RowOnEnter(row)
    local m = row.data
    if not m then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(ns.ClassColored(ns.ShortName(m.name), m.class))
    local desc = {}
    if m.level then desc[#desc + 1] = "Level " .. m.level end
    if m.race then desc[#desc + 1] = m.race end
    if m.class then
        desc[#desc + 1] = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[m.class]) or m.class
    end
    if #desc > 0 then GameTooltip:AddLine(table.concat(desc, " "), 1, 1, 1) end
    if m.guid then
        GameTooltip:AddLine("Linked to character", 0.4, 1, 0.4)
    else
        GameTooltip:AddLine("Name only - links automatically when seen", 1, 0.8, 0.2)
    end
    GameTooltip:AddLine(" ")
    for _, s in ipairs(m.sources) do
        local who = s.own and "You" or ns.ShortName(s.by)
        local when = s.added and s.added > 0 and date("%Y-%m-%d", s.added) or ""
        GameTooltip:AddDoubleLine(who, when, 1, 0.82, 0, 0.6, 0.6, 0.6)
        local reason = (s.reason and s.reason ~= "") and s.reason or "no comment"
        if s.via then reason = reason .. " (copied from " .. ns.ShortName(s.via) .. ")" end
        GameTooltip:AddLine("  " .. reason, 1, 0.6, 0.6, true)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click for options. Shift-click to link in chat.", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

local function RowOnLeave() GameTooltip:Hide() end

local function RowOnClick(row)
    local m = row.data
    if not m then return end
    if IsShiftKeyDown() then
        InsertLink("|Hplayer:" .. m.name .. "|h[" .. ns.ShortName(m.name) .. "]|h")
        return
    end
    local own = OwnSource(m)
    MenuUtil.CreateContextMenu(row, function(owner, root)
        root:CreateTitle(ns.ClassColored(ns.ShortName(m.name), m.class))
        root:CreateButton(WHISPER or "Whisper", function() Whisper(m.name) end)
        root:CreateButton("Print link in chat", function()
            ns.Print(ns.PlayerLink(m.name, m.class))
        end)
        if own then
            root:CreateButton("Edit comment...", function()
                ns.PromptAdd({ guid = m.guid, name = m.name, class = m.class, race = m.race, level = m.level })
            end)
            if IsInGroup() then
                root:CreateButton("Announce in group chat", function()
                    ns.Announce(ns.FindOwn(m.guid, m.name))
                end)
            end
            root:CreateButton("|cffff4040Remove from my list|r", function() ns.RemoveEntry(own.key) end)
        else
            root:CreateButton("Copy to my list", function() ns.ImportRecord(m) end)
            root:CreateButton("Add my comment...", function()
                ns.PromptAdd({ guid = m.guid, name = m.name, class = m.class, race = m.race, level = m.level })
            end)
        end
    end)
end

local function InitRow(row, m)
    if not row.init then
        row:SetHeight(ROW_H)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)

        row.stripe = row:CreateTexture(nil, "BACKGROUND")
        row.stripe:SetAllPoints()
        row.stripe:SetColorTexture(1, 1, 1, 0.03)

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.name:SetPoint("LEFT", 6, 0)
        row.name:SetWidth(150)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)

        row.info = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.info:SetPoint("LEFT", 160, 0)
        row.info:SetWidth(40)
        row.info:SetJustifyH("LEFT")

        row.by = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.by:SetPoint("LEFT", 205, 0)
        row.by:SetWidth(130)
        row.by:SetJustifyH("LEFT")
        row.by:SetWordWrap(false)

        row.reason = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.reason:SetPoint("LEFT", 340, 0)
        row.reason:SetPoint("RIGHT", -6, 0)
        row.reason:SetJustifyH("LEFT")
        row.reason:SetWordWrap(false)
        row.reason:SetTextColor(1, 0.7, 0.7)

        row:SetScript("OnEnter", RowOnEnter)
        row:SetScript("OnLeave", RowOnLeave)
        row:SetScript("OnClick", RowOnClick)
        row.init = true
    end

    row.data = m
    local linked = m.guid and "" or " |cffffcc33*|r"
    row.name:SetText(ns.ClassColored(ns.ShortName(m.name), m.class) .. linked)
    row.info:SetText(m.level and tostring(m.level) or "?")

    local who = {}
    for _, s in ipairs(m.sources) do
        who[#who + 1] = s.own and "|cff66ff66You|r" or ns.ShortName(s.by)
    end
    row.by:SetText(table.concat(who, ", "))

    local reasons = {}
    for _, s in ipairs(m.sources) do
        if s.reason and s.reason ~= "" then reasons[#reasons + 1] = s.reason end
    end
    row.reason:SetText(table.concat(reasons, " | "))
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

function ns.RefreshUI()
    if not frame or not frame:IsShown() then return end
    local items = BuildItems()
    scrollBox:SetDataProvider(CreateDataProvider(items), ScrollBoxConstants.RetainScrollPosition)

    tabMine:SetEnabled(currentTab ~= "mine")
    tabGroup:SetEnabled(currentTab ~= "group")
    importBtn:SetShown(currentTab == "group")

    local sharing = ns.SharingCount()
    if currentTab == "mine" then
        statusText:SetText(#items .. " player(s) on your list")
    elseif not IsInGroup() then
        statusText:SetText("Not in a group - showing only your list")
    else
        statusText:SetText(#items .. " player(s), " .. sharing .. " group member(s) sharing")
    end
    importBtn:SetEnabled(sharing > 0)
    frame.announceBtn:SetEnabled(IsInGroup())
end

---------------------------------------------------------------------------
-- Frame construction
---------------------------------------------------------------------------

local function MakeButton(parent, text, width)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    return b
end

local function MakeEditBox(parent, width, maxLetters)
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(width, 20)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(maxLetters)
    eb:SetScript("OnEscapePressed", eb.ClearFocus)
    return eb
end

local function Build()
    frame = CreateFrame("Frame", "PaskalistaFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(680, 440)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    frame:SetFrameStrata("HIGH")
    frame:SetScript("OnShow", ns.RefreshUI)
    tinsert(UISpecialFrames, "PaskalistaFrame")  -- close with Escape

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", 0, -5)
    frame.title:SetText("Paskalista")

    -- Tabs
    tabMine = MakeButton(frame, "My list", 100)
    tabMine:SetPoint("TOPLEFT", 12, -30)
    tabMine:SetScript("OnClick", function() currentTab = "mine"; ns.RefreshUI() end)

    tabGroup = MakeButton(frame, "Group", 100)
    tabGroup:SetPoint("LEFT", tabMine, "RIGHT", 4, 0)
    tabGroup:SetScript("OnClick", function() currentTab = "group"; ns.RefreshUI() end)

    local syncBtn = MakeButton(frame, "Sync", 70)
    syncBtn:SetPoint("TOPRIGHT", -12, -30)
    syncBtn:SetScript("OnClick", function() ns.RequestSync() end)

    importBtn = MakeButton(frame, "Copy lists...", 110)
    importBtn:SetPoint("RIGHT", syncBtn, "LEFT", -4, 0)
    importBtn:SetScript("OnClick", function(self)
        MenuUtil.CreateContextMenu(self, function(owner, root)
            root:CreateTitle("Copy into my list")
            root:CreateButton("Everyone's lists", function() ns.ImportFrom(nil) end)
            root:CreateDivider()
            for _, s in ipairs(ns.Senders()) do
                root:CreateButton(ns.ShortName(s.name) .. " (" .. s.count .. ")", function()
                    ns.ImportFrom(s.name)
                end)
            end
        end)
    end)

    local announceBtn = MakeButton(frame, "Announce", 90)
    announceBtn:SetPoint("RIGHT", importBtn, "LEFT", -4, 0)
    announceBtn:SetScript("OnClick", function() ns.AnnounceGroup() end)
    announceBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Announce in group chat")
        GameTooltip:AddLine("Says \"<Name> is on my paskalista, reason: ...\" for everyone on your list who is in your group.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    announceBtn:SetScript("OnLeave", GameTooltip_Hide)
    frame.announceBtn = announceBtn

    statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    statusText:SetPoint("LEFT", tabGroup, "RIGHT", 10, 0)
    statusText:SetPoint("RIGHT", announceBtn, "LEFT", -6, 0)
    statusText:SetJustifyH("LEFT")

    -- Column headers
    local function Header(text, x)
        local h = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetPoint("TOPLEFT", 12 + x, -60)
        h:SetText(text)
    end
    Header("Name", 6)
    Header("Lvl", 160)
    Header("Listed by", 205)
    Header("Comment", 340)

    -- Scrolling list
    scrollBox = CreateFrame("Frame", nil, frame, "WowScrollBoxList")
    scrollBox:SetPoint("TOPLEFT", 12, -74)
    scrollBox:SetPoint("BOTTOMRIGHT", -30, 46)

    local scrollBar = CreateFrame("EventFrame", nil, frame, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 6, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 6, 0)

    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_H)
    view:SetElementInitializer("Button", InitRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

    -- Add bar
    local nameLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLabel:SetPoint("BOTTOMLEFT", 16, 18)
    nameLabel:SetText("Name:")

    local nameBox = MakeEditBox(frame, 140, 60)
    nameBox:SetPoint("LEFT", nameLabel, "RIGHT", 10, 0)

    local reasonLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    reasonLabel:SetPoint("LEFT", nameBox, "RIGHT", 10, 0)
    reasonLabel:SetText("Comment:")

    local reasonBox = MakeEditBox(frame, 250, ns.MAX_REASON)
    reasonBox:SetPoint("LEFT", reasonLabel, "RIGHT", 10, 0)

    local addBtn = MakeButton(frame, "Add", 70)
    addBtn:SetPoint("LEFT", reasonBox, "RIGHT", 8, 0)

    local function DoAdd()
        local name = strtrim(nameBox:GetText() or "")
        local reason = reasonBox:GetText() or ""
        if name == "" then
            ns.AddTarget(reason)
        else
            ns.AddByName(name, reason)
        end
        nameBox:SetText("")
        reasonBox:SetText("")
        nameBox:ClearFocus()
        reasonBox:ClearFocus()
    end
    addBtn:SetScript("OnClick", DoAdd)
    addBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Add to your list")
        GameTooltip:AddLine("Leave Name empty to add your current target.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    addBtn:SetScript("OnLeave", GameTooltip_Hide)
    nameBox:SetScript("OnEnterPressed", function() reasonBox:SetFocus() end)
    nameBox:SetScript("OnTabPressed", function() reasonBox:SetFocus() end)
    reasonBox:SetScript("OnEnterPressed", DoAdd)
    reasonBox:SetScript("OnTabPressed", function() nameBox:SetFocus() end)

    frame:Hide()
end

function ns.ToggleUI()
    if not frame then Build() end
    frame:SetShown(not frame:IsShown())
end
