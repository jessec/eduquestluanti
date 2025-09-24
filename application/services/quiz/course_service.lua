-- course_service.lua
-- A Lua port of UserCoursesService.java for Luanti/Minetest.
-- Caches active question sets, refreshes periodically, and can pick a random unseen MC question.

---@class EduQuestCourseService
---@field http_api table|nil
---@field http table
---@field settings_api table
---@field defaults table|nil
---@field logger {info:fun(msg:string)}|nil
---@field _cache_json table|nil
---@field _question_sets table|nil
---@field _last_fetch_time number
---@field _refresher_started boolean
---@field _cfg table
local CourseService = {}
CourseService.__index = CourseService

-- -------- Config (safe fallbacks) -------------------------------------------
local DEFAULT_BASE_URL      = "https://server.eduquest.vip"
local ENDPOINT_ACTIVE_SETS  = "/api/questionset/get/active"
local ENDPOINT_SAVE_QUESTION= "/api/question/save"
local CACHE_DURATION_SEC    = 35 * 60   -- 35 minutes
local REFRESH_INTERVAL_SEC  = 5 * 60    -- 5 minutes
local MAX_RETRIES           = 20
local RETRY_DELAY_BASE_SEC  = 10        -- backoff * attempt
-------------------------------------------------------------------------------

local function now_sec()
  return minetest.get_gametime() or os.time()
end

local function log(self, msg)
  if self.logger and self.logger.info then
    self.logger.info("[CourseService] " .. msg)
  else
    minetest.log("action", "[CourseService] " .. msg)
  end
end

local function warn(msg) minetest.log("warning", "[CourseService] "..msg) end
local function err (msg) minetest.log("error",   "[CourseService] "..msg) end

