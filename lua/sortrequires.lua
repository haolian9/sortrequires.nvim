---design choices/limits:
---* only for lua
---* only top level `local x = require'x'`
---* no gap lines between require statements, otherwise the later will be ignored
---* supported forms
---  * `local x = require'x'`
---  * `local x = require'x'('x')('y')...`
---* not supported forms
---  * `local x, y = require'x', require'y'`
---  * `local x = require'x' ---x`
---  * `     local x = require'x'     `
---* sort in alphabet order, based on the 'tier' of each require statement
---
---require tiers:
---  * builtin: ffi, math
---  * vim's: require'vim.lsp.protocol'
---  * hal's: infra ...
---  * others: ...
---

local fn = require("infra.fn")
local jelly = require("infra.jellyfish")("squirrel.imports.sort", vim.log.levels.INFO)
local prefer = require("infra.prefer")
local Regulator = require("infra.Regulator")
local strlib = require("infra.strlib")
local unsafe = require("infra.unsafe")

local api = vim.api
local ts = vim.treesitter

---@alias Require {name: string, node: TSNode}

---@param root TSNode
---@param ... integer|string @child index, child type
---@return TSNode?
local function get_named_decendant(root, ...)
  local args = { ... }
  assert(#args % 2 == 0)
  local arg_iter = fn.iter(args)
  ---@type TSNode
  local next = root
  for i in arg_iter do
    local itype = arg_iter()
    next = next:named_child(i)
    if next == nil then return jelly.debug("n=%d type.expect=%s .actual=%s", i, itype, "nil") end
    if next:type() ~= itype then return jelly.debug("n=%d type.expect=%s .actual=%s", i, itype, next:type()) end
  end
  return next
end

---@param bufnr integer
---@param root TSNode
---@return string?
local function find_require_mod_name(bufnr, root)
  if root:type() ~= "variable_declaration" then return end

  local expr_list = get_named_decendant(root, 0, "assignment_statement", 1, "expression_list")
  if expr_list == nil then return end

  ---@type TSNode
  local ident
  do
    ---`local x = require'x'`
    ---`local x = require'x'('x')('y')('z')`
    local fn_call = get_named_decendant(expr_list, 0, "function_call")
    if fn_call == nil then return end
    for _ = 1, 5 do
      local child = fn_call:named_child(0)
      if child == nil then return end
      if child:type() == "identifier" then
        ident = child
        break
      end
      if child:type() ~= "function_call" then return end
      fn_call = child
    end
    if ident == nil then return jelly.err("too many nested function calls on the RHS") end
  end

  if ts.get_node_text(ident, bufnr) ~= "require" then return end

  local arg0
  do
    local args = ident:next_sibling()
    assert(args ~= nil and args:type() == "arguments")
    arg0 = args:named_child(0)
    assert(arg0 ~= nil and arg0:type() == "string")
  end

  local name
  do
    name = ts.get_node_text(arg0, bufnr)
    if strlib.startswith(name, '"') or strlib.startswith(name, "'") then
      name = string.sub(name, 2, -2)
    elseif strlib.startswith(name, "[[") then
      name = string.sub(name, 3, -3)
    else
      error("unknown chars surrounds the string")
    end
  end

  return name
end

---@type fun(orig_requires: Require[]): Require[][]
local sorted_tiers
do
  local preset_tiers = {
    fn.toset({ "ffi" }),
    fn.toset({ "vim" }),
    fn.toset({ "infra" }),
  }

  ---@param a Require
  ---@param b Require
  ---@return boolean
  local function compare_requires(a, b) return string.lower(a.name) < string.lower(b.name) end

  function sorted_tiers(orig_requires)
    local tiers = {}
    do
      for i = 1, #preset_tiers + 1 do
        tiers[i] = {}
      end
      for _, el in ipairs(orig_requires) do
        local tier_ix
        local prefix = fn.split_iter(el.name, ".")()
        for i, presets in ipairs(preset_tiers) do
          if presets[prefix] then
            tier_ix = i
            break
          end
        end
        if tier_ix == nil then tier_ix = #tiers end
        table.insert(tiers[tier_ix], el)
      end
    end

    for _, requires in ipairs(tiers) do
      table.sort(requires, compare_requires)
    end

    return tiers
  end
end

local regulator = Regulator(1024)

return function(bufnr)
  if bufnr == nil or bufnr == 0 then bufnr = api.nvim_get_current_buf() end
  if prefer.bo(bufnr, "filetype") ~= "lua" then return jelly.err("only support lua buffer") end

  if regulator:throttled(bufnr) then return jelly.debug("no change") end

  local root
  do
    local langtree = ts.get_parser()
    local trees = langtree:trees()
    assert(#trees == 1)
    root = trees[1]:root()
  end

  local start_line, stop_line, tiers
  do
    ---@type Require[]
    local requires = {}
    do
      local section_started = false
      for i in fn.range(root:named_child_count()) do
        local node = assert(root:named_child(i), i)
        local require_name = find_require_mod_name(bufnr, node)
        if require_name then
          section_started = true
          table.insert(requires, { name = require_name, node = node })
        else
          if section_started then break end
        end
      end
    end
    if #requires < 2 then return jelly.info("no need to sort requires") end

    do
      start_line = requires[1].node:range()
      _, _, stop_line = requires[#requires].node:range()
      stop_line = stop_line + 1
    end

    do ---ensure each require is the only node in its range
      ---there is no easy to do it, current impl have such limitations:
      ---* no leading/trailing space/tab before require statements
      local lineslen = unsafe.lineslen(bufnr, fn.range(start_line, stop_line))
      for _, el in ipairs(requires) do
        local start_line, start_col, stop_row, stop_col = el.node:range()
        if start_col ~= 0 then
          jelly.err("require in line=%d has leadings", start_line)
          error("multiple nodes in same line")
        end
        if stop_col ~= lineslen[stop_row] then
          jelly.err("require in line=%d has trailings", stop_row)
          error("multiple nodes in same line")
        end
      end
    end

    tiers = sorted_tiers(requires)
  end

  local sorted_lines = {}
  do
    for requires in fn.filter(function(requires) return #requires > 0 end, tiers) do
      for _, el in ipairs(requires) do
        table.insert(sorted_lines, ts.get_node_text(el.node, bufnr))
      end
      table.insert(sorted_lines, "")
    end
    assert(#sorted_lines > 1)
    ---the last line should not be blank
    table.remove(sorted_lines)
  end

  do
    local old_lines = api.nvim_buf_get_lines(bufnr, start_line, stop_line, false)
    assert(#sorted_lines == #old_lines)
    local no_changes = fn.iter_equals(sorted_lines, old_lines)
    if no_changes then
      regulator:update(bufnr)
      return jelly.debug("no changes in the require section")
    end
  end

  api.nvim_buf_set_lines(bufnr, start_line, stop_line, false, sorted_lines)
  regulator:update(bufnr)
end
