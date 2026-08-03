---@mod live_server.trust Consent for project files that change what gets executed
---
--- A repository can ship a `.liveserverrc.json`. Fields that only describe
--- *where* to serve from are harmless. Fields that decide *what process runs*
--- (`command`, `args`, `env`) are code execution by another name, so cloning a
--- repository and opening a file in it must never be enough to run them.
---
--- The model matches Neovim's own `:trust`: consent is recorded against the
--- exact file contents, so any edit — by a teammate, a dependency bot, or a
--- malicious PR — revokes it automatically.

local log = require("live_server.log")
local store = require("live_server.store")
local util = require("live_server.util")

local M = {}

--- Fields that require consent before they take effect.
M.PRIVILEGED_FIELDS = { "command", "args", "env" }

---@return live_server.Store
local function db()
  return store.open("trust")
end

---@param path string
---@param content string
---@return string
local function record_key(path, content)
  return util.sha256(util.normalize(path) .. "\0" .. content)
end

--- Recorded decision for this exact file content.
---@param path string
---@param content string
---@return "allow"|"deny"|"unknown"
function M.decision(path, content)
  local mode = require("live_server.config").get().project.trust
  if mode == "allow" then
    return "allow"
  elseif mode == "deny" then
    return "deny"
  end
  local record = db():get(record_key(path, content))
  if type(record) == "table" and (record.decision == "allow" or record.decision == "deny") then
    return record.decision
  end
  return "unknown"
end

---@param path string
---@param content string
---@param decision "allow"|"deny"
function M.record(path, content, decision)
  db():set(record_key(path, content), {
    path = util.normalize(path),
    decision = decision,
    at = os.time(),
  }):save()
  log.info("recorded trust decision", { path = path, decision = decision })
end

--- Forget every decision for `path`, or all of them when `path` is nil.
---@param path? string
---@return integer removed
function M.revoke(path)
  local database = db()
  local removed = 0
  local target = path and util.normalize(path) or nil
  for key, record in pairs(database:all()) do
    if not target or (type(record) == "table" and record.path == target) then
      database:delete(key)
      removed = removed + 1
    end
  end
  database:save()
  return removed
end

--- Every recorded decision, newest first.
---@return { path: string, decision: string, at: integer }[]
function M.list()
  local out = {}
  for _, record in pairs(db():all()) do
    if type(record) == "table" and record.path then
      out[#out + 1] = record
    end
  end
  table.sort(out, function(a, b)
    return (a.at or 0) > (b.at or 0)
  end)
  return out
end

---@param privileged table
---@return string[]
local function describe(privileged)
  local lines = {}
  if privileged.command then
    local argv = type(privileged.command) == "table" and privileged.command or { privileged.command }
    local full = vim.deepcopy(argv)
    for _, arg in ipairs(privileged.args or {}) do
      full[#full + 1] = arg
    end
    lines[#lines + 1] = "  run:  " .. util.join_argv(full)
  elseif privileged.args then
    lines[#lines + 1] = "  extra arguments:  " .. util.join_argv(privileged.args)
  end
  if privileged.env then
    for _, name in ipairs(util.sorted_keys(privileged.env)) do
      lines[#lines + 1] = ("  env:  %s=%s"):format(name, tostring(privileged.env[name]))
    end
  end
  return lines
end

--- Ask the user whether to honour the privileged fields in a project file.
--- Never blocks: the decision arrives through `callback`.
---@param opts { path: string, content: string, privileged: table }
---@param callback fun(granted: boolean)
function M.request(opts, callback)
  local prompt = table.concat({
    ("%s wants to control how the dev server is launched:"):format(vim.fn.fnamemodify(opts.path, ":~")),
    "",
    table.concat(describe(opts.privileged), "\n"),
    "",
    "Only allow this if you trust this repository.",
  }, "\n")

  vim.ui.select({
    "Deny — ignore these fields",
    "Allow once (this session)",
    "Allow and remember this file version",
    "Open the file first",
  }, { prompt = prompt }, function(choice)
    if choice == nil or choice:match("^Deny") then
      M.record(opts.path, opts.content, "deny")
      return callback(false)
    end
    if choice:match("^Open") then
      vim.cmd.split(vim.fn.fnameescape(opts.path))
      log.notify("Review the file, then run the command again.", "info")
      return callback(false)
    end
    if choice:match("^Allow and remember") then
      M.record(opts.path, opts.content, "allow")
    end
    callback(true)
  end)
end

--- Resolve trust for a project, prompting only when a decision is genuinely
--- needed. `callback(granted)` runs on the main loop.
---@param project live_server.Project
---@param callback fun(granted: boolean)
function M.ensure(project, callback)
  if not project.config_path or not project.privileged or vim.tbl_isempty(project.privileged) then
    return callback(true)
  end
  local decision = M.decision(project.config_path, project.config_content or "")
  if decision == "allow" then
    return callback(true)
  elseif decision == "deny" then
    return callback(false)
  end
  M.request({
    path = project.config_path,
    content = project.config_content or "",
    privileged = project.privileged,
  }, callback)
end

return M
