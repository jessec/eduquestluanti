-- di.lua
local DI = {}
DI.__index = DI

function DI.new() return setmetatable({f={}, s={}}, DI) end
function DI:register(name, factory) self.f[name] = factory end
function DI:resolve(name)
  local s = self.s[name]; if s then return s end
  local f = assert(self.f[name], "no provider: "..name)
  local v = f(self)
  self.s[name] = v
  return v
end
return DI