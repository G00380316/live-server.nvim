---@mod live-server live-server.nvim
---@brief [[
--- A development server manager for Neovim.
---
--- Start, stop and watch static dev servers without leaving the editor; pin a
--- port to a project so its URL never changes; and get sane behaviour when the
--- editor is running over SSH.
---
--- Quick start: >lua
---     require("live_server").setup({})
--- <
--- then `:LiveServer` opens the manager and `:LiveServer toggle` starts or
--- stops a server for the current project.
---@brief ]]

local M = {}

---@type boolean
local initialised = false

--- Configure the plugin. Optional: every entry point calls this with defaults
--- on first use, so the plugin works with no configuration at all.
---@param opts? live_server.Config
---@return live_server.Config
function M.setup(opts)
  local config = require("live_server.config")
  local options = config.setup(opts or vim.g.live_server or {})

  require("live_server.project").invalidate()
  require("live_server.remote").invalidate()
  require("live_server.adapters").refresh()
  require("live_server.ui.highlights").setup()
  require("live_server.commands").setup()

  if not initialised then
    initialised = true

    local group = vim.api.nvim_create_augroup("LiveServerNvim", { clear = true })

    -- Stop children before Neovim exits. `VimLeavePre` runs early enough that
    -- we can still wait for processes; `VimLeave` cannot be relied on for that.
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = group,
      callback = function()
        require("live_server.manager").shutdown()
      end,
      desc = "live-server: stop every managed server",
    })

    vim.api.nvim_create_autocmd({ "DirChanged" }, {
      group = group,
      callback = function()
        require("live_server.project").invalidate()
      end,
      desc = "live-server: forget cached project detection",
    })

    -- Writing a project config should take effect without restarting Neovim.
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = group,
      pattern = { ".liveserverrc.json", ".live-server.json" },
      callback = function(event)
        require("live_server.project").invalidate()
        require("live_server.log").notify(
          ("%s reloaded — restart the server to apply it."):format(vim.fn.fnamemodify(event.file, ":t")),
          "info"
        )
      end,
      desc = "live-server: reload project configuration",
    })

    if options.detect_orphans then
      -- Deferred so it never contributes to startup time.
      vim.defer_fn(function()
        require("live_server.manager").find_orphans(function(orphans)
          if #orphans > 0 then
            require("live_server.log").notify(
              ("%d dev server process%s from a previous session %s still running. `:LiveServer reap` stops %s."):format(
                #orphans,
                #orphans == 1 and "" or "es",
                #orphans == 1 and "is" or "are",
                #orphans == 1 and "it" or "them"
              ),
              "warn",
              { once = true }
            )
          end
        end)
      end, 2000)
    end
  end

  return options
end

---@return boolean
function M.did_setup()
  return require("live_server.config").did_setup
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

--- Start a server for the current project.
---@param opts? live_server.StartOpts
---@param callback? fun(server: live_server.Server?, err: string?)
function M.start(opts, callback)
  require("live_server.manager").start(opts, callback)
end

--- Stop a server. With no argument, stops the current project's server.
---@param server? live_server.Server
function M.stop(server)
  local manager = require("live_server.manager")
  if server then
    return manager.stop(server)
  end
  local project = require("live_server.project").get()
  local active = manager.find_active(project.root)
  if active then
    manager.stop(active)
  else
    require("live_server.log").notify("No server is running for this project.", "warn")
  end
end

--- Start every app discovered in the current repository, asking for consent
--- once for all of them.
---@param opts? live_server.StartOpts
---@param callback? fun(started: live_server.Server[], failures: string[])
function M.start_all(opts, callback)
  require("live_server.manager").start_all(opts, callback)
end

--- Stop every managed server.
---@return integer stopped
function M.stop_all()
  return require("live_server.manager").stop_all()
end

--- Start the current project's server, or stop it if it is already running.
---@param opts? live_server.StartOpts
---@param callback? fun(server: live_server.Server?, err: string?)
function M.toggle(opts, callback)
  require("live_server.manager").toggle(opts, callback)
end

