local Popup = require("nui.popup")

local M = {}

local api = vim.api
local state = {
  popup = nil,
  buf = nil,
  source_bufnr = nil,
  adapter_name = nil,
  tests = {},
  line_to_test = {},
  running_selectors = {},
  line_to_namespace = {},
  notified_finished = false,
}

local ns = api.nvim_create_namespace("quicktest-test-panel")
local sign_ns = api.nvim_create_namespace("quicktest-test-signs")

local status_style = {
  idle = { hl = "Comment" },
  running = { hl = "DiagnosticWarn" },
  passed = { hl = "DiagnosticOk" },
  failed = { hl = "DiagnosticError" },
  skipped = { hl = "DiagnosticWarn" },
  error = { hl = "DiagnosticError" },
}

local function get_style(status)
  return status_style[status] or status_style.idle
end

local function ensure_buf()
  if state.buf and api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end

  state.buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(state.buf, "quicktest://quicktest-test-list")
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].modifiable = false
  vim.bo[state.buf].filetype = "quicktest-tests"

  return state.buf
end

local function render_signs()
  if not state.source_bufnr or not api.nvim_buf_is_valid(state.source_bufnr) then
    return
  end

  api.nvim_buf_clear_namespace(state.source_bufnr, sign_ns, 0, -1)
  local line_count = api.nvim_buf_line_count(state.source_bufnr)

  for _, test in ipairs(state.tests) do
    if test.status and test.status ~= "idle" and test.row < line_count then
      local style = get_style(test.status)
      api.nvim_buf_set_extmark(state.source_bufnr, sign_ns, test.row, 0, {
        sign_text = "●",
        sign_hl_group = style.hl,
        priority = 200,
      })
    end
  end
end

local function build_render_entries()
  local entries = {}
  local groups = {}
  local group_order = {}
  local group_tests = {}

  for _, test in ipairs(state.tests) do
    local namespace, test_name = test.display_name:match("^([^:]+)::(.+)$")
    if namespace and test_name then
      if not groups[namespace] then
        groups[namespace] = {}
        table.insert(group_order, namespace)
      end

      table.insert(groups[namespace], {
        kind = "test",
        text = "  ● " .. test_name,
        test = test,
      })
    else
      table.insert(entries, {
        kind = "test",
        text = "● " .. test.display_name,
        test = test,
      })
    end
  end

  for idx, namespace in ipairs(group_order) do
    if idx > 1 then
      table.insert(entries, { kind = "separator" })
    end

    table.insert(entries, {
      kind = "group",
      text = namespace .. ":",
      namespace = namespace,
    })

    for _, test_entry in ipairs(groups[namespace]) do
      table.insert(entries, test_entry)
    end
  end

  return entries
end

local function render()
  local buf = ensure_buf()
  local lines = {}
  local entries = build_render_entries()
  state.line_to_test = {}
  state.line_to_namespace = {}

  for _, entry in ipairs(entries) do
    if entry.kind == "separator" then
      table.insert(lines, "")
    else
      table.insert(lines, entry.text)
    end
  end

  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local cursor_line = 1
  for _, entry in ipairs(entries) do
    if entry.kind ~= "separator" then
      local buf_row = cursor_line - 1
      if entry.kind == "test" then
        local test = entry.test
        local style = get_style(test.status)
        local dot_col = entry.text:find("●", 1, true)
        state.line_to_test[cursor_line] = test

        if dot_col then
          api.nvim_buf_set_extmark(buf, ns, buf_row, dot_col - 1, {
            end_col = dot_col,
            hl_group = style.hl,
          })
        end
      elseif entry.kind == "group" then
        state.line_to_namespace[cursor_line] = entry.namespace
        api.nvim_buf_set_extmark(buf, ns, buf_row, 0, {
          end_col = #entry.text,
          hl_group = "Title",
        })
      end
      cursor_line = cursor_line + 1
    else
      cursor_line = cursor_line + 1
    end
  end

  vim.bo[buf].modifiable = false
  render_signs()
end

function M.track_tests(bufnr, adapter_name, tests)
  if state.source_bufnr and state.source_bufnr ~= bufnr and api.nvim_buf_is_valid(state.source_bufnr) then
    api.nvim_buf_clear_namespace(state.source_bufnr, sign_ns, 0, -1)
  end

  local existing_status = {}
  if state.source_bufnr == bufnr then
    for _, test in ipairs(state.tests) do
      existing_status[test.selector] = test.status
    end
  end

  state.source_bufnr = bufnr
  state.adapter_name = adapter_name
  state.tests = {}
  state.running_selectors = {}
  state.notified_finished = false

  for _, test in ipairs(tests or {}) do
    local copy = vim.deepcopy(test)
    copy.status = existing_status[copy.selector] or copy.status or "idle"
    table.insert(state.tests, copy)
  end

  render_signs()

  if state.popup then
    render()
  end
end

