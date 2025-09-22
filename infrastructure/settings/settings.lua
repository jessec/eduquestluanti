local M = {}

---Read HTTP settings from the engine and merge with defaults.
---@param container table Dependency injection container.
---@return { url: string, token: string, timeout: number }
function M.read(container)
  local defaults     = container:resolve("defaults")
  local http         = container:resolve("http")
  local settings_api = container:resolve("settings_api")

  local base_url = settings_api:get("eduquest_base_url")
  local endpoint = settings_api:get("eduquest_endpoint")
  local token        = settings_api:get("eduquest_token") or ""
  local session_key  = settings_api:get("eduquest_session_key") or ""
  local timeout  = tonumber(settings_api:get("eduquest_http_timeout") or "")

  if not base_url or base_url == "" then base_url = defaults.base_url end
  endpoint = endpoint or defaults.endpoint
  timeout  = timeout  or defaults.timeout

  return {
    url     = http.normalize_url(base_url, endpoint),
    token   = token,
    session_key = session_key,
    timeout = timeout,
  }
end

function M.save_session_key(container, key)
  local settings_api = container:resolve("settings_api")
  if not settings_api or not settings_api.set then
    return false
  end

  key = key or ""
  settings_api:set("eduquest_session_key", key)
  if settings_api.write then
    settings_api:write()
  end
  return true
end

return M
