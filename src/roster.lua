-- Enemy roster logic shared by the desktop app and the in-game mod (Lua 5.1).
-- Pure Lua with no I/O, so build/assemble.lua can inline it into the mod.

local Enemies = require("data.enemies")
local Tables  = require("data.spawn_tables")

local M = {}

local function round(n)
  return math.floor(n + 0.5)
end

-- The wiki's armor classes. An attack needs armor penetration (AP) at least equal to the value.
local ARMOR_NAMES = {
  [0] = "Unarmored", [1] = "Very Light", [2] = "Light", [3] = "Medium", [4] = "Heavy",
  [5] = "Tank I", [6] = "Tank II", [7] = "Tank III", [8] = "Tank IV", [9] = "Tank V", [10] = "Tank VI",
}

function M.armorName(av)
  return ARMOR_NAMES[av] or ("AV" .. tostring(av))
end

-- What it takes to hurt this armor value, and how worried to be ("low",
-- "medium" or "high"); front ends map the level to a color.
function M.penetration(av)
  if av <= 1 then return "Any weapon", "low" end
  if av == 2 then return "Light pen or better (AP2+)", "low" end
  if av == 3 then return "Medium pen (AP3+)", "medium" end
  if av == 4 then return "Heavy pen (AP4+)", "medium" end
  return "Anti-tank (AP" .. av .. "+)", "high"
end

-- Normalize "Jet Brigade" / "jet-brigade" / "JET_BRIGADE" to "jet_brigade".
function M.key(s)
  if not s then return nil end
  return (s:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
end

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

function M.listFactions() return sortedKeys(Tables.factions) end
function M.listMissionTypes() return sortedKeys(Tables.mission_types) end
function M.listSubfactions(faction)
  local f = Tables.factions[faction]
  return f and sortedKeys(f.subfactions) or {}
end

-- Validate and normalize a mission table. Returns mission or nil, err.
function M.normalize(raw)
  local m = {
    name       = raw.name or "Unnamed Operation",
    planet     = raw.planet or "Unknown",
    faction    = M.key(raw.faction),
    subfaction = M.key(raw.subfaction),
    type       = M.key(raw.type) or "objective",
    difficulty = tonumber(raw.difficulty),
  }
  if not m.faction or not Tables.factions[m.faction] then
    return nil, "unknown faction '" .. tostring(raw.faction) .. "' (use: "
      .. table.concat(M.listFactions(), ", ") .. ")"
  end
  if not m.difficulty or m.difficulty < 1 or m.difficulty > 10 then
    return nil, "difficulty must be a number from 1 to 10"
  end
  m.difficulty = math.floor(m.difficulty)
  if not Tables.mission_types[m.type] then
    return nil, "unknown mission type '" .. tostring(raw.type) .. "' (use: "
      .. table.concat(M.listMissionTypes(), ", ") .. ")"
  end
  if m.subfaction == "none" or m.subfaction == "" then m.subfaction = nil end
  if m.subfaction and not Tables.factions[m.faction].subfactions[m.subfaction] then
    return nil, "unknown subfaction '" .. tostring(raw.subfaction) .. "' for "
      .. m.faction .. " (use: " .. table.concat(M.listSubfactions(m.faction), ", ") .. ")"
  end
  return m
end

-- Spawn weight of one enemy for this mission, or 0 if it won't appear.
local function weightFor(e, mission)
  if e.faction ~= mission.faction then return 0 end
  if e.subfaction and e.subfaction ~= mission.subfaction then return 0 end
  if e.min_diff > mission.difficulty then return 0 end

  local above = mission.difficulty - e.min_diff
  -- New unlocks start at half weight and ramp to full over two levels.
  local w = e.weight * math.min(1, 0.5 + 0.25 * above)
  -- Heavies and bosses keep scaling up with difficulty.
  if e.class == "heavy" or e.class == "boss" then
    w = w * (1 + 0.15 * above)
  end

  local mtype = Tables.mission_types[mission.type]
  w = w * (mtype.mult[e.class] or 1)
  if e.tags and e.tags.air and mtype.mult.air then
    w = w * mtype.mult.air
  end

  if mission.subfaction then
    local sub = Tables.factions[mission.faction].subfactions[mission.subfaction]
    w = w * (sub.mult[e.id] or 1)
  end
  return w
end

function M.tierFor(share)
  -- Use the rounded percent the player sees, so "5%" is never labeled Rare.
  local shown = round(share * 100) / 100
  for _, t in ipairs(Tables.tiers) do
    if shown >= t.min then return t.label end
  end
  return "Rare"
end

-- Build the expected roster: list of { enemy, weight, share, tier },
-- sorted most-likely first.
function M.build(mission)
  local roster, total = {}, 0
  for _, e in ipairs(Enemies) do
    local w = weightFor(e, mission)
    if w > 0 then
      roster[#roster + 1] = { enemy = e, weight = w }
      total = total + w
    end
  end
  for _, r in ipairs(roster) do
    r.share = r.weight / total
    r.tier = M.tierFor(r.share)
  end
  table.sort(roster, function(a, b)
    if a.share ~= b.share then return a.share > b.share end
    return a.enemy.name < b.enemy.name
  end)
  return roster
end

-- Share of the roster per class. Air units are also counted in their class.
function M.classMix(roster)
  local mix = { light = 0, medium = 0, heavy = 0, boss = 0, air = 0 }
  local examples = { light = {}, medium = {}, heavy = {}, boss = {}, air = {} }
  for _, r in ipairs(roster) do
    local e = r.enemy
    mix[e.class] = mix[e.class] + r.share
    table.insert(examples[e.class], e.name)
    if e.tags and e.tags.air then
      mix.air = mix.air + r.share
      table.insert(examples.air, e.name)
    end
  end
  return mix, examples
end

-- Loadout advice derived from the roster's armor and unit mix.
function M.advice(roster)
  local maxArmor, hasAir, mediumArmor = 0, false, false
  local lightShare = M.classMix(roster).light
  for _, r in ipairs(roster) do
    local e = r.enemy
    if e.armor > maxArmor then maxArmor = e.armor end
    if e.tags and e.tags.air then hasAir = true end
    if e.armor == 3 or e.armor == 4 then mediumArmor = true end
  end
  local tips = {}
  if maxArmor >= 5 then
    tips[#tips + 1] = "Anti-tank required: Recoilless Rifle, EAT-17, Quasar Cannon, Spear or Orbital Railcannon Strike."
  elseif maxArmor >= 4 then
    tips[#tips + 1] = "Heavy armor present: bring at least one anti-tank or Autocannon per squad."
  end
  if mediumArmor then
    tips[#tips + 1] = "Medium armor is common: use a medium-penetration primary or a support weapon."
  end
  if hasAir then
    tips[#tips + 1] = "Air units expected: bring explosive or anti-air options (Autocannon, Quasar, AA emplacement)."
  end
  if lightShare >= 0.5 then
    tips[#tips + 1] = "Expect large swarms of light units: Machine Gun, Stalwart, Napalm/Gas barrages, Eagle Cluster."
  end
  if #tips == 0 then
    tips[1] = "Low threat. Any loadout works."
  end
  return tips
end

return M
