local LFGAnalyzer = CreateFrame("Frame")
LFGAnalyzer:RegisterEvent("CHAT_MSG_CHANNEL")
LFGAnalyzer:RegisterEvent("ADDON_LOADED")

-- gespeicherte Einträge für die UI
local entries = {}

local buffer = {}
local lastSender = nil
local lastTimestamp = 0
local timeout = 5 -- Sekunden

-- Saved variables
local bossToRaid = {}
local weeklyKeywords = {}
local enabled = true
local debugEnabled = false

local function debugPrint(msg)
    if debugEnabled then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff8800[LFGAnalyzer Debug]|r " .. msg)
    end
end

-- forward declarations for functions used before definition
local toggleUI

-- Mapping bestimmter Bossnamen auf ihre Raids (geladen aus SavedVariables)
local bossToRaid = {}

-- extrahiert Rolleninformatioen aus einer Nachricht
local function parseRoles(msg)
    local roles = { tank = 0, heal = 0, dps = 0, ranged = 0, melee = 0 }
    local n

    n = tonumber(msg:match("(%d+)%s*tanks?"))
    if n then roles.tank = n elseif msg:match("tank") then roles.tank = 1 end

    n = tonumber(msg:match("(%d+)%s*heals?")) or tonumber(msg:match("(%d+)%s*heiler"))
    if n then roles.heal = n elseif msg:match("heal") or msg:match("heiler") then roles.heal = 1 end

    n = tonumber(msg:match("(%d+)%s*dps")) or tonumber(msg:match("(%d+)%s*dds?"))
    if n then roles.dps = n elseif msg:match("dps") or msg:match("dd") then roles.dps = 1 end

    if msg:match("range") or msg:match("rdd") then roles.ranged = roles.dps end
    if msg:match("melee") or msg:match("mdd") then roles.melee = roles.dps end

    return roles
end

local function updateEntry(sender, raids, roles, text)
    local entry = entries[sender]
    if not entry then
        entry = { sender = sender }
        entries[sender] = entry
    end

    entry.raids = table.concat(raids, ", ")
    entry.roles = roles
    entry.text = text
    entry.time = time()

    if LFGAnalyzer.frame and LFGAnalyzer.frame:IsShown() then
        LFGAnalyzer.refreshUI()
    end
end

local function resetBuffer()
    buffer = {}
    lastSender = nil
    lastTimestamp = 0
end

