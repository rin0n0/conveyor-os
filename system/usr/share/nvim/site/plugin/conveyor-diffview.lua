-- diffview.nvim ships with Conveyor OS. Icons are off: nvim-web-devicons is not installed.
local ok, diffview = pcall(require, "diffview")
if ok then
  diffview.setup({ use_icons = false })
end
