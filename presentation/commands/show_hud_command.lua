-- presentation/commands/showhud_command.lua
local function register(container)
  minetest.register_chatcommand("showhud", {
    description = "Show a test HUD layer",
    func = function(name)
      local player = minetest.get_player_by_name(name)
      if not player then
        return false, "Player not found."
      end

      local hud = container:resolve("hud_layer")
      hud.show(player, "Welcome to EduQuest!")
      return true, "HUD displayed."
    end
  })
end

return { register = register }
