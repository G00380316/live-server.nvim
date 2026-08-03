---@mod live_server.ui.dashboard The server manager panel
---
--- One screen that answers every question a developer has about their dev
--- servers — what is running, where, on which port, since when, and is it
--- reachable — and lets them act on all of it without leaving the window.
---
--- Refreshes are event-driven. A timer only runs while something is actually
--- animating, so an idle dashboard costs nothing.

local event = require("live_server.event")
local highlights = require("live_server.ui.highlights")
local icons = require("live_server.ui.icons")
local log = require("live_server.log")
local manager = require("live_server.manager")
local port_mod = require("live_server.port")
local project_mod = require("live_server.project")
local prompt = require("live_server.ui.prompt")
local remote = require("live_server.remote")
local util = require("live_server.util")
local window_mod = require("live_server.ui.window")

local M = {}

---@class live_server.ui.Row
---@field text string
---@field marks { group: string, from: integer, to: integer }[]
---@field server live_server.Server?
---@field kind string

---@class live_server.ui.DashboardState
---@field window live_server.ui.Window?
---@field rows live_server.ui.Row[]
---@field timer any
---@field tick integer
---@field unsubscribe fun()|nil
---@field pending boolean
local state = {
  window = nil,
  rows = {},
  timer = nil,
  tick = 0,
  unsubscribe = nil,
  pending = false,
}

local STATUS_LABEL = {
  running = "running",
  starting = "starting",
  stopping = "stopping",
  stopped = "stopped",
  crashed = "crashed",
  unhealthy = "no answer",
}

--------------------------------------------------------------------------------
-- Row construction
--------------------------------------------------------------------------------

---@param text string
---@param kind string
---@param opts? { server?: live_server.Server, marks?: table[] }
---@return live_server.ui.Row
local function row(text, kind, opts)
  opts = opts or {}
  return { text = text, kind = kind, server = opts.server, marks = opts.marks or {} }
end

