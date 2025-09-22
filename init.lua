local MP = minetest.get_modpath(minetest.get_current_modname())

-- ---- Add these to DI (singleton-style) -------------------------------------
-- Load once at module scope so DI returns the same instance each resolve
local DEFAULTS          = dofile(MP .. "/app/defaults.lua")
local user_impl         = dofile(MP .. "/domain/models/user.lua")
local forms_impl        = dofile(MP .. "/application/services/quiz/forms/forms_slideshow.lua")
local quiz_service      = dofile(MP .. "/application/services/quiz/quiz_service.lua")
local CourseService    = dofile(MP .. "/application/services/quiz/course_service.lua")
local UserService       = dofile(MP .. "/application/services/user/user_service.lua")
local http_impl         = dofile(MP .. "/infrastructure/http/http.lua")
local settings_impl     = dofile(MP .. "/infrastructure/settings/settings.lua")
local DI                = dofile(MP .. "/infrastructure/di/di.lua")
local session_key_ui    = dofile(MP .. "/presentation/session_key_form.lua")
local http_api_impl     = minetest.request_http_api()   -- may be nil if not whitelisted
local settings_api_impl = minetest.settings

local container = DI.new()

container:register("defaults",      function(c) return DEFAULTS end)
container:register("User",          function(c) return user_impl end)          -- the module (constructor lives on it)
container:register("http",          function(c) return http_impl end)          -- your http module (normalize_url, etc.)
container:register("settings",      function(c) return settings_impl end)          -- your settings helper module
container:register("http_api",      function(c) return http_api_impl end)      -- Luanti HTTP API (or nil)
container:register("settings_api",  function(c) return settings_api_impl end)  -- Luanti settings API
container:register("forms",         function(c) return forms_impl end)
container:register("session_key_ui", function(c) return session_key_ui end)
container:register("logger",        function(c) return { info=function(m) minetest.log("action", m) end } end)
container:register("repo",          function(c) return { get_by_id=function(id) return {id=id, name="Beam"} end } end)
container:register("svc",           function(c) return UserService.new({ repo=c:resolve("repo"), logger=c:resolve("logger") }) end)
container:register("quiz_service",  function(c) return quiz_service; end)
container:register("course_service", function(c)
  --- local CourseService = dofile(MP .. "/application/services/quiz/course_service.lua")
  return CourseService.new({
    http_api     = c:resolve("http_api"),
    http         = c:resolve("http"),
    settings_api = c:resolve("settings_api"),
    defaults     = c:resolve("defaults"),
    logger       = c:resolve("logger"),
  })
end)
-- ---------------------------------------------------------------------------


local quiz = container:resolve("quiz_service")

quiz.register(container, {
  formname = "welcome:quiz:1",
  trigger_control = "sneak", -- or "aux1"
})


