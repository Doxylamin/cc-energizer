-- energizer.lua
-- Simple controller / dashboard for Extreme Reactors Energizer
-- Inspired by Kasra-G's ReactorController

local version = "0.3"

-- If set, prefer this monitor peripheral name (e.g. "monitor_0" or "largeMonitor")
-- Leave nil to auto-detect directly attached monitor
local preferredMonitor = nil


-- Peripheral type prefix for the energizer on the modem network
local energizerType = "BigReactors-Energizer"

----------------------------------------------------
-- State
----------------------------------------------------
local energizer
local energizerName

local mon, monSide
local sizex, sizey

local t                -- touchpoint instance

-- current values from energizer
local curStored      = 0
local curCapacity    = 1   -- avoid div/0
local curIo          = 0
local curInserted    = 0
local curExtracted   = 0
local statsTable     = {}
local statsText      = ""

-- history for graphs
local ioHistory      = {}
local storedHistory  = {}
local maxHistory     = 240   -- enough for big monitors; drawing will clamp

----------------------------------------------------
-- Helpers
----------------------------------------------------

local function loadTouchpoint()
  -- Try to load touchpoint.lua in a couple of common locations.
  -- The file you provided defines a global `touchpoint` table.
  if type(touchpoint) == "table" and touchpoint.new then
    return
  end

  local ok = pcall(dofile, "/usr/apis/touchpoint.lua")
  if not ok then
    ok = pcall(dofile, "touchpoint.lua")
  end

  if not ok or type(touchpoint) ~= "table" or type(touchpoint.new) ~= "function" then
    error("Could not load touchpoint.lua (looked in /usr/apis/touchpoint.lua and ./touchpoint.lua)")
  end
end

-- RF formatter with P and E support
local function formatRF(num, decimals)
  decimals = decimals or 1
  local fmt = "%." .. decimals .. "f"

  if num >= 1e18 then
    return string.format(fmt .. "E", num / 1e18)
  elseif num >= 1e15 then
    return string.format(fmt .. "P", num / 1e15)
  elseif num >= 1e12 then
    return string.format(fmt .. "T", num / 1e12)
  elseif num >= 1e9 then
    return string.format(fmt .. "G", num / 1e9)
  elseif num >= 1e6 then
    return string.format(fmt .. "M", num / 1e6)
  elseif num >= 1e3 then
    return string.format(fmt .. "k", num / 1e3)
  else
    return string.format("%.0f", num)
  end
end


local function drawText(text, x1, y1, backColor, textColor)
  if not monSide or not mon then return end
  local x, y = mon.getCursorPos()
  mon.setCursorPos(x1, y1)
  if backColor then mon.setBackgroundColor(backColor) end
  if textColor then mon.setTextColor(textColor) end
  mon.write(text)
  mon.setTextColor(colors.white)
  mon.setBackgroundColor(colors.black)
  mon.setCursorPos(x,y)
end

local function drawBox(size, xoff, yoff, color)
  if not monSide or not mon then return end
  local w, h = size[1], size[2]
  mon.setBackgroundColor(color)
  -- top / bottom
  mon.setCursorPos(xoff, yoff)
  mon.write(string.rep(" ", w))
  mon.setCursorPos(xoff, yoff + h - 1)
  mon.write(string.rep(" ", w))
  -- sides
  for y = yoff, yoff + h - 1 do
    mon.setCursorPos(xoff, y)
    mon.write(" ")
    mon.setCursorPos(xoff + w - 1, y)
    mon.write(" ")
  end
  mon.setBackgroundColor(colors.black)
end

local function drawFilledBox(size, xoff, yoff, borderColor, fillColor)
  if not monSide or not mon then return end
  local w, h = size[1], size[2]
  drawBox(size, xoff, yoff, borderColor)
  mon.setBackgroundColor(fillColor)
  for y = yoff + 1, yoff + h - 2 do
    mon.setCursorPos(xoff + 1, y)
    mon.write(string.rep(" ", w - 2))
  end
  mon.setBackgroundColor(colors.black)
end

local function resetMon()
  if not monSide or not mon then return end
  mon.setBackgroundColor(colors.black)
  mon.clear()
  -- small text = more columns, nicer graphs
  pcall(mon.setTextScale, 0.5)
  mon.setCursorPos(1,1)
  sizex, sizey = mon.getSize()
end