-- UI erstellen
local function createUI()
    if LFGAnalyzer.frame then return end

    -- Compatibility: BackdropTemplate exists only in later client versions
    local f = CreateFrame("Frame", "LFGAnalyzerFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(400, 200)
    f:SetPoint("CENTER")
    f:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background" })
    f:SetBackdropColor(0, 0, 0, 0.8)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.title:SetPoint("TOP", 0, -10)
    f.title:SetText("LFG Analyzer")

    f.rows = {}
    f:Hide()

    LFGAnalyzer.frame = f
end

local configFrame
local function createConfigUI()
    if configFrame then return end

    local f = CreateFrame("Frame", "LFGAnalyzerConfigFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(400, 300)
    f:SetPoint("CENTER")
    f:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background" })
    f:SetBackdropColor(0, 0, 0, 0.8)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.title:SetPoint("TOP", 0, -10)
    f.title:SetText("LFG Analyzer Config")

    f.scrollFrame = CreateFrame("ScrollFrame", "LFGAnalyzerConfigScrollFrame", f, "UIPanelScrollFrameTemplate")
    f.scrollFrame:SetPoint("TOPLEFT", 10, -30)
    f.scrollFrame:SetPoint("BOTTOMRIGHT", -30, 40)

    -- The UIPanelScrollFrameTemplate expects a named child frame called
    -- <ScrollFrameName>ScrollChildFrame during its OnLoad handler. Without this
    -- named child, the template's setup triggers an error in older clients.
    -- Create the content frame with the expected name so the template can find
    -- it immediately.
    local content = CreateFrame(
        "Frame",
        "LFGAnalyzerConfigScrollFrameScrollChildFrame",
        f.scrollFrame
    )
    content:SetSize(360, 1)
    content:SetPoint("TOPLEFT")
    f.scrollFrame:SetScrollChild(content)
    f.content = content

    f.enableCheck = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    f.enableCheck:SetPoint("TOPLEFT")
    f.enableCheck.text = f.enableCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.enableCheck.text:SetPoint("LEFT", f.enableCheck, "RIGHT", 0, 0)
    f.enableCheck.text:SetText("Enable")

    f.debugCheck = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    f.debugCheck:SetPoint("TOPLEFT", f.enableCheck, "BOTTOMLEFT", 0, -5)
    f.debugCheck.text = f.debugCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.debugCheck.text:SetPoint("LEFT", f.debugCheck, "RIGHT", 0, 0)
    f.debugCheck.text:SetText("Debug")

    f.aliasHeader = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.aliasHeader:SetPoint("TOPLEFT", f.debugCheck, "BOTTOMLEFT", 0, -10)
    f.aliasHeader:SetText("Alias Zuordnungen")

    f.aliasHeaderAlias = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.aliasHeaderAlias:SetPoint("TOPLEFT", f.aliasHeader, "BOTTOMLEFT", 0, -5)
    f.aliasHeaderAlias:SetWidth(150)
    f.aliasHeaderAlias:SetText("Alias")
    f.aliasHeaderRaid = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.aliasHeaderRaid:SetPoint("LEFT", f.aliasHeaderAlias, "RIGHT", 10, 0)
    f.aliasHeaderRaid:SetWidth(150)
    f.aliasHeaderRaid:SetText("Raid")

    f.aliasEntries = {}
    f.aliasRows = {}
    f.aliasContainer = CreateFrame("Frame", nil, content)
    f.aliasContainer:SetPoint("TOPLEFT", f.aliasHeaderRaid, "BOTTOMLEFT", 0, -5)
    f.aliasContainer:SetSize(360, 1)

    local function refreshAliasList()
        for _, row in ipairs(f.aliasRows) do
            row:Hide()
        end

        local index = 0
        for alias, raid in pairs(f.aliasEntries) do
            index = index + 1
            local row = f.aliasRows[index]
            if not row then
                row = CreateFrame("Frame", nil, content)
                row:SetSize(360, 20)
                if index == 1 then
                    row:SetPoint("TOPLEFT", f.aliasContainer, "TOPLEFT")
                else
                    row:SetPoint("TOPLEFT", f.aliasRows[index-1], "BOTTOMLEFT", 0, -2)
                end
                row.alias = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                row.alias:SetPoint("LEFT")
                row.alias:SetWidth(150)
                row.alias:SetJustifyH("LEFT")
                row.raid = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                row.raid:SetPoint("LEFT", row.alias, "RIGHT", 10, 0)
                row.raid:SetWidth(150)
                row.raid:SetJustifyH("LEFT")
                row.remove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                row.remove:SetSize(20, 20)
                row.remove:SetText("-")
                row.remove:SetPoint("RIGHT")
                f.aliasRows[index] = row
            end
            row.alias:SetText(alias)
            row.raid:SetText(raid)
            row.remove:SetScript("OnClick", function()
                f.aliasEntries[alias] = nil
                refreshAliasList()
            end)
            row:Show()
        end

        local row = f.newAliasRow
        if not row then
            row = CreateFrame("Frame", nil, content)
            row:SetSize(360, 20)
            row.aliasEdit = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
            row.aliasEdit:SetSize(150, 20)
            row.aliasEdit:SetAutoFocus(false)
            row.aliasEdit:SetPoint("LEFT")
            row.aliasEdit:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background" })
            row.aliasEdit:SetBackdropColor(0, 0, 0, 0.5)

            row.raidEdit = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
            row.raidEdit:SetSize(150, 20)
            row.raidEdit:SetAutoFocus(false)
            row.raidEdit:SetPoint("LEFT", row.aliasEdit, "RIGHT", 10, 0)
            row.raidEdit:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background" })
            row.raidEdit:SetBackdropColor(0, 0, 0, 0.5)
            row.add = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.add:SetSize(20, 20)
            row.add:SetText("+")
            row.add:SetPoint("LEFT", row.raidEdit, "RIGHT", 10, 0)
            row.add:SetScript("OnClick", function()
                local alias = row.aliasEdit:GetText():lower():gsub("^%s+", ""):gsub("%s+$", "")
                local raid = row.raidEdit:GetText():gsub("^%s+", ""):gsub("%s+$", "")
                if alias ~= "" and raid ~= "" then
                    f.aliasEntries[alias] = raid
                    row.aliasEdit:SetText("")
                    row.raidEdit:SetText("")
                    refreshAliasList()
                end
            end)
            f.newAliasRow = row
        end

        if index == 0 then
            row:SetPoint("TOPLEFT", f.aliasContainer, "TOPLEFT")
        else
            row:SetPoint("TOPLEFT", f.aliasRows[index], "BOTTOMLEFT", 0, -5)
        end
        row:Show()

        f.weeklyHeader:SetPoint("TOPLEFT", row, "BOTTOMLEFT", 0, -10)
        f.weeklyContainer:SetPoint("TOPLEFT", f.weeklyHeader, "BOTTOMLEFT", 0, -5)
        refreshWeeklyList()
    end

    f.refreshAliasList = refreshAliasList

    f.weeklyHeader = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.weeklyHeader:SetPoint("TOPLEFT", f.aliasContainer, "BOTTOMLEFT", 0, -10)
    f.weeklyHeader:SetText("Weekly Schlagworte")

    f.weeklyEntries = {}
    f.weeklyRows = {}
    f.weeklyContainer = CreateFrame("Frame", nil, content)
    f.weeklyContainer:SetPoint("TOPLEFT", f.weeklyHeader, "BOTTOMLEFT", 0, -5)
    f.weeklyContainer:SetSize(360, 1)

    local function refreshWeeklyList()
        for _, row in ipairs(f.weeklyRows) do row:Hide() end

        local index = 0
        for i, kw in ipairs(f.weeklyEntries) do
            index = index + 1
            local row = f.weeklyRows[index]
            if not row then
                row = CreateFrame("Frame", nil, content)
                row:SetSize(360, 20)
                if index == 1 then
                    row:SetPoint("TOPLEFT", f.weeklyContainer, "TOPLEFT")
                else
                    row:SetPoint("TOPLEFT", f.weeklyRows[index-1], "BOTTOMLEFT", 0, -2)
                end
                row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                row.text:SetPoint("LEFT")
                row.remove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                row.remove:SetSize(20, 20)
                row.remove:SetText("-")
                row.remove:SetPoint("RIGHT")
                f.weeklyRows[index] = row
            end
            row.text:SetText(kw)
            row.remove:SetScript("OnClick", function()
                table.remove(f.weeklyEntries, i)
                refreshWeeklyList()
            end)
            row:Show()
        end

        local row = f.newWeeklyRow
        if not row then
            row = CreateFrame("Frame", nil, content)
            row:SetSize(360, 20)
            row.edit = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
            row.edit:SetSize(120, 20)
            row.edit:SetAutoFocus(false)
            row.edit:SetPoint("LEFT")
            row.edit:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background" })
            row.edit:SetBackdropColor(0, 0, 0, 0.5)
            row.add = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.add:SetSize(20, 20)
            row.add:SetText("+")
            row.add:SetPoint("LEFT", row.edit, "RIGHT", 10, 0)
            row.add:SetScript("OnClick", function()
                local kw = row.edit:GetText():lower():gsub("^%s+", ""):gsub("%s+$", "")
                if kw ~= "" then
                    table.insert(f.weeklyEntries, kw)
                    row.edit:SetText("")
                    refreshWeeklyList()
                end
            end)
            f.newWeeklyRow = row
        end

        if index == 0 then
            row:SetPoint("TOPLEFT", f.weeklyContainer, "TOPLEFT")
        else
            row:SetPoint("TOPLEFT", f.weeklyRows[index], "BOTTOMLEFT", 0, -5)
        end
        row:Show()
        local height = math.abs(row:GetBottom() or 0) + 30
        content:SetHeight(height)
    end

    f.refreshWeeklyList = refreshWeeklyList

    f.saveButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.saveButton:SetSize(80, 22)
    f.saveButton:SetPoint("BOTTOM", 0, 10)
    f.saveButton:SetText("Save")

    f.saveButton:SetScript("OnClick", function()
        local mapping = {}
        for alias, raid in pairs(f.aliasEntries) do
            mapping[alias] = raid
        end
        LFGAnalyzerDB.bossToRaid = mapping
        bossToRaid = mapping

        local weekly = {}
        for _, kw in ipairs(f.weeklyEntries) do
            table.insert(weekly, kw)
        end
        LFGAnalyzerDB.weekly = weekly
        weeklyKeywords = weekly

        LFGAnalyzerDB.enabled = f.enableCheck:GetChecked()
        enabled = LFGAnalyzerDB.enabled
        LFGAnalyzerDB.debug = f.debugCheck:GetChecked()
        debugEnabled = LFGAnalyzerDB.debug

        f:Hide()
    end)

    configFrame = f
end

local function toggleConfig()
    createConfigUI()
    if configFrame:IsShown() then
        configFrame:Hide()
    else
        for k in pairs(configFrame.aliasEntries) do
            configFrame.aliasEntries[k] = nil
        end
        for boss, raid in pairs(LFGAnalyzerDB.bossToRaid or {}) do
            configFrame.aliasEntries[boss] = raid
        end
        configFrame.refreshAliasList()
        configFrame.weeklyEntries = {}
        for _, kw in ipairs(LFGAnalyzerDB.weekly or {}) do
            table.insert(configFrame.weeklyEntries, kw)
        end
        configFrame.refreshWeeklyList()
        configFrame.enableCheck:SetChecked(LFGAnalyzerDB.enabled)
        configFrame.debugCheck:SetChecked(LFGAnalyzerDB.debug)
        configFrame:Show()
    end
end

local minimapButton
local menuFrame
local function updateMinimapButtonPos(angle)
    local radius = (Minimap:GetWidth() / 2) + 10
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function createMinimapButton()
    if minimapButton then return end

    minimapButton = CreateFrame("Button", "LFGAnalyzerMinimapButton", Minimap)
    minimapButton:SetSize(31, 31)
    minimapButton:SetFrameStrata("LOW")
    minimapButton:SetHighlightTexture("Interface/Minimap/UI-Minimap-ZoomButton-Highlight")

    -- Hintergrund und Umrandung wie andere Minimap-Buttons
    local background = minimapButton:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetTexture("Interface/Minimap/UI-Minimap-Background")
    background:SetPoint("TOPLEFT", 7, -5)
    minimapButton.background = background

    local icon = minimapButton:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetTexture("Interface/ICONS/INV_Misc_GroupLooking")
    icon:SetPoint("TOPLEFT", 7, -6)
    minimapButton.icon = icon

    local overlay = minimapButton:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface/Minimap/MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")
    minimapButton.overlay = overlay

    menuFrame = CreateFrame("Frame", "LFGAnalyzerMenuFrame", UIParent, "UIDropDownMenuTemplate")

    local menuList = {
        { text = "LFG Analyzer", isTitle = true, notCheckable = true },
        { text = "Show Window", func = toggleUI, notCheckable = true },
        { text = "Config", func = toggleConfig, notCheckable = true },
        {
            text = "Debug",
            func = function()
                debugEnabled = not debugEnabled
                LFGAnalyzerDB.debug = debugEnabled
            end,
            checked = function() return debugEnabled end,
            keepShownOnClick = true,
        },
    }

    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapButton:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            EasyMenu(menuList, menuFrame, "cursor", 0 , 0, "MENU")
        else
            toggleUI()
        end
    end)

    minimapButton:SetMovable(true)
    minimapButton:EnableMouse(true)
    minimapButton:RegisterForDrag("LeftButton")
    minimapButton:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local x, y = GetCursorPosition()
            local scale = UIParent:GetScale()
            x, y = x / scale, y / scale
            local angle = math.atan2(y - my, x - mx)
            LFGAnalyzerDB.minimap.angle = angle
            updateMinimapButtonPos(angle)
        end)
    end)
    minimapButton:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    updateMinimapButtonPos(LFGAnalyzerDB.minimap.angle or 0)
