---@mod live_server.health `:checkhealth live_server`
---
--- Written to answer the questions a bug report would otherwise take three
--- round trips to establish: which backend is installed, at what version, is
--- the configured port range usable, is this an SSH session, and where is the
--- log.

local M = {}

local health = vim.health or {}
local start = health.start or health.report_start
local ok = health.ok or health.report_ok
local info = health.info or health.report_info
local warn = health.warn or health.report_warn
local error_ = health.error or health.report_error

local function check_neovim()
  start("Neovim")
  if vim.fn.has("nvim-0.9") == 1 then
    ok("Neovim " .. tostring(vim.version()))
  else
    error_("live-server.nvim requires Neovim 0.9 or newer")
  end
  if vim.fn.has("nvim-0.10") == 1 then
    ok("`vim.ui.open` available — browser opening uses the platform default")
  else
    info("Neovim 0.10+ would enable `vim.ui.open` for browser opening")
  end
end

local function check_config()
  start("Configuration")
  local config = require("live_server.config")
  if not config.did_setup then
    info("`setup()` has not been called; defaults are in use")
  else
    ok("`setup()` completed")
  end

  local issues = config.validate(config.options)
  if #issues == 0 then
    ok("configuration is valid")
  else
    for _, issue in ipairs(issues) do
      error_(issue)
    end
  end

  local cfg = config.get()
  info(("serving host: %s%s"):format(cfg.host, cfg.expose == true and " (LAN exposure enabled)" or ""))
  info(("port strategy: %s, range %d-%d"):format(cfg.port.strategy, cfg.port.range[1], cfg.port.range[2]))
  if cfg.expose == true then
    warn("`expose = true` binds every interface — anyone on your network can read the served files")
  end
end

---@param callback fun()
local function check_adapters(callback)
  start("Server backends")
  local adapters = require("live_server.adapters")
  local names = adapters.names()
  local pending = #names
  if pending == 0 then
    error_("no adapters registered")
    return callback()
  end

  local any_available = false

  -- Both branches finish through here. Checking `any_available` inside the
  -- "is installed" branch would make the most important message in the whole
  -- health check — you have no dev server — unreachable for the one user who
  -- needs it.
  local function finish()
    pending = pending - 1
    if pending > 0 then
      return
    end
    if not any_available then
      error_("no dev server is installed — `npm install -g live-server`, or use python3")
    end
    callback()
  end

  for _, name in ipairs(names) do
    local spec = adapters.get(name)
    if adapters.available(name) then
      any_available = true
      adapters.version(name, function(version)
        ok(
          ("%s %s%s"):format(
            spec.display,
            version or "(version unknown)",
            spec.live_reload and "" or "  [no live reload]"
          )
        )
        finish()
      end)
    else
      info(("%s is not installed — %s"):format(spec.display, spec.install))
      finish()
    end
  end
end

