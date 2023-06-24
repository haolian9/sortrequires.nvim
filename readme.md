an opinionated nvim plugin to sort require statements in alphabet order

## design choices/limits:
* only for lua
* based on treesitter
* only top level `local x = require'x'`
* no gap lines between require statements, otherwise these lines will be ignored
* sort in alphabet order
* supported forms
  * `local x = require'x'`
  * `local x = require'x'('x')('y')...`
* not supported forms
  * `local x, y = require'x', require'y'`

## status
* it just works
* it is feature-freezed

## prerequisites
* nvim 0.9.*
* haolian9/infra.nvim
* proper treesitter config for lua buffers

## usage
* `:lua require'sortrequires'()`

## todo
require tiers
* builtin: ffi, math
* vim's: vim.lsp.protocol
* hal's: infra ...
* others: ...