local function pushHistory(buf, value)
  buf[#buf + 1] = value
  if #buf > maxHistory then
    table.remove(buf, 1)
  end
end

-- Common calculation for buffer bar width, so all panels agree
local function getBarWidth()
  local w = math.floor(sizex * 0.2)
  if w < 18 then w = 18 end
  if w > sizex - 12 then
    -- leave a bit of space for right panels; still keep minimum 10
    w = math.max(10, sizex - 12)
  end
  return w
end

----------------------------------------------------
-- Peripheral discovery
----------------------------------------------------

local function findFirstEnergizerName()
  local names = peripheral.getNames()
  table.sort(names)
  for _, name in ipairs(names) do
    local pType = peripheral.getType(name)
    if pType == energizerType or name:match("^" .. energizerType .. "_") then
      return name
    end
  end
  return nil
end

-- If preferredMonitor is set, try that first. Otherwise look for a directly attached monitor.
local function findMonitor()
  if preferredMonitor and peripheral.isPresent(preferredMonitor) and peripheral.getType(preferredMonitor) == "monitor" then
    return preferredMonitor
  end

  -- fallback: only local monitor directly on computer
  local sides = { "top", "bottom", "left", "right", "front", "back" }
  for _, side in ipairs(sides) do
    if peripheral.isPresent(side) and peripheral.getType(side) == "monitor" then
      return side
    end
  end

  return nil
end

local function initMon()
  monSide = findMonitor()
  if not monSide then
    mon = nil
    return
  end

  mon = peripheral.wrap(monSide)
  if not mon then
    monSide = nil
    return
  end

  loadTouchpoint()
  resetMon()
  t = touchpoint.new(monSide)
end

----------------------------------------------------
-- Energizer polling
----------------------------------------------------

local function updateStats()
  if not energizer then return end

  -- Numeric values
  curStored    = energizer.getEnergyStored() or 0
  curCapacity  = energizer.getEnergyCapacity() or 1
  curIo        = energizer.getEnergyIoLastTick() or 0
  curInserted  = energizer.getEnergyInsertedLastTick() or 0
  curExtracted = energizer.getEnergyExtractedLastTick() or 0

  -- Histories for graphs
  pushHistory(ioHistory, curIo)
  pushHistory(storedHistory, curStored)

  -- stats table
  local okStats, tbl = pcall(energizer.getEnergyStats)
  if okStats and type(tbl) == "table" then
    statsTable = tbl
  else
    statsTable = {}
  end

  -- stats text
  local okTxt, txt = pcall(energizer.getEnergyStatsAsText)
  if okTxt and type(txt) == "string" then
    statsText = txt
  else
    statsText = ""
  end
end

----------------------------------------------------
-- Graphs
----------------------------------------------------

local function drawHistoryGraph(buf, label, xoff, yoff, w, h, color)
  if not monSide or not mon or w < 6 or h < 4 or #buf == 0 then return end

  drawBox({w, h}, xoff, yoff, colors.gray)
  drawText(" " .. label .. " ", xoff + 2, yoff, colors.black, color or colors.cyan)

  local gx = xoff + 1
  local gy = yoff + 1
  local gw = w - 2
  local gh = h - 2

  local n = #buf
  local startIndex = math.max(1, n - gw + 1)

  local minVal = buf[startIndex]
  local maxVal = buf[startIndex]
  for i = startIndex, n do
    local v = buf[i]
    if v < minVal then minVal = v end
    if v > maxVal then maxVal = v end
  end

  if maxVal == minVal then
    maxVal = maxVal + 1
    minVal = minVal - 1
  end

  local range = maxVal - minVal
  if range <= 0 then range = 1 end

  for idx = startIndex, n do
    local v = buf[idx]
    local normalized = (v - minVal) / range
    local height = math.max(1, math.floor(normalized * (gh - 1) + 0.5))
    local col = gx + (idx - startIndex)

    for j = 0, height - 1 do
      mon.setCursorPos(col, gy + gh - 1 - j)
      mon.setBackgroundColor(color or colors.cyan)
      mon.write(" ")
    end
  end

  mon.setBackgroundColor(colors.black)
end

----------------------------------------------------
-- Drawing panels
----------------------------------------------------

local function drawTitle()
  if not monSide or not mon then return end
  drawText("Energizer Controller v" .. version, 1, 1, colors.black, colors.white)
  if energizerName then
    local txt = "Peripheral: " .. energizerName
    drawText(txt, 1, sizey, colors.black, colors.gray)
  end
end

-- Build a buffer info line that fits into maxWidth
local function makeBufferLine(maxWidth)
  local pct = 0
  if curCapacity > 0 then
    pct = (curStored / curCapacity) * 100
  end

  -- Variant 1: 1 decimal
  local line1 = formatRF(curStored, 1) .. " / " .. formatRF(curCapacity, 1) .. " RF"
  if #line1 <= maxWidth then return line1 end

  -- Variant 2: 0 decimals
  local line2 = formatRF(curStored, 0) .. " / " .. formatRF(curCapacity, 0) .. " RF"
  if #line2 <= maxWidth then return line2 end

  -- Fallback: just percentage
  local line3 = string.format("%.1f%% full", pct)
  if #line3 <= maxWidth then return line3 end

  -- In the absolute worst case, truncate
  return line3:sub(1, maxWidth)
end

local function drawBufferPanel()
  if not monSide or not mon then return end

  local barWidth = getBarWidth()
  local barHeight = sizey - 4
  local xoff = 1
  local yoff = 2

  if barHeight < 6 then
    barHeight = sizey - 3
  end

  -- Outer border
  drawBox({barWidth, barHeight}, xoff, yoff, colors.gray)

  -- Label
  local title = "Buffer"
  local titleX = xoff + math.floor((barWidth - #title) / 2)
  if titleX < xoff then titleX = xoff end
  drawText(title, titleX, yoff, colors.black, colors.orange)

  -- Compute percentage
  local pct = 0
  if curCapacity > 0 then
    pct = (curStored / curCapacity) * 100
  end
  if pct < 0 then pct = 0 end
  if pct > 100 then pct = 100 end

  -- Inner area for fill
  local innerHeight = barHeight - 2
  local innerWidth  = barWidth - 2
  if innerHeight < 1 or innerWidth < 1 then return end

  local filledRows = math.floor(innerHeight * pct / 100 + 0.5)

  for i = 0, innerHeight - 1 do
    local rowY = yoff + 1 + (innerHeight - 1 - i) -- bottom-up
    mon.setCursorPos(xoff + 1, rowY)
    if i < filledRows then
      mon.setBackgroundColor(colors.lime)
    else
      mon.setBackgroundColor(colors.gray)
    end
    mon.write(string.rep(" ", innerWidth))
  end

  mon.setBackgroundColor(colors.black)

  -- Percentage line at the bottom
  local pctLine = string.format("%5.1f%%", pct)
  local pctX = xoff + math.floor((barWidth - #pctLine) / 2)
  if pctX < xoff then pctX = xoff end
  drawText(pctLine, pctX, yoff + barHeight - 1, colors.black, colors.white)

  -- Current / max line just above bottom (rounded to fit)
  local maxTextWidth = barWidth - 2
  if maxTextWidth > 0 then
    local infoLine = makeBufferLine(maxTextWidth)
    local infoX = xoff + 1 + math.floor((maxTextWidth - #infoLine) / 2)
    if infoX < xoff + 1 then infoX = xoff + 1 end
    drawText(infoLine, infoX, yoff + barHeight - 2, colors.black, colors.white)
  end
end

local function drawIoPanel(xoff, yoff, w, h)
  if not monSide or not mon or w < 10 or h < 5 then return end

  drawBox({w, h}, xoff, yoff, colors.cyan)
  drawText(" I/O (last tick) ", xoff + 2, yoff, colors.black, colors.cyan)

  local lineY = yoff + 2
  drawText("Inserted : " .. formatRF(curInserted)  .. " RF/t", xoff + 2, lineY,
    colors.black, colors.green)
  lineY = lineY + 1
  drawText("Extracted: " .. formatRF(curExtracted) .. " RF/t", xoff + 2, lineY,
    colors.black, colors.red)
  lineY = lineY + 1
  drawText("Net I/O  : " .. formatRF(curIo)        .. " RF/t", xoff + 2, lineY,
    colors.black, colors.yellow)
end

local function drawStatsPanel(xoff, yoff, w, h)
  if not monSide or not mon or w < 10 or h < 5 then return end

  drawBox({w, h}, xoff, yoff, colors.blue)
  drawText(" Energizer Stats ", xoff + 2, yoff, colors.black, colors.blue)

  local lineY = yoff + 2

  -- One line per table entry
  for k, v in pairs(statsTable) do
    if lineY > yoff + h - 2 then break end
    local txt = tostring(k) .. ": " .. tostring(v)
    drawText(txt, xoff + 2, lineY, colors.black, colors.white)
    lineY = lineY + 1
  end

  -- Then the text block, wrapped
  if statsText ~= "" and lineY <= yoff + h - 2 then
    drawText("AsText:", xoff + 2, lineY, colors.black, colors.orange)
    lineY = lineY + 1

    local maxLen = w - 4
    local pos = 1
    while pos <= #statsText and lineY <= yoff + h - 2 do
      local chunk = statsText:sub(pos, pos + maxLen - 1)
      drawText(chunk, xoff + 2, lineY, colors.black, colors.lightGray)
      pos = pos + maxLen
      lineY = lineY + 1
    end
  end
end

local function drawScene()
  if not monSide or not mon then return end
  resetMon()
  drawTitle()

  local barWidth = getBarWidth()
  drawBufferPanel()

  -- Compute layout for right side
  local rightX = barWidth + 2
  local rightW = sizex - rightX + 1
  local topY = 2
  local usableH = sizey - 3

  if rightW < 10 or usableH < 6 then
    return
  end

  -- Split right side: top = IO graph, middle = I/O text, bottom = stats
  local graphH = math.max(4, math.floor(usableH * 0.35))
  local ioPanelH = math.max(5, math.floor(usableH * 0.25))
  local statsH = usableH - graphH - ioPanelH - 1

  if statsH < 5 then
    statsH = 5
  end

  -- Graph for net I/O and stored RF
  drawHistoryGraph(ioHistory, "Net RF/t", rightX, topY, rightW, graphH, colors.orange)

  -- stored RF graph just below if there's enough vertical space
  local storedTop = topY + graphH
  if usableH >= graphH + 6 then
    local storedH = math.max(4, math.floor(graphH * 0.6))
    drawHistoryGraph(storedHistory, "Stored RF", rightX, storedTop, rightW, storedH, colors.green)
    storedTop = storedTop + storedH
  end

  -- IO text panel
  drawIoPanel(rightX, storedTop, rightW, ioPanelH)

  -- Stats panel at bottom
  local statsY = storedTop + ioPanelH
  if statsY + statsH - 1 <= sizey - 1 then
    drawStatsPanel(rightX, statsY, rightW, statsH)
  end

  if t then
    t:draw()
  end
end

----------------------------------------------------
-- Timers
----------------------------------------------------

local function startTimer(seconds, callback)
  local id = os.startTimer(seconds)
  local function handler(event)
    if event[1] == "timer" and event[2] == id then
      id = os.startTimer(seconds)
      callback()
    end
  end
  return handler
end

----------------------------------------------------
-- Main loop
----------------------------------------------------

local function loop()
  if not energizer then return end

  -- update stats every 0.25s
  local updateTick = startTimer(0.25, function()
    updateStats()
  end)

  -- redraw every 0.25s
  local redrawTick = startTimer(0.25, function()
    drawScene()
  end)

  local function handleResize(event)
    if event[1] == "monitor_resize" then
      initMon()
      drawScene()
    end
  end

  while true do
    local event
    if monSide and t then
      event = { t:handleEvents() }
    else
      event = { os.pullEvent() }
    end

    updateTick(event)
    redrawTick(event)
    handleResize(event)
    -- no buttons yet, but touchpoint is ready for later
  end
end

----------------------------------------------------
-- Entry point
----------------------------------------------------

local function main()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1,1)
  print("Energizer Controller v" .. version)
  print("Searching for " .. energizerType .. "_[?] peripherals on network...")

  energizerName = findFirstEnergizerName()
  while not energizerName do
    print("No energizer found. Retrying in 1s...")
    sleep(1)
    energizerName = findFirstEnergizerName()
  end

  energizer = peripheral.wrap(energizerName)
  if not energizer then
    error("Failed to wrap energizer '" .. energizerName .. "'", 0)
  end

  print("Found energizer: " .. energizerName)
  print("Available methods:")
  for _, m in ipairs(peripheral.getMethods(energizerName) or {}) do
    print("  - " .. m)
  end

  print("Initializing monitor (directly attached, no cables)...")
  initMon()
  if not monSide then
    print("No directly attached monitor found.")
    print("Attach a monitor directly to this computer to see the dashboard.")
  else
    print("Using monitor on side: " .. monSide)
  end

  print("Starting dashboard...")
  sleep(1)
  updateStats()
  drawScene()
  loop()
end

main()
