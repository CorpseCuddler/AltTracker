local addonName = ...

-- Backwards-compatible DB init (old versions may not have .realm / .characters)
AltTrackerDB = AltTrackerDB or {}
AltTrackerDB.characters = AltTrackerDB.characters or {}
AltTrackerDB.realm = AltTrackerDB.realm or {}

-- Extended DB:
--  AltTrackerDB.characters[ "Name-Realm" ] = { professions = {...}, bags = {...}, bank = {...}, name = "Name" }
--  AltTrackerDB.realm[ "Realm" ] = { counts = {...}, lastScan = 0 }

------------------------------------------------------------
-- Keys / storage
------------------------------------------------------------
local function GetCharacterKey()
  local name = UnitName("player")
  local realm = GetRealmName()
  return string.format("%s-%s", name or "Unknown", realm or "Unknown")
end

local function RealmKey()
  return GetRealmName() or "UnknownRealm"
end

local function EnsureCharacterData()
  local key = GetCharacterKey()
  if not AltTrackerDB.characters[key] then
    AltTrackerDB.characters[key] = { professions = {}, bags = {}, bank = {}, name = (UnitName("player") or "Unknown") }
  end
  local cd = AltTrackerDB.characters[key]
  cd.professions = cd.professions or {}
  cd.bags = cd.bags or {}
  cd.bank = cd.bank or {}
  cd.name = cd.name or (UnitName("player") or "Unknown")
  return cd
end

local function EnsureRealmData()
  -- Ensure tables exist even if SavedVariables were created by older versions
  AltTrackerDB.realm = AltTrackerDB.realm or {}

  local rk = RealmKey()
  AltTrackerDB.realm[rk] = AltTrackerDB.realm[rk] or { counts = {}, lastScan = 0 }
  local rd = AltTrackerDB.realm[rk]
  rd.counts = rd.counts or {}
  rd.lastScan = rd.lastScan or 0
  return rd
end

------------------------------------------------------------
-- Shared helpers
------------------------------------------------------------
local function ItemIDFromLink(link)
  return link and tonumber(link:match("item:(%d+)"))
end

local function AddCount(t, itemID, count)
  if not itemID or not count or count <= 0 then return end
  t[itemID] = (t[itemID] or 0) + count
end

local function WipeTable(t)
  for k in pairs(t) do t[k] = nil end
end

------------------------------------------------------------
-- Profession tracking (original AltTracker logic)
------------------------------------------------------------
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
          characterData.professions[name] = characterData.professions[name] or {}
          characterData.professions[name].rank = rank
          characterData.professions[name].maxRank = maxRank
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
      characterData.professions[name] = characterData.professions[name] or {}
      characterData.professions[name].rank = rank
      characterData.professions[name].maxRank = maxRank
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
  characterData.professions[professionName] = characterData.professions[professionName] or {}
  local professionData = characterData.professions[professionName]

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
          local itemID = ItemIDFromLink(reagentLink)
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

------------------------------------------------------------
-- NEW: Per-character bag + bank item counts (for alt totals)
------------------------------------------------------------
local function ScanBags()
  local cd = EnsureCharacterData()
  WipeTable(cd.bags)

  for bag = 0, 4 do
    local slots = GetContainerNumSlots(bag) or 0
    for slot = 1, slots do
      local link = GetContainerItemLink(bag, slot)
      if link then
        local itemID = ItemIDFromLink(link)
        local _, count = GetContainerItemInfo(bag, slot)
        AddCount(cd.bags, itemID, count or 1)
      end
    end
  end
end

local function ScanBank()
  -- Only accurate while bank is open.
  if not BankFrame or not BankFrame:IsShown() then return end

  local cd = EnsureCharacterData()
  WipeTable(cd.bank)

  -- Main bank slots
  for slot = 1, (NUM_BANKGENERIC_SLOTS or 28) do
    local link = GetContainerItemLink(BANK_CONTAINER, slot)
    if link then
      local itemID = ItemIDFromLink(link)
      local _, count = GetContainerItemInfo(BANK_CONTAINER, slot)
      AddCount(cd.bank, itemID, count or 1)
    end
  end

  -- Bank bag slots (5..11)
  for bag = (NUM_BAG_SLOTS or 4) + 1, (NUM_BAG_SLOTS or 4) + (NUM_BANKBAGSLOTS or 7) do
    local slots = GetContainerNumSlots(bag) or 0
    for slot = 1, slots do
      local link = GetContainerItemLink(bag, slot)
      if link then
        local itemID = ItemIDFromLink(link)
        local _, count = GetContainerItemInfo(bag, slot)
        AddCount(cd.bank, itemID, count or 1)
      end
    end
  end
end

------------------------------------------------------------
-- NEW: Realm Bank (Ascension Realm Bank uses GuildBankFrame)
------------------------------------------------------------
local function ScanRealmBank()
  if not GuildBankFrame or not GuildBankFrame:IsShown() then return end

  local rd = EnsureRealmData()
  WipeTable(rd.counts)

  local numTabs = GetNumGuildBankTabs() or 0
  local SLOTS_PER_TAB = 98

  for tab = 1, numTabs do
    for slot = 1, SLOTS_PER_TAB do
      local link = GetGuildBankItemLink(tab, slot)
      if link then
        local itemID = ItemIDFromLink(link)
        local _, count = GetGuildBankItemInfo(tab, slot) -- texture, count, locked
        AddCount(rd.counts, itemID, count or 1)
      end
    end
  end

  rd.lastScan = time()
