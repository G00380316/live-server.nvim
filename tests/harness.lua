--- Minimal test harness.
---
--- Deliberately dependency-free: `make test` must work on a clean checkout with
--- nothing but Neovim installed, and CI must not be able to break because a
--- test framework changed its API.

local M = {
  passed = 0,
  failed = 0,
  skipped = 0,
  failures = {},
  _prefix = {},
}

local function label(name)
  local parts = vim.deepcopy(M._prefix)
  parts[#parts + 1] = name
  return table.concat(parts, " › ")
end

---@param name string
---@param fn fun()
function M.describe(name, fn)
  table.insert(M._prefix, name)
  local ok, err = pcall(fn)
  if not ok then
    M.failed = M.failed + 1
    M.failures[#M.failures + 1] = { name = label("<suite>"), err = tostring(err) }
  end
  table.remove(M._prefix)
end

---@param name string
---@param fn fun()
function M.it(name, fn)
  local ok, err = pcall(fn)
  if ok then
    M.passed = M.passed + 1
    io.write("  ok   " .. label(name) .. "\n")
  else
    M.failed = M.failed + 1
    M.failures[#M.failures + 1] = { name = label(name), err = tostring(err) }
    io.write("  FAIL " .. label(name) .. "\n")
  end
end

---@param name string
---@param reason string
function M.skip(name, reason)
  M.skipped = M.skipped + 1
  io.write("  skip " .. label(name) .. "  (" .. reason .. ")\n")
end

---@param message string
local function fail(message)
  error(message, 3)
end

---@param actual any
---@param expected any
---@param message? string
function M.eq(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    fail(
      ("%sexpected %s, got %s"):format(message and (message .. ": ") or "", vim.inspect(expected), vim.inspect(actual))
    )
  end
end

---@param actual any
---@param expected any
---@param message? string
function M.neq(actual, expected, message)
  if vim.deep_equal(actual, expected) then
    fail(("%sexpected something other than %s"):format(message and (message .. ": ") or "", vim.inspect(expected)))
  end
end

---@param value any
---@param message? string
function M.truthy(value, message)
  if not value then
    fail(("%sexpected a truthy value, got %s"):format(message and (message .. ": ") or "", vim.inspect(value)))
  end
end

---@param value any
---@param message? string
function M.falsy(value, message)
  if value then
    fail(("%sexpected a falsy value, got %s"):format(message and (message .. ": ") or "", vim.inspect(value)))
  end
end

---@param haystack string
---@param needle string
---@param message? string
function M.contains(haystack, needle, message)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    fail(("%sexpected %s to contain %q"):format(message and (message .. ": ") or "", vim.inspect(haystack), needle))
  end
end

---@param list any[]
---@param value any
---@param message? string
function M.includes(list, value, message)
  for _, item in ipairs(list) do
    if vim.deep_equal(item, value) then
      return
    end
  end
  fail(("%sexpected list to include %s"):format(message and (message .. ": ") or "", vim.inspect(value)))
end

---@param fn fun()
---@param pattern? string
function M.throws(fn, pattern)
  local ok, err = pcall(fn)
  if ok then
    fail("expected an error, but the call succeeded")
  end
  if pattern and not tostring(err):find(pattern) then
    fail(("expected error matching %q, got %s"):format(pattern, tostring(err)))
  end
end

---@param url string
---@param timeout? integer
---@return string status
---@return integer exit_code
---@return string stderr
function M.http_status(url, timeout)
  local output = vim.fn.tempname()
  local result = vim
    .system({
      "curl",
      "-fsS",
      "-o",
      output,
      "-w",
      "%{http_code}",
      "--max-time",
      tostring(timeout or 20),
      url,
    }, { text = true })
    :wait()
  pcall(vim.fn.delete, output)
  return vim.trim(result.stdout or ""), result.code or -1, vim.trim(result.stderr or "")
end

---@return integer exit_code
function M.report()
  io.write("\n")
  for _, failure in ipairs(M.failures) do
    io.write("FAILED  " .. failure.name .. "\n")
    io.write("        " .. failure.err:gsub("\n", "\n        ") .. "\n\n")
  end
  io.write(("%d passed, %d failed, %d skipped\n"):format(M.passed, M.failed, M.skipped))
  return M.failed == 0 and 0 or 1
end

return M