local function check_ports()
  start("Ports")
  local cfg = require("live_server.config").get()
  local net = require("live_server.net")
  local range = cfg.port.range

  local free, checked = 0, 0
  for port = range[1], math.min(range[2], range[1] + 19) do
    checked = checked + 1
    if net.is_free(cfg.host, port) then
      free = free + 1
    end
  end
  if free == 0 then
    error_(("no free port in the first %d of %d-%d"):format(checked, range[1], range[2]))
  elseif free < checked / 2 then
    warn(("only %d of the first %d ports in %d-%d are free"):format(free, checked, range[1], range[2]))
  else
    ok(("%d of the first %d ports in %d-%d are free"):format(free, checked, range[1], range[2]))
  end

  local pins = require("live_server.port").pins()
  if #pins == 0 then
    info("no port pins recorded")
  else
    ok(("%d port pin%s recorded"):format(#pins, #pins == 1 and "" or "s"))
    for _, pin in ipairs(pins) do
      local exists = require("live_server.util").is_dir(pin.root)
      local line = ("  %s → %s :%d"):format(vim.fn.fnamemodify(pin.root, ":~"), pin.adapter, pin.port)
      if exists then
        info(line)
      else
        warn(line .. "  (directory is gone — `:LiveServer pins prune` clears it)")
      end
    end
  end
end

local function check_project()
  start("Current project")
  local project = require("live_server.project").get()
  local adapters = require("live_server.adapters")
  local util = require("live_server.util")

  info("root: " .. vim.fn.fnamemodify(project.root, ":~"))
  if project.serve_dir ~= project.root then
    info("serves: " .. vim.fn.fnamemodify(project.serve_dir, ":~"))
  end

  local discover = require("live_server.discover")
  local candidates = discover.candidates(project.root, { refresh = true })
  local remembered = discover.remembered(project.root)

  if #candidates == 0 then
    warn("nothing servable found here — no package.json with a dev script, no index.html")
  elseif #candidates == 1 and candidates[1].relative == "" then
    ok("servable at the project root")
  else
    ok(("%d app%s found inside this repository"):format(#candidates, #candidates == 1 and "" or "s"))
    for _, candidate in ipairs(candidates) do
      info(
        ("  %-28s %s%s"):format(
          candidate.relative ~= "" and candidate.relative or ".",
          candidate.label,
          candidate.dir == remembered and "   (remembered)" or ""
        )
      )
    end
    if #candidates > 1 and not remembered then
      info("  `:LiveServer apps` lists these; the first start will ask which one")
    end
  end

  local target = candidates[1] and candidates[1].dir or project.root
  local framework = require("live_server.framework").detect(target)
  if framework then
    ok(("%s detected (%s run %s)"):format(framework.display, framework.package_manager.name, framework.script))
    info(("  %s = %s"):format(framework.script, framework.script_body))
    info(("  port arrives as %s"):format(framework.port_style == "flag" and framework.port_flag or "$PORT"))
    if not framework.recognised then
      info("  not a recognised framework — `:LiveServer start node` runs it anyway")
    end

    local targeted = require("live_server.project").derive(project, target)
    local request = adapters.get("node") and adapters.get("node").requires_consent(targeted)
    if request then
      local decision = require("live_server.trust").decision(request.path, request.content)
      if decision == "allow" then
        ok("  this script is trusted")
      elseif decision == "deny" then
        warn("  this script is denied — `:LiveServer trust revoke` clears that")
      else
        info("  starting it will ask for consent first")
      end
    end
  else
    info("no Node dev server detected here")
  end

  local targeted_project = require("live_server.project").derive(project, target)
  local chosen, err = adapters.resolve(nil, targeted_project)
  if chosen then
    local where = util.relative(project.root, target)
    ok(
      ("`:LiveServer start` here would use %s%s"):format(
        adapters.display_for(chosen.name, targeted_project),
        (where and where ~= "") and (" in " .. where) or ""
      )
    )
  else
    warn(err or "no adapter fits this project")
  end
end

local function check_environment()
  start("Environment")
  local remote = require("live_server.remote")
  local util = require("live_server.util")

  if remote.is_remote() then
    local remote_info = remote.info()
    ok(("SSH session detected (%s@%s)"):format(remote_info.user, remote_info.host))
    info("URLs will be reported for port forwarding instead of opening a browser here")
  else
    ok("local session")
  end

  if util.is_wsl then
    info("WSL detected — browser opening goes through the Windows host")
  end

  local lan = require("live_server.net").lan_ip()
  info("LAN address: " .. (lan or "none detected"))

  local browser_cfg = require("live_server.config").get().browser
  if browser_cfg.cmd then
    local shown = type(browser_cfg.cmd) == "table" and table.concat(browser_cfg.cmd, " ") or browser_cfg.cmd
    info("browser command: " .. shown)
  elseif vim.ui.open then
    ok("browser opening: vim.ui.open")
  else
    local candidates = { "xdg-open", "open", "wslview", "explorer.exe" }
    local found = vim.tbl_filter(util.executable, candidates)
    if #found > 0 then
      ok("browser opening: " .. found[1])
    else
      warn("no URL opener found; set `browser.cmd` or open URLs manually")
    end
  end
end

local function check_state()
  start("State")
  local util = require("live_server.util")
  local log = require("live_server.log")

  local manager = require("live_server.manager")
  local active = manager.count_active()
  info(("%d server%s running in this session"):format(active, active == 1 and "" or "s"))
  for _, server in ipairs(manager.servers({ active_only = true })) do
    info(("  %s  %s  %s"):format(server.project.name, server.adapter.display, server:url()))
  end

  local log_path = log.path()
  if util.is_file(log_path) then
    local stat = util.uv.fs_stat(log_path)
    ok(("log: %s (%.1f KB)"):format(log_path, (stat and stat.size or 0) / 1024))
  else
    info("log: " .. log_path .. " (not created yet)")
  end

  local trusted = require("live_server.trust").list()
  if #trusted > 0 then
    info(("%d project file%s trusted"):format(#trusted, #trusted == 1 and "" or "s"))
    for _, record in ipairs(trusted) do
      info(("  [%s] %s"):format(record.decision, vim.fn.fnamemodify(record.path, ":~")))
    end
  end
end

--- Entry point for `:checkhealth live_server`.
function M.check()
  check_neovim()
  check_config()
  check_adapters(function()
    check_ports()
    check_project()
    check_environment()
    check_state()

    require("live_server.manager").find_orphans(function(orphans)
      if #orphans > 0 then
        start("Orphaned processes")
        warn(
          ("%d server process%s from a previous session are still running"):format(
            #orphans,
            #orphans == 1 and "" or "es"
          )
        )
        for _, record in ipairs(orphans) do
          warn(("  pid %d on port %s (%s)"):format(record.pid, tostring(record.port), record.adapter or "?"))
        end
        info("`:LiveServer reap` stops them")
      end
    end)
  end)
end

return M
