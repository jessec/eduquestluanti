-- app/forms_slideshow.lua
local M = {}

-- Per-player slideshow state:
-- state = { index=1, correct=0, a_idx=1, checked=false, reveal=false }
-- question format expected:
-- q = { text="...", answers = { {label="...", correct=true/false}, ... } }

-- ----- THEME (dark) ---------------------------------------------------------
local DARK_BG       = "#121212"   -- whole formspec background
local PANEL_BG      = "#1e1e1e"   -- card/panel behind content
local TEXT_LIGHT    = "#f5f5f5"   -- default text
local TEXT_MUTED    = "#c7c7c7"   -- secondary text (optional)
local OK_COLOR      = "#14a03d"   -- success
local ERROR_COLOR   = "#c32323"   -- error
local BTN_BG        = "#2a2a2a"
local BTN_BORDER    = "#444444"

local FONT_ALIAS
local FONT_STYLE_ATTR = ""
local FONT_FORMSPEC_PREFIX = ""
local REGISTERED_MEDIA_NAME = nil

local version = minetest.get_version() or {}
local VERSION_MAJOR = tonumber(version.major or version.MAJOR or 0) or 0
local VERSION_MINOR = tonumber(version.minor or version.MINOR or 0) or 0
local VERSION_PATCH = tonumber(version.patch or version.PATCH or 0) or 0
local SERVER_SUPPORTS_MEDIA = (VERSION_MAJOR > 5) or (VERSION_MAJOR == 5 and VERSION_MINOR >= 15)

local MOD_NAME = minetest.get_current_modname() or "eduquest"
local MOD_PATH = minetest.get_modpath(MOD_NAME)
local DEFAULT_FONT_FILENAME = "NotoSansThai-Regular.ttf"
local DEFAULT_FONT_PATH = MOD_PATH and (MOD_PATH .. "/fonts/" .. DEFAULT_FONT_FILENAME) or ""

local function resolve_font_config()
  local settings = minetest.settings
  local font_path = settings and settings:get("eduquest_forms_font_path") or ""

  if font_path == "" and DEFAULT_FONT_PATH ~= "" then
    local f = io.open(DEFAULT_FONT_PATH, "rb")
    if f then
      f:close()
      font_path = DEFAULT_FONT_PATH
    end
  end

  if font_path == "" then
    return
  end

  local f = io.open(font_path, "rb")
  if not f then
    minetest.log("warning", "[eduquest] eduquest_forms_font_path not found: " .. font_path)
    return
  end
  f:close()

  local alias = (settings and settings:get("eduquest_forms_font_alias")) or "eduquest_text"
  local size  = tonumber(settings and settings:get("eduquest_forms_font_size") or "") or 18

  FONT_ALIAS = alias
  FONT_STYLE_ATTR = "font=" .. alias

  local escaped_target
  if SERVER_SUPPORTS_MEDIA then
    local filename = font_path:match("([^/\\]+)$") or font_path
    local media_name = string.format("%s__%s", MOD_NAME, filename)

    if REGISTERED_MEDIA_NAME ~= media_name then
      local ok, err = pcall(minetest.register_media, {
        name = media_name,
        filepath = font_path,
      })
      if not ok then
        minetest.log("warning", "[eduquest] Failed to register font media: " .. tostring(err))
        return
      end
      REGISTERED_MEDIA_NAME = media_name
    end

    escaped_target = minetest.formspec_escape(media_name)
  else
    escaped_target = minetest.formspec_escape(font_path)
  end

  local font_line = ("font[%s;%s;%d]"):format(alias, escaped_target, size)

  FONT_FORMSPEC_PREFIX = table.concat({
    font_line,
    ("style_type[label;font=%s]"):format(alias),
    ("style_type[button;font=%s]"):format(alias),
    ("style_type[field;font=%s]"):format(alias),
    ("style_type[textarea;font=%s]"):format(alias),
    ("style_type[hypertext;font=%s]"):format(alias),
  }, "")

  minetest.log("action", string.format("[eduquest] Using quiz font '%s' (%s @ %d)", alias, font_path, size))
end

resolve_font_config()

local function now_ms()
  if minetest.get_us_time then
    local ok, val = pcall(minetest.get_us_time)
    if ok and type(val) == "number" then
      return math.floor(val / 1000)
    end
  end
  return os.time() * 1000
end

