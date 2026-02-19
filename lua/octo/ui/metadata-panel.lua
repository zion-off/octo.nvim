-- Metadata panel for displaying PR/Issue details in a side panel
-- Inspired by file-panel.lua

local utils = require "octo.utils"
local config = require "octo.config"
local constants = require "octo.constants"
local bubbles = require "octo.ui.bubbles"
local logins = require "octo.logins"
local M = {}

local name_counter = 1

---@class MetadataPanel
---@field bufid integer
---@field winid integer
---@field parent_bufnr integer
---@field size integer
local MetadataPanel = {}
MetadataPanel.__index = MetadataPanel

MetadataPanel.winopts = {
  relativenumber = false,
  number = false,
  list = false,
  winfixwidth = true,
  winfixheight = false,
  foldenable = false,
  spell = false,
  wrap = true,
  linebreak = true,
  breakindent = true,
  cursorline = false,
  signcolumn = "no",
  foldmethod = "manual",
  foldcolumn = "0",
  scrollbind = false,
  cursorbind = false,
  diff = false,
  winhl = table.concat({
    "EndOfBuffer:OctoEndOfBuffer",
    "Normal:OctoNormal",
    "WinSeparator:OctoWinSeparator",
    "SignColumn:OctoNormal",
    "StatusLine:OctoStatusLine",
    "StatusLineNC:OctoStatuslineNC",
  }, ","),
}

MetadataPanel.bufopts = {
  swapfile = false,
  buftype = "nofile",
  modifiable = false,
  filetype = "octo_panel",
  bufhidden = "hide",
}

---MetadataPanel constructor.
---@param parent_bufnr integer The parent buffer number
---@return MetadataPanel
function MetadataPanel:new(parent_bufnr)
  local this = {
    parent_bufnr = parent_bufnr,
    size = config.values.metadata_panel and config.values.metadata_panel.size or 50,
  }

  setmetatable(this, self)
  return this
end

function MetadataPanel:is_open()
  local valid = self.winid and vim.api.nvim_win_is_valid(self.winid)
  if not valid then
    self.winid = nil
  end
  return valid
end

function MetadataPanel:is_focused()
  return self:is_open() and vim.api.nvim_get_current_win() == self.winid
end

function MetadataPanel:open()
  if not self:buf_loaded() then
    self:init_buffer()
  end
  if self:is_open() then
    return
  end

  -- Validate parent buffer
  if not vim.api.nvim_buf_is_valid(self.parent_bufnr) then
    return
  end

  -- Get the parent window
  local parent_wins = vim.fn.win_findbuf(self.parent_bufnr)
  if #parent_wins == 0 then
    return
  end

  local original_win = vim.api.nvim_get_current_win()

  -- Use pcall to safely handle window operations
  local success = pcall(function()
    -- Focus the parent window first
    vim.api.nvim_set_current_win(parent_wins[1])

    -- Create vertical split on the right
    vim.cmd "vsplit"
    vim.cmd "wincmd L"
    vim.cmd("vertical resize " .. self.size)
    self.winid = vim.api.nvim_get_current_win()

    for k, v in pairs(MetadataPanel.winopts) do
      vim.api.nvim_set_option_value(k, v, { win = self.winid })
    end

    vim.cmd("buffer " .. self.bufid)

    -- Return focus to parent window
    vim.api.nvim_set_current_win(parent_wins[1])
  end)

  -- Restore original window if operation failed
  if not success and vim.api.nvim_win_is_valid(original_win) then
    vim.api.nvim_set_current_win(original_win)
  end
end

function MetadataPanel:close()
  if self:is_open() and #vim.api.nvim_tabpage_list_wins(0) > 1 then
    pcall(vim.api.nvim_win_hide, self.winid)
  end
end

function MetadataPanel:destroy()
  if self:buf_loaded() then
    self:close()
    pcall(vim.api.nvim_buf_delete, self.bufid, { force = true })
  else
    self:close()
  end
end

function MetadataPanel:toggle()
  if self:is_open() then
    self:close()
  else
    self:open()
  end
end

function MetadataPanel:buf_loaded()
  return self.bufid and vim.api.nvim_buf_is_loaded(self.bufid)
end

function MetadataPanel:init_buffer()
  local bn = vim.api.nvim_create_buf(false, false)

  for k, v in pairs(MetadataPanel.bufopts) do
    vim.api.nvim_set_option_value(k, v, { buf = bn })
  end

  local bufname = "OctoMetadata-" .. name_counter
  name_counter = name_counter + 1
  local ok = pcall(vim.api.nvim_buf_set_name, bn, bufname)
  if not ok then
    utils.wipe_named_buffer(bufname)
    vim.api.nvim_buf_set_name(bn, bufname)
  end
  self.bufid = bn

  return bn
end

---Write a line to the metadata panel buffer
---@param line integer
---@param text string
---@param hl_group? string
function MetadataPanel:write_line(line, text, hl_group)
  if not self:buf_loaded() then
    return
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = self.bufid })
  vim.api.nvim_buf_set_lines(self.bufid, line - 1, line, false, { text })

  if hl_group then
    vim.api.nvim_buf_add_highlight(self.bufid, -1, hl_group, line - 1, 0, -1)
  end

  vim.api.nvim_set_option_value("modifiable", false, { buf = self.bufid })
end

---Write virtual text to the metadata panel buffer
---@param line integer
---@param chunks [string, string][]
---@param opts? table Additional extmark options
function MetadataPanel:write_virtual_text(line, chunks, opts)
  if not self:buf_loaded() then
    return
  end

  opts = opts or {}
  local col = opts.col or 0
  opts.col = nil
  local extmark_opts = vim.tbl_extend("force", {
    virt_text = chunks,
    virt_text_pos = "inline",
    hl_mode = "combine",
  }, opts)

  pcall(vim.api.nvim_buf_set_extmark, self.bufid, constants.OCTO_DETAILS_VT_NS, line - 1, col, extmark_opts)
end

---Clear the metadata panel buffer
function MetadataPanel:clear()
  if not self:buf_loaded() then
    return
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = self.bufid })
  vim.api.nvim_buf_set_lines(self.bufid, 0, -1, false, {})
  vim.api.nvim_buf_clear_namespace(self.bufid, constants.OCTO_DETAILS_VT_NS, 0, -1)
  vim.api.nvim_set_option_value("modifiable", false, { buf = self.bufid })
end

M.MetadataPanel = MetadataPanel

return M
