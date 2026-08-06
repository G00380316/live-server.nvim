---@mod live_server.ui.logs Process output, for one server or all of them
---
--- When a server misbehaves the answer is almost always in its stdout. This
--- tails it in place, follows new lines like `tail -f`, and stops following the
--- moment the user scrolls up — so reading a stack trace is never interrupted
--- by the view jumping to the bottom.
---
--- With several services running, watching them one window at a time hides the
--- thing you actually need: the order events happened in across processes. The
--- combined view interleaves every server by timestamp, tagged and coloured per
--- service, and can be narrowed to one service without losing that context.

local event = require("live_server.event")
local highlights = require("live_server.ui.highlights")
local util = require("live_server.util")
local window_mod = require("live_server.ui.window")

local M = {}

--- Hard cap on rendered lines. Beyond this the buffer costs more than it tells
--- you, and the ring buffers keep the rest anyway.
local MAX_LINES = 3000

---@class live_server.ui.LogState
---@field window live_server.ui.Window?
---@field servers live_server.Server[] everything this view covers
---@field isolated live_server.Server? narrowed to one service
---@field follow boolean
---@field timestamps boolean
---@field unsubscribe fun()|nil
---@field pending boolean
local state = {
  window = nil,
  servers = {},
  isolated = nil,
  follow = true,
  timestamps = false,
  unsubscribe = nil,
  pending = false,
}

--- Colour slots cycled across services, so each keeps a stable colour for as
--- long as the view is open.
local SERVICE_GROUPS = {
  "LiveServerLogService1",
  "LiveServerLogService2",
  "LiveServerLogService3",
  "LiveServerLogService4",
  "LiveServerLogService5",
  "LiveServerLogService6",
}

---@return live_server.Server[]
local function visible_servers()
  if state.isolated then
    return { state.isolated }
  end
  return state.servers
end

--- Short, unique-enough label for a service.
---@param server live_server.Server
---@return string
local function tag_for(server)
  local relative = util.relative(server.project.root, server.project.workdir)
  if relative and relative ~= "" then
    return relative
  end
  return server.project.name
end

---@class live_server.ui.LogEntry
---@field at integer
---@field seq integer global insertion order
---@field stream string
---@field text string
---@field server live_server.Server

