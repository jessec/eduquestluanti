-- defaults.lua (immutable)
local _defaults = {
  base_url = "https://server.eduquest.vip",
  endpoint = "/api/student/credit/get",
  timeout  = 10,
}

return setmetatable({}, {
  __index = _defaults,
  __newindex = function()
    error("DEFAULTS is read-only", 2)
  end,
  __metatable = false,
})
