local M = {}



function M.build_formspec(q)
  local rows = {
    "formspec_version[6]size[8,7]",
    "label[0.5,0.8;" .. minetest.formspec_escape(q.text) .. "]",
  }

  for idx, answer in ipairs(q.answers) do
    local y = 1.5 + (idx - 1) * 1.1
    local name = string.format("answer_%d", idx)
    rows[#rows + 1] = string.format("button[1,%.1f;6,0.9;%s;%s]",
      y,
      name,
      minetest.formspec_escape(answer.label)
    )
  end

  rows[#rows + 1] = "button_exit[2.5,5.2;3,0.8;skip;Skip quiz]"
  return table.concat(rows)
end


function M.show_question(player, player_state, questions, formname, forms)
  local name = player:get_player_name()
  local state = player_state[name]
  if not state then
    state = { index = 1, correct = 0 }
    player_state[name] = state
  end

  local question = questions[state.index]
  if not question then
    minetest.close_formspec(name, formname)
    minetest.chat_send_player(name, "Thanks for completing the welcome quiz!")
    return
  end

  minetest.show_formspec(name, formname, forms.build_formspec(question))
end

return M