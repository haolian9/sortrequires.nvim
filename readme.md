an opinionated nvim plugin to sort require statements in alphabet order

## design choices/limits:
* only for lua
* based on treesitter
* only top level `local x = require'x'`
* assume all require statements are in the same part of a buffer
* supported forms
  * `local x = require'x'`
  * `local x = require'x'('x')('y')...`
* not supported forms
  * `local x, y = require'x', require'y'`
  * `local x = require'x' ---x`
* sort in alphabet order, based on the 'tier' of each require statement
* require tiers:
  * builtin: ffi, math
  * vim's: vim
  * hal's: infra
  * others: ...

## status
* it may change the AST, use it with caution
* it is feature-freezed

## prerequisites
* nvim 0.9.*
* haolian9/infra.nvim
* proper treesitter config for lua buffers

## usage
* `:lua require'sortrequires'()`
