local addonName = ...

-- Backwards-compatible DB init (old versions may not have .realm / .characters)
AltTrackerDB = AltTrackerDB or {}
AltTrackerDB.characters = AltTrackerDB.characters or {}
AltTrackerDB.realm = AltTrackerDB.realm or {}

-- Forward declaration (options UI defined later)
local CreateOptionsPanel

-- Extended DB:
--  AltTrackerDB.characters[ "Name-Realm" ] = { professions = {...}, neededItems = {...}, bags = {...}, bank = {...}, money = <copper>, name = "Name" }
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
    AltTrackerDB.characters[key] = { professions = {}, bags = {}, bank = {}, pbank = {}, name = (UnitName("player") or "Unknown"), money = 0 }
  end
  local cd = AltTrackerDB.characters[key]
  cd.professions = cd.professions or {}
  cd.bags = cd.bags or {}
  cd.bank = cd.bank or {}
  cd.pbank = cd.pbank or {}
  cd.name = cd.name or (UnitName("player") or "Unknown")
  cd.money = tonumber(cd.money) or 0
  cd.enabled = (cd.enabled ~= false)
  cd.profFilter = cd.profFilter or {}
  return cd
end

local function EnsureRealmData()
  AltTrackerDB.realm = AltTrackerDB.realm or {}
  local rk = RealmKey()
  AltTrackerDB.realm[rk] = AltTrackerDB.realm[rk] or { rbank = {}, lastScan = 0, lastScanPersonal = 0 }
  local rd = AltTrackerDB.realm[rk]
  rd.rbank = rd.rbank or rd.counts or {}
  rd.counts = rd.rbank -- backward compat alias
  rd.lastScan = rd.lastScan or 0
  rd.lastScanPersonal = rd.lastScanPersonal or 0
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
-- Gold tracking + tooltip on the bag gold display (AdiBags + fallback)
------------------------------------------------------------
local function FormatMoney(copper)
  copper = tonumber(copper) or 0
  if type(_G.GetCoinTextureString) == "function" then
    return _G.GetCoinTextureString(copper)
  end
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = math.floor(copper % 100)
  return string.format("%dg %ds %dc", g, s, c)
end

local pendingMoney, moneyAt = false, 0

local function StoreMyMoney()
  local cd = EnsureCharacterData()
  cd.money = GetMoney() or 0
end

local function RequestMoneyStore()
  pendingMoney = true
  moneyAt = GetTime() + 0.20
end

