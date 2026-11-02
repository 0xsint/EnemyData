-- "Ping" HP card: shows a pinged enemy's health, armor and body parts, and
-- tracks damage you log against it. (Lua 5.1)

local Briefing = require("src.briefing")
local Term     = require("src.term")

local M = {}

local WIDTH = 90
local BAR = 20
local LABEL = 14 -- minimum; grows to fit the longest part name, up to MAX_LABEL
local MAX_LABEL = 30

local LEVEL_COLORS = { low = "green", medium = "yellow", high = "red" }

local function penetrationNeeded(av)
  local text, level = Briefing.penetration(av)
  return text, LEVEL_COLORS[level]
end

-- Create a fresh pinged target with full health. A part with no health of its own (shared = true in
-- the data) uses the main pool's size, so damage logged on it still counts down to a kill.
function M.newTarget(enemy, inRoster)
  local t = { def = enemy, hp = enemy.hp, dead = false, inRoster = inRoster, parts = {}, log = {}, label = LABEL }
  for _, p in ipairs(enemy.parts or {}) do
    local max = p.hp or enemy.hp
    t.parts[#t.parts + 1] = {
      name = p.name, max = max, cur = max, armor = p.armor, shared = p.hp == nil,
      fatal = p.fatal, to_main = p.to_main == nil and 1 or p.to_main,
    }
    t.label = math.min(MAX_LABEL, math.max(t.label, #p.name + 2))
  end
  return t
end

local function findPart(t, name)
  local q = Briefing.key(name)
  for _, p in ipairs(t.parts) do
    if Briefing.key(p.name) == q then return p end
  end
  for _, p in ipairs(t.parts) do
    if Briefing.key(p.name):find(q, 1, true) == 1 then return p end
  end
  return nil
end

-- Apply damage to the main body or a named part. Returns message or nil, err.
function M.applyDamage(t, dmg, partName)
  if t.dead then return nil, t.def.name .. " is already dead. Use 'reset' or ping a new target." end
  dmg = tonumber(dmg)
  if not dmg or dmg <= 0 then return nil, "damage must be a positive number" end

  local mainDmg, where = dmg, "Body"
  if partName and partName ~= "" then
    local p = findPart(t, partName)
    if not p then
      local names = {}
      for _, part in ipairs(t.parts) do names[#names + 1] = part.name end
      return nil, "no part '" .. partName .. "'"
        .. (#names > 0 and (" (parts: " .. table.concat(names, ", ") .. ")") or " (this enemy has no parts)")
    end
    where = p.name
    p.cur = math.max(0, p.cur - dmg)
    mainDmg = dmg * p.to_main
    t.log[#t.log + 1] = "-" .. Term.round(dmg) .. " " .. where
    if p.cur == 0 and not p.broken then
      p.broken = true
      if p.fatal then
        t.dead = true
        t.hp = 0
        t.log[#t.log + 1] = where .. " destroyed (fatal)"
        return where .. " destroyed. " .. t.def.name .. " KILLED."
      end
      t.log[#t.log + 1] = where .. " destroyed"
    end
  else
    t.log[#t.log + 1] = "-" .. Term.round(dmg) .. " " .. where
  end

  t.hp = math.max(0, t.hp - mainDmg)
  if t.hp == 0 then
    t.dead = true
    return t.def.name .. " KILLED."
  end
  return Term.round(dmg) .. " damage to " .. where .. ". " .. Term.round(t.hp) .. " HP left."
end

function M.reset(t)
  local fresh = M.newTarget(t.def, t.inRoster)
  for k, v in pairs(fresh) do t[k] = v end
end

function M.render(t)
  local e = t.def
  local rows = {}

  local title = Term.row():add(">> PING  ", "yellow"):add(e.name:upper(), "bold")
  local tag = "[" .. e.faction:upper() .. "]"
  title:add(string.rep(" ", math.max(1, WIDTH - #title.plain - #tag))):add(tag, "red")
  rows[#rows + 1] = title

  local pen, penColor = penetrationNeeded(e.armor)
  rows[#rows + 1] = Term.row():add("Class: "):add(Term.padRight(e.class, 8), "cyan")
    :add("Armor: "):add(Briefing.armorName(e.armor) .. " (AV" .. e.armor .. ")", penColor)
  rows[#rows + 1] = Term.row():add("Needs: "):add(pen, penColor)
  if not t.inRoster then
    rows[#rows + 1] = Term.row():add("! Not expected in this mission", "magenta")
  end
  rows[#rows + 1] = "-"

  local status = Term.row():add(Term.padRight("HEALTH", t.label), "bold")
  status:addBar(t.hp, e.hp, BAR)
  status:add(" " .. Term.round(t.hp) .. "/" .. e.hp)
  if t.dead then status:add("  DEAD", "red") end
  rows[#rows + 1] = status

  if #t.parts > 0 then
    rows[#rows + 1] = Term.row()
    rows[#rows + 1] = Term.row():add("PARTS", "bold"):add("   (main) = uses the main health pool", "gray")
    for _, p in ipairs(t.parts) do
      local r = Term.row():add(Term.padRight(" " .. p.name, t.label))
      r:addBar(p.cur, p.max, BAR)
      r:add(" " .. Term.padRight(Term.round(p.cur) .. "/" .. p.max .. (p.shared and " (main)" or ""), 20))
      r:add("AV" .. p.armor, p.armor >= 5 and "red" or (p.armor >= 3 and "yellow" or "green"))
      if p.broken then
        r:add(" BROKEN", "red")
      elseif p.fatal then
        r:add(" KILL", "magenta")
      end
      rows[#rows + 1] = r
    end
  end

  rows[#rows + 1] = "-"
  for i, line in ipairs(Term.wrap("Tip: " .. (e.weak or "No notes."), WIDTH)) do
    rows[#rows + 1] = Term.row():add(line, i == 1 and "cyan" or nil)
  end

  if #t.log > 0 then
    local first = math.max(1, #t.log - 3)
    local recent = {}
    for i = first, #t.log do recent[#recent + 1] = t.log[i] end
    for _, line in ipairs(Term.wrap("Log: " .. table.concat(recent, ", "), WIDTH)) do
      rows[#rows + 1] = Term.row():add(line, "gray")
    end
  end

  Term.box(rows, WIDTH, t.dead and "red" or "yellow")
end

return M
