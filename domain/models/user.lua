-- user.lua
local User = {}
User.__index = User

function User.new(id, name)
  assert(type(id)=="number" and type(name)=="string", "bad args")
  return setmetatable({ id=id, name=name }, User)
end

function User:get_id()   return self.id end
function User:get_name() return self.name end
function User:set_name(n) self.name = assert(n, "name required") end
function User:greet()    return ("Hello, %s (id=%d)!"):format(self.name, self.id) end
function User:__tostring() return ("User{id=%d, name=%q}"):format(self.id, self.name) end

return User