local function GetAllAltMoney()
  local list = {}
  local total = 0
  for characterKey, characterData in pairs(AltTrackerDB.characters or {}) do
    if characterData and characterData.enabled == false then
      -- skip
    else
    local name = characterData.name or (characterKey:match("^[^-]+") or characterKey)
    local m = tonumber(characterData.money) or 0
    if m > 0 then
      total = total + m
      list[#list + 1] = { name = name, money = m }
    end
    end
  end
  table.sort(list, function(a, b)
    if a.money == b.money then return a.name < b.name end
    return a.money > b.money
  end)
  return list, total
end

local function ShowGoldTooltip(owner)
  local tip = GameTooltip
  tip:SetOwner(owner, "ANCHOR_TOPLEFT")
  tip:ClearLines()
  tip:AddLine("AltTracker Gold", 1, 1, 1)

  local list, total = GetAllAltMoney()
  tip:AddDoubleLine("Total:", FormatMoney(total), 1, 1, 1, 0.8, 0.8, 0.8)

  for i = 1, math.min(#list, 30) do
    tip:AddDoubleLine(list[i].name .. ":", FormatMoney(list[i].money), 0.75, 0.75, 0.75, 0.75, 0.75, 0.75)
  end
  tip:Show()
end

local function HookGoldFrame()
  local function HookOne(f)
    if not f or f.AltTrackerGoldHooked then return false end
    if f.EnableMouse then f:EnableMouse(true) end
    if f.HookScript then
      f:HookScript("OnEnter", function(self) ShowGoldTooltip(self) end)
      f:HookScript("OnLeave", function() GameTooltip:Hide() end)
    else
      f:SetScript("OnEnter", function(self) ShowGoldTooltip(self) end)
      f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    f.AltTrackerGoldHooked = true
    return true
  end

  local hookedAny = false

  -- AdiBags coins (hook all that exist)
  hookedAny = HookOne(_G.AdiBagsMoneyFrameGoldButton) or hookedAny
  hookedAny = HookOne(_G.AdiBagsMoneyFrameSilverButton) or hookedAny
  hookedAny = HookOne(_G.AdiBagsMoneyFrameCopperButton) or hookedAny
  if hookedAny then return true end

  -- Fallback money frames
  hookedAny = HookOne(_G.AdiBagsMoneyFrame) or hookedAny
  hookedAny = HookOne(_G.BackpackMoneyFrame) or hookedAny
  hookedAny = HookOne(_G.MainMenuBarBackpackButtonMoneyFrame) or hookedAny
  hookedAny = HookOne(_G.MainMenuBarMoneyFrame) or hookedAny

  return hookedAny
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
      if characterData.profFilter[name] == nil then characterData.profFilter[name] = true end
          if characterData.profFilter[name] == nil then characterData.profFilter[name] = true end
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
      if skillUps == nil then skillUps = recipeInfo.skillUps end
      if skillUps == nil then skillUps = recipeInfo.skillUp end
      if skillUps == 0 then
        return false
      end
    end

    return true
  end

  local characterData = EnsureCharacterData()
  characterData.professions[professionName] = characterData.professions[professionName] or {}
  local professionData = characterData.professions[professionName]

  if characterData.profFilter[professionName] == nil then characterData.profFilter[professionName] = true end

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
-- Per-character bag + bank item counts (for alt totals)
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
  if not BankFrame or not BankFrame:IsShown() then return end

  local cd = EnsureCharacterData()
  WipeTable(cd.bank)

  for slot = 1, (NUM_BANKGENERIC_SLOTS or 28) do
    local link = GetContainerItemLink(BANK_CONTAINER, slot)
    if link then
      local itemID = ItemIDFromLink(link)
      local _, count = GetContainerItemInfo(BANK_CONTAINER, slot)
      AddCount(cd.bank, itemID, count or 1)
    end
  end

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
-- Realm Bank (Ascension Realm Bank uses GuildBankFrame)
------------------------------------------------------------
local function DetectAscensionBankMode()
  -- Ascension uses GuildBankFrame for both banks.
  -- Reliable detection strategy:
  --  1) If ANY visible text on the frame contains "personal" => Personal Bank
  --  2) If ANY visible text on the frame contains "realm bank" or "daily withdrawals" => Realm Bank
  --
  -- Reason: the title fontstring is not always the same between the two UIs, but the Realm Bank UI
  -- usually has an extra line like "Remaining Daily Withdrawals for Realm Bank".
  local function CheckText(s)
    if not s or s == "" then return nil end
    local t = string.lower(s)
    if t:find("personal") then return "personal" end
    if t:find("realm bank") or t:find("daily withdrawals") or t:find("warband") then return "realm" end
    return nil
  end

  -- Check common title objects first
  local title = ""
  if _G.GuildBankFrameTitleText and _G.GuildBankFrameTitleText.GetText then
    title = _G.GuildBankFrameTitleText:GetText() or ""
    local r = CheckText(title)
    if r then return r end
  end

  -- Scan all fontstrings on the frame for reliable markers
  if _G.GuildBankFrame and _G.GuildBankFrame.GetRegions then
    local regions = { _G.GuildBankFrame:GetRegions() }
    for i = 1, #regions do
      local region = regions[i]
      if region and region.GetObjectType and region:GetObjectType() == "FontString" and region.GetText then
        local r = CheckText(region:GetText())
        if r then return r end
      end
    end
  end

  -- Fallback: if we couldn't find markers, assume realm (safer for your use-case)
  return "realm"
end