end

function LFGAnalyzer.refreshUI()
    createUI()
    local f = LFGAnalyzer.frame

    for _, row in ipairs(f.rows) do
        row:Hide()
    end

    local index = 0
    for _, entry in pairs(entries) do
        index = index + 1
        local row = f.rows[index]
        if not row then
            row = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row:SetPoint("TOPLEFT", 10, -20 - (index - 1) * 15)
            f.rows[index] = row
        end
        local r = entry.roles or {}
        row:SetText(string.format("%s | %s | T:%d H:%d DD:%d", entry.sender, entry.raids or "", r.tank or 0, r.heal or 0, r.dps or 0))
        row:Show()
    end
end

function toggleUI()
    createUI()
    if LFGAnalyzer.frame:IsShown() then
        LFGAnalyzer.frame:Hide()
    else
        LFGAnalyzer.refreshUI()
        LFGAnalyzer.frame:Show()
    end
end

local function analyzeMessage(fullMessage, sender)
    debugPrint("Analyzing message from " .. sender .. ": " .. fullMessage)
    local lower = fullMessage:lower()
    local results = {}
    local roles = parseRoles(lower)

    if lower:match("lfm") or lower:match("suche") or lower:match("suchen") then
        if lower:match("icc") then table.insert(results, "ICC") end
        if lower:match("toc") then table.insert(results, "ToC") end
        if lower:match("voa") then table.insert(results, "VoA") end
        for _, kw in ipairs(weeklyKeywords) do
            if lower:match(kw) then
                table.insert(results, "Weekly")
                break
            end
        end
        if roles.dps > 0 then table.insert(results, "DPS gesucht") end
        if roles.tank > 0 then table.insert(results, "Tank gesucht") end
        if roles.heal > 0 then table.insert(results, "Healer gesucht") end

        -- Suche nach Bossnamen
        for boss, raid in pairs(bossToRaid) do
            if lower:match(boss) then
                table.insert(results, raid)
                break
            end
        end
    end

    if #results > 0 then
        debugPrint("Match found: " .. table.concat(results, ", "))
        DEFAULT_CHAT_FRAME:AddMessage(
            string.format("|cff00ff00[Analyzer]|r %s sucht: %s", sender, table.concat(results, ", "))
        )
        updateEntry(sender, results, roles, fullMessage)
    end