end

------------------------------------------------------------
-- Tooltip: professions + alt totals + realm bank + grand total
------------------------------------------------------------
local function BuildAltCountLines(itemID)
  local lines = {}
  local altsTotal = 0

  for characterKey, characterData in pairs(AltTrackerDB.characters or {}) do
    local name = characterData.name or (characterKey:match("^[^-]+") or characterKey)
    local bags = (characterData.bags and characterData.bags[itemID]) or 0
    local bank = (characterData.bank and characterData.bank[itemID]) or 0
    local total = bags + bank
    if total > 0 then
      altsTotal = altsTotal + total
      lines[#lines + 1] = { name = name, total = total, bags = bags, bank = bank }
    end
  end

  table.sort(lines, function(a, b)
    if a.total == b.total then
      return a.name < b.name
    end
    return a.total > b.total
  end)

  return lines, altsTotal
end

local function AddTooltipInfo(tooltip)
  local _, itemLink = tooltip:GetItem()
  if not itemLink then return end

  local itemID = ItemIDFromLink(itemLink)
  if not itemID then return end

  local foundProf = false

  -- Profession-needed lines
  for characterKey, characterData in pairs(AltTrackerDB.characters or {}) do
    local characterName = characterData.name or (characterKey:match("^[^-]+") or characterKey)
    for professionName, professionData in pairs(characterData.professions or {}) do
      if professionData.neededItems and professionData.neededItems[itemID] then
        local entry = professionData.neededItems[itemID]
        if type(entry) == "table" and entry.status == "future" then
          tooltip:AddLine(string.format("Will be needed by %s's %s (future recipe)", characterName, professionName), 1, 0.7, 0.2)
        else
          tooltip:AddLine(string.format("Needed by %s's %s", characterName, professionName), 0.2, 1, 0.2)
        end
        foundProf = true
      end
    end
  end

  -- Alt inventory section (sorted by item count)
  local altLines, altsTotal = BuildAltCountLines(itemID)

  -- Realm bank count
  local rd = EnsureRealmData()
  local realmBank = (rd.counts and rd.counts[itemID]) or 0
  realmBank = tonumber(realmBank) or 0

  local grandTotal = (tonumber(altsTotal) or 0) + realmBank

  if foundProf or #altLines > 0 or realmBank > 0 then
    tooltip:AddLine(" ")
    tooltip:AddDoubleLine("AltTracker:", string.format("%d item(s) total", grandTotal), 1, 1, 1, 0.8, 0.8, 0.8)
    if realmBank > 0 then
      tooltip:AddDoubleLine("Realm Bank:", tostring(realmBank), 0.3, 0.8, 1.0, 0.3, 0.8, 1.0)
    end
for i = 1, math.min(#altLines, 20) do
      local a = altLines[i]
      tooltip:AddDoubleLine(
        "  " .. a.name .. ":",
        string.format("%d (%d bags, %d bank)", a.total, a.bags, a.bank),
        0.75, 0.75, 0.75,
        0.75, 0.75, 0.75
      )
    end
    tooltip:AddLine(" ")

    tooltip:Show()
  end
end

------------------------------------------------------------
-- Events
------------------------------------------------------------
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("SKILL_LINES_CHANGED")
frame:RegisterEvent("TRADE_SKILL_SHOW")
frame:RegisterEvent("TRADE_SKILL_UPDATE")

-- inventory/bank/realm bank tracking
frame:RegisterEvent("BAG_UPDATE")
frame:RegisterEvent("BANKFRAME_OPENED")
frame:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
frame:RegisterEvent("GUILDBANKFRAME_OPENED")
frame:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
frame:RegisterEvent("GUILDBANK_UPDATE_TABS")
frame:RegisterEvent("GUILDBANK_ITEM_LOCK_CHANGED")

-- Simple throttles
local pendingBagScan, bagScanAt = false, 0
local pendingRealmScan, realmScanAt = false, 0

local function RequestBagScan()
  pendingBagScan = true
  bagScanAt = GetTime() + 0.20
end

local function RequestRealmScan(delay)
  pendingRealmScan = true
  realmScanAt = GetTime() + (delay or 0.25)
end

frame:SetScript("OnUpdate", function()
  if pendingBagScan and GetTime() >= bagScanAt then
    pendingBagScan = false
    ScanBags()
  end
  if pendingRealmScan and GetTime() >= realmScanAt then
    pendingRealmScan = false
    ScanRealmBank()
  end
end)

frame:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" then
    UpdateProfessionList()
    GameTooltip:HookScript("OnTooltipSetItem", AddTooltipInfo)
    RequestBagScan()
    return
  end

  if event == "SKILL_LINES_CHANGED" then
    UpdateProfessionList()
    return
  end

  if event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_UPDATE" then
    ScanTradeSkills()
    return
  end

  if event == "BAG_UPDATE" then
    RequestBagScan()
    return
  end

  if event == "BANKFRAME_OPENED" or event == "PLAYERBANKSLOTS_CHANGED" then
    ScanBank()
    return
  end

  if event == "GUILDBANKFRAME_OPENED" then
    RequestRealmScan(0.10)
    return
  end

  if event == "GUILDBANKBAGSLOTS_CHANGED"
    or event == "GUILDBANK_UPDATE_TABS"
    or event == "GUILDBANK_ITEM_LOCK_CHANGED"
  then
    RequestRealmScan()
    return
  end
end)
