---@mod live_server.project Project root detection and per-project settings
---
--- A "project" is the unit everything else is keyed on: ports are pinned to it,
--- servers are listed under it, and the dashboard groups by it. Detection is
--- cached per directory and invalidated when the file changes on disk, so the
--- hot path (statusline, dashboard refresh) does no filesystem work.

local log = require("live_server.log")
local util = require("live_server.util")

local M = {}

---@class live_server.Project
---@field root string absolute project root
---@field name string display name (basename of root)
---@field serve_dir string absolute directory actually served
---@field config table sanitized settings from the project file
---@field privileged table execution-affecting settings awaiting consent
---@field config_path string? project file that was read
---@field config_content string? its raw contents, for the trust record

---@class live_server.ProjectCacheEntry
---@field project live_server.Project
---@field mtime integer
---@field checked integer

---@type table<string, live_server.ProjectCacheEntry>
local cache = {}

--- Settings a project file may set without any consent prompt: they choose
--- where and how to serve, never what to execute.
local SAFE_FIELDS = {
  server = "string",
  port = "number",
  host = "string",
  root = "string",
  open = "string",
  entry_file = "string",
  expose = "boolean",
  auto_open = "boolean",
}

---@return live_server.Config
local function config()
  return require("live_server.config").get()
end

--- Directory to start searching upward from.
---@param path? string
---@return string
local function start_dir(path)
  if path and path ~= "" then
    return util.is_dir(path) and util.normalize(path) or util.normalize(vim.fs.dirname(path))
  end
  local buf_name = vim.api.nvim_buf_get_name(0)
  local buftype = vim.bo.buftype
  if buf_name ~= "" and buftype == "" then
    return util.normalize(vim.fs.dirname(buf_name))
  end
  return util.normalize(vim.fn.getcwd())
end

--- Walk up from `dir` looking for any of `patterns`.
---@param dir string
---@param patterns string[]
---@return string?
local function find_root(dir, patterns)
  if vim.fs.root then -- Neovim 0.10+
    local ok, root = pcall(vim.fs.root, dir, patterns)
    if ok and root then
      return util.normalize(root)
    end
  end
  local found = vim.fs.find(patterns, { upward = true, path = dir, limit = 1 })
  if found and found[1] then
    return util.normalize(vim.fs.dirname(found[1]))
  end
  return nil
end

--- Pick the directory that actually holds the site.
---@param root string
---@param override string?
---@return string
local function resolve_serve_dir(root, override)
  if override and override ~= "" then
    local candidate = util.is_absolute(override) and util.normalize(override) or util.normalize(root .. "/" .. override)
    if util.is_dir(candidate) then
      return candidate
    end
    log.warn("configured serve directory does not exist, falling back to project root", {
      root = root,
      serve_dir = override,
    })
    return root
  end

  if util.is_file(root .. "/index.html") then
    return root
  end
  for _, name in ipairs(config().root.auto) do
    local candidate = root .. "/" .. name
    if util.is_file(candidate .. "/index.html") then
      return candidate
    end
  end
  return root
end

--- Read and sanitize a project file. Unknown or wrongly-typed keys are dropped
--- with a warning rather than aborting: a stale config should not stop the dev
--- server from coming up.
---@param root string
---@return table safe
---@return table privileged
---@return string? path
---@return string? content
local function read_project_file(root)
  local cfg = config()
  if not cfg.project.enabled then
    return {}, {}, nil, nil
  end

  for _, name in ipairs(cfg.project.files) do
    local path = root .. "/" .. name
    if util.is_file(path) then
      local content = util.read_file(path)
      if not content then
        log.warn("project file could not be read", { path = path })
        return {}, {}, nil, nil
      end
      local decoded, err = util.json_decode(content)
      if type(decoded) ~= "table" then
        log.notify(
          ("%s is not valid JSON and was ignored (%s)"):format(vim.fn.fnamemodify(path, ":~:."), err or "parse error"),
          "warn",
          { once = true }
        )
        return {}, {}, path, content
      end

      local safe, privileged = {}, {}
      for key, value in pairs(decoded) do
        local expected = SAFE_FIELDS[key]
        if expected then
          if type(value) == expected then
            safe[key] = value
          else
            log.warn("project file field has the wrong type", { path = path, key = key, expected = expected })
          end
        elseif key == "watch" and type(value) == "table" then
          safe.watch = value
        elseif vim.tbl_contains(require("live_server.trust").PRIVILEGED_FIELDS, key) then
          privileged[key] = value
        else
          log.warn("unknown project file field", { path = path, key = key })
        end
      end

      -- A project file must not be able to point the server at $HOME or `/`.
      -- Escaping the project root is exactly the shape of an attack that turns
      -- "I cloned a repo" into "I served my SSH keys on localhost".
      if safe.root then
        local candidate = util.is_absolute(safe.root) and util.normalize(safe.root)
          or util.normalize(root .. "/" .. safe.root)
        if not util.is_within(root, candidate) then
          log.notify(
            ("%s tried to serve %s, which is outside the project. Ignored."):format(
              vim.fn.fnamemodify(path, ":~:."),
              candidate
            ),
            "warn"
          )
          safe.root = nil
        end
      end

      return safe, privileged, path, content
    end
  end

  return {}, {}, nil, nil
end

---@param root string
---@return live_server.Project
local function build(root)
  local safe, privileged, path, content = read_project_file(root)
  local serve_dir = resolve_serve_dir(root, safe.root or config().root.serve_dir)
  return {
    root = root,
    name = vim.fn.fnamemodify(root, ":t"),
    serve_dir = serve_dir,
    config = safe,
    privileged = privileged,
    config_path = path,
    config_content = content,
  }
end

---@param root string
---@return integer
local function config_mtime(root)
  local latest = 0
  for _, name in ipairs(config().project.files) do
    local stat = util.uv.fs_stat(root .. "/" .. name)
    if stat then
      latest = math.max(latest, stat.mtime.sec)
    end
  end
  return latest
end

--- Project containing `path`, or the current buffer when omitted.
---@param path? string
---@return live_server.Project
function M.get(path)
  local dir = start_dir(path)
  local cached = cache[dir]
  local now = util.now()
  if cached then
    -- Re-stat at most every 2s; project files change rarely and this function
    -- is called from the statusline.
    if now - cached.checked < 2000 then
      return cached.project
    end
    cached.checked = now
    if config_mtime(cached.project.root) == cached.mtime then
      return cached.project
    end
  end

  local cfg = config()
  local root = find_root(dir, cfg.root.patterns)
  if not root then
    root = cfg.root.fallback == "file" and dir or util.normalize(vim.fn.getcwd())
  end

  local project = build(root)
  cache[dir] = { project = project, mtime = config_mtime(root), checked = now }
  return project
end

--- Drop cached detection. Called on `DirChanged` and after `setup()`.
---@param path? string only this directory
function M.invalidate(path)
  if path then
    cache[util.normalize(path)] = nil
  else
    cache = {}
  end
end

--- URL path for the current buffer relative to a served directory, e.g.
--- `about/index.html`. Returns nil when the buffer lives elsewhere.
---@param serve_dir string
---@param bufnr? integer
---@return string?
function M.relative_page(serve_dir, bufnr)
  bufnr = bufnr or 0
  if vim.bo[bufnr].buftype ~= "" then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  local relative = util.relative(serve_dir, util.normalize(name))
  if not relative or relative == "" then
    return nil
  end
  -- Only markup is meaningful as a page; a `.js` buffer should still open the
  -- page that loads it, which is the site root.
  if not relative:match("%.html?$") then
    return nil
  end
  return relative
end

return M
