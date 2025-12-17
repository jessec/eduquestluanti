local M = {}

local FORMNAME = "eduquest:session_key"
local pending = {}

local function trim(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function build_formspec()
  local parts = {
    "formspec_version[6]size[7,3.4]",
    "label[0.4,0.5;" .. minetest.formspec_escape("Paste your Eduquest session key") .. "]",
    "field[0.4,1.3;6.2,0.8;session_key;;]",
    "button[0.8,2.2;2.2,0.8;cancel;Cancel]",
    "button[3.6,2.2;2.2,0.8;save;Save]",
  }
  return table.concat(parts)
end

function M.request_key(container, player_name, opts)
  opts = opts or {}

  if not player_name or player_name == "" then
    return false
  end

  local settings = container:resolve("settings")
  if settings then
    local config = settings.read(container)
    if config.session_key and config.session_key ~= "" then
      if opts.on_success then
        opts.on_success(config.session_key)
      end
      return true
    end
  end

  pending[player_name] = {
    container  = container,
    on_success = opts.on_success,
    on_cancel  = opts.on_cancel,
  }

  minetest.show_formspec(player_name, FORMNAME, build_formspec())
  return false
end

minetest.register_on_player_receive_fields(function(player, formname, fields)
  if formname ~= FORMNAME then return end
  if not player then return end

  local name = player:get_player_name()
  local entry = pending[name]
  if not entry then return end

  if fields.quit and not (fields.save or fields.cancel) then
    pending[name] = nil
    if entry.on_cancel then entry.on_cancel() end
    return
  end

  if fields.cancel then
    minetest.close_formspec(name, FORMNAME)
    pending[name] = nil
    if entry.on_cancel then entry.on_cancel() end
    return
  end

  if fields.save or fields.key_enter_field == "session_key" then
    local key = trim(fields.session_key or "")
    if key == "" then
      minetest.chat_send_player(name, "Session key cannot be empty.")
      return
    end

    local ok = false
    if entry.container then
      local settings = entry.container:resolve("settings")
      if settings and settings.save_session_key then
        ok = settings.save_session_key(entry.container, key)
      end
    end

    if ok then
      minetest.close_formspec(name, FORMNAME)
      pending[name] = nil
      minetest.chat_send_player(name, "Session key saved.")
      if entry.on_success then entry.on_success(key) end
    else
      minetest.chat_send_player(name, "Failed to save session key.")
    end
    return
  end
end)

return M