--- Every line from every visible server, oldest first.
---@return live_server.ui.LogEntry[]
local function merged_entries()
  local servers = visible_servers()
  local entries = {}
  for _, server in ipairs(servers) do
    for _, line in ipairs(server:log_lines()) do
      entries[#entries + 1] = {
        at = line.at,
        seq = line.seq or 0,
        stream = line.stream,
        text = line.text,
        server = server,
      }
    end
  end

  -- Sequence first: it is a true global order across processes, where the
  -- timestamp is only as fine-grained as the event loop's cached clock.
  table.sort(entries, function(a, b)
    if a.seq ~= b.seq then
      return a.seq < b.seq
    end
    return a.at < b.at
  end)

  if #entries > MAX_LINES then
    local trimmed = {}
    for index = #entries - MAX_LINES + 1, #entries do
      trimmed[#trimmed + 1] = entries[index]
    end
    return trimmed
  end
  return entries
end

local function render()
  local window = state.window
  if not window or not window:is_valid() then
    return
  end

  local servers = visible_servers()
  local combined = #state.servers > 1

  ---@type table<string, string>
  local colour_of = {}
  for index, server in ipairs(state.servers) do
    colour_of[server.id] = SERVICE_GROUPS[((index - 1) % #SERVICE_GROUPS) + 1]
  end

  local tag_width = 0
  if combined then
    for _, server in ipairs(state.servers) do
      tag_width = math.max(tag_width, util.width(tag_for(server)))
    end
    tag_width = math.min(tag_width, 22)
  end

  local entries = merged_entries()
  local start_ms = math.huge
  for _, server in ipairs(servers) do
    start_ms = math.min(start_ms, server.started_at or util.now())
  end
  if start_ms == math.huge then
    start_ms = util.now()
  end

  local lines, marks = {}, {}
  if #entries == 0 then
    lines[1] = "  (no output yet)"
    marks[1] = { { group = "LiveServerHint", from = 0, to = #lines[1] } }
  else
    for index, entry in ipairs(entries) do
      local line, row_marks = "", {}

      if state.timestamps then
        local stamp = ("%7s  "):format("+" .. util.duration(math.max(0, entry.at - start_ms)))
        row_marks[#row_marks + 1] = { group = "LiveServerLogTime", from = 0, to = #stamp }
        line = stamp
      end

      if combined then
        -- Left-truncated, like the dashboard: `…_ai_server/socket` identifies
        -- the service, where `my-faithpal_ai…` is the same string for two of
        -- them.
        local tag = util.pad(util.truncate_left(tag_for(entry.server), tag_width), tag_width) .. " │ "
        row_marks[#row_marks + 1] = {
          group = colour_of[entry.server.id] or "LiveServerLogMeta",
          from = #line,
          to = #line + #tag,
        }
        line = line .. tag
      end

      local body_from = #line
      line = line .. entry.text
      local body_group = entry.stream == "stderr" and "LiveServerLogErr"
        or entry.stream == "system" and "LiveServerLogMeta"
        or nil
      if body_group then
        row_marks[#row_marks + 1] = { group = body_group, from = body_from, to = #line }
      end

      lines[index] = line
      marks[index] = row_marks
    end
  end

  window:set_lines(lines)
  window:clear_highlights()
  for index, row_marks in pairs(marks) do
    for _, mark in ipairs(row_marks) do
      window:highlight(mark.group, index - 1, mark.from, mark.to)
    end
  end

  if combined then
    window:set_title(
      state.isolated and ("%s — %s"):format(tag_for(state.isolated), state.isolated.status)
        or ("All output — %d services"):format(#state.servers)
    )
  else
    local server = servers[1]
    if server then
      window:set_title(
        ("%s — %s :%d (%s)"):format(server.project.name, server:display_name(), server.port, server.status)
      )
    end
  end

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

---@param servers live_server.Server[]
---@param title string
local function open_window(servers, title)
  highlights.apply()

  state.servers = servers
  state.isolated = nil
  state.follow = true

  if M.is_open() then
    render()
    state.window:focus()
    return
  end

  local window = window_mod.open({
    title = title,
    width = 0.85,
    height = 0.75,
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

  window:map("c", function()
    for _, server in ipairs(visible_servers()) do
      server.logs:clear()
    end
    render()
  end, "Clear the buffer")

  window:map("G", function()
    state.follow = true
    render()
  end, "Jump to the end and follow")

  window:map("r", function()
    local target = state.isolated or state.servers[1]
    if target then
      require("live_server.manager").restart(target)
    end
  end, "Restart this server")

  window:map("y", function()
    local text = {}
    for _, entry in ipairs(merged_entries()) do
      text[#text + 1] = entry.text
    end
    require("live_server.remote").copy(table.concat(text, "\n"))
    require("live_server.log").notify(("Copied %d lines."):format(#text), "info")
  end, "Copy visible output")

  -- Number keys narrow to one service and back, so a noisy neighbour can be
  -- silenced without losing the merged view.
  for index = 1, math.min(9, #servers) do
    window:map(tostring(index), function()
      local target = state.servers[index]
      if not target then
        return
      end
      state.isolated = (state.isolated == target) and nil or target
      state.follow = true
      render()
    end, "Show only service " .. index)
  end
  window:map("0", function()
    state.isolated = nil
    render()
  end, "Show every service")

  -- Any manual cursor movement away from the last line means the user is
  -- reading; stop yanking the viewport out from under them.
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = window.buf,
    callback = function()
      if not window:is_open() then
        return
      end
      state.follow = window:cursor_row() >= vim.api.nvim_buf_line_count(window.buf)
    end,
    desc = "live-server: pause log following while scrolled up",
  })

  state.unsubscribe = event.on("*", function(payload)
    if not payload.server then
      return
    end
    for _, server in ipairs(state.servers) do
      if server == payload.server then
        request_render()
        return
      end
    end
  end)

  window:on_close(function()
    if state.unsubscribe then
      state.unsubscribe()
      state.unsubscribe = nil
    end
    state.window = nil
    state.servers = {}
    state.isolated = nil
  end)

  render()
end

--- Show output for one server.
---@param server live_server.Server
function M.open(server)
  open_window({ server }, server.project.name)
end

--- Show every server's output in one window, interleaved by time.
---@param servers? live_server.Server[] defaults to everything active
function M.open_all(servers)
  servers = servers or require("live_server.manager").servers({ active_only = true })
  if #servers == 0 then
    require("live_server.log").notify("No servers are running.", "warn")
    return
  end
  if #servers == 1 then
    return M.open(servers[1])
  end
  open_window(servers, "All output")
end

--- Legend mapping number keys to services, for the help overlay.
---@return string[]
function M.legend()
  local out = {}
  for index, server in ipairs(state.servers) do
    out[#out + 1] = ("%d  %s"):format(index, tag_for(server))
  end
  return out
end

return M
