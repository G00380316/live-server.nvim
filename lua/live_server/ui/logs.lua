---@mod live_server.ui.logs Live process output for one server
---
--- When a server misbehaves the answer is almost always in its stdout. This
--- tails it in place, follows new lines like `tail -f`, and stops following the
--- moment the user scrolls up — so reading a stack trace is never interrupted
--- by the view jumping to the bottom.

local event = require("live_server.event")
local highlights = require("live_server.ui.highlights")
local util = require("live_server.util")
local window_mod = require("live_server.ui.window")

local M = {}

---@class live_server.ui.LogState
---@field window live_server.ui.Window?
---@field server live_server.Server?
---@field follow boolean
---@field timestamps boolean
---@field unsubscribe fun()|nil
---@field pending boolean
local state = {
  window = nil,
  server = nil,
  follow = true,
  timestamps = false,
  unsubscribe = nil,
  pending = false,
}

---@param entry { at: integer, stream: string, text: string }
---@param start_ms integer
---@return string
local function format_line(entry, start_ms)
  if not state.timestamps then
    return entry.text
  end
  local offset = math.max(0, entry.at - start_ms)
  return ("%7s  %s"):format("+" .. util.duration(offset), entry.text)
end

local function render()
  local window = state.window
  local server = state.server
  if not window or not window:is_valid() or not server then
    return
  end

  local entries = server:log_lines()
  local start_ms = server.started_at or (entries[1] and entries[1].at) or util.now()

  local lines = {}
  local groups = {}
  if #entries == 0 then
    lines[1] = "  (no output yet)"
    groups[1] = "LiveServerHint"
  else
    for index, entry in ipairs(entries) do
      lines[index] = format_line(entry, start_ms)
      groups[index] = entry.stream == "stderr" and "LiveServerLogErr"
        or entry.stream == "system" and "LiveServerLogMeta"
        or "LiveServerLogOut"
    end
  end

  window:set_lines(lines)
  window:clear_highlights()
  for index, group in ipairs(groups) do
    if group ~= "LiveServerLogOut" then
      window:highlight(group, index - 1, 0, #lines[index])
    end
  end

  window:set_title(
    ("%s — %s :%d (%s)"):format(server.project.name, server.adapter.display, server.port, server.status)
  )

  if state.follow and window:is_open() then
    pcall(vim.api.nvim_win_set_cursor, window.win, { #lines, 0 })
  end
end

local function request_render()
  if state.pending then
    return
  end
  state.pending = true
  vim.schedule(function()
    state.pending = false
    render()
  end)
end

---@return boolean
function M.is_open()
  return state.window ~= nil and state.window:is_valid()
end

function M.close()
  if state.window then
    state.window:close()
  end
end

--- Show output for `server`.
---@param server live_server.Server
function M.open(server)
  highlights.apply()

  if M.is_open() then
    state.server = server
    state.follow = true
    render()
    state.window:focus()
    return
  end

  state.server = server
  state.follow = true

  local window = window_mod.open({
    title = server.project.name,
    width = 0.8,
    height = 0.7,
    filetype = "liveserver-log",
  })
  state.window = window

  vim.wo[window.win].wrap = true
  vim.wo[window.win].linebreak = true

  window:map({ "q", "<Esc>" }, function()
    window:close()
  end, "Close")

  window:map("f", function()
    state.follow = not state.follow
    require("live_server.log").notify(state.follow and "Following new output." or "Stopped following.", "info")
    render()
  end, "Toggle follow")

  window:map("t", function()
    state.timestamps = not state.timestamps
    render()
  end, "Toggle timestamps")

  window:map("r", function()
    require("live_server.manager").restart(server)
  end, "Restart this server")

  window:map("c", function()
    server.logs:clear()
    render()
  end, "Clear the buffer")

  window:map("G", function()
    state.follow = true
    render()
  end, "Jump to the end and follow")

  window:map("y", function()
    local lines = {}
    for _, entry in ipairs(server:log_lines()) do
      lines[#lines + 1] = entry.text
    end
    require("live_server.remote").copy(table.concat(lines, "\n"))
    require("live_server.log").notify(("Copied %d lines."):format(#lines), "info")
  end, "Copy all output")

  -- Any manual cursor movement away from the last line means the user is
  -- reading; stop yanking the viewport out from under them.
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = window.buf,
    callback = function()
      if not window:is_open() then
        return
      end
      local total = vim.api.nvim_buf_line_count(window.buf)
      state.follow = window:cursor_row() >= total
    end,
    desc = "live-server: pause log following while scrolled up",
  })

  state.unsubscribe = event.on("*", function(payload)
    if payload.server == state.server then
      request_render()
    end
  end)

  window:on_close(function()
    if state.unsubscribe then
      state.unsubscribe()
      state.unsubscribe = nil
    end
    state.window = nil
    state.server = nil
  end)

  render()
end

return M