local function ScanGuildBankInto(targetCounts)
  if not GuildBankFrame or not GuildBankFrame:IsShown() then return end
  if not targetCounts then return end

  WipeTable(targetCounts)

  local numTabs = GetNumGuildBankTabs() or 0
  local SLOTS_PER_TAB = 98

  for tab = 1, numTabs do
    for slot = 1, SLOTS_PER_TAB do
      local link = GetGuildBankItemLink(tab, slot)
      if link then
        local itemID = ItemIDFromLink(link)
        local _, count = GetGuildBankItemInfo(tab, slot)
        AddCount(targetCounts, itemID, count or 1)
      end
    end
  end
end

local function ScanAscensionBank()
  if not GuildBankFrame or not GuildBankFrame:IsShown() then return end

  local mode = DetectAscensionBankMode()
  if mode == "personal" then
    local cd = EnsureCharacterData()
    ScanGuildBankInto(cd.pbank)
    local rd = EnsureRealmData()
    rd.lastScanPersonal = time()
  else
    local rd = EnsureRealmData()
    ScanGuildBankInto(rd.rbank)
    rd.lastScan = time()
  end
end

------------------------------------------------------------
-- Tooltip: professions + realm bank + alts (sorted) + spacer professions + realm bank + alts (sorted) + spacer
------------------------------------------------------------
local function BuildAltCountLines(itemID)
  local lines = {}
  local altsTotal = 0

  for characterKey, characterData in pairs(AltTrackerDB.characters or {}) do
    if characterData and characterData.enabled == false then
      -- skip
    else
    local name = characterData.name or (characterKey:match("^[^-]+") or characterKey)
    local bags = (characterData.bags and characterData.bags[itemID]) or 0
    local bank = (characterData.bank and characterData.bank[itemID]) or 0
    local pbank = (characterData.pbank and characterData.pbank[itemID]) or 0
    local total = bags + bank + pbank
    if total > 0 then
      altsTotal = altsTotal + total
      lines[#lines + 1] = { name = name, total = total, bags = bags, bank = bank, pbank = pbank }
    end
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
    if characterData and characterData.enabled == false then
      -- skip
    else
      local characterName = characterData.name or (characterKey:match("^[^-]+") or characterKey)
    for professionName, professionData in pairs(characterData.professions or {}) do
      if characterData.profFilter and characterData.profFilter[professionName] == false then
        -- skip profession
      else
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
  end
  end

  local altLines, altsTotal = BuildAltCountLines(itemID)

  local rd = EnsureRealmData()
  local realmBank = tonumber((rd.rbank and rd.rbank[itemID]) or (rd.counts and rd.counts[itemID]) or 0) or 0
  local cd = EnsureCharacterData()
  local personalBank = tonumber((cd.pbank and cd.pbank[itemID]) or 0) or 0
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
        string.format("%d (%d bags, %d bank, %d pbank)", a.total, a.bags, a.bank, (a.pbank or 0)),
        0.75, 0.75, 0.75,
        0.75, 0.75, 0.75
      )
    end

    -- Spacer after AltTracker block (keeps distance from ItemLevel, etc.)
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
frame:RegisterEvent("PLAYER_MONEY")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

-- Simple throttles
local pendingBagScan, bagScanAt = false, 0
local pendingRealmScan, realmScanAt = false, 0
local goldHookDone, goldHookTries, goldHookNext = false, 0, 0

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
    ScanAscensionBank()
  end
  if pendingMoney and GetTime() >= moneyAt then
    pendingMoney = false
    StoreMyMoney()
  end

  -- Retry hooking AdiBags coin buttons for a short time after login/UI loads
  if (not goldHookDone) and GetTime() >= goldHookNext and goldHookTries < 30 then
    goldHookTries = goldHookTries + 1
    goldHookDone = HookGoldFrame() or false
    goldHookNext = GetTime() + 0.5
  end
end)

