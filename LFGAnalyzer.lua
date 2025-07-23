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

    f.aliasLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.aliasLabel:SetPoint("TOPLEFT", 10, -30)
    f.aliasLabel:SetText("Alias=Raid (eine pro Zeile)")

    f.aliasBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.aliasBox:SetMultiLine(true)
    f.aliasBox:SetSize(360, 100)
    f.aliasBox:SetPoint("TOPLEFT", f.aliasLabel, "BOTTOMLEFT", 0, -5)
    f.aliasBox:SetAutoFocus(false)

    f.weeklyLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.weeklyLabel:SetPoint("TOPLEFT", f.aliasBox, "BOTTOMLEFT", 0, -10)
    f.weeklyLabel:SetText("Weekly Schlagworte (eine pro Zeile)")

    f.weeklyBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.weeklyBox:SetMultiLine(true)
    f.weeklyBox:SetSize(360, 60)
    f.weeklyBox:SetPoint("TOPLEFT", f.weeklyLabel, "BOTTOMLEFT", 0, -5)
    f.weeklyBox:SetAutoFocus(false)

    f.saveButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.saveButton:SetSize(80, 22)
    f.saveButton:SetPoint("BOTTOM", 0, 10)
    f.saveButton:SetText("Save")

    f.saveButton:SetScript("OnClick", function()
        local mapping = {}
        for line in string.gmatch(f.aliasBox:GetText() or "", "[^\n]+") do
            local alias, raid = line:match("([^=]+)=(.+)")
            if alias and raid then
                alias = alias:lower():gsub("^%s+", ""):gsub("%s+$", "")
                raid = raid:gsub("^%s+", ""):gsub("%s+$", "")
                if alias ~= "" and raid ~= "" then
                    mapping[alias] = raid
                end
            end
        end
        LFGAnalyzerDB.bossToRaid = mapping
        bossToRaid = mapping

        local weekly = {}
        for line in string.gmatch(f.weeklyBox:GetText() or "", "[^\n]+") do
            local kw = line:lower():gsub("^%s+", ""):gsub("%s+$", "")
            if kw ~= "" then
                table.insert(weekly, kw)
            end
        end
        LFGAnalyzerDB.weekly = weekly
        weeklyKeywords = weekly

        f:Hide()
    end)

    configFrame = f
end

local function toggleConfig()
    createConfigUI()
    if configFrame:IsShown() then
        configFrame:Hide()
    else
        local aliasLines = {}
        for boss, raid in pairs(LFGAnalyzerDB.bossToRaid or {}) do
            table.insert(aliasLines, boss .. "=" .. raid)
        end
        table.sort(aliasLines)
        configFrame.aliasBox:SetText(table.concat(aliasLines, "\n"))
        configFrame.weeklyBox:SetText(table.concat(LFGAnalyzerDB.weekly or {}, "\n"))
        configFrame:Show()
    end
end

local minimapButton
local function updateMinimapButtonPos(angle)
    local radius = (Minimap:GetWidth() / 2) + 10
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function createMinimapButton()
    if minimapButton then return end

    minimapButton = CreateFrame("Button", "LFGAnalyzerMinimapButton", Minimap)
    minimapButton:SetSize(32, 32)
    minimapButton:SetFrameStrata("LOW")
    minimapButton:SetHighlightTexture("Interface/Minimap/UI-Minimap-ZoomButton-Highlight")
    local tex = minimapButton:CreateTexture(nil, "BACKGROUND")
    tex:SetAllPoints()
    tex:SetTexture("Interface/ICONS/INV_Misc_GroupLooking")
    minimapButton.texture = tex

    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapButton:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            toggleConfig()
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
        local msg, sender, _, _, _, _, _, _, _, channelName = ...
        if type(channelName) == "string" and (channelName:lower():match("world") or channelName:lower():match("global")) then
            local timestamp = time()

            if sender == lastSender and (timestamp - lastTimestamp) <= timeout then
                table.insert(buffer, msg)
                lastTimestamp = timestamp
            else
                if lastSender and #buffer > 0 then
                    analyzeMessage(table.concat(buffer, " "), lastSender)
                end
                resetBuffer()
                buffer = { msg }
                lastSender = sender
                lastTimestamp = timestamp
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

            bossToRaid = LFGAnalyzerDB.bossToRaid
            weeklyKeywords = LFGAnalyzerDB.weekly

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
