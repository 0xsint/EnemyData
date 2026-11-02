-- Terminal drawing helpers (Lua 5.1). ANSI colors work in Windows Terminal,
-- PowerShell 7 and most Linux/macOS terminals; pass --no-color otherwise.

local M = {}

local useColor = true

local CODES = {
  reset = "\27[0m", bold = "\27[1m", red = "\27[31m", green = "\27[32m",
  yellow = "\27[33m", blue = "\27[34m", magenta = "\27[35m", cyan = "\27[36m",
  gray = "\27[90m",
}

function M.setColor(enabled)
  useColor = enabled
end

function M.paint(color, s)
  if not useColor or not color or not CODES[color] then return s end
  return CODES[color] .. s .. CODES.reset
end

function M.round(n)
  return math.floor(n + 0.5)
end

function M.padRight(s, width)
  if #s >= width then return s:sub(1, width) end
  return s .. string.rep(" ", width - #s)
end

function M.padLeft(s, width)
  if #s >= width then return s:sub(1, width) end
  return string.rep(" ", width - #s) .. s
end

-- Word-wrap plain text to a list of lines no longer than `width`.
function M.wrap(text, width)
  local lines, line = {}, ""
  for word in text:gmatch("%S+") do
    if line == "" then
      line = word
    elseif #line + 1 + #word <= width then
      line = line .. " " .. word
    else
      lines[#lines + 1] = line
      line = word
    end
  end
  if line ~= "" then lines[#lines + 1] = line end
  return lines
end

-- A Row tracks the visible text separately from the colored text so the box
-- border lines up regardless of escape codes.
local Row = {}
Row.__index = Row

function M.row()
  return setmetatable({ plain = "", out = "" }, Row)
end

function Row:add(s, color)
  self.plain = self.plain .. s
  self.out = self.out .. M.paint(color, s)
  return self
end

-- Health bar, e.g. [#########-----], colored by remaining percentage.
function M.bar(cur, max, width)
  local pct = 0
  if max > 0 then pct = cur / max end
  if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end
  local filled = M.round(pct * width)
  if cur > 0 and filled == 0 then filled = 1 end
  local color = "green"
  if pct <= 0.3 then color = "red" elseif pct <= 0.6 then color = "yellow" end
  return string.rep("#", filled), string.rep("-", width - filled), color
end

function Row:addBar(cur, max, width)
  local full, empty, color = M.bar(cur, max, width)
  self:add("[")
  self:add(full, color)
  self:add(empty, "gray")
  self:add("]")
  return self
end

-- Single-color meter for frequencies, e.g. ##########.......... (frac 0..1).
function Row:addMeter(frac, width)
  local filled = M.round(math.max(0, math.min(1, frac)) * width)
  if frac > 0 and filled == 0 then filled = 1 end
  self:add(string.rep("#", filled), "cyan")
  self:add(string.rep(".", width - filled), "gray")
  return self
end

-- Print rows inside an ASCII box of the given inner width.
function M.box(rows, width, borderColor)
  local edge = M.paint(borderColor, "+" .. string.rep("-", width + 2) .. "+")
  local side = M.paint(borderColor, "|")
  io.write(edge, "\n")
  for _, r in ipairs(rows) do
    if r == "-" then
      io.write(M.paint(borderColor, "|" .. string.rep("-", width + 2) .. "|"), "\n")
    else
      local padding = width - #r.plain
      if padding < 0 then padding = 0 end
      io.write(side, " ", r.out, string.rep(" ", padding), " ", side, "\n")
    end
  end
  io.write(edge, "\n")
end

return M
