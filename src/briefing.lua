-- Mission preloader: turns briefing info into the roster of enemies you
-- should expect, plus loadout advice. (Lua 5.1)
-- Roster math lives in src/roster.lua (shared with the in-game mod); this
-- module adds the terminal briefing screen and enemy lookup on top of it.

local Enemies = require("data.enemies")
local Tables  = require("data.spawn_tables")
local Roster  = require("src.roster")
local Term    = require("src.term")

local M = setmetatable({}, { __index = Roster })

local FREQ_BAR = 20

local CLASSES = {
  { key = "light", label = "Light" },
  { key = "medium", label = "Medium" },
  { key = "heavy", label = "Heavy" },
  { key = "boss", label = "Boss" },
  { key = "air", label = "Air" },
}

local function armorColor(av)
  if av >= 5 then return "red" elseif av >= 3 then return "yellow" end
  return "green"
end

local function percent(share)
  local p = Term.round(share * 100)
  if p == 0 then return "<1%" end
  return p .. "%"
end

local function tierNote(label)
  for _, t in ipairs(Tables.tiers) do
    if t.label == label then return t.note end
  end
  return ""
end

function M.render(mission, roster, width)
  width = width or 74
  local faction = Tables.factions[mission.faction]
  local rows = {}

  local function fit(s, room)
    if #s <= room then return s end
    return s:sub(1, room - 3) .. "..."
  end

  rows[#rows + 1] = Term.row():add("MISSION BRIEFING  ", "bold")
    :add(fit(mission.name:upper(), width - 18), "yellow")
  rows[#rows + 1] = Term.row():add("Planet: "):add(fit(mission.planet, width - 8), "cyan")
  rows[#rows + 1] = Term.row():add("Enemy: "):add(faction.name, "red")
    :add(mission.subfaction and (" / " .. faction.subfactions[mission.subfaction].name) or "", "magenta")
  rows[#rows + 1] = Term.row():add("Difficulty: ")
    :add(mission.difficulty .. " - " .. Tables.difficulties[mission.difficulty], "yellow")
  rows[#rows + 1] = Term.row():add("Type: "):add(Tables.mission_types[mission.type].name, "cyan")
  -- Enemy frequency chart: one bar per enemy, grouped by tier, most common
  -- first. Bars share one color; the tier is spelled out in the headers.
  local top = roster[1] and roster[1].share or 1
  rows[#rows + 1] = "-"
  rows[#rows + 1] = Term.row():add("ENEMY FREQUENCY", "bold")
    :add("   % = share of all enemies; bars scaled to the largest row", "gray")
  rows[#rows + 1] = Term.row():add(
    Term.padRight("  #", 4) .. Term.padRight(" ENEMY", 21) .. Term.padRight("HOW OFTEN", FREQ_BAR)
    .. Term.padLeft("%", 5) .. "  " .. Term.padRight("ARMOR", 10) .. Term.padLeft("HEALTH", 8), "gray")
  local lastTier
  for i, r in ipairs(roster) do
    if r.tier ~= lastTier then
      lastTier = r.tier
      rows[#rows + 1] = Term.row()
      rows[#rows + 1] = Term.row():add(r.tier:upper(), "bold"):add("  " .. tierNote(r.tier), "gray")
    end
    local e = r.enemy
    rows[#rows + 1] = Term.row()
      :add(Term.padLeft(tostring(i), 3) .. " ", "gray")
      :add(Term.padRight(e.name, 21))
      :addMeter(r.share / top, FREQ_BAR)
      :add(Term.padLeft(percent(r.share), 5))
      :add("  ")
      :add(Term.padRight(M.armorName(e.armor), 10), armorColor(e.armor))
      :add(Term.padLeft(e.hp .. " HP", 8))
  end

  -- Threat mix: how the roster splits across enemy classes.
  local mix, examples = M.classMix(roster)
  local topClass = 0
  for _, c in ipairs(CLASSES) do
    if mix[c.key] > topClass then topClass = mix[c.key] end
  end
  rows[#rows + 1] = "-"
  rows[#rows + 1] = Term.row():add("THREAT MIX", "bold"):add("   share of enemies by class", "gray")
  for _, c in ipairs(CLASSES) do
    if mix[c.key] > 0 then
      local r = Term.row()
        :add(Term.padRight(" " .. c.label, 9))
        :addMeter(mix[c.key] / topClass, FREQ_BAR)
        :add(Term.padLeft(percent(mix[c.key]), 5))
        :add("  ")
      local room = width - #r.plain
      local list = table.concat(examples[c.key], ", ")
      if #list > room then list = list:sub(1, room - 3) .. "..." end
      rows[#rows + 1] = r:add(list, "gray")
    end
  end

  rows[#rows + 1] = "-"
  rows[#rows + 1] = Term.row():add("LOADOUT ADVICE", "bold")
  for _, tip in ipairs(M.advice(roster)) do
    for j, line in ipairs(Term.wrap(tip, width - 2)) do
      rows[#rows + 1] = Term.row():add(j == 1 and "* " or "  ", "cyan"):add(line)
    end
  end

  Term.box(rows, width, "cyan")
end

-- Find an enemy by roster number, id, name, alias or partial name.
-- Searches the mission roster first, then every enemy of the faction.
-- Returns enemy, inRoster   or   nil, errMessage.
function M.find(query, roster, faction)
  local n = tonumber(query)
  if n then
    local r = roster[n]
    if r then return r.enemy, true end
    return nil, "no roster entry #" .. query
  end

  local q = M.key(query)
  if not q or q == "" then return nil, "ping what? (name or roster number)" end

  local function matches(e, exact)
    local names = { e.id, M.key(e.name) }
    for _, a in ipairs(e.aliases or {}) do names[#names + 1] = M.key(a) end
    for _, name in ipairs(names) do
      if exact then
        if name == q then return true end
      elseif name:find(q, 1, true) then
        return true
      end
    end
    return false
  end

  local pools = {}
  local rosterPool = {}
  for _, r in ipairs(roster) do rosterPool[#rosterPool + 1] = r.enemy end
  pools[1] = { list = rosterPool, inRoster = true }
  local allPool = {}
  for _, e in ipairs(Enemies) do
    if not faction or e.faction == faction then allPool[#allPool + 1] = e end
  end
  pools[2] = { list = allPool, inRoster = false }
  pools[3] = { list = Enemies, inRoster = false }

  for _, exact in ipairs({ true, false }) do
    for _, pool in ipairs(pools) do
      local hits = {}
      for _, e in ipairs(pool.list) do
        if matches(e, exact) then hits[#hits + 1] = e end
      end
      if #hits == 1 then return hits[1], pool.inRoster end
      if #hits > 1 then
        local names = {}
        for _, e in ipairs(hits) do names[#names + 1] = e.name end
        return nil, "ambiguous: " .. table.concat(names, ", ")
      end
    end
  end
  return nil, "no enemy matches '" .. query .. "'"
end

return M
