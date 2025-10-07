-- infrastructure/config/font_config.lua
local function init_fonts(MP)
  local function exists(p)
    local f = io.open(p, "rb")
    if f then f:close(); return true end
    return false
  end

  local base_mod   = MP .. "/presentation/fonts"
  local base_files = "/storage/emulated/0/Android/data/vip.eduquest.educraft/files/Minetest/fonts"

  local function pick(rel)
    local a = base_mod .. "/" .. rel
    if exists(a) then return a end
    local b = base_files .. "/" .. rel
    if exists(b) then return b end
    return nil
  end

  local cfg = {
    font_path           = pick("NotoSansThai-Regular.ttf"),
    font_path_bold      = pick("NotoSansThai-Bold.ttf"),
    font_size           = "18",
    mono_font_size      = "18",
    font_bold           = false,
    font_italic         = false,
    font_shadow         = "1",
    font_shadow_alpha   = "127",
  }

  for k, v in pairs(cfg) do
    if v ~= nil then
      if type(v) == "boolean" then
        minetest.settings:set_bool(k, v)
      else
        minetest.settings:set(k, v)
      end
    else
      minetest.log("warning", "[fonts] Missing asset for " .. k .. " (not set)")
    end
  end

  minetest.settings:write()
  for k, _ in pairs(cfg) do
    minetest.log("action", ("[fonts] %s = %s"):format(k, tostring(minetest.settings:get(k))))
  end
  minetest.chat_send_all("[eduquest] Font settings saved. Restart the game to apply.")
end

return { init_fonts = init_fonts }
