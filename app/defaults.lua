-- defaults.lua (immutable)
local _defaults = {
  base_url = "http://localhost:8888",
  endpoint = "/student/credit/get",
  timeout  = 10,
}

return setmetatable({}, {
  __index = _defaults,
  __newindex = function()
    error("DEFAULTS is read-only", 2)
  end,
  __metatable = false,
})
