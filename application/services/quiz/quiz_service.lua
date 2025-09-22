local M = {}

--- Register the quiz callbacks and wire HTTP integration.
---@param container table
---@param opts table|nil  -- opts.trigger_control: "sneak" | "aux1" (default "sneak")
function M.register(container, opts)
  opts = opts or {}
  local FORMNAME = opts.formname or "welcome:quiz"
  local TRIGGER  = (opts.trigger_control == "aux1") and "aux1" or "sneak" -- default: Shift

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

  local http   = container:resolve("http")
  local forms  = container:resolve("forms")
  local course_service = container:resolve("course_service")
  local settings_api = container:resolve("settings_api")
  local storage = nil

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
    if course_service and course_service.get_question then
      local raw, reason = course_service:get_question()
      if raw then
        local adapted = adapt_course_question(raw, name)
        if adapted then
          return adapted
        end
      else
        local msg
        if reason == "loading_or_empty" then
          msg = "Questions are still loading. Please try again in a moment."
        elseif reason == "no_unseen_mc" then
          msg = "You've answered all available questions for now."
        elseif reason == "invalid_question" then
          msg = "This question couldn't be loaded; trying a fallback."
        elseif reason == "storage_unavailable" then
          ---msg = "Unable to access quiz storage yet; using fallback questions."
          msg = "Questions are still loading. Please try again in a moment."
        end
        if msg then
          --minetest.chat_send_player(name, msg)
        end
      end
    end

    return clone_fallback_question()
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

  local function build_save_payload(player_name, question, selected_idx, state)
    if not question or not question._course_question then
      return nil
    end

    local raw_question = question._course_question
    local hash = question.questionHash or raw_question.questionHash
    if not hash or hash == "" then
      return nil
    end

    local answers = question.answers or {}
    local selected = answers[selected_idx]
    if not selected then
      return nil
    end

    local student_answer = selected._raw or selected.label or ""
    if student_answer == "" then
      return nil
    end

    local correct_answer = raw_question.correctAnswer or ""
    if correct_answer == "" then
      for _, candidate in ipairs(answers) do
        if candidate.correct and candidate._raw and candidate._raw ~= "" then
          correct_answer = candidate._raw
          break
        end
      end
    end

    local current_ms = now_ms()
    local started_ms = state and state.question_started_at_ms or current_ms
    if type(started_ms) ~= "number" then
      started_ms = current_ms
    end
    local elapsed_ms = math.max(0, current_ms - started_ms)

    minetest.log("warning", string.format("[eduquest] Failed to save question for %s: %s", question.questionSetId, hash))
    -- question set id is not correct
    local payload = {
      questionSetId = question.questionSetId,
      studentId = resolve_student_id(player_name),
      hash = hash,
      owner = "student",
      question = raw_question.questionText or question.text,
      correctAnswer = correct_answer,
      studentAnswer = student_answer,
      grade = selected.correct and 100 or 0,
      feedback = selected.correct and "Correct" or "Incorrect",
      timestamp = as_int_string(now_ms()),
      time = math.floor(elapsed_ms / 1000),
      correct = selected.correct == true,
    }

    if raw_question.reward ~= nil then
      payload.reward = raw_question.reward
    elseif question.reward ~= nil then
      payload.reward = question.reward
    end

    return payload
  end

  local function save_course_attempt(player_name, question, state)
    if not (course_service and course_service.save_question) then
      return
    end

    if not question or not question._course_question then
      return
    end

    if state and state._last_saved_index and state._last_saved_index == state.index then
      return
    end

    local selected_idx = (state and state.a_idx) or 1
    local payload = build_save_payload(player_name, question, selected_idx, state)
    if not payload then
      return
    end

    if state then
      state._last_saved_index = state.index
    end

    course_service:save_question(payload, function(ok, err_msg)
      if not ok then
        if err_msg then
          minetest.log("warning", string.format("[eduquest] Failed to save question for %s: %s", player_name, tostring(err_msg)))
        end
        if state then
          state._last_saved_index = nil
        end
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
      local q = fetch_question_for_player(name)
      if not q then
        return nil
      end
      bank[#bank + 1] = q
    end

    return bank
  end

  local function mark_question_answered(hash)
    if not hash or hash == "" then return end

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
        if existing == hash then
          return
        end
      end
    end

    arr[#arr + 1] = hash
    local ok, encoded = pcall(minetest.write_json, arr)
    if ok and encoded then
      store:set_string("questions_done", encoded)
    end
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
      local player = minetest.get_player_by_name(name)
      if not player then return false, "Player not found." end

      local bank = ensure_question_bank(name)
      if not bank or #bank == 0 then
        return false, "No quiz questions are available right now."
      end
      -- (Re)start slideshow state fresh
      local st = create_initial_state()
      player_state[name] = st
      forms.show_question(player, player_state, bank, FORMNAME, forms)
      http.call_api(container, { player_name = name })
      return true, "Quiz opened."
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
          local bank = ensure_question_bank(name)
          if not bank or #bank == 0 then
            minetest.chat_send_player(name, "No quiz questions are available right now.")
          else
            player_state[name] = create_initial_state()
            forms.show_question(player, player_state, bank, FORMNAME, forms)
            http.call_api(container, { player_name = name })
          end
        end
      end
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
      if current_question and current_question._course_hash then
        mark_question_answered(current_question._course_hash)
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
