local LFGAnalyzer = CreateFrame("Frame")
LFGAnalyzer:RegisterEvent("CHAT_MSG_CHANNEL")

local buffer = {}
local lastSender = nil
local lastTimestamp = 0
local timeout = 5 -- Sekunden

local function resetBuffer()
    buffer = {}
    lastSender = nil
    lastTimestamp = 0
end

local function analyzeMessage(fullMessage, sender)
    local lower = fullMessage:lower()
    local results = {}

    if lower:match("lfm") then
        if lower:match("icc") then table.insert(results, "ICC") end
        if lower:match("toc") then table.insert(results, "ToC") end
        if lower:match("weekly") then table.insert(results, "Weekly") end
        if lower:match("voa") then table.insert(results, "VoA") end
        if lower:match("%d+ dds") then table.insert(results, "DPS gesucht") end
        if lower:match("tank") then table.insert(results, "Tank gesucht") end
        if lower:match("healer") then table.insert(results, "Healer gesucht") end
    end

    if #results > 0 then
        DEFAULT_CHAT_FRAME:AddMessage(
            string.format("|cff00ff00[Analyzer]|r %s sucht: %s", sender, table.concat(results, ", "))
        )
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
end
