local Job = require("plenary.job")
local q = require("quicktest.adapters.pytest.query")
local ts = require("quicktest.ts")
local fs = require("quicktest.fs_utils")

---@class PytestAdapterOptions
---@field cwd (fun(bufnr: integer, current: string?): string)?
---@field bin (fun(bufnr: integer, current: string?): string)?
---@field additional_args (fun(bufnr: integer): string[])?
---@field args (fun(bufnr: integer, current: string[]): string[])?
---@field env (fun(bufnr: integer, current: table<string, string>): table<string, string>)?
---@field is_enabled (fun(bufnr: integer, type: RunType, current: boolean): boolean)?

local M = {
  name = "pytest",
  ---@type PytestAdapterOptions
  options = {},
}

---@class PytestRunParams
---@field bufnr integer
---@field file string?
---@field ns_name string?
---@field test_name string?
---@field tests? PytestTestCase[]
---@field selected_test? PytestTestCase
---@field cwd string
---@field bin string
---@field opts AdapterRunOpts

---@class PytestTestCase
---@field id string
---@field row integer
---@field end_row integer
---@field name string
---@field ns_name string?
---@field display_name string
---@field selector string

local function build_selector(file, ns_name, test_name)
  if ns_name and ns_name ~= "" then
    return string.format("%s::%s::%s", file, ns_name, test_name)
  end

  return string.format("%s::%s", file, test_name)
end

---@param bufnr integer
---@return PytestTestCase[]
function M.list_tests(bufnr)
  local filetype = vim.bo[bufnr].filetype
  local parser = vim.treesitter.get_parser(bufnr, filetype)
  if not parser then
    return {}
  end

  local tree = parser:parse()[1]
  if not tree then
    return {}
  end

  local root = tree:root()
  local query = vim.treesitter.query.parse(filetype, q)
  local file = vim.api.nvim_buf_get_name(bufnr)

  local namespaces = {}
  local pending_ranges = {
    namespace = nil,
    test = nil,
  }
  local tests = {}

  for id, node in query:iter_captures(root, bufnr, 0, -1) do
    local capture = query.captures[id]

    if capture == "namespace.definition" then
      local start_row, _, end_row, _ = node:range()
      pending_ranges.namespace = { start_row = start_row, end_row = end_row }
    elseif capture == "namespace.name" and pending_ranges.namespace then
      table.insert(namespaces, {
        name = vim.treesitter.get_node_text(node, bufnr),
        start_row = pending_ranges.namespace.start_row,
        end_row = pending_ranges.namespace.end_row,
      })
      pending_ranges.namespace = nil
    elseif capture == "test.definition" then
      local start_row, _, end_row, _ = node:range()
      pending_ranges.test = { start_row = start_row, end_row = end_row }
    elseif capture == "test.name" and pending_ranges.test then
      local name = vim.treesitter.get_node_text(node, bufnr)
      local ns_name

      for _, namespace in ipairs(namespaces) do
        if pending_ranges.test.start_row > namespace.start_row and pending_ranges.test.end_row <= namespace.end_row then
          ns_name = namespace.name
          break
        end
      end

      local selector = build_selector(file, ns_name, name)
      table.insert(tests, {
        id = selector,
        row = pending_ranges.test.start_row,
        end_row = pending_ranges.test.end_row,
        name = name,
        ns_name = ns_name,
        display_name = ns_name and string.format("%s::%s", ns_name, name) or name,
        selector = selector,
      })
      pending_ranges.test = nil
    end
  end

  return tests
end

---@param bufnr integer
---@return string?
M.get_cwd = function(bufnr)
  local buffer_name = vim.api.nvim_buf_get_name(bufnr) -- Get the current buffer's file path
  local path = vim.fn.fnamemodify(buffer_name, ":p:h") -- Get the full path of the directory containing the file
  local detected_cwd = fs.find_ancestor_of_file(path, "pyproject.toml") or path

  return M.options.cwd and M.options.cwd(bufnr, detected_cwd) or detected_cwd
