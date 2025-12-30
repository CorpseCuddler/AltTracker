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

local function GetProfessionData(characterData, professionName)
  characterData.professions[professionName] = characterData.professions[professionName] or {}
  local professionData = characterData.professions[professionName]
  if professionData.showInTooltip == nil then
    professionData.showInTooltip = true
  end
  return professionData
end

local function UpdateProfessionList()
  local characterData = EnsureCharacterData()
  local getProfessions = _G.GetProfessions
  local getProfessionInfo = _G.GetProfessionInfo
  if type(getProfessions) == "function" and type(getProfessionInfo) == "function" then
    local professionIDs = { getProfessions() }
    for _, professionID in ipairs(professionIDs) do
      if professionID then
        local name, _, rank, maxRank = getProfessionInfo(professionID)
        if name then
          local professionData = GetProfessionData(characterData, name)
          professionData.rank = rank
          professionData.maxRank = maxRank
        end
      end
    end
    return
  end

  local getNumSkillLines = _G.GetNumSkillLines
  local getSkillLineInfo = _G.GetSkillLineInfo
  if type(getNumSkillLines) ~= "function" or type(getSkillLineInfo) ~= "function" then
    return
  end

  for skillIndex = 1, getNumSkillLines() do
    local name, isHeader, _, rank, _, _, maxRank, isAbandonable = getSkillLineInfo(skillIndex)
    if name and not isHeader and isAbandonable and maxRank and maxRank > 0 then
      local professionData = GetProfessionData(characterData, name)
      professionData.rank = rank
      professionData.maxRank = maxRank
    end
  end
end

local function ScanTradeSkills()
  local professionName, rank, maxRank = GetTradeSkillLine()
  if not professionName then
    return
  end

  local function GetRecipeStatus(skillIndex, skillType)
    if skillType == "header" then
      return nil
    end

    if C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo then
      local recipeInfo = C_TradeSkillUI.GetRecipeInfo(skillIndex)
      if recipeInfo then
        if recipeInfo.learned == false or recipeInfo.available == false or recipeInfo.disabled then
          return "future"
        end
      end
    end

    if skillType == "unavailable" then
      return "future"
    end

    return "usable"
  end

  local function IsRecipeSkillUpEligible(skillIndex, skillType)
    if skillType == "header" then
      return false
    end

    local recipeInfo
    if C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo then
      recipeInfo = C_TradeSkillUI.GetRecipeInfo(skillIndex)
    end

    local difficulty = recipeInfo and recipeInfo.difficulty or skillType
    if difficulty == "trivial" then
      return false
    end

    if recipeInfo then
      local skillUps = recipeInfo.numSkillUps
      if skillUps == nil then
        skillUps = recipeInfo.skillUps
      end
      if skillUps == nil then
        skillUps = recipeInfo.skillUp
      end
      if skillUps == 0 then
        return false
      end
    end

    return true
  end

  local characterData = EnsureCharacterData()
  local professionData = GetProfessionData(characterData, professionName)

  professionData.rank = rank
  professionData.maxRank = maxRank
  professionData.neededItems = {}

  for skillIndex = 1, GetNumTradeSkills() do
    local _, skillType = GetTradeSkillInfo(skillIndex)
    local status = GetRecipeStatus(skillIndex, skillType)
    if status and IsRecipeSkillUpEligible(skillIndex, skillType) then
      local reagentCount = GetTradeSkillNumReagents(skillIndex)
      for reagentIndex = 1, reagentCount do
        local reagentLink = GetTradeSkillReagentItemLink(skillIndex, reagentIndex)
        if reagentLink then
          local itemID = tonumber(reagentLink:match("item:(%d+)"))
          if itemID then
            local existing = professionData.neededItems[itemID]
            if not existing or (existing.status == "future" and status == "usable") then
              professionData.neededItems[itemID] = { status = status }
            end
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
    local characterName = characterKey:match("^[^-]+") or characterKey
    for professionName, professionData in pairs(characterData.professions or {}) do
      if professionData.showInTooltip == nil then
        professionData.showInTooltip = true
      end
      if professionData.showInTooltip and professionData.neededItems and professionData.neededItems[itemID] then
        local entry = professionData.neededItems[itemID]
        if type(entry) == "table" and entry.status == "future" then
          tooltip:AddLine(string.format("Will be needed by %s's %s (future recipe)", characterName, professionName), 1, 0.7, 0.2)
        else
          tooltip:AddLine(string.format("Needed by %s's %s", characterName, professionName), 0.2, 1, 0.2)
        end
        found = true
      end
    end
  end

  if found then
    tooltip:Show()
  end
end

