---@mod live_server.ui.window Float/split scaffolding shared by the UI
---
--- Handles the parts every panel needs and always gets subtly wrong: sizing
--- that survives a resized terminal, falling back to a split when a float would
--- not fit, restoring the cursor to where the user came from, and tearing down
--- autocommands so a closed window leaves nothing behind.

local highlights = require("live_server.ui.highlights")
local util = require("live_server.util")

local M = {}

---@class live_server.ui.Window
---@field buf integer
---@field win integer
---@field ns integer
---@field private _augroup integer
---@field private _prev_win integer
---@field private _on_close fun()|nil
local Window = {}
Window.__index = Window

---@param fraction number
---@param total integer
---@param min integer
---@param max integer
---@return integer
local function dimension(fraction, total, min, max)
  local value = fraction <= 1 and math.floor(total * fraction) or math.floor(fraction)
  return math.floor(util.clamp(value, min, math.min(max, total)))
end

---@class live_server.ui.WindowOpts
---@field title string shown in the border
---@field width? number fraction of the editor when <= 1, else absolute cells
---@field height? number same units as `width`
---@field filetype? string buffer filetype, for user autocommands
---@field footer? string border footer (Neovim 0.10+, bordered floats only)
---@field enter? boolean focus the window on open, default true
---@field force_split? boolean never use a float

