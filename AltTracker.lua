local addonName = ...

AltTrackerDB = AltTrackerDB or { characters = {} }

local function GetCharacterKey()
  local name = UnitName("player")
  local realm = GetRealmName()
  return string.format("%s-%s", name or "Unknown", realm or "Unknown")
end

local function EnsureCharacterData()
  local key = GetCharacterKey()
  if not AltTrackerDB.characters[key] then
    AltTrackerDB.characters[key] = { professions = {} }
  end
  return AltTrackerDB.characters[key]
end

local function UpdateProfessionList()
  local characterData = EnsureCharacterData()
  local professionIDs = { GetProfessions() }
  for _, professionID in ipairs(professionIDs) do
    if professionID then
      local name, _, rank, maxRank = GetProfessionInfo(professionID)
      if name then
        characterData.professions[name] = characterData.professions[name] or {}
        characterData.professions[name].rank = rank
        characterData.professions[name].maxRank = maxRank
      end
    end
  end
end

local function ScanTradeSkills()
  local professionName, rank, maxRank = GetTradeSkillLine()
  if not professionName then
    return
  end

  local characterData = EnsureCharacterData()
  characterData.professions[professionName] = characterData.professions[professionName] or {}
  local professionData = characterData.professions[professionName]

  professionData.rank = rank
  professionData.maxRank = maxRank
  professionData.neededItems = {}

  for skillIndex = 1, GetNumTradeSkills() do
    local _, skillType = GetTradeSkillInfo(skillIndex)
    if skillType and skillType ~= "header" and skillType ~= "trivial" then
      local reagentCount = GetTradeSkillNumReagents(skillIndex)
      for reagentIndex = 1, reagentCount do
        local reagentLink = GetTradeSkillReagentItemLink(skillIndex, reagentIndex)
        if reagentLink then
          local itemID = tonumber(reagentLink:match("item:(%d+)"))
          if itemID then
            professionData.neededItems[itemID] = true
          end
        end
      end
    end
  end
end

local function AddTooltipInfo(tooltip)
  local _, itemLink = tooltip:GetItem()
  if not itemLink then
    return
  end

  local itemID = tonumber(itemLink:match("item:(%d+)"))
  if not itemID then
    return
  end

  local found = false
  for characterKey, characterData in pairs(AltTrackerDB.characters or {}) do
    for professionName, professionData in pairs(characterData.professions or {}) do
      if professionData.neededItems and professionData.neededItems[itemID] then
        tooltip:AddLine(string.format("Needed by %s's %s", characterKey, professionName), 0.2, 1, 0.2)
        found = true
      end
    end
  end

  if found then
    tooltip:Show()
  end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("SKILL_LINES_CHANGED")
frame:RegisterEvent("TRADE_SKILL_SHOW")
frame:RegisterEvent("TRADE_SKILL_UPDATE")

frame:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" then
    UpdateProfessionList()
    GameTooltip:HookScript("OnTooltipSetItem", AddTooltipInfo)
  elseif event == "SKILL_LINES_CHANGED" then
    UpdateProfessionList()
  elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_UPDATE" then
    ScanTradeSkills()
  end
end)