--- Append a highlighted segment and return the updated line.
---@param line string
---@param marks table[]
---@param text string
---@param group string?
---@return string
local function append(line, marks, text, group)
  local from = #line
  local result = line .. text
  if group and text ~= "" then
    marks[#marks + 1] = { group = group, from = from, to = #result }
  end
  return result
end

---@param server live_server.Server
---@return string, string
local function status_glyph(server)
  if server.status == "starting" or server.status == "stopping" then
    return icons.spinner(state.tick), highlights.for_status(server.status)
  end
  return icons.get(server.status), highlights.for_status(server.status)
end

---@param server live_server.Server
---@return string[]
local function badges(server)
  local out = {}
  if port_mod.get_pin(server.project.workdir, server.adapter.name) == server.port then
    out[#out + 1] = icons.prefix("pinned") .. "pinned"
  end
  if server.exposed then
    out[#out + 1] = icons.prefix("exposed") .. "network"
  end
  if not server:has_live_reload() and server:is_active() then
    out[#out + 1] = "no reload"
  end
  if server.restarts > 0 then
    out[#out + 1] = ("restarts %d"):format(server.restarts)
  end
  return out
end

---@param servers live_server.Server[]
---@param width integer
---@return live_server.ui.Row[]
local function build_rows(servers, width)
  local rows = {}
  local active = 0
  for _, server in ipairs(servers) do
    if server:is_active() then
      active = active + 1
    end
  end

  -- Summary line
  do
    local marks = {}
    local line = " "
    if #servers == 0 then
      line = append(line, marks, "No servers", "LiveServerHint")
    else
      line = append(line, marks, ("%d running"):format(active), active > 0 and "LiveServerRunning" or "LiveServerHint")
      if #servers > active then
        line = append(line, marks, "  " .. icons.get("separator") .. "  ", "LiveServerHint")
        line = append(line, marks, ("%d stopped"):format(#servers - active), "LiveServerHint")
      end
    end
    if remote.is_remote() then
      line = append(line, marks, "  " .. icons.get("separator") .. "  ", "LiveServerHint")
      line = append(line, marks, icons.prefix("remote") .. "ssh session", "LiveServerBadge")
    end
    rows[#rows + 1] = row(line, "summary", { marks = marks })
    rows[#rows + 1] = row("", "blank")
  end

  if #servers == 0 then
    local cfg = require("live_server.config").get()
    local keys = cfg.ui.keys
    local first_key = type(keys.new) == "table" and keys.new[1] or keys.new
    local help_key = type(keys.help) == "table" and keys.help[1] or keys.help
    local project = project_mod.get()

    local marks = {}
    local line = append("  ", marks, "Nothing is running yet.", "LiveServerHeader")
    rows[#rows + 1] = row(line, "empty", { marks = marks })
    rows[#rows + 1] = row("", "blank")

    for _, hint in ipairs({
      { first_key, ("start a server for %s"):format(project.name) },
      { help_key, "show every key" },
    }) do
      if hint[1] then
        local hint_marks = {}
        local hint_line = append("  ", hint_marks, util.pad(tostring(hint[1]), 4), "LiveServerKey")
        hint_line = append(hint_line, hint_marks, hint[2], "LiveServerHint")
        rows[#rows + 1] = row(hint_line, "hint", { marks = hint_marks })
      end
    end
    return rows
  end

  -- Column widths, computed from the data so nothing is truncated needlessly,
  -- then capped so one long backend name cannot push the rest off screen.
  local adapter_width, port_width, sub_width = 0, 0, 0
  for _, server in ipairs(servers) do
    adapter_width = math.max(adapter_width, util.width(server:display_name()))
    port_width = math.max(port_width, util.width(tostring(server.port)))
    local relative = util.relative(server.project.root, server.project.workdir)
    if relative and relative ~= "" then
      sub_width = math.max(sub_width, util.width(relative))
    end
  end
  adapter_width = math.floor(util.clamp(adapter_width, 6, math.max(10, width * 0.25)))
  -- Only as wide as it needs to be, and zero when every server sits at its
  -- repository root — the common case must not pay for the monorepo one.
  -- Generous, because this column is what tells `api` from `api/socket`, and a
  -- cap that collapses two names to the same string is worse than no column.
  sub_width = math.floor(math.min(sub_width, math.max(12, width * 0.34)))

  ---@type table<string, live_server.Server[]>
  local grouped, order = {}, {}
  for _, server in ipairs(servers) do
    local key = server.project.root
    if not grouped[key] then
      grouped[key] = {}
      order[#order + 1] = key
    end
    table.insert(grouped[key], server)
  end

  for index, root in ipairs(order) do
    if index > 1 then
      rows[#rows + 1] = row("", "blank")
    end

    local group = grouped[root]
    local marks = {}
    local line = append(" ", marks, icons.prefix("project"), "LiveServerProject")
    -- The repository's own name: a derived project's `name` already carries
    -- the sub-path, which the per-server column shows.
    line = append(line, marks, vim.fn.fnamemodify(root, ":t"), "LiveServerProject")
    local remaining = width - util.width(line) - 3
    if remaining > 12 then
      line = append(line, marks, "  " .. util.shorten_path(root, remaining), "LiveServerHint")
    end
    rows[#rows + 1] = row(line, "project", { marks = marks })

    for _, server in ipairs(group) do
      local server_marks = {}
      local glyph, glyph_group = status_glyph(server)

      local text = "  "
      if glyph ~= "" then
        text = append(text, server_marks, util.pad(glyph, icons.status_width()) .. " ", glyph_group)
      end
      text = append(
        text,
        server_marks,
        util.pad(util.truncate(server:display_name(), adapter_width), adapter_width + 2),
        "LiveServerAdapter"
      )
      if sub_width > 0 then
        local sub = util.relative(server.project.root, server.project.workdir) or ""
        -- Truncate from the left: `…_ai_server/socket` still identifies the
        -- app, where `my-faithpal_…` is the same string for three of them.
        text =
          append(text, server_marks, util.pad(util.truncate_left(sub, sub_width), sub_width + 2), "LiveServerProject")
      end
      text = append(text, server_marks, util.pad(STATUS_LABEL[server.status] or server.status, 11), glyph_group)
      text = append(text, server_marks, util.pad(":" .. server.port, port_width + 3), "LiveServerPort")

      local badge_list = badges(server)
      local badge_text = #badge_list > 0 and table.concat(badge_list, "  ") or ""
      local uptime = (server:is_active() and server.ready_at) and ("up " .. util.duration(server:uptime())) or ""

      -- Pad the uptime column only while the badges still fit after it.
      -- Alignment is worth less than telling the user a server has no live
      -- reload, so the padding yields first.
      local uptime_width = 9
      if badge_text ~= "" and util.width(text) + uptime_width + util.width(badge_text) + 2 > width then
        uptime_width = util.width(uptime) + (uptime ~= "" and 2 or 0)
      end
      text = append(text, server_marks, util.pad(uptime, uptime_width), "LiveServerHint")

      if badge_text ~= "" and util.width(text) + util.width(badge_text) <= width then
        text = append(text, server_marks, badge_text, "LiveServerBadge")
      end

      rows[#rows + 1] = row(text, "server", { server = server, marks = server_marks })

      local cfg = require("live_server.config").get()
      if not cfg.ui.compact and server:is_active() then
        local url_marks = {}
        local indent = "     "
        local url = remote.is_remote() and remote.local_url(server) or server:url()
        local url_width = math.max(20, width - #indent - 2)
        local url_line = append(indent, url_marks, util.truncate(url, url_width), "LiveServerUrl")
        rows[#rows + 1] = row(url_line, "url", { server = server, marks = url_marks })
      end
    end
  end

  return rows
end

---@return live_server.ui.Row[]
local function footer_rows(width)
  local cfg = require("live_server.config").get()
  if not cfg.ui.footer then
    return {}
  end

  local keys = cfg.ui.keys
  ---@param value any
  ---@return string
  local function first(value)
    if type(value) == "table" then
      return tostring(value[1])
    end
    return tostring(value)
  end

  local pairs_list = {
    { first(keys.open), "open" },
    { first(keys.toggle), "start/stop" },
    { first(keys.restart), "restart" },
    { first(keys.change_port), "port" },
    { first(keys.logs), "logs" },
    { first(keys.yank_url), "copy" },
    { first(keys.new), "new" },
    { first(keys.help), "help" },
  }

  local marks = {}
  local line = " "
  for index, entry in ipairs(pairs_list) do
    if entry[1] ~= "nil" then
      if index > 1 then
        line = append(line, marks, "  ", nil)
      end
      line = append(line, marks, entry[1], "LiveServerKey")
      line = append(line, marks, " " .. entry[2], "LiveServerHint")
    end
  end

  return {
    row("", "blank"),
    row(string.rep("─", math.max(0, width)), "separator", {
      marks = { { group = "LiveServerSeparator", from = 0, to = -1 } },
    }),
    row(util.truncate(line, width - 1), "footer", { marks = marks }),
  }
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

---@return boolean
local function needs_animation()
  for _, server in ipairs(manager.servers()) do
    if server.status == "starting" or server.status == "stopping" then
      return true
    end
  end
  return false
end

local function stop_timer()
  if state.timer then
    pcall(function()
      state.timer:stop()
      state.timer:close()
    end)
    state.timer = nil
  end
end

local render

--- Run the refresh timer only as fast as the current state warrants: fast while
--- a spinner is turning, once a second otherwise for the uptime column, and not
--- at all when nothing is active.
local function schedule_timer()
  stop_timer()
  if not state.window or not state.window:is_valid() then
    return
  end

  local interval
  if needs_animation() then
    interval = require("live_server.config").get().ui.refresh
  elseif manager.count_active() > 0 then
    interval = 1000
  else
    return
  end

  local timer = util.uv.new_timer()
  if not timer then
    return
  end
  state.timer = timer
  timer:start(interval, interval, function()
    vim.schedule(function()
      state.tick = state.tick + 1
      render()
    end)
  end)
end

render = function()
  local window = state.window
  if not window or not window:is_valid() then
    return
  end

  local width = window:width()
  local servers = manager.servers()
  local rows = build_rows(servers, width)
  vim.list_extend(rows, footer_rows(width))

  state.rows = rows

  local lines = {}
  for _, entry in ipairs(rows) do
    lines[#lines + 1] = entry.text
  end

  window:set_lines(lines)
  window:clear_highlights()
  for index, entry in ipairs(rows) do
    for _, mark in ipairs(entry.marks) do
      local to = mark.to
      if to == -1 then
        to = #entry.text
      end
      window:highlight(mark.group, index - 1, mark.from, to)
    end
  end

  local active = manager.count_active()
  window:set_title(active > 0 and ("Live Server — %d active"):format(active) or "Live Server")

  schedule_timer()
end

--- Coalesce bursts of events into a single redraw on the next tick.
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

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

---@return live_server.Server?
local function current_server()
  if not state.window or not state.window:is_valid() then
    return nil
  end
  local entry = state.rows[state.window:cursor_row()]
  return entry and entry.server or nil
end

---@param message string
---@return live_server.Server?
local function require_server(message)
  local server = current_server()
  if not server then
    log.notify(message or "Put the cursor on a server first.", "warn")
  end
  return server
end

---@param direction 1|-1
local function move_to_server(direction)
  if not state.window or not state.window:is_valid() then
    return
  end
  local current = state.window:cursor_row()
  local total = #state.rows
  for step = 1, total do
    local index = current + direction * step
    if index < 1 then
      index = total + index
    elseif index > total then
      index = index - total
    end
    local entry = state.rows[index]
    if entry and entry.kind == "server" then
      state.window:set_cursor_row(index)
      return
    end
  end
end

local function action_open()
  local server = require_server("Move to a server to open it.")
  if server then
    require("live_server.browser").open(server)
  end
end

local function action_toggle()
  local server = current_server()
  if server then
    if server:is_active() then
      manager.stop(server)
    else
      server.restarts = 0
      server:start()
    end
    return
  end
  -- No server under the cursor: the useful default is "start one here".
  manager.start({})
end

local function action_restart()
  local server = require_server("Move to a server to restart it.")
  if server then
    manager.restart(server)
  end
end

local function action_logs()
  local server = require_server("Move to a server to see its output.")
  if server then
    require("live_server.ui.logs").open(server)
  end
end

local function action_yank()
  local server = require_server("Move to a server to copy its URL.")
  if not server then
    return
  end
  local url = remote.is_remote() and remote.local_url(server) or server:url()
  local copied, method = remote.copy(url)
  log.notify(
    copied and ("Copied %s (%s)"):format(url, method) or ("Could not copy; the URL is %s"):format(url),
    copied and "info" or "warn"
  )
end

local function action_change_port()
  local server = require_server("Move to a server to change its port.")
  if not server then
    return
  end
  prompt.port({ default = server.port, host = server.host, prompt = "New port: " }, function(port)
    if not port then
      return
    end
    if server:is_active() then
      manager.change_port(server, port)
    else
      server.port = port
      request_render()
    end
  end)
end

local function action_pin()
  local server = require_server("Move to a server to pin its port.")
  if not server then
    return
  end
  local pinned = port_mod.get_pin(server.project.workdir, server.adapter.name)
  if pinned == server.port then
    port_mod.unpin(server.project.workdir, server.adapter.name)
    log.notify(("Unpinned %s for %s."):format(server.adapter.display, server.project.name), "info")
  else
    port_mod.pin(server.project.workdir, server.adapter.name, server.port)
    log.notify(
      ("Pinned %s to port %d for %s — it will reuse this port from now on."):format(
        server.adapter.display,
        server.port,
        server.project.name
      ),
      "info"
    )
  end
  request_render()
end

local function action_new()
  prompt.adapter({ prompt = "Start which server?" }, function(adapter_name)
    if not adapter_name then
      return
    end
    manager.start({ adapter = adapter_name })
  end)
end

local function action_start_all()
  local project = project_mod.get()
  prompt.confirm(("Start every app in %s?"):format(project.name), {}, function(confirmed)
    if confirmed then
      manager.start_all({})
    end
  end)
end

local function action_delete()
  local server = require_server("Move to a server to remove it.")
  if not server then
    return
  end
  if server:is_active() then
    manager.stop(server, function()
      manager.forget(server)
    end)
  else
    manager.forget(server)
  end
end

local function action_expose()
  local server = require_server("Move to a server to change how it is bound.")
  if not server then
    return
  end
  if server.exposed then
    manager.stop(server, function()
      manager.forget(server)
      manager.start({ adapter = server.adapter.name, dir = server.project.workdir, port = server.port, expose = false })
    end)
    return
  end
  manager.stop(server, function()
    manager.forget(server)
    manager.start({ adapter = server.adapter.name, dir = server.project.workdir, port = server.port, expose = true })
  end)
end

local function action_forward_hint()
  local server = require_server("Move to a server to get its forwarding command.")
  if not server then
    return
  end
  if not remote.is_remote() then
    log.notify("This is a local session — no forwarding needed:\n  " .. server:url(), "info")
    return
  end
  local command = remote.forward_command(server)
  local copied = remote.copy(command)
  log.notify(
    ("Run this on your machine:\n  %s%s"):format(command, copied and "\n\n(copied to your clipboard)" or ""),
    "info"
  )
end

local function action_stop_all()
  local active = manager.count_active()
  if active == 0 then
    log.notify("Nothing is running.", "info")
    return
  end
  prompt.confirm(("Stop all %d running server%s?"):format(active, active == 1 and "" or "s"), {}, function(confirmed)
    if confirmed then
      manager.stop_all()
    end
  end)
end

local function action_refresh()
  require("live_server.adapters").refresh()
  project_mod.invalidate()
  request_render()
  log.notify("Refreshed.", "info")
end

--------------------------------------------------------------------------------
-- Help overlay
--------------------------------------------------------------------------------

local function action_help()
  local cfg = require("live_server.config").get()
  local keys = cfg.ui.keys

  ---@param value any
  ---@return string
  local function label(value)
    if type(value) == "table" then
      return table.concat(value, " / ")
    end
    return tostring(value)
  end

  local entries = {
    { label(keys.open), "Open the server's page in a browser" },
    { label(keys.toggle), "Start or stop the server under the cursor" },
    { label(keys.restart), "Restart it, keeping the same port" },
    { label(keys.change_port), "Move it to a different port" },
    { label(keys.pin_port), "Pin / unpin this port to the project" },
    { label(keys.logs), "Show the process output" },
    { label(keys.yank_url), "Copy the URL to the clipboard" },
    { label(keys.new), "Start a new server here" },
    { label(keys.start_all), "Start every app in this repository" },
    { label(keys.delete), "Stop and remove the entry" },
    { label(keys.expose), "Toggle exposing it on the local network" },
    { label(keys.forward_hint), "Show the ssh port-forwarding command" },
    { label(keys.stop_all), "Stop every running server" },
    { label(keys.refresh), "Re-scan installed backends" },
    { "<Tab> / <S-Tab>", "Jump between servers" },
    { label(keys.close), "Close this window" },
  }

  local width = 0
  for _, entry in ipairs(entries) do
    width = math.max(width, util.width(entry[1]))
  end

  local help = window_mod.open({
    title = "Live Server — keys",
    width = math.min(66, vim.o.columns - 8),
    height = math.min(#entries + 4, vim.o.lines - 6),
    filetype = "liveserver-help",
  })

  local lines, marks = {}, {}
  lines[#lines + 1] = ""
  for _, entry in ipairs(entries) do
    local key_text = "  " .. util.pad(entry[1], width + 3)
    lines[#lines + 1] = key_text .. entry[2]
    marks[#marks + 1] = { row = #lines - 1, from = 2, to = 2 + #entry[1], group = "LiveServerKey" }
    marks[#marks + 1] = { row = #lines - 1, from = #key_text, to = #key_text + #entry[2], group = "LiveServerHint" }
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  Every action is also available as `:LiveServer <subcommand>`."
  marks[#marks + 1] = { row = #lines - 1, from = 0, to = -1, group = "LiveServerHint" }

  help:set_lines(lines)
  for _, mark in ipairs(marks) do
    help:highlight(mark.group, mark.row, mark.from, mark.to == -1 and #lines[mark.row + 1] or mark.to)
  end
  help:map({ "q", "<Esc>", "?" }, function()
    help:close()
  end, "Close help")
end

--------------------------------------------------------------------------------
-- Open / close
--------------------------------------------------------------------------------

---@return boolean
function M.is_open()
  return state.window ~= nil and state.window:is_valid()
end

function M.close()
  if state.window then
    state.window:close()
  end
end

--- Open the manager.
function M.open()
  if M.is_open() then
    state.window:focus()
    return
  end

  highlights.setup()

  local window = window_mod.open({
    title = "Live Server",
    filetype = "liveserver",
  })
  state.window = window
  state.tick = 0

  local cfg = require("live_server.config").get()
  local keys = cfg.ui.keys

  window:map(keys.open, action_open, "Open in browser")
  window:map(keys.toggle, action_toggle, "Start/stop server")
  window:map(keys.restart, action_restart, "Restart server")
  window:map(keys.logs, action_logs, "Show server output")
  window:map(keys.yank_url, action_yank, "Copy URL")
  window:map(keys.change_port, action_change_port, "Change port")
  window:map(keys.pin_port, action_pin, "Pin/unpin port")
  window:map(keys.new, action_new, "Start a new server")
  window:map(keys.start_all, action_start_all, "Start every app here")
  window:map(keys.delete, action_delete, "Stop and remove")
  window:map(keys.expose, action_expose, "Toggle network exposure")
  window:map(keys.forward_hint, action_forward_hint, "SSH forwarding command")
  window:map(keys.stop_all, action_stop_all, "Stop all servers")
  window:map(keys.refresh, action_refresh, "Refresh")
  window:map(keys.help, action_help, "Help")
  window:map(keys.close, function()
    window:close()
  end, "Close")
  window:map("<Tab>", function()
    move_to_server(1)
  end, "Next server")
  window:map("<S-Tab>", function()
    move_to_server(-1)
  end, "Previous server")

  state.unsubscribe = event.on("changed", request_render)

  window:on_close(function()
    stop_timer()
    if state.unsubscribe then
      state.unsubscribe()
      state.unsubscribe = nil
    end
    state.window = nil
    state.rows = {}
  end)

  render()

  -- Land the cursor on the first server rather than the summary line.
  for index, entry in ipairs(state.rows) do
    if entry.kind == "server" then
      window:set_cursor_row(index)
      break
    end
  end
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

--- Force a redraw from outside (used by the command layer).
function M.refresh()
  if M.is_open() then
    request_render()
  end
end

return M
