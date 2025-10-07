-- hud_layer.lua
local M = {}

function M.show(player, text)
    if not player or not player:is_player() then
        minetest.log("warning", "[hud_layer] Invalid player")
        return
    end

    local id = player:hud_add({
        hud_elem_type = "text",
        position      = {x = 0.5, y = 0.5},
        offset        = {x = 0, y = 0},
        text          = text or "Hello world!",
        alignment     = {x = 0, y = 0},
        scale         = {x = 100, y = 100},
        number        = 0xFFFFFF, -- white text
    })

    minetest.log("action", "[hud_layer] HUD displayed for " .. player:get_player_name())
    return id
end

return M