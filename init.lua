-- init.lua
local MODNAME = minetest.get_current_modname() or "eduquest"
local MP = minetest.get_modpath(MODNAME)
assert(MP, ("[eduquest] Could not resolve modpath for '%s'"):format(MODNAME))

-- --- Setup DI container -----------------------------------------------------
local DI = dofile(MP .. "/infrastructure/di/di.lua")
local container = DI.new()

-- Core registrations (lazy for simplicity)
container:register("defaults",       function() return dofile(MP .. "/app/defaults.lua") end)
container:register("User",           function() return dofile(MP .. "/domain/models/user.lua") end)
container:register("forms",          function() return dofile(MP .. "/application/services/quiz/forms/forms_slideshow.lua") end)
container:register("http",           function() return dofile(MP .. "/infrastructure/http/http.lua") end)
container:register("settings",       function() return dofile(MP .. "/infrastructure/settings/settings.lua") end)
container:register("key_ui",         function() return dofile(MP .. "/presentation/form/key_form.lua") end)
container:register("hud_layer",      function() return dofile(MP .. "/presentation/hud/hud_layer.lua") end)

-- System-provided APIs
container:register("http_api",     function() return minetest.request_http_api() end)
container:register("settings_api", function() return minetest.settings end)

-- Simple inline services
container:register("logger", function()
  return { info = function(m) minetest.log("action", m) end }
end)

container:register("repo", function()
  return { get_by_id = function(id) return { id = id, name = "Beam" } end }
end)

-- Domain services (instantiate with dependencies)
local UserService   = dofile(MP .. "/application/services/user/user_service.lua")
local CourseService = dofile(MP .. "/application/services/quiz/course_service.lua")
local quiz_service  = dofile(MP .. "/application/services/quiz/quiz_service.lua")

container:register("user_service", function(c)
  return UserService.new({
    repo   = c:resolve("repo"),
    logger = c:resolve("logger"),
  })
end)

container:register("course_service", function(c)
  return CourseService.new({
    http_api     = c:resolve("http_api"),
    http         = c:resolve("http"),
    settings_api = c:resolve("settings_api"),
    defaults     = c:resolve("defaults"),
    logger       = c:resolve("logger"),
  })
end)

container:register("quiz_service", function() return quiz_service end)

-- --- Feature initialization -------------------------------------------------
local quiz = container:resolve("quiz_service")
quiz.register(container, {
  formname = "welcome:quiz:1",
  trigger_control = "sneak",
})

-- Commands
local showhud_command = dofile(MP .. "/presentation/commands/show_hud_command.lua")
showhud_command.register(container)

-- Config
local font_config = dofile(MP .. "/infrastructure/config/font_config.lua")
minetest.register_on_mods_loaded(function()
  font_config.init_fonts(MP)
end)
