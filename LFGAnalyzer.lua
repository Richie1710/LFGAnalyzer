local LFGAnalyzer = CreateFrame("Frame")
LFGAnalyzer:RegisterEvent("CHAT_MSG_CHANNEL")

-- gespeicherte Einträge für die UI
local entries = {}

local buffer = {}
local lastSender = nil
local lastTimestamp = 0
local timeout = 5 -- Sekunden

-- Mapping bestimmter Bossnamen auf ihre Raids
local bossToRaid = {
    ["noth der seuchenfürst"] = "Naxxramas",
    ["noth the plaguebringer"] = "Naxxramas",
    ["lord mark'gar"] = "ICC"
}

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

local function toggleUI()
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
        if lower:match("weekly") then table.insert(results, "Weekly") end
        if lower:match("voa") then table.insert(results, "VoA") end
        if lower:match("muss sterben") then table.insert(results, "Weekly") end
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
LFGAnalyzer:SetScript("OnEvent", function(_, _, msg, sender, _, _, _, _, _, _, channelName, ...)
    -- Ensure we actually received a string for the channel name
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
end)

-- Cleanup on logout or reload
SLASH_LFGANALYZER1 = "/lfganalyzer"
SlashCmdList["LFGANALYZER"] = function()
    if lastSender and #buffer > 0 then
        analyzeMessage(table.concat(buffer, " "), lastSender)
    end
    resetBuffer()
    toggleUI()
end