-- Trim, collapse internal whitespace, lowercase (like Java version's norm)
local function norm(s)
  if not s then return "" end
  local t = s:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
  return t:lower()
end

-- Simple, deterministic string hash (djb2) for dedupe/identity
local bit = rawget(_G, "bit32") or rawget(_G, "bit")  -- Lua 5.2 or LuaJIT
local function djb2(s)
  if bit then
    local band, bxor, lshift = bit.band, bit.bxor, bit.lshift
    local h = 5381
    for i = 1, #s do
      h = band(bxor(lshift(h, 5) + h, s:byte(i)), 0xffffffff)  -- (h<<5)+h then XOR
    end
    return string.format("%08x", h)
  else
    -- Fallback to additive variant if no bit library is available
    local h = 5381
    for i = 1, #s do
      h = (h * 33 + s:byte(i)) % 4294967296
    end
    return string.format("%08x", h)
  end
end

-- Canonical, shuffle-proof payload (ignore images)
local function canonical_payload(q)
  -- expecting question schema: { questionText, answers = {..}, correctAnswer, image? }
  local text    = norm(q.questionText)
  local correct = norm(q.correctAnswer)

  local answers = {}
  if type(q.answers) == "table" then
    for _, a in ipairs(q.answers) do
      if a and a ~= "" then table.insert(answers, norm(a)) end
    end
  end
  table.sort(answers, function(a,b) return a:lower() < b:lower() end)

  return "Q|"..text.."|A|"..table.concat(answers, "|").."|C|"..correct
end

local function compute_hash(q)
  if q.questionHash and q.questionHash ~= "" then return q.questionHash end
  local h = djb2(canonical_payload(q))
  q.questionHash = h
  return h
end

local function is_multiple_choice(q)
  if not q then return false end
  local ans = q.answers
  if type(ans) ~= "table" or #ans < 2 then return false end
  local correct = q.correctAnswer
  if not correct or correct == "" then return false end

  local c = norm(correct)
  for _, a in ipairs(ans) do
    if a and norm(a) == c then return true end
  end
  return false
end

-- Depth-first collection of questions from BlockDto-like trees
local function collect_questions_recursive_unique(block, unique_by_hash, context)
  if not block then return end

  -- Process registry entries
  local registry = block.registry
  if type(registry) == "table" then
    for _, list in pairs(registry) do
      if type(list) == "table" then
        for _, q in ipairs(list) do
          if type(q) == "table" and q.questionText then
            -- Prefer the provided UUID-like key; fallback to compute_hash if absent.
            local h = q.questionHash or (type(compute_hash) == "function" and compute_hash(q)) or nil
            if h and h ~= "" and unique_by_hash[h] == nil then
              if context then
                -- NEVER modify an existing questionSetId; only fill if missing/empty.
                local set_id = context.set_id
                if set_id and (q.questionSetId == nil or q.questionSetId == "") then
                  q.questionSetId = set_id
                elseif set_id and q.questionSetId and q.questionSetId ~= set_id then
                  -- Optional: surface a mismatch for diagnostics; do not mutate.
                  -- minetest.log("warning", "[collect] questionSetId mismatch for hash " .. h)
                end

                -- Fill owner only if missing/empty.
                local owner = context.owner
                if owner and (q.owner == nil or q.owner == "") then
                  q.owner = owner
                end
              end

              unique_by_hash[h] = q
            end
          end
        end
      end
    end
  end

  -- Recurse into children
  local children = block.children
  if type(children) == "table" then
    for _, child in ipairs(children) do
      collect_questions_recursive_unique(child, unique_by_hash, context)
    end
  end
end


-- Read mod settings and combine URL pieces
local function build_urls(self)
  local s = self.settings_api
  local http = self.http

  local base = (s and s:get("eduquest_base_url")) or (self.defaults and self.defaults.BASE_URL) or DEFAULT_BASE_URL
  if base == "" then base = DEFAULT_BASE_URL end

  local normalize = http and http.normalize_url or function(b,e)
    if b:sub(-1) == "/" then b = b:sub(1,-2) end
    if e:sub(1,1) ~= "/" then e = "/"..e end
    return b..e
  end

  return {
    active_sets = normalize(base, ENDPOINT_ACTIVE_SETS),
    save_question = normalize(base, ENDPOINT_SAVE_QUESTION),
  }
end

local function resolve_token(self, cb)
  cb = cb or function() end

  local settings_api = self.settings_api
  local keys = {
    "eduquest_token",
    "welcome_popup_token",
    "clerk_token",
  }

  for _, key in ipairs(keys) do
    local value = settings_api and settings_api:get(key)
    if value and value ~= "" then
      cb(value, nil)
      return
    end
  end

  local session_key = settings_api and settings_api:get("eduquest_session_key")
  if session_key and session_key ~= "" then
    if self.http and self.http.fetch_session_token then
      local timeout = (self._cfg and self._cfg.timeout) or 10
      self.http.fetch_session_token(self.http_api, timeout, session_key, function(token)
        if token and token ~= "" then
          cb(token, nil)
        else
          cb(nil, "session_exchange_failed")
        end
      end)
    else
      warn("Session key available but HTTP helper missing; cannot fetch bearer token.")
      cb(nil, "no_http_helper")
    end
    return
  end

  cb(nil, "no_token")
end

-- Async GET with retries; on success, returns parsed JSON (table) to cb(json,nil)
local function get_json_with_retry(self, url, headers, cb, attempt)
  attempt = attempt or 1
  if not self.http_api then cb(nil, "HTTP disabled"); return end

  self.http_api.fetch({
    url = url,
    method = "GET",
    timeout = (self._cfg and self._cfg.timeout) or 10,
    extra_headers = headers,
  }, function(res)
    if res.succeeded and res.code == 200 and res.data then
      local ok, parsed = pcall(minetest.parse_json, res.data)
      if ok then cb(parsed, nil) else cb(nil, "JSON parse error") end
      return
    end

    -- 4xx => don't retry
    if res.code and res.code >= 400 and res.code < 500 then
      cb(nil, "Client error: "..tostring(res.code))
      return
    end

    if attempt >= MAX_RETRIES then
      cb(nil, "Failed after retries")
      return
    end

    local delay = RETRY_DELAY_BASE_SEC * attempt
    minetest.after(delay, function()
      get_json_with_retry(self, url, headers, cb, attempt + 1)
    end)
  end)
end

-- Async POST JSON
local function post_json(self, url, headers, body, cb)
  if not self.http_api then cb(nil, "HTTP disabled"); return end
  self.http_api.fetch({
    url = url,
    method = "POST",
    data = body,
    timeout = (self._cfg and self._cfg.timeout) or 10,
    extra_headers = headers,
  }, function(res)
    if res.succeeded and res.code == 200 then
      cb(true, nil)
    else
      cb(false, "HTTP "..tostring(res.code or "fail"))
    end
  end)
end

-- ---------------------- Constructor -----------------------------------------
---@param deps { http_api?:table, http:table, settings_api:table, defaults?:table, logger?:{info:fun(string)} }
function CourseService.new(deps)
  local self = setmetatable({}, CourseService)
  self.http_api     = deps.http_api
  self.http         = deps.http or {}
  self.settings_api = deps.settings_api or minetest.settings
  self.defaults     = deps.defaults
  self.logger       = deps.logger
  self._cache_json  = nil
  self._question_sets = nil
  self._last_fetch_time = 0
  self._refresher_started = false
  self._storage = nil

  local urls = build_urls(self)
  self._cfg = {
    urls = urls,
    timeout = tonumber(self.settings_api:get("eduquest_http_timeout") or "") or 10,
  }

  -- kick off background refresher (minetest.after loop)
  self:start_refresher()
  return self
end

-- ---------------------- Public API ------------------------------------------

-- Ensure data exists or trigger refresh (non-blocking). Returns cached JSON (or nil if not yet available).
function CourseService:get_user_courses()
  local expired = (now_sec() - (self._last_fetch_time or 0)) > CACHE_DURATION_SEC
  if (not self._cache_json) or expired or (type(self._question_sets) ~= "table") then
    self:_refresh_async()
  end
  return self._cache_json
end

function CourseService:get_question_sets()
  -- Will be a table (array) after first successful fetch, else nil
  return self._question_sets
end

function CourseService:clear_cache()
  self._cache_json = nil
  self._question_sets = nil
  self._last_fetch_time = 0
end

-- Pick a random unseen multiple-choice question (returns q or nil, reason)
function CourseService:get_question()
  -- make sure we've at least initiated a fetch
  self:get_user_courses()

  if not self._question_sets or #self._question_sets == 0 then
    return nil, "loading_or_empty"
  end

  -- Load answered hashes (very simple mod storage example)
  local answered = {}
  local storage = self._storage
  if not storage then
    storage = minetest.get_mod_storage()
    if storage then
      self._storage = storage
    else
      warn("Mod storage unavailable; cannot track answered questions yet.")
      storage = {
        get_string = function() return "" end,
        set_string = function() end,
      }
      self._storage = storage
      return nil, "storage_unavailable"
    end
  end

  local raw = storage:get_string("questions_done")
  if raw and raw ~= "" then
    local ok, arr = pcall(minetest.parse_json, raw)
    if ok and type(arr) == "table" then
      for _, h in ipairs(arr) do answered[h] = true end
    end
  end

  -- Collect all questions uniquely by hash across sets/blocks
  local unique = {}
  for _, set in ipairs(self._question_sets) do
    if set and type(set.blocks) == "table" then
      local context = {
        set_id = set.id or set._id or set.questionSetId or set.question_set_id,
        owner = set.owner or set.ownerId or set.owner_id
          or (type(set.meta) == "table" and (set.meta.owner or set.meta.ownerId or set.meta.owner_id))
      }
      for _, block in ipairs(set.blocks) do
        collect_questions_recursive_unique(block, unique, context)
      end
    end
  end

  local unseen = {}
  for h, q in pairs(unique) do
    if not answered[h] and is_multiple_choice(q) then
      table.insert(unseen, q)
    end
  end

  if #unseen == 0 then
    return nil, "no_unseen_mc"
  end

  local idx = math.random(1, #unseen)
  local selected = unseen[idx]
  if not (selected and selected.questionText and selected.correctAnswer) then
    return nil, "invalid_question"
  end
  log(self, ("🎲 Selected MC question: %s"):format(selected.questionText))
  return selected
end

-- Save question attempt/result to server (async). payload: table -> JSON.
-- cb(ok:boolean, err?:string)
function CourseService:save_question(payload, cb)
  cb = cb or function() end
  resolve_token(self, function(token)
    if not token or token == "" then cb(false, "no_token"); return end

    local headers = {
      "Content-Type: application/json",
      "Authorization: Bearer " .. token
    }

    local ok, json = pcall(minetest.write_json, payload)
    if not ok then cb(false, "json_encode_error"); return end

    post_json(self, self._cfg.urls.save_question, headers, json, function(ok2, e2)
      if not ok2 then
        err("Failed to save question: "..tostring(e2))
        cb(false, e2)
      else
        log(self, "✅ Question saved successfully.")
        cb(true)
      end
    end)
  end)
end

-- ---------------------- Internals -------------------------------------------

function CourseService:_refresh_async()
  if not self.http_api then
    warn("HTTP disabled. Set secure.http_mods = <your_modname> and restart.")
    return
  end

  resolve_token(self, function(token, err_code)
    if not token or token == "" then
      if err_code == "session_exchange_failed" then
        warn("Failed to exchange session key for bearer token; cannot fetch question sets yet.")
      else
        warn("No token set (e.g., eduquest_token). Cannot fetch question sets yet.")
      end
      return
    end

    self:clear_cache()
    log(self, "🔄 Fetching question sets...")
    local headers = {
      "Accept: application/json",
      "Authorization: Bearer " .. token
    }

    get_json_with_retry(self, self._cfg.urls.active_sets, headers, function(json, e)
      if not json then
        err("Fetch failed: "..tostring(e))
        return
      end

      -- Expecting { data = { questionSets = [...] } } like Java mapper
      local data = (json and json.data) or {}
      local sets = data.questionSets or data or {}
      if type(sets) ~= "table" then sets = {} end

      self._cache_json      = json
      self._question_sets   = sets
      self._last_fetch_time = now_sec()
      log(self, "✅ Question sets loaded.")
    end)
  end)
end

function CourseService:_tick_refresher()
  self:_refresh_async()
  minetest.after(REFRESH_INTERVAL_SEC, function() self:_tick_refresher() end)
end

function CourseService:start_refresher()
  if self._refresher_started then return end
  self._refresher_started = true
  minetest.after(1, function() self:_tick_refresher() end)
end

-- Factory helper for DI containers
-- Usage in DI:
-- container:register("course_service", function(c)
--   local svc = CourseService.new({
--     http_api     = c:resolve("http_api"),
--     http         = c:resolve("http"),
--     settings_api = c:resolve("settings_api"),
--     defaults     = c:resolve("defaults"),
--     logger       = c:resolve("logger"),
--   })
--   return svc
-- end)
return CourseService