end

---@param bufnr integer
---@return string?
M.get_bin = function(cwd, bufnr)
  return M.options.bin and M.options.bin(bufnr, "pytest") or "pytest"
end

--- Builds parameters for running tests based on buffer number and cursor position.
--- This function should be customized to extract necessary information from the buffer.
---@param bufnr integer
---@param cursor_pos integer[]
---@param opts AdapterRunOpts
---@return PytestRunParams | nil, string | nil
M.build_line_run_params = function(bufnr, cursor_pos, opts)
  local cwd = M.get_cwd(bufnr)

  if not cwd then
    return nil, "Failed to find cwd"
  end

  local bin = M.get_bin(cwd, bufnr)

  if not bin then
    return nil, "Failed to find pytest binary"
  end

  local file = vim.api.nvim_buf_get_name(bufnr)
  local tests = M.list_tests(bufnr)
  local ns_name = ts.get_current_test_name(q, bufnr, cursor_pos, "namespace")
  local test_name = ts.get_current_test_name(q, bufnr, cursor_pos, "test")
  local selected_selector = test_name and build_selector(file, ns_name, test_name) or nil
  local selected_test

  for _, test in ipairs(tests) do
    if selected_selector and test.selector == selected_selector then
      selected_test = test
      break
    end
  end

  local params = {
    bufnr = bufnr,
    ns_name = ns_name,
    test_name = test_name,
    file = file,
    tests = tests,
    selected_test = selected_test,
    cwd = cwd,
    bin = bin,
    opts = opts,
    -- Add other parameters as needed
  }
  return params, nil
end

---@param bufnr integer
---@param cursor_pos integer[]
---@param opts AdapterRunOpts
---@return PytestRunParams | nil, string | nil
M.build_all_run_params = function(bufnr, cursor_pos, opts)
  local cwd = M.get_cwd(bufnr)

  if not cwd then
    return nil, "Failed to find cwd"
  end

  local bin = M.get_bin(cwd, bufnr)

  if not bin then
    return nil, "Failed to find pytest binary"
  end

  local params = {
    bufnr = bufnr,
    cwd = cwd,
    bin = bin,
    opts = opts,
    -- Add other parameters as needed
  }
  return params, nil
end

---@param bufnr integer
---@param cursor_pos integer[]
---@param opts AdapterRunOpts
---@return PytestRunParams | nil, string | nil
---@diagnostic disable-next-line: unused-local
M.build_file_run_params = function(bufnr, cursor_pos, opts)
  local cwd = M.get_cwd(bufnr)

  if not cwd then
    return nil, "Failed to find cwd"
  end

  local bin = M.get_bin(cwd, bufnr)

  if not bin then
    return nil, "Failed to find pytest binary"
  end

  local file = vim.api.nvim_buf_get_name(bufnr) -- Get the current buffer's file path

  local params = {
    bufnr = bufnr,
    cwd = cwd,
    bin = bin,
    file = file,
    tests = M.list_tests(bufnr),
    opts = opts,
    -- Add other parameters as needed
  }

  return params, nil
end

---@param bufnr integer
---@param selectors string[]
---@param opts AdapterRunOpts
---@return PytestRunParams | nil, string | nil
M.build_selectors_run_params = function(bufnr, selectors, opts)
  local cwd = M.get_cwd(bufnr)

  if not cwd then
    return nil, "Failed to find cwd"
  end

  local bin = M.get_bin(cwd, bufnr)

  if not bin then
    return nil, "Failed to find pytest binary"
  end

  local tests = M.list_tests(bufnr)
  local selected_tests = {}
  local selector_set = {}
  for _, sel in ipairs(selectors) do
    selector_set[sel] = true
  end

  for _, test in ipairs(tests) do
    if selector_set[test.selector] then
      table.insert(selected_tests, test)
    end
  end

  local params = {
    bufnr = bufnr,
    selectors = selectors,
    tests = selected_tests,
    cwd = cwd,
    bin = bin,
    opts = opts,
  }

  return params, nil