end

-- WoW 3.3.5 passes the channel base name as the 9th argument of CHAT_MSG_CHANNEL
-- After the message and sender parameters. Earlier versions may differ, so we
-- use a variable number of placeholders to reach that argument.
LFGAnalyzer:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_CHANNEL" then
        if not enabled then return end
        local msg, sender, _, _, _, _, _, _, _, channelName = ...
        if type(channelName) == "string" and (channelName:lower():match("world") or channelName:lower():match("global")) then
            local timestamp = time()

            if sender == lastSender and (timestamp - lastTimestamp) <= timeout then
                table.insert(buffer, msg)
                debugPrint("Buffering message from " .. sender)
                lastTimestamp = timestamp
            else
                if lastSender and #buffer > 0 then
                    analyzeMessage(table.concat(buffer, " "), lastSender)
                end
                resetBuffer()
                buffer = { msg }
                lastSender = sender
                lastTimestamp = timestamp
                debugPrint("New message sequence from " .. sender)
            end
        end
    elseif event == "ADDON_LOADED" then
        local addon = ...
        if addon == "LFGAnalyzer" then
            LFGAnalyzerDB = LFGAnalyzerDB or {}
            LFGAnalyzerDB.bossToRaid = LFGAnalyzerDB.bossToRaid or {
                ["noth der seuchenfürst"] = "Naxxramas",
                ["noth the plaguebringer"] = "Naxxramas",
                ["lord mark'gar"] = "ICC"
            }
            LFGAnalyzerDB.weekly = LFGAnalyzerDB.weekly or { "weekly", "muss sterben" }
            LFGAnalyzerDB.minimap = LFGAnalyzerDB.minimap or { angle = 0 }
            LFGAnalyzerDB.enabled = (LFGAnalyzerDB.enabled ~= false)
            LFGAnalyzerDB.debug = LFGAnalyzerDB.debug or false

            bossToRaid = LFGAnalyzerDB.bossToRaid
            weeklyKeywords = LFGAnalyzerDB.weekly
            enabled = LFGAnalyzerDB.enabled
            debugEnabled = LFGAnalyzerDB.debug

            createMinimapButton()
        end
    end
end)

-- Cleanup on logout or reload
SLASH_LFGANALYZER1 = "/lfganalyzer"
SlashCmdList["LFGANALYZER"] = function(msg)
    if lastSender and #buffer > 0 then
        analyzeMessage(table.concat(buffer, " "), lastSender)
    end
    resetBuffer()
    if msg and msg:lower() == "config" then
        toggleConfig()
    else
        toggleUI()
    end
end