local function run_test_or_namespace_under_cursor()
  if not state.buf or api.nvim_get_current_buf() ~= state.buf then
    return
  end

  local cursor = api.nvim_win_get_cursor(0)
  local line = cursor[1]

  local test = state.line_to_test[line]
  if test then
    require("quicktest").run_line("auto", state.adapter_name, {
      bufnr = state.source_bufnr,
      cursor_pos = { test.row + 1, 0 },
    })
    return
  end

  local namespace = state.line_to_namespace[line]
  if namespace then
    local tests_in_namespace = {}
    for _, t in ipairs(state.tests) do
      if t.ns_name == namespace then
        table.insert(tests_in_namespace, t)
      end
    end

    if #tests_in_namespace > 0 then
      local selectors = {}
      for _, t in ipairs(tests_in_namespace) do
        table.insert(selectors, t.selector)
      end

      require("quicktest").run_selectors(state.adapter_name, selectors, {
        bufnr = state.source_bufnr,
      })
    end
  end
end

local function run_namespace_under_cursor()
  if not state.buf or api.nvim_get_current_buf() ~= state.buf then
    return
  end

  local cursor = api.nvim_win_get_cursor(0)
  local namespace = state.line_to_namespace[cursor[1]]
  if not namespace then
    return
  end

  local tests_in_namespace = {}
  for _, test in ipairs(state.tests) do
    if test.ns_name == namespace then
      table.insert(tests_in_namespace, test)
    end
  end

  if #tests_in_namespace == 0 then
    return
  end

  local selectors = {}
  for _, test in ipairs(tests_in_namespace) do
    table.insert(selectors, test.selector)
  end

  require("quicktest").run_selectors(state.adapter_name, selectors, {
    bufnr = state.source_bufnr,
  })
end

local function ensure_keymaps(buf)
  vim.keymap.set("n", "<CR>", run_test_or_namespace_under_cursor, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "r", run_test_or_namespace_under_cursor, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "R", run_namespace_under_cursor, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "q", function()
    M.close()
  end, { buffer = buf, silent = true, nowait = true })
end

function M.open(source_bufnr, adapter_name, tests)
  M.track_tests(source_bufnr, adapter_name, tests)

  local buf = ensure_buf()
  local entries = build_render_entries()
  ensure_keymaps(buf)

  if not state.popup then
    local popup_options = vim.tbl_deep_extend("force", {
      enter = true,
      focusable = true,
      bufnr = buf,
      border = { style = "rounded", text = { top = " Quicktest Cases ", top_align = "center" } },
      position = "50%",
      size = {
        width = 60,
        height = math.max(8, math.min(#entries + 4, 20)),
      },
    }, require("quicktest").config.popup_options or {})

    popup_options.bufnr = buf
    popup_options.size.height = math.max(8, math.min(#entries + 4, 20))
    state.popup = Popup(popup_options)
    state.popup:mount()
  end

  render()
end

function M.close()
  if state.popup then
    state.popup:unmount()
    state.popup = nil
  end
end

local function check_all_tests_finished()
  if state.notified_finished then
    return false
  end

  if #state.running_selectors == 0 then
    return false
  end

  local passed = 0
  local failed = 0
  local skipped = 0
  local error_count = 0
  local running = 0

  for _, test in ipairs(state.tests) do
    if state.running_selectors[test.selector] then
      if test.status == "passed" then
        passed = passed + 1
      elseif test.status == "failed" then
        failed = failed + 1
      elseif test.status == "skipped" then
        skipped = skipped + 1
      elseif test.status == "error" then
        error_count = error_count + 1
      elseif test.status == "running" then
        running = running + 1
      end
    end
  end

  if running > 0 then
    return false
  end

  local total = passed + failed + skipped + error_count
  if total == 0 then
    return false
  end

  state.notified_finished = true

  if failed > 0 or error_count > 0 then
    vim.notify(
      string.format("Tests failed: %d passed, %d failed, %d error, %d skipped", passed, failed, error_count, skipped),
      vim.log.levels.ERROR
    )
  else
    vim.notify(string.format("Tests passed: %d passed, %d skipped", passed, skipped), vim.log.levels.INFO)
  end

  return true
end

function M.update_test_status(bufnr, selector, status)
  if not bufnr or state.source_bufnr ~= bufnr then
    return
  end

  if status == "running" then
    state.running_selectors[selector] = true
  end

  for _, test in ipairs(state.tests) do
    if test.selector == selector then
      test.status = status
      render()
      check_all_tests_finished()
      return
    end

    local test_id = test.selector:match("::.*$")
    local output_id = selector:match("::.*$")
    if test_id and output_id and test_id == output_id then
      test.status = status
      if status == "running" then
        state.running_selectors[test.selector] = true
      end
      render()
      check_all_tests_finished()
      return
    end
  end
end

function M.reset_running_tests(bufnr, selectors)
  if not bufnr or state.source_bufnr ~= bufnr then
    return
  end

  state.notified_finished = false
  state.running_selectors = {}

  for _, test in ipairs(state.tests) do
    for _, selector in ipairs(selectors) do
      if test.selector == selector then
        test.status = "running"
        state.running_selectors[test.selector] = true
        break
      end

      local test_id = test.selector:match("::.*$")
      local sel_id = selector:match("::.*$")
      if test_id and sel_id and test_id == sel_id then
        test.status = "running"
        state.running_selectors[test.selector] = true
        break
      end
    end
  end

  render()
end

function M.get_tests()
  return state.tests
end

return M
