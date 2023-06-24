---design choices/limits:
---* only for lua
---* only top level `local x = require'x'`
---* no gap lines between require statements, otherwise the later will be ignored
---* sort in alphabet order
---* supported forms
---  * `local x = require'x'`
---  * `local x = require'x'('x')('y')...`
---* not supported forms
---  * `local x, y = require'x', require'y'`
---
---todo: require tiers
---  * builtin: ffi, math
---  * vim's: require'vim.lsp.protocol'
---  * hal's: infra ...
---  * others: ...
---

local fn = require("infra.fn")
local jelly = require("infra.jellyfish")("squirrel.imports.sort", vim.log.levels.DEBUG)
local prefer = require("infra.prefer")

local api = vim.api
local ts = vim.treesitter

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
    if next == nil then return jelly.debug("n=%d type.expect=%s .actual=%s sexpr=%s", i, itype, "nil", "nil") end
    if next:type() ~= itype then return jelly.debug("n=%d type.expect=%s .actual=%s sexpr=%s", i, itype, next:type(), next:sexpr()) end
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
    if ident == nil then return end
  end

  if ts.get_node_text(ident, bufnr) ~= "require" then return end

  local arg0
  do
    local args = ident:next_sibling()
    assert(args ~= nil and args:type() == "arguments")
    arg0 = args:named_child(0)
    assert(arg0 ~= nil and arg0:type() == "string")
  end

  return ts.get_node_text(arg0, bufnr)
end

return function(bufnr)
  if bufnr == nil or bufnr == 0 then bufnr = api.nvim_get_current_buf() end
  if prefer.bo(bufnr, "filetype") ~= "lua" then return jelly.err("only support lua buffer") end

  local root
  do
    local langtree = ts.get_parser()
    local trees = langtree:trees()
    assert(#trees == 1)
    root = trees[1]:root()
  end

  ---@type {name: string, node: TSNode}[]
  local requires = {}
  do
    local section_started = false
    for i in fn.range(root:named_child_count()) do
      local node = assert(root:named_child(i), i)
      local require_name = find_require_mod_name(bufnr, node)
      if require_name then
        section_started = true
        -- todo: ensure there is no other node at the same line
        table.insert(requires, { name = require_name, node = node })
      else
        if section_started then break end
      end
    end
  end
  if #requires < 2 then return jelly.info("no need to sort requires") end

  local start_line, stop_line
  do
    start_line = requires[1].node:range()
    _, _, stop_line = requires[#requires].node:range()
    stop_line = stop_line + 1
  end

  table.sort(requires, function(a, b) return string.lower(a.name) < string.lower(b.name) end)

  local sorted = {}
  for _, el in ipairs(requires) do
    table.insert(sorted, ts.get_node_text(el.node, bufnr))
  end

  api.nvim_buf_set_lines(bufnr, start_line, stop_line, false, sorted)
end
