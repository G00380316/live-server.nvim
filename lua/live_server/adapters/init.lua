---@mod live_server.adapters Pluggable server backends
---
--- An adapter turns "serve this directory on this port" into an argv list. That
--- is the entire contract, which is what makes it easy to add Vite, `caddy
--- file-server`, or an internal tool without touching the rest of the plugin.
---
--- Nothing here ever builds a shell string: argv lists are passed straight to
--- `jobstart`, so a directory named `; rm -rf ~` is just a directory name.

local log = require("live_server.log")
local util = require("live_server.util")

local M = {}

---@class live_server.SpawnContext
---@field host string interface to bind
---@field port integer
---@field serve_dir string absolute directory to serve
---@field project live_server.Project
---@field config live_server.Config
---@field entry_file string? SPA fallback document
---@field ignore string[] glob patterns excluded from watching
---@field extensions string[] file extensions that trigger a reload
---@field delay integer reload debounce in milliseconds
---@field extra string[] user-supplied extra arguments

---@class live_server.AdapterSpec
---@field name string stable identifier used in commands and pins
---@field display string human label
---@field bin string primary executable
---@field install string how to install it
---@field live_reload boolean does it push changes to the browser
---@field supports table<string, boolean> optional capabilities
---@field build fun(ctx: live_server.SpawnContext): string[] argv
---@field detect? fun(): boolean override for availability
---@field version_args? string[] arguments that print a version

---@type table<string, live_server.AdapterSpec>
local registry = {}

---@type string[]
local builtin_names = { "live_server", "browser_sync", "serve", "python" }

---@type table<string, boolean>
local availability_cache = {}

local function load_builtins()
  if next(registry) ~= nil then
    return
  end
  for _, name in ipairs(builtin_names) do
    local ok, spec = pcall(require, "live_server.adapters." .. name)
    if ok and type(spec) == "table" then
      registry[spec.name or name] = spec
    else
      log.error("failed to load builtin adapter", { name = name, err = tostring(spec) })
    end
  end
end

--- Register (or replace) an adapter.
---@param spec live_server.AdapterSpec
function M.register(spec)
  load_builtins()
  assert(type(spec) == "table" and type(spec.name) == "string", "adapter needs a name")
  assert(type(spec.build) == "function", "adapter needs a build() function")
  registry[spec.name] = vim.tbl_extend("keep", spec, {
    display = spec.name,
    bin = spec.name,
    install = "",
    live_reload = false,
    supports = {},
  })
  availability_cache[spec.name] = nil
end

--- Merge user-defined adapters from `config.adapters`.
local function load_user_adapters()
  local cfg = require("live_server.config").get()
  for name, spec in pairs(cfg.adapters or {}) do
    if not registry[name] or registry[name].__user then
      local copy = vim.tbl_extend("force", { name = name }, spec)
      copy.__user = true
      if type(copy.build) == "function" then
        M.register(copy)
      elseif type(copy.command) == "table" then
        -- Convenience form: a fixed command with `{port}`/`{dir}`/`{host}`
        -- placeholders, so simple cases need no Lua.
        copy.build = function(ctx)
          local argv = {}
          for _, arg in ipairs(spec.command) do
            argv[#argv + 1] = (
              arg:gsub("{(%w+)}", {
                port = tostring(ctx.port),
                host = ctx.host,
                dir = ctx.serve_dir,
                root = ctx.project.root,
              })
            )
          end
          return argv
        end
        M.register(copy)
      else
        log.error("user adapter needs build() or command", { name = name })
      end
    end
  end
end

--- Adapter by name.
---@param name string
---@return live_server.AdapterSpec?
function M.get(name)
  load_builtins()
  load_user_adapters()
  return registry[name]
end

--- Every registered adapter, in a stable order.
---@return live_server.AdapterSpec[]
function M.all()
  load_builtins()
  load_user_adapters()
  local out = {}
  for _, name in ipairs(util.sorted_keys(registry)) do
    out[#out + 1] = registry[name]
  end
  return out
end

---@return string[]
function M.names()
  local out = {}
  for _, spec in ipairs(M.all()) do
    out[#out + 1] = spec.name
  end
  return out
end

--- Is the backing executable installed? Cached, because `executable()` hits the
--- filesystem and the dashboard asks repeatedly.
---@param name string
---@param opts? { refresh?: boolean }
---@return boolean
function M.available(name, opts)
  if opts and opts.refresh then
    availability_cache[name] = nil
  end
  if availability_cache[name] ~= nil then
    return availability_cache[name]
  end
  local spec = M.get(name)
  if not spec then
    return false
  end
  local ok
  if spec.detect then
    ok = spec.detect() == true
  else
    ok = util.executable(spec.bin)
  end
  availability_cache[name] = ok
  return ok
end

--- Forget cached availability, e.g. after the user installs something.
function M.refresh()
  availability_cache = {}
end

--- Resolve the adapter to use.
---@param name? string explicit request, or `"auto"`/nil
---@return live_server.AdapterSpec? spec
---@return string? err
function M.resolve(name)
  local cfg = require("live_server.config").get()
  name = name or cfg.server or "auto"

  if name ~= "auto" then
    local spec = M.get(name)
    if not spec then
      return nil, ("unknown server '%s' (known: %s)"):format(name, table.concat(M.names(), ", "))
    end
    if not M.available(name) then
      return nil, ("%s is not installed. %s"):format(spec.display, spec.install)
    end
    return spec, nil
  end

  for _, candidate in ipairs(cfg.adapter_priority) do
    if M.get(candidate) and M.available(candidate) then
      return M.get(candidate), nil
    end
  end

  -- Nothing from the priority list; take anything at all before giving up.
  for _, spec in ipairs(M.all()) do
    if M.available(spec.name) then
      return spec, nil
    end
  end

  local hints = {}
  for _, candidate in ipairs(cfg.adapter_priority) do
    local spec = M.get(candidate)
    if spec and spec.install ~= "" then
      hints[#hints + 1] = "  " .. spec.install
    end
  end
  return nil, "no dev server found. Install one of:\n" .. table.concat(hints, "\n")
end

--- Read an adapter's version string, asynchronously. Used by `:checkhealth`.
---@param name string
---@param callback fun(version: string?)
function M.version(name, callback)
  local spec = M.get(name)
  if not spec or not M.available(name) then
    return callback(nil)
  end
  local argv = { spec.bin }
  for _, arg in ipairs(spec.version_args or { "--version" }) do
    argv[#argv + 1] = arg
  end

  local output = {}
  local ok = pcall(vim.fn.jobstart, argv, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      vim.list_extend(output, data or {})
    end,
    on_stderr = function(_, data)
      vim.list_extend(output, data or {})
    end,
    on_exit = function()
      local version
      for _, line in ipairs(output) do
        local trimmed = vim.trim(util.strip_ansi(line))
        if trimmed ~= "" then
          version = trimmed:match("%d+%.%d+%.%d+") or trimmed
          break
        end
      end
      vim.schedule(function()
        callback(version)
      end)
    end,
  })
  if not ok then
    callback(nil)
  end
end

--- Shared helper: comma-joined ignore globs, capped so the argv stays sane.
---@param ctx live_server.SpawnContext
---@return string[]
function M.ignore_globs(ctx)
  local out = {}
  for _, pattern in ipairs(ctx.ignore) do
    out[#out + 1] = pattern
  end
  return out
end

return M
