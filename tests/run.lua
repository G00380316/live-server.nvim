--- Test entry point.
---
---   nvim --headless -u NONE -l tests/run.lua [pattern]
---
--- Prefer `make test`, which points XDG_DATA_HOME and XDG_STATE_HOME at a
--- throwaway directory so a test run can never touch real port pins or trust
--- records.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path

-- Refuse to run against the user's real state directory: these tests write port
-- pins and trust records, and losing those would be a rude surprise.
local sandbox = vim.env.LIVE_SERVER_TEST_HOME
local state = vim.fs.normalize(vim.fn.stdpath("state"))
if not sandbox or not vim.startswith(state, vim.fs.normalize(sandbox)) then
  io.write("refusing to run outside a sandbox.\n")
  io.write("  state dir: " .. state .. "\n")
  io.write("  expected under: " .. tostring(sandbox) .. "\n")
  io.write("Use `make test`, which points XDG_* at ./.test-home.\n")
  vim.cmd("cq 2")
  return
end

local harness = require("harness")
local pattern = vim.env.LIVE_SERVER_TEST_PATTERN

local specs = vim.fn.glob(root .. "/tests/spec/*_spec.lua", false, true)
table.sort(specs)

io.write("live-server.nvim test suite\n")
io.write(("Neovim %s\n\n"):format(tostring(vim.version())))

for _, spec in ipairs(specs) do
  local name = vim.fn.fnamemodify(spec, ":t:r")
  if not pattern or name:find(pattern) then
    io.write(name .. "\n")
    local chunk, load_err = loadfile(spec)
    if not chunk then
      harness.failed = harness.failed + 1
      harness.failures[#harness.failures + 1] = { name = name, err = tostring(load_err) }
      io.write("  FAIL could not load: " .. tostring(load_err) .. "\n")
    else
      local ok, err = pcall(chunk)
      if not ok then
        harness.failed = harness.failed + 1
        harness.failures[#harness.failures + 1] = { name = name, err = tostring(err) }
        io.write("  FAIL " .. tostring(err) .. "\n")
      end
    end
    io.write("\n")
  end
end

-- Leave nothing running behind us.
pcall(function()
  require("live_server.manager").stop_all({ sync = true, quiet = true })
end)

local code = harness.report()
vim.cmd("cq " .. code)
