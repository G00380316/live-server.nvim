---@mod live_server.discover Finding the app inside the repository
---
--- A very common layout puts the git repository one level above the thing you
--- actually run:
---
---     ~/code/my-repo/          <- .git, and where the editor pins the root
---       frontend/package.json  <- the app
---       api/package.json       <- another app
---
--- Root detection deliberately stops at the repository, because that is what
--- the rest of the editor (and the user's own root-locking setup) expects. So
--- instead of moving the root, this module looks *downward* for the directories
--- that can actually be served, and lets the start flow target one of them.
---
--- The search is bounded on every axis — depth, directories visited, results —
--- and it only runs when the root itself has nothing to serve, so the common
--- case costs nothing.

local framework_mod = require("live_server.framework")
local log = require("live_server.log")
local store = require("live_server.store")
local util = require("live_server.util")

local M = {}

---@class live_server.Candidate
---@field dir string absolute directory
---@field kind "node"|"static" what makes it servable
---@field label string human description, e.g. "Next.js"
---@field depth integer directories below the root
---@field source "root"|"workspace"|"scan" how it was found
---@field relative string path relative to the root, "" for the root itself

---@return live_server.Config
local function config()
  return require("live_server.config").get()
end

---@return live_server.Store
local function memory()
  return store.open("workdirs")
end

--- Directory names never worth descending into. Kept separate from
--- `watch.ignore` because that list is about *file watching*; this one is about
--- not walking 40,000 files in `node_modules` to answer one question.
---@type table<string, boolean>
local SKIP = {
  [".git"] = true,
  [".hg"] = true,
  [".svn"] = true,
  ["node_modules"] = true,
  ["bower_components"] = true,
  ["vendor"] = true,
  ["target"] = true,
  ["__pycache__"] = true,
  [".venv"] = true,
  ["venv"] = true,
  [".next"] = true,
  [".nuxt"] = true,
  [".svelte-kit"] = true,
  [".astro"] = true,
  [".cache"] = true,
  [".turbo"] = true,
  ["coverage"] = true,
  [".idea"] = true,
  [".vscode"] = true,
  ["Pods"] = true,
  ["DerivedData"] = true,
}

---@param name string
---@return boolean
local function skippable(name)
  if SKIP[name] then
    return true
  end
  -- Hidden directories are dotfiles, caches and tool state far more often than
  -- they are the app you want to run.
  return name:sub(1, 1) == "."
end

--- What, if anything, makes this directory servable.
---@param dir string
---@return live_server.Candidate? partial candidate (no depth/source/relative)
function M.inspect(dir)
  local detected = framework_mod.detect(dir)
  if detected then
    return { dir = dir, kind = "node", label = detected.display }
  end
  if util.is_file(dir .. "/index.html") then
    return { dir = dir, kind = "static", label = "static site" }
  end
  return nil
end

--- Workspace globs declared by the repository. When a monorepo tells us where
--- its packages live, that beats guessing every time.
---@param root string
---@return string[] globs
function M.workspace_globs(root)
  local globs = {}

  local data = framework_mod.package_json(root)
  if type(data) == "table" then
    local workspaces = data.workspaces
    if type(workspaces) == "table" then
      -- Both `["a/*"]` and `{ packages = ["a/*"] }` are valid npm/yarn.
      local list = workspaces.packages or workspaces
      if type(list) == "table" then
        for _, pattern in ipairs(list) do
          if type(pattern) == "string" then
            globs[#globs + 1] = pattern
          end
        end
      end
    end
  end

  -- pnpm keeps them in a separate file. Only the `packages:` list is needed, so
  -- a full YAML parser would be a dependency bought for nothing.
  local pnpm = util.read_file(root .. "/pnpm-workspace.yaml") or util.read_file(root .. "/pnpm-workspace.yml")
  if pnpm then
    local in_packages = false
    for line in pnpm:gmatch("[^\r\n]+") do
      if line:match("^packages:") then
        in_packages = true
      elseif in_packages then
        local entry = line:match("^%s*%-%s*['\"]?([^'\"#]+)['\"]?%s*$")
        if entry then
          globs[#globs + 1] = vim.trim(entry)
        elseif line:match("^%S") then
          in_packages = false -- a new top-level key ends the list
        end
      end
    end
  end

  return globs
end

---@param root string
---@param globs string[]
---@return live_server.Candidate[]
local function from_workspaces(root, globs)
  local found = {}
  local seen = {}

  for _, glob in ipairs(globs) do
    if not glob:match("^!") then -- negations are exclusions; ignore them here
      local pattern = root .. "/" .. glob
      local ok, matches = pcall(vim.fn.glob, pattern, true, true)
      if ok and type(matches) == "table" then
        for _, match in ipairs(matches) do
          local dir = util.normalize(match)
          if not seen[dir] and util.is_dir(dir) and util.is_within(root, dir) then
            seen[dir] = true
            local candidate = M.inspect(dir)
            if candidate then
              local relative = util.relative(root, dir) or ""
              candidate.depth = select(2, relative:gsub("/", "")) + 1
              candidate.source = "workspace"
              candidate.relative = relative
              found[#found + 1] = candidate
            end
          end
        end
      end
    end
  end

  return found
end

--- Breadth-first walk below `root`, so shallow results are found first and the
--- caps bite on the deep, uninteresting parts of a tree.
---@param root string
---@param opts { depth: integer, max_results: integer, max_dirs: integer }
---@return live_server.Candidate[]
local function scan(root, opts)
  local found = {}
  local queue = { { dir = root, depth = 0 } }
  local visited = 0
  local head = 1

  while head <= #queue do
    local entry = queue[head]
    head = head + 1

    if entry.depth >= opts.depth or visited >= opts.max_dirs or #found >= opts.max_results then
      -- Keep draining the queue only to respect ordering; nothing more to do.
      break
    end

    local handle = util.uv.fs_scandir(entry.dir)
    if handle then
      while true do
        local name, kind = util.uv.fs_scandir_next(handle)
        if not name then
          break
        end
        -- `fs_scandir_next` reports "link" for symlinks; resolve by stat so a
        -- symlinked package directory still counts, but never follow one that
        -- points back up the tree.
        local child = entry.dir .. "/" .. name
        local is_dir = kind == "directory"
        if kind == "link" then
          is_dir = util.is_dir(child)
        end

        if is_dir and not skippable(name) then
          visited = visited + 1
          local dir = util.normalize(child)
          if util.is_within(root, dir) then
            local candidate = M.inspect(dir)
            if candidate then
              candidate.depth = entry.depth + 1
              candidate.source = "scan"
              candidate.relative = util.relative(root, dir) or name
              found[#found + 1] = candidate
              if #found >= opts.max_results then
                break
              end
            end
            -- Descend even into a directory that is itself servable: a repo
            -- can have `site/` (static) containing `site/app/` (the real app).
            queue[#queue + 1] = { dir = dir, depth = entry.depth + 1 }
          end
        end

        if visited >= opts.max_dirs then
          break
        end
      end
    end
  end

  if visited >= opts.max_dirs then
    log.debug("discovery hit the directory cap", { root = root, visited = visited })
  end

  return found
end

---@type table<string, { candidates: live_server.Candidate[], at: integer }>
local cache = {}

--- Every servable directory at or below `root`, best first.
---@param root string
---@param opts? { refresh?: boolean }
---@return live_server.Candidate[]
function M.candidates(root, opts)
  root = util.normalize(root)
  local cfg = config()

  local cached = cache[root]
  if cached and not (opts and opts.refresh) and util.now() - cached.at < 5000 then
    return cached.candidates
  end

  ---@type live_server.Candidate[]
  local found = {}

  -- The root itself always wins when it is runnable: a monorepo root with a
  -- `dev` script (turbo, nx) means exactly what it says.
  local at_root = M.inspect(root)
  if at_root then
    at_root.depth = 0
    at_root.source = "root"
    at_root.relative = ""
    found[#found + 1] = at_root
  end

  if cfg.discover.enabled and not (at_root and at_root.kind == "node") then
    local globs = M.workspace_globs(root)
    if #globs > 0 then
      vim.list_extend(found, from_workspaces(root, globs))
    end

    -- Only walk the tree when nothing better turned up. A declared workspace is
    -- always a better answer than a guess.
    if #found == 0 then
      vim.list_extend(
        found,
        scan(root, {
          depth = cfg.discover.depth,
          max_results = cfg.discover.max_results,
          max_dirs = cfg.discover.max_dirs,
        })
      )
    end
  end

  -- Shallow before deep, runnable apps before static folders, then by name so
  -- the order is stable between runs.
  table.sort(found, function(a, b)
    if a.depth ~= b.depth then
      return a.depth < b.depth
    end
    if (a.kind == "node") ~= (b.kind == "node") then
      return a.kind == "node"
    end
    return a.dir < b.dir
  end)

  cache[root] = { candidates = found, at = util.now() }
  return found
end

--- Remembered choice for a repository.
---@param root string
---@return string?
function M.remembered(root)
  local record = memory():get(util.normalize(root))
  if type(record) == "table" and type(record.dir) == "string" and util.is_dir(record.dir) then
    return record.dir
  end
  return nil
end

---@param root string
---@param dir string
function M.remember(root, dir)
  memory():set(util.normalize(root), { dir = util.normalize(dir), at = os.time() }):save()
  log.info("remembered project directory", { root = root, dir = dir })
end

---@param root string
---@return boolean removed
function M.forget(root)
  local key = util.normalize(root)
  local db = memory()
  if db:get(key) == nil then
    return false
  end
  db:delete(key):save()
  return true
end

--- Choose which directory to serve.
---
--- Order: an explicit `dir`, then the directory holding the current buffer,
--- then a remembered choice, then the only candidate, then a prompt.
---@param project live_server.Project
---@param opts { dir?: string, adapter?: string, silent?: boolean }
---@param callback fun(dir: string?, candidate: live_server.Candidate?)
function M.resolve(project, opts, callback)
  local cfg = config()
  local root = project.root

  -- An explicit directory narrows the search rather than ending it. Pointing at
  -- a directory that can be served means "serve this"; pointing at one that
  -- cannot — a repository root with the app inside it — means "look in here",
  -- which is exactly the case this module exists for.
  if opts.dir and opts.dir ~= "" then
    local dir = util.normalize(opts.dir)
    if util.is_dir(dir) then
      local direct = M.inspect(dir)
      if direct then
        direct.depth, direct.source, direct.relative = 0, "root", ""
        return callback(dir, direct)
      end
      root = dir
    end
  end

  local candidates = M.candidates(root)

  if #candidates == 0 then
    return callback(root, nil)
  end
  if #candidates == 1 then
    return callback(candidates[1].dir, candidates[1])
  end

  -- The buffer you are looking at is the strongest signal available about
  -- which of several apps you meant.
  local buffer_name = vim.api.nvim_buf_get_name(0)
  if buffer_name ~= "" and vim.bo.buftype == "" then
    local buffer_dir = util.normalize(vim.fs.dirname(buffer_name))
    local best, best_depth = nil, -1
    for _, candidate in ipairs(candidates) do
      if util.is_within(candidate.dir, buffer_dir) and candidate.depth > best_depth then
        best, best_depth = candidate, candidate.depth
      end
    end
    if best then
      return callback(best.dir, best)
    end
  end

  local remembered = M.remembered(root)
  if remembered then
    for _, candidate in ipairs(candidates) do
      if candidate.dir == remembered then
        return callback(candidate.dir, candidate)
      end
    end
  end

  if not cfg.discover.prompt or opts.silent then
    return callback(candidates[1].dir, candidates[1])
  end

  vim.ui.select(candidates, {
    prompt = ("%s has several apps — which one?"):format(project.name),
    format_item = function(candidate)
      return ("%-28s %s"):format(candidate.relative ~= "" and candidate.relative or ".", candidate.label)
    end,
  }, function(choice)
    if not choice then
      return callback(nil, nil)
    end
    if cfg.discover.remember then
      M.remember(root, choice.dir)
    end
    callback(choice.dir, choice)
  end)
end

--- Drop cached scans.
function M.invalidate()
  cache = {}
end

return M
