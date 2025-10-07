---@diagnostic disable: redundant-parameter
local M = {}

local SESSION_BASE_URL = "https://server.eduquest.vip/api/session/get/"


local function perform_api_request(http_api, config, token)
    local headers = {
        "Accept: application/json",
    }

    if token and token ~= "" then
        headers[#headers + 1] = "Authorization: Bearer " .. token
    else
        minetest.log("warning", "[eduquest] eduquest_token is empty; proceeding without Authorization header")
    end

    minetest.log("action", string.format("[eduquest] HTTP GET %s (timeout=%d)", config.url, config.timeout))

    http_api.fetch({
        url = config.url,
        method = "GET",
        timeout = config.timeout,
        extra_headers = headers,
    }, function(res)
        if res.succeeded and res.code == 200 then
            minetest.log("action", "[eduquest] API OK: " .. (res.data or ""))
        else
            minetest.log("error", "[eduquest] API error code=" .. tostring(res.code)
                .. " body=" .. tostring(res.data))
        end
    end)
end

local function extract_token(payload)
    if type(payload) == "string" then
        return payload
    end

    if type(payload) ~= "table" then
        return nil
    end

    -- Common token key spellings
    local direct = payload.token or payload.Token or payload.access_token
        or payload.session_token or payload.sessionToken
    if type(direct) == "string" and direct ~= "" then
        return direct
    end

    for _, key in ipairs({ "value", "Value", "data", "result", "session" }) do
        local candidate = payload[key]
        if type(candidate) == "string" and candidate ~= "" then
            return candidate
        elseif type(candidate) == "table" then
            local nested = extract_token(candidate)
            if nested and nested ~= "" then
                return nested
            end
        end
    end

    for _, v in pairs(payload) do
        if type(v) == "string" and v:match("^[A-Za-z0-9-_]+%.[A-Za-z0-9-_]+%.[A-Za-z0-9-_]+$") then
            return v -- likely JWT
        elseif type(v) == "table" then
            local nested = extract_token(v)
            if nested and nested ~= "" then
                return nested
            end
        end
    end

    return nil
end

local function fetch_session_token_internal(http_api, timeout, session_key, callback)
    callback = callback or function() end

    if not http_api then
        minetest.log("warning", "[eduquest] HTTP disabled; cannot fetch session token")
        callback(nil)
        return
    end

    if not session_key or session_key == "" then
        minetest.log("warning", "[eduquest] Session key missing; cannot fetch token")
        callback(nil)
        return
    end

    local session_url = SESSION_BASE_URL .. session_key

    minetest.log("action", string.format("[eduquest] HTTP GET %s (timeout=%d)", session_url, timeout))

    http_api.fetch({
        url = session_url,
        method = "GET",
        timeout = timeout,
        extra_headers = {
            "Accept: application/json",
        },
    }, function(res)
        if res.succeeded and res.code == 200 and res.data then
            local parsed = minetest.parse_json(res.data)
            if not parsed then
                minetest.log("error", "[eduquest] Session response JSON parse failed; body=" .. res.data)
            else
                local token = extract_token(parsed)
                if token and token ~= "" then
                    callback(token)
                    return
                end

                minetest.log("error", "[eduquest] Session response missing token; body=" .. res.data)
            end
        else
            minetest.log("error", "[eduquest] Session API error code=" .. tostring(res.code)
                .. " body=" .. tostring(res.data))
        end

        callback(nil)
    end)
end

function M.fetch_session_token(http_api, timeout, session_key, callback)
    fetch_session_token_internal(http_api, timeout, session_key, callback)
end

function M.normalize_url(base, endpoint)
    if not endpoint or endpoint == "" then
        -- (optional) trim trailing "/" from base for consistency
        if base:sub(-1) == "/" then base = base:sub(1, -2) end
        return base
    end

    if base:sub(-1) == "/" then
        base = base:sub(1, -2)
    end

    if endpoint:sub(1, 1) ~= "/" then
        endpoint = "/" .. endpoint
    end

    return base .. endpoint
end

---Call the configured Eduquest API using the engine's HTTP subsystem.
---@param container table
---@param opts table|nil
function M.resolve_token(container, opts, callback)
    opts = opts or {}
    callback = callback or function() end

    local config = opts.config
    local settings = container:resolve("settings")
    if not config then
        if not settings or not settings.read then
            callback(nil, nil)
            return
        end
        config = settings.read(container)
    end

    local http_api = container:resolve("http_api")

    local function finish(token)
        callback(token, config)
    end

    if config.token and config.token ~= "" then
        finish(config.token)
        return
    end

    if config.session_key and config.session_key ~= "" then
        M.fetch_session_token(http_api, config.timeout, config.session_key, function(token)
            finish(token)
        end)
        return
    end

    local player_name = opts.player_name
    if player_name then
        local session_ui = container:resolve("session_key_ui")
        if session_ui and session_ui.request_key then
            session_ui.request_key(container, player_name, {
                on_success = function(saved_key)
                    config.session_key = saved_key
                    M.fetch_session_token(http_api, config.timeout, saved_key, function(token)
                        finish(token)
                    end)
                end,
                on_cancel = function()
                    minetest.log("warning", "[eduquest] Session key entry cancelled by player " .. player_name)
                    finish(nil)
                end,
            })
            return
        end
    end

    finish(nil)
end

function M.call_api(container, opts)
    return M.call_api_with_opts(container, opts)
end

function M.call_api_with_opts(container, opts)
    opts = opts or {}

    local http_api     = container:resolve("http_api")
    local settings_api = container:resolve("settings_api")

    minetest.log("action", "[eduquest] secure.http_mods = " ..
        (settings_api:get("secure.http_mods") or "<nil>"))

    if not http_api then
        minetest.log("warning", "[eduquest] HTTP disabled (set secure.http_mods = eduquest)")
        return
    end

    local settings = container:resolve("settings")
    local config = settings.read(container)

    if not config.url or config.url == "" then
        minetest.log("warning", "[eduquest] Missing eduquest_base_url/eduquest_endpoint; skipping HTTP call")
        return
    end

    M.resolve_token(container, { player_name = opts.player_name, config = config }, function(token, resolved_config)
        local effective_config = resolved_config or config

        if not token then
            if effective_config.session_key and effective_config.session_key ~= "" then
                minetest.log("warning", "[eduquest] Failed to fetch session token; continuing without Authorization header")
            else
                minetest.log("warning", "[eduquest] Session key not configured; continuing without Authorization header")
            end
        end

        perform_api_request(http_api, effective_config, token)
    end)
end

return M
