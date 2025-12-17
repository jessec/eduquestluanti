-- course_service.lua
-- A Lua port of UserCoursesService.java for Luanti/Minetest.
-- Caches active question items (v2), refreshes periodically, and can pick a random unseen MC question.

---@class EduQuestCourseService
---@field http_api table|nil
---@field http table
---@field settings_api table
---@field defaults table|nil
---@field logger {info:fun(msg:string)}|nil
---@field _cache_json table|nil
---@field _question_items table|nil
---@field _courses table|nil
---@field _last_fetch_time number
---@field _refresher_started boolean
---@field _cfg table
---@field _current_course_id_mem string|nil
local CourseService = {}
CourseService.__index = CourseService

-- -------- Config (safe fallbacks) -------------------------------------------
local DEFAULT_BASE_URL      = "https://server.eduquest.vip"
local ENDPOINT_ACTIVE_QUESTIONS  = "/api/v2/questions/active"
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

local function quizlog(msg)
  minetest.log("action", "[eduquest_quiz] " .. msg)
end

local function safe_str(v)
  if type(v) == "string" then return v end
  if v == nil then return "" end
  return tostring(v)
end

-- Trim, collapse internal whitespace, lowercase (like Java version's norm)
local function norm(s)
  if not s then return "" end
  local t = s:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
  return t:lower()
end

-- Simple, deterministic string hash (djb2) for fallback identity
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

-- Canonical payload for fallback hashing
local function canonical_payload(q)
  -- expecting question schema: { questionText, answers = {..}, correctAnswer }
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

local function make_item_key(course_id, item_id)
  if not course_id or course_id == "" or not item_id or item_id == "" then
    return nil
  end
  return course_id .. ":" .. item_id
end

local function load_answered_keys_from_storage(storage)
  local answered = {}
  if not storage then
    return answered
  end

  local raw = storage:get_string("questions_done")
  if raw and raw ~= "" then
    local ok, arr = pcall(minetest.parse_json, raw)
    if ok and type(arr) == "table" then
      for _, key in ipairs(arr) do
        if type(key) == "string" and key ~= "" then
          answered[key] = true
        end
      end
    end
  end

  return answered
end


-- Read mod settings and combine URL pieces
local function build_urls(self)
  local s = self.settings_api
  local http = self.http

  local base = (s and s:get("eduquest_base_url")) or (self.defaults and self.defaults.base_url) or DEFAULT_BASE_URL
  if base == "" then base = DEFAULT_BASE_URL end

  local normalize = http and http.normalize_url or function(b,e)
    if b:sub(-1) == "/" then b = b:sub(1,-2) end
    if e:sub(1,1) ~= "/" then e = "/"..e end
    return b..e
  end

  return {
    active_questions = normalize(base, ENDPOINT_ACTIVE_QUESTIONS),
    progress_for_course = function(course_id)
      return normalize(base, "/api/courses/" .. course_id .. "/progress")
    end,
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
    if not (res and res.succeeded and res.code == 200) then
      cb(false, "HTTP " .. tostring(res and res.code or "fail"), nil)
      return
    end

    if res.data and res.data ~= "" then
      local ok, parsed = pcall(minetest.parse_json, res.data)
      if ok then
        cb(true, nil, parsed)
        return
      end
      cb(false, "JSON parse error", nil)
      return
    end

    cb(true, nil, nil)
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
  self._question_items = nil
  self._courses = nil
  self._last_fetch_time = 0
  self._refresher_started = false
  self._storage = nil
  self._current_course_id_mem = nil

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
  if (not self._cache_json) or expired or (type(self._question_items) ~= "table") then
    self:_refresh_async()
  end
  return self._cache_json
end

function CourseService:get_question_items() return self._question_items end
function CourseService:get_courses() return self._courses end

function CourseService:clear_cache()
  self._cache_json = nil
  self._question_items = nil
  self._courses = nil
  self._last_fetch_time = 0
end

function CourseService:get_attempt_counter(course_id)
  course_id = safe_str(course_id)
  if course_id == "" then
    return 0
  end

  local storage = self._storage
  if not storage then
    storage = minetest.get_mod_storage()
    self._storage = storage
  end

  local key = "eduquest.course_attempt_counter." .. course_id
  if storage then
    local n = tonumber(storage:get_string(key) or "") or 0
    return math.max(0, math.floor(n))
  end

  self._attempt_counter_mem = self._attempt_counter_mem or {}
  local n = tonumber(self._attempt_counter_mem[course_id] or 0) or 0
  return math.max(0, math.floor(n))
end

function CourseService:increment_attempt_counter(course_id)
  course_id = safe_str(course_id)
  if course_id == "" then
    return 0
  end

  local current = self:get_attempt_counter(course_id)
  local next_val = current + 1

  local storage = self._storage
  if not storage then
    storage = minetest.get_mod_storage()
    self._storage = storage
  end

  local key = "eduquest.course_attempt_counter." .. course_id
  if storage then
    storage:set_string(key, tostring(next_val))
    quizlog(("attemptCounter courseId=%s next=%d"):format(course_id, next_val))
    return next_val
  end

  self._attempt_counter_mem = self._attempt_counter_mem or {}
  self._attempt_counter_mem[course_id] = next_val
  quizlog(("attemptCounter(mem) courseId=%s next=%d"):format(course_id, next_val))
  return next_val
end

function CourseService:get_current_course_id()
  local storage = self._storage
  if not storage then
    storage = minetest.get_mod_storage()
    self._storage = storage
  end

  if storage then
    return storage:get_string("eduquest.current_course_id") or ""
  end

  return self._current_course_id_mem or ""
end

function CourseService:set_current_course_id(course_id)
  course_id = safe_str(course_id)
  local storage = self._storage
  if not storage then
    storage = minetest.get_mod_storage()
    self._storage = storage
  end

  if storage then
    storage:set_string("eduquest.current_course_id", course_id)
  else
    self._current_course_id_mem = course_id
  end

  if course_id ~= "" then
    quizlog("currentCourseId=" .. course_id)
  end
end

local function item_is_answered(item, answered_keys)
  if not item then return false end
  if item.selectedAnswer ~= nil and safe_str(item.selectedAnswer) ~= "" then
    return true
  end
  local key = make_item_key(item.courseId, item.itemId)
  return key ~= nil and answered_keys[key] == true
end

local function item_is_eligible_mc(item)
  if type(item) ~= "table" then return false end
  local q = {
    questionText = item.prompt or item.title or "",
    answers = item.answers,
    correctAnswer = item.correctAnswer,
  }
  return is_multiple_choice(q)
end

local function normalize_item_to_question(item)
  if type(item) ~= "table" then return nil end
  local course_id = safe_str(item.courseId)
  local item_id = safe_str(item.itemId)
  if course_id == "" or item_id == "" then
    return nil
  end

  local question = {
    courseId = course_id,
    itemId = item_id,
    order = item.order,
    title = item.title,
    prompt = item.prompt,
    answers = item.answers,
    correctAnswer = item.correctAnswer,
    selectedAnswer = item.selectedAnswer,

    -- legacy-shaped fields expected downstream
    questionText = item.prompt or item.title or "",
    questionHash = item_id,
    questionSetId = course_id,
  }

  if question.questionText == "" then
    question.questionText = item.title or item.prompt or "Untitled question"
  end

  if not question.questionHash or question.questionHash == "" then
    compute_hash(question)
  end

  return question
end

local function build_course_index(question_items, courses)
  local present = {}
  local updated_at_by_id = {}

  if type(courses) == "table" then
    for _, c in ipairs(courses) do
      if type(c) == "table" then
        local id = safe_str(c.id)
        if id ~= "" then
          present[id] = true
          updated_at_by_id[id] = safe_str(c.updatedAt)
        end
      end
    end
  end

  if type(question_items) == "table" then
    for _, item in ipairs(question_items) do
      if type(item) == "table" then
        local course_id = safe_str(item.courseId)
        if course_id ~= "" then
          present[course_id] = true
        end
      end
    end
  end

  return present, updated_at_by_id
end

local function pick_best_course_id(question_items, answered_keys, updated_at_by_id, prefer_existing)
  local counts = {}
  local total_courses = {}

  for _, item in ipairs(question_items or {}) do
    if type(item) == "table" then
      local course_id = safe_str(item.courseId)
      if course_id ~= "" then
        total_courses[course_id] = true
        if item_is_eligible_mc(item) and not item_is_answered(item, answered_keys) then
          counts[course_id] = (counts[course_id] or 0) + 1
        end
      end
    end
  end

  local function course_sort(a, b)
    local ca = counts[a] or 0
    local cb = counts[b] or 0
    if ca ~= cb then
      return ca > cb
    end
    local ua = safe_str(updated_at_by_id[a])
    local ub = safe_str(updated_at_by_id[b])
    if ua ~= ub and (ua ~= "" or ub ~= "") then
      return ua > ub
    end
    return a < b
  end

  local courses = {}
  for cid, _ in pairs(total_courses) do
    courses[#courses + 1] = cid
  end
  table.sort(courses, course_sort)

  if prefer_existing and prefer_existing ~= "" then
    local existing_count = counts[prefer_existing] or 0
    if existing_count > 0 then
      return prefer_existing, counts
    end
  end

  for _, cid in ipairs(courses) do
    if (counts[cid] or 0) > 0 then
      return cid, counts
    end
  end

  return "", counts
end

function CourseService:remaining_unseen_count(course_id, assume_answered_item_id)
  course_id = safe_str(course_id)
  if course_id == "" then
    return 0
  end

  local items = self._question_items
  if type(items) ~= "table" or #items == 0 then
    return 0
  end

  local storage = self._storage
  if not storage then
    storage = minetest.get_mod_storage()
    self._storage = storage
  end
  local answered_keys = load_answered_keys_from_storage(storage)

  local assumed_key = nil
  if assume_answered_item_id and assume_answered_item_id ~= "" then
    assumed_key = make_item_key(course_id, assume_answered_item_id)
    if assumed_key then
      answered_keys[assumed_key] = true
    end
  end

  local count = 0
  for _, item in ipairs(items) do
    if type(item) == "table" and safe_str(item.courseId) == course_id then
      if item_is_eligible_mc(item) and not item_is_answered(item, answered_keys) then
        count = count + 1
      end
    end
  end

  return count
end

function CourseService:is_course_complete_after(course_id, item_id)
  return self:remaining_unseen_count(course_id, item_id) == 0
end

function CourseService:mark_answered_in_cache(course_id, item_id, selected_answer)
  course_id = safe_str(course_id)
  item_id = safe_str(item_id)
  if course_id == "" or item_id == "" then
    return false
  end

  local items = self._question_items
  if type(items) ~= "table" then
    return false
  end

  selected_answer = safe_str(selected_answer)
  for _, item in ipairs(items) do
    if type(item) == "table" and safe_str(item.courseId) == course_id and safe_str(item.itemId) == item_id then
      item.selectedAnswer = selected_answer ~= "" and selected_answer or item.selectedAnswer
      quizlog(("cacheMarkAnswered courseId=%s itemId=%s selectedAnswer=%s"):format(course_id, item_id, selected_answer ~= "" and selected_answer or "<empty>"))
      return true
    end
  end

  return false
end

-- Pick a random unseen multiple-choice question (returns question or nil, reason)
function CourseService:get_question()
  self:get_user_courses()

  local items = self._question_items
  if type(items) ~= "table" or #items == 0 then
    return nil, "loading_or_empty"
  end

  quizlog(("activeQuestions items=%d courses=%d"):format(#items, type(self._courses) == "table" and #self._courses or 0))

  local storage = self._storage
  if not storage then
    storage = minetest.get_mod_storage()
    self._storage = storage
  end
  local answered_keys = load_answered_keys_from_storage(storage)

  local present, updated_at_by_id = build_course_index(items, self._courses)

  local saved = self:get_current_course_id()
  local current_course_id = ""
  if saved ~= "" and present[saved] == true then
    current_course_id = saved
  end

  local best, _counts = pick_best_course_id(items, answered_keys, updated_at_by_id, current_course_id)
  if best == "" then
    quizlog("no eligible unseen items across courses")
    return nil, "no_unseen_mc"
  end
  current_course_id = best
  self:set_current_course_id(current_course_id)

  local candidates = {}
  for _, item in ipairs(items) do
    if type(item) == "table" and safe_str(item.courseId) == current_course_id then
      if item_is_eligible_mc(item) and not item_is_answered(item, answered_keys) then
        candidates[#candidates + 1] = item
      end
    end
  end

  if #candidates == 0 then
    quizlog(("courseExhausted courseId=%s"):format(current_course_id))
    return nil, "no_unseen_mc"
  end

  local idx = math.random(1, #candidates)
  local selected_item = candidates[idx]
  local normalized = normalize_item_to_question(selected_item)
  if not (normalized and normalized.questionText and normalized.correctAnswer) then
    quizlog(("invalidQuestion courseId=%s itemId=%s"):format(current_course_id, safe_str(selected_item and selected_item.itemId)))
    return nil, "invalid_question"
  end

  log(self, ("🎲 Selected MC question course=%s item=%s"):format(current_course_id, normalized.questionHash))
  quizlog(("selected courseId=%s itemId=%s order=%s"):format(current_course_id, safe_str(normalized.questionHash), safe_str(normalized.order)))
  return normalized
end

-- Save progress to server (async). cb(ok:boolean, err?:string, json?:table)
function CourseService:save_progress(course_id, payload, cb)
  cb = cb or function() end
  course_id = safe_str(course_id)
  if course_id == "" then
    cb(false, "missing_course_id")
    return
  end

  resolve_token(self, function(token)
    if not token or token == "" then cb(false, "no_token"); return end

    local headers = {
      "Content-Type: application/json",
      "Authorization: Bearer " .. token
    }

    local ok, json = pcall(minetest.write_json, payload)
    if not ok then cb(false, "json_encode_error"); return end

    local url = self._cfg.urls.progress_for_course(course_id)
    quizlog(("POST progress courseId=%s url=%s itemId=%s currentIndex=%s completed=%s"):format(
      course_id,
      url,
      safe_str(payload and payload.itemId),
      safe_str(payload and payload.currentIndex),
      tostring(payload and payload.completed)
    ))
    post_json(self, url, headers, json, function(ok2, e2, parsed)
      if not ok2 then
        err("Failed to save progress: " .. tostring(e2))
        quizlog(("progressError courseId=%s itemId=%s err=%s"):format(course_id, safe_str(payload and payload.itemId), tostring(e2)))
        cb(false, e2, parsed)
        return
      end

      if parsed and parsed.success == false then
        quizlog(("progressApiError courseId=%s itemId=%s message=%s"):format(course_id, safe_str(payload and payload.itemId), safe_str(parsed.message)))
        cb(false, parsed.message or "api_error", parsed)
        return
      end

      log(self, "✅ Progress saved successfully.")
      quizlog(("progressOK courseId=%s itemId=%s"):format(course_id, safe_str(payload and payload.itemId)))
      cb(true, nil, parsed)
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


    --- local url = "http://10.0.2.2:8888/api/v2/questions/active"
    local url  = self._cfg.urls.active_questions

    self:clear_cache()
    log(self, "🔄 Fetching active questions...")
    quizlog(("GET activeQuestions url=%s"):format(url))
    local headers = {
      "Accept: application/json",
      "Authorization: Bearer " .. token
    }


    get_json_with_retry(self, url, headers, function(json, e)
      if not json then
        err("Fetch failed: "..tostring(e))
        quizlog(("activeQuestionsError err=%s"):format(tostring(e)))
        return
      end

      local data = (json and json.data) or {}
      local items = data.questionItems or {}
      local courses = data.courses or {}
      if type(items) ~= "table" then items = {} end
      if type(courses) ~= "table" then courses = {} end

      self._cache_json      = json
      self._question_items  = items
      self._courses         = courses
      self._last_fetch_time = now_sec()
      log(self, ("✅ Active questions loaded (%d items, %d courses)."):format(#items, #courses))
      quizlog(("activeQuestionsOK items=%d courses=%d"):format(#items, #courses))
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