end

---@param params PytestRunParams
local function build_args(params)
  local args = {}

  if params.selectors and #params.selectors > 0 then
    vim.list_extend(args, params.selectors)
  elseif params.file ~= "" and params.file ~= nil then
    if params.test_name ~= "" and params.test_name ~= nil then
      local test_selector = params.file

      if params.ns_name ~= "" and params.ns_name ~= nil then
        test_selector = string.format("%s::%s::%s", test_selector, params.ns_name, params.test_name)
      else
        test_selector = string.format("%s::%s", test_selector, params.test_name)
      end

      vim.list_extend(args, {
        test_selector,
      })
    else
      vim.list_extend(args, {
        params.file,
      })
    end
  end

  if params.tests and #params.tests > 0 and not vim.tbl_contains(args, "-vv") then
    table.insert(args, "-vv")
  end

  return args
end

---@param line string
---@return string|nil, string|nil
local function parse_test_result_line(line)
  local clean_line = line:gsub("[\27\155][][()#;?%d]*[A-PRZcf-ntqry=><~]", "")
  local selector, status = clean_line:match("^(%S+)%s+(PASSED|FAILED|ERROR|SKIPPED|XFAIL|XPASS)%s*")
  if not selector or not status then
    return nil, nil
  end

  if status == "PASSED" or status == "XFAIL" then
    return selector, "passed"
  end

  if status == "FAILED" or status == "ERROR" or status == "XPASS" then
    return selector, "failed"
  end

  return selector, "skipped"
end

--- Executes the test with the given parameters.
---@param params PytestRunParams
---@param send fun(data: any)
---@return integer
M.run = function(params, send)
  local args = build_args(params)
  local env = vim.fn.environ()

  local additional_args = M.options.additional_args and M.options.additional_args(params.bufnr) or {}
  additional_args = params.opts.additional_args and vim.list_extend(additional_args, params.opts.additional_args)
    or additional_args
  if additional_args ~= nil then
    args = vim.list_extend(args, additional_args)
  end

  args = M.options.args and M.options.args(params.bufnr, args) or args
  env = M.options.env and M.options.env(params.bufnr, env) or env

  local running_tests = {}
  if params.selected_test then
    running_tests = { params.selected_test }
  elseif params.tests then
    running_tests = params.tests
  end

  for _, test in ipairs(running_tests) do
    send({
      type = "test_status",
      status = "running",
      selector = test.selector,
      row = test.row,
      bufnr = params.bufnr,
      display_name = test.display_name,
    })
  end

  local job = Job:new({
    command = params.bin,
    args = args, -- Modify based on how your test command needs to be structured
    env = env,
    cwd = params.cwd,
    on_stdout = function(_, data)
      for k, v in pairs(vim.split(data, "\n")) do
        local selector, status = parse_test_result_line(v)
        if selector and status then
          send({
            type = "test_status",
            status = status,
            selector = selector,
            bufnr = params.bufnr,
          })
        end
        send({ type = "stdout", output = v })
      end
    end,
    on_stderr = function(_, data)
      for k, v in pairs(vim.split(data, "\n")) do
        send({ type = "stderr", output = v })
      end
    end,
    on_exit = function(_, return_val)
      send({ type = "exit", code = return_val })
    end,
  })

  job:start()

  ---@type integer
  ---@diagnostic disable-next-line: assign-type-mismatch
  local pid = job.pid

  return pid
end

--- Checks if the plugin is enabled for the given buffer.
---@param bufnr integer
---@param type RunType
---@return boolean
M.is_enabled = function(bufnr, type)
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  is_test_file = string.match(file_path, "test_.*%.py$")

  if M.options.is_enabled == nil then
    return is_test_file
  end

  return M.options.is_enabled(bufnr, type, is_test_file)
end

--- Adapter options.
setmetatable(M, {
  ---@param opts GoAdapterOptions
  __call = function(_, opts)
    M.options = opts

    return M
  end,
})

return M