local function ToggleProfessionTooltip(professionName, isChecked)
  if not professionName then
    return
  end
  local characterData = EnsureCharacterData()
  local professionData = GetProfessionData(characterData, professionName)
  professionData.showInTooltip = isChecked and true or false
end

local function UpdateTradeSkillCheckbox()
  if not _G.TradeSkillFrame or not _G.TradeSkillFrameTitleText then
    return
  end

  local professionName = GetTradeSkillLine()
  if not professionName then
    return
  end

  local characterData = EnsureCharacterData()
  local professionData = GetProfessionData(characterData, professionName)

  local checkbox = TradeSkillFrame.altTrackerTooltipCheckbox
  if not checkbox then
    checkbox = CreateFrame("CheckButton", nil, TradeSkillFrame, "UICheckButtonTemplate")
    checkbox:SetSize(20, 20)
    checkbox:SetPoint("LEFT", TradeSkillFrameTitleText, "RIGHT", 4, 0)
    checkbox:SetScript("OnClick", function(self)
      ToggleProfessionTooltip(self.professionName, self:GetChecked())
    end)
    TradeSkillFrame.altTrackerTooltipCheckbox = checkbox
  end

  checkbox.professionName = professionName
  checkbox:SetChecked(professionData.showInTooltip)
  checkbox:Show()
end

local function UpdateProfessionsFrameCheckboxes()
  if not _G.ProfessionsFrame or not ProfessionsFrame.ProfessionList or not ProfessionsFrame.ProfessionList.ScrollBox then
    return
  end

  local characterData = EnsureCharacterData()
  local scrollBox = ProfessionsFrame.ProfessionList.ScrollBox
  if not scrollBox.ForEachFrame then
    return
  end

  scrollBox:ForEachFrame(function(button)
    local professionName
    if button.GetData then
      local data = button:GetData()
      professionName = data and (data.professionName or data.name)
    end
    if not professionName and button.ProfessionName and button.ProfessionName.GetText then
      professionName = button.ProfessionName:GetText()
    end
    if not professionName and button.Name and button.Name.GetText then
      professionName = button.Name:GetText()
    end
    if not professionName and button.Text and button.Text.GetText then
      professionName = button.Text:GetText()
    end
    if not professionName or professionName == "" then
      return
    end

    local professionData = GetProfessionData(characterData, professionName)
    local checkbox = button.altTrackerTooltipCheckbox
    if not checkbox then
      checkbox = CreateFrame("CheckButton", nil, button, "UICheckButtonTemplate")
      checkbox:SetSize(20, 20)
      checkbox:SetPoint("LEFT", button, "RIGHT", 4, 0)
      checkbox:SetScript("OnClick", function(self)
        ToggleProfessionTooltip(self.professionName, self:GetChecked())
      end)
      button.altTrackerTooltipCheckbox = checkbox
    end

    checkbox.professionName = professionName
    checkbox:SetChecked(professionData.showInTooltip)
    checkbox:Show()
  end)
end

local function UpdateProfessionCheckboxes()
  SetupProfessionCheckboxHooks()
  UpdateTradeSkillCheckbox()
  UpdateProfessionsFrameCheckboxes()
end

local function SetupProfessionCheckboxHooks()
  if _G.TradeSkillFrame and not TradeSkillFrame.altTrackerHooked then
    TradeSkillFrame.altTrackerHooked = true
    TradeSkillFrame:HookScript("OnShow", UpdateTradeSkillCheckbox)
  end

  if _G.ProfessionsFrame and not ProfessionsFrame.altTrackerHooked then
    ProfessionsFrame.altTrackerHooked = true
    ProfessionsFrame:HookScript("OnShow", UpdateProfessionsFrameCheckboxes)
    if ProfessionsFrame.ProfessionList then
      if ProfessionsFrame.ProfessionList.RefreshScrollBox then
        hooksecurefunc(ProfessionsFrame.ProfessionList, "RefreshScrollBox", UpdateProfessionsFrameCheckboxes)
      end
      if ProfessionsFrame.ProfessionList.ScrollBox and ProfessionsFrame.ProfessionList.ScrollBox.RegisterCallback then
        ProfessionsFrame.ProfessionList.ScrollBox:RegisterCallback("OnScrollRangeChanged", UpdateProfessionsFrameCheckboxes)
      end
    end
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
    SetupProfessionCheckboxHooks()
    UpdateProfessionCheckboxes()
  elseif event == "SKILL_LINES_CHANGED" then
    UpdateProfessionList()
    UpdateProfessionCheckboxes()
  elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_UPDATE" then
    ScanTradeSkills()
    UpdateProfessionCheckboxes()
  end
end)
