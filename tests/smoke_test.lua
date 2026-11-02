-- Smoke test (Lua 5.1): lua tests/smoke_test.lua
-- Renders every faction/subfaction/difficulty/mission combination and checks
-- the output, then pings and damages every enemy part.

local scriptDir = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
package.path = scriptDir .. "../?.lua;" .. package.path

local Enemies  = require("data.enemies")
local Tables   = require("data.spawn_tables")
local Term     = require("src.term")
local Briefing = require("src.briefing")
local HpUi     = require("src.hp_ui")

local failures, checks = 0, 0
local function check(ok, msg)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL: " .. msg)
  end
end

-- Capture io.write so rendered boxes can be inspected.
local realWrite = io.write
local captured
local function capture(fn)
  captured = {}
  io.write = function(...)
    for i = 1, select("#", ...) do captured[#captured + 1] = tostring(select(i, ...)) end
  end
  local ok, err = pcall(fn)
  io.write = realWrite
  return ok, err, table.concat(captured)
end

-- Every line of a box must have the same visible width once colors are removed.
local function checkBox(text, label)
  local width
  for line in text:gmatch("[^\n]+") do
    local visible = #line:gsub("\27%[[%d;]*m", "")
    width = width or visible
    check(visible == width, label .. ": misaligned line (" .. visible .. " vs " .. width .. "): " .. line)
  end
end

Term.setColor(true)

-- 1. Every briefing combination.
local combos = 0
for _, faction in ipairs(Briefing.listFactions()) do
  local subs = { false }
  for _, s in ipairs(Briefing.listSubfactions(faction)) do subs[#subs + 1] = s end
  for _, sub in ipairs(subs) do
    for diff = 1, 10 do
      for _, mtype in ipairs(Briefing.listMissionTypes()) do
        combos = combos + 1
        local label = faction .. "/" .. tostring(sub) .. "/d" .. diff .. "/" .. mtype
        local mission, err = Briefing.normalize({
          faction = faction, subfaction = sub or nil, difficulty = diff, type = mtype,
          name = string.rep("Long Operation Name ", 6), planet = string.rep("Planet", 10) })
        check(mission ~= nil, label .. ": normalize failed: " .. tostring(err))
        if mission then
          local roster = Briefing.build(mission)
          check(#roster > 0, label .. ": empty roster")

          local sum, rank = 0, { Common = 1, Uncommon = 2, Rare = 3 }
          for i, r in ipairs(roster) do
            sum = sum + r.share
            check(r.enemy.faction == faction, label .. ": wrong faction " .. r.enemy.id)
            check(r.enemy.min_diff <= diff, label .. ": " .. r.enemy.id .. " below min difficulty")
            if i > 1 then
              check(rank[r.tier] >= rank[roster[i - 1].tier], label .. ": tiers out of order")
            end
            local found = Briefing.find(tostring(i), roster, faction)
            check(found == r.enemy, label .. ": ping #" .. i .. " mismatch")
          end
          check(math.abs(sum - 1) < 1e-9, label .. ": shares sum to " .. sum)

          local ok, renderErr, out = capture(function() Briefing.render(mission, roster) end)
          check(ok, label .. ": render error " .. tostring(renderErr))
          if ok then checkBox(out, label) end
        end
      end
    end
  end
end

-- 2. Ping and damage every enemy and part.
for _, e in ipairs(Enemies) do
  for _, q in ipairs({ e.id, e.name }) do
    local found, err = Briefing.find(q, {}, e.faction)
    check(found == e, "find '" .. q .. "' -> " .. tostring(found and found.id or err))
  end
  for _, alias in ipairs(e.aliases or {}) do
    local found, err = Briefing.find(alias, {}, e.faction)
    check(found == e, "alias '" .. alias .. "' -> " .. tostring(found and found.id or err))
  end

  local t = HpUi.newTarget(e, true)
  local ok, err, out = capture(function() HpUi.render(t) end)
  check(ok, e.id .. ": card render error " .. tostring(err))
  if ok then
    checkBox(out, e.id .. " card")
    local plain = out:gsub("\27%[[%d;]*m", "")
    check(plain:find(" " .. e.hp .. "/" .. e.hp, 1, true) ~= nil, e.id .. ": health total missing")
    for _, p in ipairs(e.parts or {}) do
      check(plain:find(" " .. p.name .. " ", 1, true) ~= nil, e.id .. ": part name '" .. p.name .. "' cut off")
    end
    -- A bar must close with "]" before its numbers: "[####--] 150/150".
    check(plain:find("[#%-] %d") == nil, e.id .. ": HP bar missing closing bracket")
  end

  for i = 1, #t.parts do
    HpUi.reset(t)
    local p = t.parts[i] -- reset rebuilds the part tables
    local msg, hitErr = HpUi.applyDamage(t, p.max, p.name)
    check(msg ~= nil, e.id .. ": hit " .. p.name .. " failed: " .. tostring(hitErr))
    check(p.cur == 0 and p.broken, e.id .. ": " .. p.name .. " not broken")
    if p.fatal then check(t.dead, e.id .. ": fatal part " .. p.name .. " did not kill") end
    ok, err, out = capture(function() HpUi.render(t) end)
    check(ok, e.id .. ": card after hit error " .. tostring(err))
    if ok then checkBox(out, e.id .. " card after " .. p.name) end
  end

  HpUi.reset(t)
  check(t.hp == e.hp and not t.dead, e.id .. ": reset failed")
  HpUi.applyDamage(t, e.hp)
  check(t.dead, e.id .. ": full body damage did not kill")
  check(HpUi.applyDamage(t, 1) == nil, e.id .. ": hit on dead target accepted")
end

-- 3. Bad input is rejected.
check(Briefing.normalize({ faction = "cyborgs", difficulty = 5 }) == nil, "accepted unknown faction")
check(Briefing.normalize({ faction = "terminids", difficulty = 11 }) == nil, "accepted difficulty 11")
check(Briefing.normalize({ faction = "terminids", difficulty = 5, subfaction = "jet_brigade" }) == nil,
  "accepted bot subfaction on bugs")
check(Briefing.normalize({ faction = "Terminids", difficulty = "7", subfaction = "Predator Strain" }) ~= nil,
  "rejected mixed-case input")

print(string.format("%d combinations, %d enemies, %d checks, %d failures",
  combos, #Enemies, checks, failures))
os.exit(failures == 0 and 0 or 1)