frame:SetScript("OnEvent", function(_, event, arg1)
  if event == "PLAYER_LOGIN" then
    UpdateProfessionList()
    GameTooltip:HookScript("OnTooltipSetItem", AddTooltipInfo)

    RequestBagScan()
    StoreMyMoney()
    goldHookDone = HookGoldFrame() or false
    goldHookTries = 0
    goldHookNext = GetTime() + 0.5
    if not _G.ALTTRACKER_OPTIONS_INIT then
      _G.ALTTRACKER_OPTIONS_INIT = true
      CreateOptionsPanel()
    end
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

  if event == "PLAYER_MONEY" then
    RequestMoneyStore()
    if not goldHookDone then
      goldHookDone = HookGoldFrame() or false
    end
    return
  end

  if event == "ADDON_LOADED" then
    local addon = arg1
    if addon == "AdiBags" then
      if not goldHookDone then
        goldHookDone = HookGoldFrame() or false
        goldHookTries = 0
        goldHookNext = GetTime() + 0.2
      end
    end
    return
  end

  if event == "PLAYER_ENTERING_WORLD" then
    if not goldHookDone then
      goldHookDone = HookGoldFrame() or false
      goldHookTries = 0
      goldHookNext = GetTime() + 0.2
    end
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


------------------------------------------------------------
-- Options UI (Interface Options) - per character toggles, profession filters, purge
------------------------------------------------------------
local function SortedCharacterKeys()
  local keys = {}
  for k in pairs(AltTrackerDB.characters or {}) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

local function CharDisplayName(key, cd)
  if cd and cd.name then return cd.name end
  return (key and key:match("^[^-]+")) or tostring(key or "?")
end

local function PurgeCharacter(key)
  if not key then return end
  AltTrackerDB.characters[key] = nil
end

CreateOptionsPanel = function()
  local panel = CreateFrame("Frame", "AltTrackerOptionsPanel", _G.InterfaceOptionsFramePanelContainer or _G.InterfaceOptionsFrame)
  panel.name = "AltTracker"

  local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText("AltTracker")

  local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
  sub:SetText("Choose which characters and professions are tracked, or purge old character data.")

  -- Dropdown label
  local ddLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  ddLabel:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -18)
  ddLabel:SetText("Character")

  local dropdown = CreateFrame("Frame", "AltTrackerCharDropdown", panel, "UIDropDownMenuTemplate")
  dropdown:SetPoint("TOPLEFT", ddLabel, "BOTTOMLEFT", -16, -4)

  local enabledCB = CreateFrame("CheckButton", "AltTrackerEnableCB", panel, "InterfaceOptionsCheckButtonTemplate")
  enabledCB:SetPoint("TOPLEFT", dropdown, "BOTTOMLEFT", 20, -10)
  _G[enabledCB:GetName().."Text"]:SetText("Enable tracking for this character (items + professions + gold)")

  local profHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  profHeader:SetPoint("TOPLEFT", enabledCB, "BOTTOMLEFT", 0, -12)
  profHeader:SetText("Tracked professions for this character")

  local profChecks = {}
  for i = 1, 12 do
    local cb = CreateFrame("CheckButton", "AltTrackerProfCB"..i, panel, "InterfaceOptionsCheckButtonTemplate")
    local col = (i > 6) and 1 or 0
    local row = ((i - 1) % 6)
    cb:SetPoint("TOPLEFT", profHeader, "BOTTOMLEFT", col * 240, -8 - row * 22)
    cb:Hide()
    profChecks[i] = cb
  end

  local purgeBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  purgeBtn:SetSize(140, 22)
  purgeBtn:SetPoint("TOPLEFT", profHeader, "BOTTOMLEFT", 0, -150)
  purgeBtn:SetText("Purge character...")

  local confirmText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  confirmText:SetPoint("TOPLEFT", purgeBtn, "BOTTOMLEFT", 0, -6)
  confirmText:SetText("Purging deletes saved items, bank, professions, and gold for that character.")

  local selectedKey = nil

  local function RefreshProfessionChecks()
    for i = 1, #profChecks do profChecks[i]:Hide() end
    if not selectedKey then return end
    local cd = AltTrackerDB.characters[selectedKey]
    if not cd then return end

    local profNames = {}
    for pname in pairs(cd.professions or {}) do
      profNames[#profNames + 1] = pname
    end
    table.sort(profNames)

    for i = 1, math.min(#profNames, #profChecks) do
      local pname = profNames[i]
      local cb = profChecks[i]
      _G[cb:GetName().."Text"]:SetText(pname)
      cb:SetChecked(cd.profFilter and cd.profFilter[pname] ~= false)
      cb:SetScript("OnClick", function(self)
        cd.profFilter = cd.profFilter or {}
        cd.profFilter[pname] = self:GetChecked() and true or false
      end)
      cb:Show()
    end
  end

  local function RefreshCharacterUI()
    if not selectedKey then return end
    local cd = AltTrackerDB.characters[selectedKey]
    if not cd then return end
    enabledCB:SetChecked(cd.enabled ~= false)
    RefreshProfessionChecks()
  end

  enabledCB:SetScript("OnClick", function(self)
    if not selectedKey then return end
    local cd = AltTrackerDB.characters[selectedKey]
    if not cd then return end
    cd.enabled = self:GetChecked() and true or false
  end)

  purgeBtn:SetScript("OnClick", function()
    if not selectedKey then return end
    local cd = AltTrackerDB.characters[selectedKey]
    if not cd then return end
    local name = CharDisplayName(selectedKey, cd)

    StaticPopupDialogs["ALTTRACKER_PURGE_CHAR"] = {
      text = "Purge ALL AltTracker data for |cffffd200" .. name .. "|r?\n\nThis will permanently delete:\n  • Profession tracking + needed items\n  • Bag + bank item counts\n  • Gold totals\n\nThis cannot be undone.",
      button1 = "Purge",
      button2 = CANCEL,
      OnAccept = function()
        PurgeCharacter(selectedKey)
        selectedKey = nil
        UIDropDownMenu_SetText(dropdown, "(select a character)")
        enabledCB:SetChecked(false)
        for i = 1, #profChecks do profChecks[i]:Hide() end
        -- rebuild dropdown list
        UIDropDownMenu_Initialize(dropdown, dropdown.initialize)
        UIDropDownMenu_SetWidth(dropdown, 180)
        UIDropDownMenu_SetText(dropdown, "(select a character)")
      end,
      timeout = 0,
      whileDead = 1,
      hideOnEscape = 1,
      preferredIndex = 3,
    }
    StaticPopup_Show("ALTTRACKER_PURGE_CHAR")
  end)

  local function SetSelected(key)
    selectedKey = key
    local cd = AltTrackerDB.characters[selectedKey]
    local name = cd and CharDisplayName(selectedKey, cd) or "(unknown)"
    UIDropDownMenu_SetText(dropdown, name)
    RefreshCharacterUI()
  end

  local function InitializeDropdown(self, level)
    local keys = SortedCharacterKeys()
    if #keys == 0 then
      local info = UIDropDownMenu_CreateInfo()
      info.text = "(no saved characters)"
      info.notCheckable = true
      UIDropDownMenu_AddButton(info, level)
      return
    end

    for _, key in ipairs(keys) do
      local cd = AltTrackerDB.characters[key]
      local info = UIDropDownMenu_CreateInfo()
      info.text = CharDisplayName(key, cd)
      info.notCheckable = true
      info.func = function() SetSelected(key) end
      UIDropDownMenu_AddButton(info, level)
    end
  end

  dropdown.initialize = InitializeDropdown
  UIDropDownMenu_Initialize(dropdown, InitializeDropdown)
  UIDropDownMenu_SetWidth(dropdown, 180)
  UIDropDownMenu_SetText(dropdown, "(select a character)")

  panel.refresh = function()
    -- Called when the panel is shown
    UIDropDownMenu_Initialize(dropdown, InitializeDropdown)
    if selectedKey and AltTrackerDB.characters[selectedKey] then
      RefreshCharacterUI()
    end
  end

  InterfaceOptions_AddCategory(panel)
end

-- Slash commands to open config
local function OpenAltTrackerConfig()
  -- InterfaceOptionsFrame_OpenToCategory is quirky in 3.3.5; calling twice helps.
  if InterfaceOptionsFrame then
    InterfaceOptionsFrame_Show()
  end
  InterfaceOptionsFrame_OpenToCategory("AltTracker")
  InterfaceOptionsFrame_OpenToCategory("AltTracker")
end

SLASH_ALTTRACKER1 = "/alttracker"
SLASH_ALTTRACKER2 = "/at"
SlashCmdList["ALTTRACKER"] = function()
  OpenAltTrackerConfig()
end


