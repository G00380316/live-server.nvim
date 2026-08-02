---@mod live_server.ui.icons Icon sets with a text-only mode
---
--- Icons are decoration, never information. Every row that shows a glyph also
--- shows the status word next to it, so the interface reads identically with
--- `ui.icons = "text"`, in a terminal without a patched font, and through a
--- screen reader.

local M = {}

---@type table<string, table<string, string>>
local sets = {
  nerd = {
    running = "●",
    starting = "◐",
    stopping = "◑",
    stopped = "○",
    crashed = "✖",
    unhealthy = "▲",
    project = "",
    url = "",
    pinned = "",
    exposed = "",
    reload = "",
    remote = "",
    bullet = "•",
    arrow = "→",
    separator = "·",
  },
  ascii = {
    running = "*",
    starting = "+",
    stopping = "-",
    stopped = "o",
    crashed = "x",
    unhealthy = "!",
    project = "/",
    url = "@",
    pinned = "#",
    exposed = "^",
    reload = "~",
    remote = ">",
    bullet = "-",
    arrow = "->",
    separator = "-",
  },
  text = setmetatable({}, {
    __index = function()
      return ""
    end,
  }),
}

---@type string[]
local spinners = {
  nerd = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
  ascii = { "|", "/", "-", "\\" },
  text = { "" },
}

--- Resolve the configured mode, expanding `"auto"`.
---@return "nerd"|"ascii"|"text"
function M.mode()
  local configured = require("live_server.config").get().ui.icons
  if configured ~= "auto" then
    return configured
  end
  if vim.g.have_nerd_font then
    return "nerd"
  end
  -- No Nerd Font declared: box-drawing and geometric shapes are still safe in
  -- any UTF-8 terminal, so prefer them over ASCII when the encoding allows.
  if vim.o.encoding == "utf-8" then
    return "nerd"
  end
  return "ascii"
end

--- Icon for a key, or an empty string in text mode.
---@param name string
---@return string
function M.get(name)
  local set = sets[M.mode()] or sets.ascii
  return set[name] or ""
end

--- Icon followed by a space, or nothing at all when there is no icon. Keeps
--- text mode free of stray padding.
---@param name string
---@return string
function M.prefix(name)
  local icon = M.get(name)
  if icon == "" then
    return ""
  end
  return icon .. " "
end

--- Current spinner frame for an animation tick.
---@param tick integer
---@return string
function M.spinner(tick)
  local cfg = require("live_server.config").get()
  if not cfg.ui.spinner then
    return M.get("starting")
  end
  local frames = spinners[M.mode()] or spinners.ascii
  if #frames == 0 then
    return ""
  end
  return frames[(tick % #frames) + 1]
end

--- Widest glyph in the current set, so columns line up regardless of mode.
---@return integer
function M.status_width()
  local widest = 0
  for _, name in ipairs({ "running", "starting", "stopped", "crashed", "unhealthy" }) do
    widest = math.max(widest, vim.fn.strdisplaywidth(M.get(name)))
  end
  return widest
end

return M