local function hx(s, color)
  s = minetest.formspec_escape(s or "")
  local want_color = color or TEXT_LIGHT

  if FONT_STYLE_ATTR ~= "" or want_color then
    local attrs = {}
    if FONT_STYLE_ATTR ~= "" then
      attrs[#attrs + 1] = FONT_STYLE_ATTR
    end
    if want_color then
      attrs[#attrs + 1] = "color=" .. want_color
    end
    return ("<style %s>%s</style>"):format(table.concat(attrs, " "), s)
  end

  return s
end

local function find_correct_index(q)
  for i, a in ipairs(q.answers or {}) do
    if a.correct then return i end
  end
  return nil
end

local function safe_state(player_state, name)
  local st = player_state[name]
  if not st then
    st = { index = 1, correct = 0, a_idx = 1, checked = false, reveal = false }
    player_state[name] = st
  end
  if not st.a_idx then st.a_idx = 1 end
  if st.checked == nil then st.checked = false end
  if st.reveal == nil then st.reveal = false end
  if not st.question_started_at_ms then
    st.question_started_at_ms = now_ms()
  end
  return st
end


function M.build_formspec(q, st)
  local rows = { "formspec_version[6]size[8,7]" }

  -- 1) Dark window background (second arg 'true' = fill entire window)
  rows[#rows+1] = ("bgcolor[%s;true]"):format(DARK_BG)

  -- 2) Global styles: light text for labels/hypertext, dark buttons
  -- (Keep your font styles; we add textcolor/bg/border here.)
  if FONT_FORMSPEC_PREFIX ~= "" then
    rows[#rows+1] = FONT_FORMSPEC_PREFIX
  end
  rows[#rows+1] = ("style_type[label;textcolor=%s]"):format(TEXT_LIGHT)
  rows[#rows+1] = ("style_type[hypertext;textcolor=%s]"):format(TEXT_LIGHT)
  rows[#rows+1] =
    ("style_type[button;textcolor=%s;bgcolor=%s;border=true;bordercolor=%s]"):
      format(TEXT_LIGHT, BTN_BG, BTN_BORDER)

  -- 3) Panel behind content (drawn first; later items appear on top)
  rows[#rows+1] = ("box[0.3,0.4;7.4,5.4;%s]"):format(PANEL_BG)

  -- Question text (bold, hypertext so we can style consistently)
  rows[#rows+1] = ("hypertext[0.5,0.6;7,1;question;<b>%s</b>]"):format(
    hx(q.text or "")
  )

  -- Current choice line (green if correct after submit)
  local a = (q.answers or {})[st.a_idx or 1]
  local show = a and a.label or "—"
  local correct_idx = find_correct_index(q)
  local is_correct_choice = (st.reveal and correct_idx and st.a_idx == correct_idx)
  local ans_markup = hx((show or ""), is_correct_choice and OK_COLOR or TEXT_LIGHT)
  rows[#rows+1] = ("hypertext[0.5,2.0;7,2;answer;%s]"):format(ans_markup)

  -- Feedback line
  local feedback = ""
  if st.checked then
    local is_correct = a and a.correct
    feedback = hx(is_correct and "Correct!" or "Try again!", is_correct and OK_COLOR or ERROR_COLOR)
  end
  rows[#rows+1] = ("hypertext[0.5,3.5;7,0.9;feedback;%s]"):format(feedback)

  -- Optional: per-button fine-tuning (if you want distinct accents)
  rows[#rows+1] = "style[submit;bgcolor=#2b3d2c;bordercolor=#355a36]"  -- a subtle green-ish
  rows[#rows+1] = "style[next;bgcolor=#2a2a2a;bordercolor=#444444]"
  rows[#rows+1] = "style[prev;bgcolor=#2a2a2a;bordercolor=#444444]"

  -- Controls: Prev / Submit / Next (keep layout)
  rows[#rows+1] = "button[0.5,4.6;2,0.9;prev;Prev]"
  if not st.checked then
    rows[#rows+1] = "button[3,4.6;2,0.9;submit;Submit]"
  else
    rows[#rows+1] = "button[3,4.6;2,0.9;dummy; ]"
  end
  if st.checked then
    rows[#rows+1] = "button[5.5,4.6;2,0.9;next;Next]"
  else
    --rows[#rows+1] = "button[5.5,4.6;2,0.9;dummy2; ]"
  end

  return table.concat(rows)
end


function M.show_question(player, player_state, questions, formname, forms)
  local name = player:get_player_name()
  local st = safe_state(player_state, name)

  local q = questions[st.index]
  if not q then
    minetest.close_formspec(name, formname)
    minetest.chat_send_player(name, "Thanks for completing the welcome quiz!")
    return
  end

  if st._rendered_index ~= st.index then
    st._rendered_index = st.index
    st.question_started_at_ms = now_ms()
  elseif not st.question_started_at_ms then
    st.question_started_at_ms = now_ms()
  end

  -- Clamp a_idx within answers
  local total = #(q.answers or {})
  if total == 0 then st.a_idx = 1 else st.a_idx = math.max(1, math.min(st.a_idx or 1, total)) end

  minetest.show_formspec(name, formname, M.build_formspec(q, st))
end

-- Helper you can call from your on_receive_fields
function M.handle_fields(name, fields, player_state, questions, formname)
  if not (fields.prev or fields.submit or fields.next or fields.skip) then
    return false
  end

  local st = safe_state(player_state, name)
  local q = questions[st.index]
  if not q then return false end

  if fields.prev then
    local total = #(q.answers or {})
    if total > 0 then
      st.a_idx = ((st.a_idx - 2 + total) % total) + 1
    end
    if not st.checked then st.reveal = false end
  elseif fields.submit then
    st.checked = true
    st.reveal  = true
    local correct_idx = find_correct_index(q)
    -- Snap to correct choice like the Java version
    if correct_idx then st.a_idx = correct_idx end
  elseif fields.next then
    st.index  = st.index + 1
    st.a_idx  = 1
    st.checked = false
    st.reveal  = false
  elseif fields.skip then
    minetest.close_formspec(name, formname)
    return true
  end

  -- Re-show
  local player = minetest.get_player_by_name(name)
  if player then
    M.show_question(player, player_state, questions, formname, M)
  end
  return true
end

return M
