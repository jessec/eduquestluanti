-- user_service.lua
local UserService = {}
UserService.__index = UserService

-- deps = { repo=..., logger=..., clock=... }
function UserService.new(deps)
  assert(deps and deps.repo, "repo required")
  deps.logger = deps.logger or { info=function() end }
  return setmetatable({ _deps = deps }, UserService)
end

function UserService:greet(id)
  local u = self._deps.repo:get_by_id(id)
  self._deps.logger.info("greeted "..id)
  return ("Hello, %s!"):format(u.name)
end

return UserService