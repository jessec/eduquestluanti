local M = {}

--- Register the quiz callbacks and wire HTTP integration.
---@param container table
---@param opts table|nil  -- opts.trigger_control: "sneak" | "aux1" (default "sneak")
function M.register(container, opts)
  opts = opts or {}
  local FORMNAME = opts.formname or "welcome:quiz"
  local TRIGGER  = (opts.trigger_control == "aux1") and "aux1" or "sneak" -- default: Shift
  local STATUS_FORMNAME = "eduquest:quiz_status"

  local fallback_questions = opts.questions or {
    {
      text = "Which tool digs stone fastest?",
      answers = {
        { label = "Wooden shovel", correct = false },
        { label = "Stone pickaxe", correct = true },
        { label = "Steel axe",     correct = false },
      },
    },
    {
      text = "Which ore smelts into steel?",
      answers = {
        { label = "Tin lump",    correct = false },
        { label = "Copper lump", correct = false },
        { label = "Iron lump",   correct = true },
      },
    },
    {
      text = "How do you open the inventory?",
      answers = {
        { label = "Press E",  correct = true },
        { label = "Press Q",  correct = false },
        { label = "Press F5", correct = false },
      },
    },
  }

  local player_state     = {}  -- per-player quiz state (slideshow module also uses this)
  local player_questions = {}  -- per-player dynamic question banks
  local last_ctrl        = {}  -- per-player last control snapshot for rising-edge detection
  local status_state     = {}  -- per-player status formspec state

  local http   = container:resolve("http")
  local forms  = container:resolve("forms")
  local course_service = container:resolve("course_service")
  local settings_api = container:resolve("settings_api")
  local http_api = container:resolve("http_api")
  local session_key_ui = container:resolve("session_key_ui")
  local storage = nil

  local function quizlog(msg)
    minetest.log("action", "[eduquest_quiz] " .. msg)
  end

  local function get_storage()
    if storage then return storage end
    local obtained = minetest.get_mod_storage()
    if not obtained then
      storage = {
        get_string = function() return "" end,
        set_string = function() end,
      }
      minetest.log("warning", "[eduquest] Mod storage unavailable; using in-memory placeholders.")
      return storage
    end
    storage = obtained
    return storage
  end

  local utf8lib = rawget(_G, "utf8")

  local function strip_abc_prefix(text)
    if type(text) ~= "string" then return "" end
    return text:gsub("^%s*[A-Za-z][%.)%s]+", "", 1)
  end

  local function is_thai_str(text)
    if type(text) ~= "string" then return false end
    if not utf8lib or not utf8lib.codes then return false end
    for _, codepoint in utf8lib.codes(text) do
      if codepoint >= 0x0E00 and codepoint <= 0x0E7F then
        return true
      end
    end
    return false
  end

  local function clean_thai_punctuation(text)
    if type(text) ~= "string" then return "" end
    if not utf8lib or not utf8lib.codes or not utf8lib.char then
      return text
    end
    if not is_thai_str(text) then
      return text
    end

    local allowed = {}
    for _, codepoint in utf8lib.codes(text) do
      local keep = (codepoint >= 0x0E00 and codepoint <= 0x0E7F)
        or (codepoint >= 0x30 and codepoint <= 0x39)
        or codepoint == 0x20
      if keep then
        allowed[#allowed + 1] = utf8lib.char(codepoint)
      end
    end

    local cleaned = table.concat(allowed)
    cleaned = cleaned:gsub("^%s+", "")
    cleaned = cleaned:gsub("%s+$", "")
    return cleaned
  end

  local function normalize_answer_text(text)
    local stripped = strip_abc_prefix(text or "")
    local cleaned = clean_thai_punctuation(stripped)
    if cleaned == "" then
      cleaned = stripped
    end
    if cleaned == "" and type(text) == "string" then
      cleaned = text
    end
    return cleaned
  end

  local function normalize_question_text(text)
    local cleaned = clean_thai_punctuation(text or "")
    if cleaned == "" and type(text) == "string" then
      cleaned = text
    end
    return (cleaned or ""):gsub("^%s+", ""):gsub("%s+$", "")
  end

  if course_service and course_service.get_user_courses then
    course_service:get_user_courses() -- prime async fetch in the background
  end

local function now_ms()
  if minetest.get_us_time then
    local ok, us = pcall(minetest.get_us_time)
    if ok and type(us) == "number" then
      return math.floor(us / 1000 + 0.5)
    end
  end
  return os.time() * 1000
end

-- When putting into a string field (formspec/HTTP params), force an integer string:
local function as_int_string(n)
  return string.format("%d", math.floor(tonumber(n) or 0))
end

  local function build_quiz_status_formspec(title, message_lines, opts2)
    opts2 = opts2 or {}

    local title_text = minetest.formspec_escape(title or "EduQuest Quiz")
    local msg = minetest.formspec_escape(table.concat(message_lines or {}, "\n"))

    local parts = {
      "formspec_version[6]size[9,4.6]",
      "bgcolor[#121212;true]",
      "style_type[label;textcolor=#f5f5f5]",
      "style_type[textarea;textcolor=#f5f5f5]",
      "style_type[button;textcolor=#f5f5f5;bgcolor=#2a2a2a;border=true;bordercolor=#444444]",
      ("label[0.4,0.4;%s]"):format(title_text),
      ("textarea[0.4,0.9;8.2,2.9;msg;;%s]"):format(msg),
      "button[5.6,3.95;3,0.8;retry;Retry]",
      "button_exit[0.4,3.95;3,0.8;close;Close]",
    }

    if opts2.hide_retry then
      parts[#parts] = nil
      parts[#parts] = nil
      parts[#parts + 1] = "button_exit[3.2,3.95;3,0.8;close;OK]"
    end

    return table.concat(parts, "")
  end

  local function build_health_lines(reason)
    local lines = {}

    local secure_http_mods = settings_api and settings_api:get("secure.http_mods") or ""
    if not http_api then
      lines[#lines + 1] = "HTTP is disabled."
      lines[#lines + 1] = "Fix: set secure.http_mods = eduquest and restart."
    else
      lines[#lines + 1] = "HTTP is enabled."
      lines[#lines + 1] = ("secure.http_mods = %s"):format(secure_http_mods ~= "" and secure_http_mods or "<unset>")
    end

    local base_url = settings_api and settings_api:get("eduquest_base_url") or ""
    lines[#lines + 1] = ("Base URL: %s"):format(base_url ~= "" and base_url or "(default) https://server.eduquest.vip")
    if base_url:match("^http://127%.0%.0%.1") then
      lines[#lines + 1] = "Android emulator tip: use http://10.0.2.2:<port> for host localhost."
    end

    local token = settings_api and settings_api:get("eduquest_token") or ""
    local session_key = settings_api and settings_api:get("eduquest_session_key") or ""
    if token ~= "" then
      lines[#lines + 1] = "Auth: eduquest_token is set."
    elseif session_key ~= "" then
      lines[#lines + 1] = "Auth: eduquest_session_key is set."
    else
      if reason == "auth_missing" then
        lines[#lines + 1] = "Sign-in required: please enter your EduQuest session key."
      else
        lines[#lines + 1] = "Auth missing: set eduquest_token or eduquest_session_key."
      end
    end

    if reason == "no_unseen_mc" then
      lines[#lines + 1] = "No playable unanswered questions were found."
      lines[#lines + 1] = "You may have completed them already, or the question data is invalid."
    elseif reason == "invalid_question" then
      lines[#lines + 1] = "Questions were received but are not playable (answers/correctAnswer mismatch)."
    end

    return lines
  end

  local function auth_is_configured()
    local token = settings_api and settings_api:get("eduquest_token") or ""
    local session_key = settings_api and settings_api:get("eduquest_session_key") or ""
    return token ~= "" or session_key ~= ""
  end

  local auth_prompt_open = {}
  local try_open_quiz
  local show_status

  local function prompt_for_session_key(player_name, source)
    if auth_prompt_open[player_name] then
      return
    end
    auth_prompt_open[player_name] = true

    if not session_key_ui or not session_key_ui.request_key then
      auth_prompt_open[player_name] = nil
      show_status(player_name, "setup", "auth_missing")
      return
    end

    quizlog(("requestSessionKey source=%s player=%s"):format(tostring(source or "unknown"), player_name))
    session_key_ui.request_key(container, player_name, {
      on_success = function()
        auth_prompt_open[player_name] = nil
        if course_service and course_service.clear_cache then
          course_service:clear_cache()
        end
        if course_service and course_service.get_user_courses then
          course_service:get_user_courses()
        end
        minetest.after(0, function()
          try_open_quiz(player_name, "session_key_saved")
        end)
      end,
      on_cancel = function()
        auth_prompt_open[player_name] = nil
        show_status(player_name, "setup", "auth_missing")
      end,
    })
  end

  show_status = function(player_name, mode, reason)
    status_state[player_name] = {
      mode = mode,
      reason = reason,
      shown_at_ms = now_ms(),
    }

    local title
    local lines = {}

    if mode == "wait" then
      title = "Loading EduQuest questions…"
      lines[#lines + 1] = "Please wait a moment and try again."
      lines[#lines + 1] = ""
      for _, l in ipairs(build_health_lines(reason)) do lines[#lines + 1] = l end
      minetest.show_formspec(player_name, STATUS_FORMNAME, build_quiz_status_formspec(title, lines))

      local opened_at = status_state[player_name].shown_at_ms
      minetest.after(4, function()
        local st = status_state[player_name]
        if st and st.shown_at_ms == opened_at and st.mode == "wait" then
          minetest.close_formspec(player_name, STATUS_FORMNAME)
        end
      end)
      return
    end

    title = "EduQuest quiz not available"
    lines[#lines + 1] = "No EduQuest questions are available right now."
    lines[#lines + 1] = ""
    for _, l in ipairs(build_health_lines(reason)) do lines[#lines + 1] = l end
    minetest.show_formspec(player_name, STATUS_FORMNAME, build_quiz_status_formspec(title, lines))
  end

  local function trim_lower(s)
    if type(s) ~= "string" then return "" end
    return s:gsub("^%s+", ""):gsub("%s+$", ""):lower()
  end

  local function clone_fallback_question()
    if not fallback_questions or #fallback_questions == 0 then
      return nil
    end

    local src = fallback_questions[math.random(#fallback_questions)]
    local copy = { text = src.text, answers = {} }
    for _, ans in ipairs(src.answers or {}) do
      copy.answers[#copy.answers + 1] = { label = ans.label, correct = ans.correct }
    end
    return copy
  end

  local function adapt_course_question(raw, player_name)
    if type(raw) ~= "table" then return nil end

    local answers = {}
    local normalized_correct = normalize_answer_text(raw.correctAnswer or "")
    local correct_norm = trim_lower(normalized_correct ~= "" and normalized_correct or (raw.correctAnswer or ""))
    local choices = raw.answers or {}
    local matched = false

    for _, choice in ipairs(choices) do
      local raw_label
      local choice_table = nil

      if type(choice) == "table" then
        choice_table = choice
        raw_label = choice.label or choice.text or choice.answer or choice.value or choice.name or choice.title
        if raw_label == nil and type(choice_table.get_label) == "function" then
          local ok, value = pcall(choice_table.get_label, choice_table)
          if ok then raw_label = value end
        end
        if type(raw_label) ~= "string" then
          raw_label = tostring(raw_label or "")
        end
      else
        raw_label = tostring(choice or "")
      end

      raw_label = raw_label or ""
      if raw_label ~= "" then
        local normalized_label = normalize_answer_text(raw_label)
        local compare_value = trim_lower(normalized_label ~= "" and normalized_label or raw_label)
        local is_correct = (compare_value == correct_norm)
        if not is_correct and choice_table and choice_table.correct ~= nil then
          is_correct = choice_table.correct == true
        end
        if is_correct then matched = true end
        local display = normalized_label ~= "" and normalized_label or raw_label
        answers[#answers + 1] = {
          label = display,
          correct = is_correct,
          _raw = raw_label,
        }
      end
    end

    if #answers == 0 or not matched then
      minetest.log("warning", "[eduquest] Received malformed course question; using fallback")
      if player_name then
        minetest.chat_send_player(player_name, "Question data incomplete, loading fallback question.")
      end
      return nil
    end

    local question_text = normalize_question_text(raw.questionText or "")
    if question_text == "" then
      question_text = raw.questionText or "Untitled question"
    end

    return {
      text = question_text,
      answers = answers,
      _course_hash = raw.questionHash,
      _course_question = raw,
      questionSetId = raw.questionSetId or raw.question_set_id or raw.setId or raw.set_id,
      owner = raw.owner or raw.ownerId or raw.owner_id,
      reward = raw.reward,
    }
  end

  local function fetch_question_for_player(name)
    if not auth_is_configured() then
      prompt_for_session_key(name, "fetch_question")
      return nil, "auth_missing"
    end

    if course_service and course_service.get_question then
      local raw, reason = course_service:get_question()
      if raw then
        quizlog(("fetchedQuestion courseId=%s itemId=%s"):format(tostring(raw.questionSetId or raw.courseId or ""), tostring(raw.questionHash or raw.itemId or "")))
        local adapted = adapt_course_question(raw, name)
        if adapted then
          return adapted
        end
        show_status(name, "setup", "invalid_question")
        return nil, "invalid_question"
      else
        quizlog(("noQuestion reason=%s"):format(tostring(reason)))
        if reason == "loading_or_empty" or reason == "storage_unavailable" then
          show_status(name, "wait", reason)
          return nil, reason
        end
        show_status(name, "setup", reason or "no_unseen_mc")
        return nil, reason or "no_unseen_mc"
      end
    end

    show_status(name, "setup", "no_course_service")
    return nil, "no_course_service"
  end

  local function resolve_student_id(player_name)
    if settings_api and settings_api.get then
      local configured = settings_api:get("eduquest_student_id")
      if configured and configured ~= "" then
        return configured
      end
    end
    return player_name
  end

  local mark_question_answered

  local function make_item_key(course_id, item_id)
    if not course_id or course_id == "" or not item_id or item_id == "" then
      return nil
    end
    return course_id .. ":" .. item_id
  end

  local function build_progress_payload(player_name, question, selected_idx, state)
    if not question or not question._course_question then
      return nil
    end

    local raw_question = question._course_question
    local course_id = question.questionSetId or raw_question.courseId or raw_question.questionSetId
    local item_id = raw_question.itemId or raw_question.questionHash or question._course_hash
    if not course_id or course_id == "" or not item_id or item_id == "" then
      return nil
    end

    local answers = question.answers or {}
    local selected = answers[selected_idx]
    if not selected then
      return nil
    end

    local selected_answer = selected._raw or selected.label or ""
    if selected_answer == "" then
      return nil
    end

    local current_index = 0
    if course_service and course_service.get_attempt_counter then
      current_index = course_service:get_attempt_counter(course_id)
    end

    local completed = false
    if course_service and course_service.is_course_complete_after then
      completed = course_service:is_course_complete_after(course_id, item_id) == true
    end

    local payload = {
      itemId = item_id,
      currentIndex = current_index,
      selectedAnswer = selected_answer,
      completed = completed,
    }

    quizlog(("payload courseId=%s itemId=%s currentIndex=%s completed=%s selectedAnswer=%s"):format(
      tostring(course_id),
      tostring(item_id),
      tostring(current_index),
      tostring(completed),
      tostring(selected_answer)
    ))

    return payload
  end

  local function save_course_attempt(player_name, question, state)
    if not (course_service and course_service.save_progress) then
      return
    end

    if not question or not question._course_question then
      return
    end

    if state and state._last_saved_index and state._last_saved_index == state.index then
      return
    end

    local selected_idx = (state and state.a_idx) or 1
    local payload = build_progress_payload(player_name, question, selected_idx, state)
    if not payload then
      return
    end

    if state then
      state._last_saved_index = state.index
    end

    local raw_question = question._course_question
    local course_id = question.questionSetId or raw_question.courseId or raw_question.questionSetId
    quizlog(("submit courseId=%s itemId=%s"):format(tostring(course_id), tostring(payload.itemId)))
    course_service:save_progress(course_id, payload, function(ok, err_msg, json)
      if not ok then
        if err_msg then
          minetest.log("warning", string.format("[eduquest] Failed to save progress for %s: %s", player_name, tostring(err_msg)))
        end
        quizlog(("saveFailed courseId=%s itemId=%s err=%s"):format(tostring(course_id), tostring(payload.itemId), tostring(err_msg)))
        if state then
          state._last_saved_index = nil
        end
        return
      end

      quizlog(("saveOK courseId=%s itemId=%s"):format(tostring(course_id), tostring(payload.itemId)))

      local item_id = payload.itemId
      local answered_key = make_item_key(course_id, item_id)
      if answered_key then
        mark_question_answered(answered_key)
      end

      if course_service and course_service.increment_attempt_counter then
        course_service:increment_attempt_counter(course_id)
      end

      if course_service and course_service.mark_answered_in_cache then
        course_service:mark_answered_in_cache(course_id, item_id, payload.selectedAnswer)
      end
    end)
  end

  local function create_initial_state()
    return {
      index = 1,
      correct = 0,
      a_idx = 1,
      checked = false,
      reveal = false,
      _active = true,
      question_started_at_ms = now_ms(),
      _last_saved_index = nil,
    }
  end

  local function ensure_question_bank(name, opts)
    local bank = player_questions[name]
    if not bank then
      bank = {}
      player_questions[name] = bank
    end

    local target_index = (opts and opts.target_index) or 1
    while #bank < target_index do
      local q, reason = fetch_question_for_player(name)
      if not q then
        return nil, reason
      end
      bank[#bank + 1] = q
    end

    return bank
  end

  try_open_quiz = function(name, source)
    if not auth_is_configured() then
      prompt_for_session_key(name, source)
      return false
    end

    local player = minetest.get_player_by_name(name)
    if not player then
      return false
    end

    local bank = ensure_question_bank(name)
    if not bank or #bank == 0 then
      return false
    end

    player_state[name] = create_initial_state()
    minetest.close_formspec(name, STATUS_FORMNAME)
    forms.show_question(player, player_state, bank, FORMNAME, forms)
    quizlog(("openQuiz source=%s player=%s"):format(tostring(source or "unknown"), name))
    http.call_api(container, { player_name = name })
    return true
  end

  mark_question_answered = function(key)
    if not key or key == "" then return end

    local store = get_storage()
    if not store then return end

    local raw = store:get_string("questions_done")
    local arr = {}
    if raw and raw ~= "" then
      local ok, parsed = pcall(minetest.parse_json, raw)
      if ok and type(parsed) == "table" then
        arr = parsed
      end
      for _, existing in ipairs(arr) do
        if existing == key then
          return
        end
      end
    end

    arr[#arr + 1] = key
    local ok, encoded = pcall(minetest.write_json, arr)
    if ok and encoded then
      store:set_string("questions_done", encoded)
    end

    quizlog(("markAnswered key=%s"):format(tostring(key)))
  end

  -- -----Test------------------------------------------------------------------
  local svc   = container:resolve("svc")
  local User  = container:resolve("User")
  minetest.log("action", svc:greet(7))
  ---@type User
  local u = User.new(7, "Nok")
  minetest.log("action", tostring(u))
  minetest.log("action", u:greet())
  -- -----Test------------------------------------------------------------------






  -- Clean up tracking when players leave
  minetest.register_on_leaveplayer(function(player)
    local name = player:get_player_name()
    player_state[name] = nil
    player_questions[name] = nil
    last_ctrl[name]    = nil
  end)

  -- Optional: also provide a manual command to open the quiz
  minetest.register_chatcommand("quiz", {
    description = "Open the welcome quiz",
    func = function(name)
      if try_open_quiz(name, "chatcommand") then
        return true, "Quiz opened."
      end
      if not auth_is_configured() then
        return true, "Enter your session key to start."
      end
      return false, "EduQuest quiz not available right now."
    end
  })

  -- Start quiz when the chosen control is PRESSED (rising edge)
  -- NOTE: Minetest does not distinguish left vs right Shift; "sneak" is any Shift.
  local accum = 0
  minetest.register_globalstep(function(dtime)
    accum = accum + dtime
    if accum < 0.10 then return end  -- poll ~10x per second
    accum = 0

    for _, player in ipairs(minetest.get_connected_players()) do
      local name = player:get_player_name()
      local ctrl = player:get_player_control() or {}
      local last = last_ctrl[name] or {}

      local now_pressed  = not not ctrl[TRIGGER]
      local was_pressed  = not not last[TRIGGER]
      local rising_edge  = (now_pressed and not was_pressed)

      -- Store snapshot for next tick
      last_ctrl[name] = { [TRIGGER] = now_pressed }

      -- Only open the quiz on rising edge, and only if not already active
      if rising_edge then
        -- if there is an active formspec with our formname, don't reopen
        local st = player_state[name]
        if not st or not st._active then
          try_open_quiz(name, "trigger_" .. TRIGGER)
        end
      end
    end
  end)

  minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= STATUS_FORMNAME then return end
    if not player then return end

    local name = player:get_player_name()
    if fields.quit or fields.close then
      status_state[name] = nil
      return
    end

    if fields.retry then
      if course_service and course_service.clear_cache then
        course_service:clear_cache()
        if course_service.get_user_courses then
          course_service:get_user_courses()
        end
      end

      try_open_quiz(name, "status_retry")
    end
  end)

  -- Delegate button handling to slideshow handler (prev/submit/next/skip)
  minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= FORMNAME then return end

    local name  = player:get_player_name()
    local state = player_state[name]
    if not state then return end

    -- Closed without pressing Skip => drop state
    if fields.quit and not fields.skip then
      player_state[name] = nil
      player_questions[name] = nil
      return
    end

    -- If user hit Skip, clear state right away
    if fields.skip then
      player_state[name] = nil
      player_questions[name] = nil
      return
    end

    local bank_current = ensure_question_bank(name)
    local current_question = bank_current and bank_current[state.index]

    if fields.submit and current_question then
      save_course_attempt(name, current_question, state)
    end

    local target_index = (state.index or 1)
    if fields.next then
      if current_question and current_question._course_hash and current_question.questionSetId then
        local answered_key = make_item_key(current_question.questionSetId, current_question._course_hash)
        if answered_key then
          mark_question_answered(answered_key)
        end
      end
      target_index = target_index + 1
    end

    local bank = ensure_question_bank(name, { target_index = target_index })
    if not bank or #bank == 0 then
      minetest.close_formspec(name, FORMNAME)
      player_state[name] = nil
      player_questions[name] = nil
      minetest.chat_send_player(name, "Quiz unavailable right now. Please try again later.")
      return
    end

    -- Let the slideshow form handle prev/submit/next and re-render
    if forms.handle_fields(name, fields, player_state, bank, FORMNAME) then
      -- If slideshow advanced beyond last question, it closed the form.
      -- We can detect completion and clear the active flag/state.
      local st = player_state[name]
      local current_bank = player_questions[name] or bank
      if st and st.index > #(current_bank or {}) then
        player_state[name] = nil
        player_questions[name] = nil
      end
      return
    end
  end)
end

return M