--- Open a panel.
---@param opts live_server.ui.WindowOpts
---@return live_server.ui.Window
function M.open(opts)
  local cfg = require("live_server.config").get()
  highlights.apply()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = opts.filetype or "liveserver"
  -- Named so `:ls`, session pickers and window titles show something useful
  -- instead of `[Scratch]`.
  pcall(vim.api.nvim_buf_set_name, buf, "live-server://" .. (opts.filetype or "dashboard"))

  local prev_win = vim.api.nvim_get_current_win()
  local columns, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight - 1

  local win
  local use_float = not opts.force_split and columns >= cfg.ui.min_float_width and lines >= 12

  if use_float then
    local width = dimension(opts.width or cfg.ui.width, columns, 40, columns - 4)
    local height = dimension(opts.height or cfg.ui.height, lines, 8, lines - 2)

    ---@type vim.api.keyset.win_config
    local win_config = {
      relative = "editor",
      width = width,
      height = height,
      row = math.max(0, math.floor((lines - height) / 2)),
      col = math.max(0, math.floor((columns - width) / 2)),
      style = "minimal",
      border = cfg.ui.border,
      title = " " .. opts.title .. " ",
      title_pos = "center",
      zindex = 60,
    }
    if opts.footer and vim.fn.has("nvim-0.10") == 1 and cfg.ui.border ~= "none" then
      win_config.footer = " " .. opts.footer .. " "
      win_config.footer_pos = "center"
    end
    win = vim.api.nvim_open_win(buf, opts.enter ~= false, win_config)
  else
    -- Too small for a readable float: a split is the accessible choice, not a
    -- cramped popup with truncated rows.
    vim.cmd("botright " .. math.max(10, math.floor(lines * 0.4)) .. "split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.wo[win].winfixheight = true
  end

  local window_options = {
    wrap = false,
    cursorline = true,
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldenable = false,
    spell = false,
    list = false,
    winhl = table.concat({
      "Normal:LiveServerNormal",
      "NormalFloat:LiveServerNormal",
      "FloatBorder:LiveServerBorder",
      "FloatTitle:LiveServerTitle",
      "CursorLine:LiveServerCursorLine",
    }, ","),
  }
  for name, value in pairs(window_options) do
    pcall(vim.api.nvim_set_option_value, name, value, { win = win })
  end

  local self = setmetatable({
    buf = buf,
    win = win,
    ns = vim.api.nvim_create_namespace("live_server_ui_" .. buf),
    _augroup = vim.api.nvim_create_augroup("LiveServerWindow" .. buf, { clear = true }),
    _prev_win = prev_win,
  }, Window)

  vim.api.nvim_create_autocmd({ "WinClosed" }, {
    group = self._augroup,
    pattern = tostring(win),
    callback = function()
      self:_teardown()
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout" }, {
    group = self._augroup,
    buffer = buf,
    callback = function()
      self:_teardown()
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = self._augroup,
    callback = function()
      self:recentre()
    end,
  })

  return self
end

---@return boolean
function Window:is_open()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

---@return boolean
function Window:is_valid()
  return self:is_open() and vim.api.nvim_buf_is_valid(self.buf)
end

--- Replace the contents, keeping the cursor row where possible.
---@param lines string[]
function Window:set_lines(lines)
  if not self:is_valid() then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(self.win)
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false
  local row = math.min(cursor[1], math.max(1, #lines))
  pcall(vim.api.nvim_win_set_cursor, self.win, { row, cursor[2] })
end

--- Apply a highlight to part of a line (0-indexed row, byte columns).
---@param group string
---@param row integer
---@param col_start integer
---@param col_end integer
function Window:highlight(group, row, col_start, col_end)
  if not self:is_valid() then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, self.buf, self.ns, row, col_start, {
    end_col = col_end,
    hl_group = group,
    strict = false,
  })
end

function Window:clear_highlights()
  if self:is_valid() then
    vim.api.nvim_buf_clear_namespace(self.buf, self.ns, 0, -1)
  end
end

--- Update the border title (float only).
---@param title string
function Window:set_title(title)
  if not self:is_open() then
    return
  end
  local config = vim.api.nvim_win_get_config(self.win)
  if config.relative == "" then
    return
  end
  config.title = " " .. title .. " "
  pcall(vim.api.nvim_win_set_config, self.win, config)
end

--- Keep a float centred after the terminal is resized.
function Window:recentre()
  if not self:is_open() then
    return
  end
  local config = vim.api.nvim_win_get_config(self.win)
  if config.relative == "" then
    return
  end
  local columns, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight - 1
  config.width = math.min(config.width, math.max(40, columns - 4))
  config.height = math.min(config.height, math.max(8, lines - 2))
  config.row = math.max(0, math.floor((lines - config.height) / 2))
  config.col = math.max(0, math.floor((columns - config.width) / 2))
  pcall(vim.api.nvim_win_set_config, self.win, config)
end

--- Map a key (or list of keys) in this window's buffer.
---@param keys string|string[]|false
---@param fn fun()
---@param desc string
function Window:map(keys, fn, desc)
  if keys == false or keys == nil then
    return
  end
  local list = type(keys) == "table" and keys or { keys }
  for _, key in ipairs(list) do
    if key and key ~= "" then
      vim.keymap.set("n", key, function()
        if self:is_valid() then
          fn()
        end
      end, { buffer = self.buf, nowait = true, silent = true, desc = desc })
    end
  end
end

---@param fn fun()
function Window:on_close(fn)
  self._on_close = fn
end

function Window:_teardown()
  if self._closed then
    return
  end
  self._closed = true
  pcall(vim.api.nvim_del_augroup_by_id, self._augroup)
  if self._on_close then
    local ok, err = pcall(self._on_close)
    if not ok then
      require("live_server.log").error("window close handler failed", { err = tostring(err) })
    end
  end
end

--- Close the panel and return focus where it came from.
function Window:close()
  self:_teardown()
  if self:is_open() then
    pcall(vim.api.nvim_win_close, self.win, true)
  end
  if self._prev_win and vim.api.nvim_win_is_valid(self._prev_win) then
    pcall(vim.api.nvim_set_current_win, self._prev_win)
  end
end

function Window:focus()
  if self:is_open() then
    vim.api.nvim_set_current_win(self.win)
  end
end

---@return integer
function Window:cursor_row()
  if not self:is_open() then
    return 1
  end
  return vim.api.nvim_win_get_cursor(self.win)[1]
end

---@param row integer
function Window:set_cursor_row(row)
  if not self:is_open() then
    return
  end
  local count = vim.api.nvim_buf_line_count(self.buf)
  pcall(vim.api.nvim_win_set_cursor, self.win, { math.floor(util.clamp(row, 1, count)), 0 })
end

--- Inner width available for content.
---@return integer
function Window:width()
  if not self:is_open() then
    return 80
  end
  return vim.api.nvim_win_get_width(self.win)
end

M.Window = Window

return M