--- Restart a server on the same port.
---@param server? live_server.Server
function M.restart(server)
  local manager = require("live_server.manager")
  server = server or manager.find_active(require("live_server.project").get().root)
  if not server then
    return require("live_server.log").notify("No server is running for this project.", "warn")
  end
  manager.restart(server)
end

--- Open a server's page in the browser (or report the SSH forwarding command).
---@param server? live_server.Server
---@param path? string
function M.open(server, path)
  local manager = require("live_server.manager")
  server = server or manager.find_active(require("live_server.project").get().root)
  if not server then
    return require("live_server.log").notify("No server is running for this project.", "warn")
  end
  require("live_server.browser").open(server, path)
end

--------------------------------------------------------------------------------
-- Ports
--------------------------------------------------------------------------------

--- Pin a port to the current project so it is reused from now on.
---@param port integer
---@param opts? { adapter?: string, root?: string }
function M.pin(port, opts)
  opts = opts or {}
  local root = opts.root or M.workdir()
  local adapter = opts.adapter
  if not adapter then
    local resolved = require("live_server.adapters").resolve()
    adapter = resolved and resolved.name
  end
  if not adapter then
    return require("live_server.log").notify("No server backend available to pin.", "error")
  end
  require("live_server.port").pin(root, adapter, port)
end

---@param opts? { adapter?: string, root?: string }
---@return boolean removed
function M.unpin(opts)
  opts = opts or {}
  local root = opts.root or M.workdir()
  local port_mod = require("live_server.port")
  if opts.adapter then
    return port_mod.unpin(root, opts.adapter)
  end
  local removed = false
  for _, name in ipairs(require("live_server.adapters").names()) do
    removed = port_mod.unpin(root, name) or removed
  end
  return removed
end

--- The directory a server would run in here: the current project's app, which
--- may live below the repository root.
---@return string
function M.workdir()
  local project = require("live_server.project").get()
  local current = M.current()
  if current then
    return current.project.workdir
  end
  local candidates = require("live_server.discover").candidates(project.root)
  return candidates[1] and candidates[1].dir or project.root
end

--- Apps discovered inside the current repository.
---@return live_server.Candidate[]
function M.apps()
  return require("live_server.discover").candidates(require("live_server.project").get().root)
end

--- Every recorded pin.
---@return { root: string, adapter: string, port: integer }[]
function M.pins()
  return require("live_server.port").pins()
end

--------------------------------------------------------------------------------
-- Introspection and UI
--------------------------------------------------------------------------------

--- All known servers.
---@param opts? { active_only?: boolean }
---@return live_server.Server[]
function M.servers(opts)
  return require("live_server.manager").servers(opts)
end

--- The active server for the current project, if any.
---@return live_server.Server?
function M.current()
  return require("live_server.manager").find_active(require("live_server.project").get().root)
end

--- Open the server manager.
function M.dashboard()
  require("live_server.ui.dashboard").open()
end

--- Show a server's process output.
---@param server? live_server.Server
function M.logs(server)
  server = server or M.current() or require("live_server.manager").servers()[1]
  if not server then
    return require("live_server.log").notify("No servers to show output for.", "warn")
  end
  require("live_server.ui.logs").open(server)
end

--- Statusline text for the current project. Empty when nothing is running.
---@param opts? { global?: boolean }
---@return string
function M.statusline(opts)
  return require("live_server.statusline").component(opts)
end

--- Ready-made lualine component.
---@param opts? table
---@return table
function M.lualine(opts)
  return require("live_server.statusline").lualine(opts)
end

--- Subscribe to server events (`starting`, `ready`, `stopped`, `crashed`, …).
---@param name live_server.EventName|"*"
---@param fn fun(payload: table)
---@return fun() unsubscribe
function M.on(name, fn)
  return require("live_server.event").on(name, fn)
end

--- Register a custom server backend.
---@param spec live_server.AdapterSpec
function M.register_adapter(spec)
  require("live_server.adapters").register(spec)
end

--- Health check entry point (`:checkhealth live_server`).
function M.check()
  require("live_server.health").check()
end

return M
