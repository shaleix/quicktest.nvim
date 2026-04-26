describe("test panel", function()
  local original_popup
  local original_quicktest
  local test_panel

  before_each(function()
    original_popup = package.loaded["nui.popup"]
    original_quicktest = package.loaded["quicktest"]

    package.loaded["nui.popup"] = function(opts)
      return {
        bufnr = opts.bufnr,
        mount = function()
        end,
        unmount = function()
        end,
      }
    end
    package.loaded["quicktest"] = {
      config = {
        popup_options = {},
      },
    }

    package.loaded["quicktest.test_panel"] = nil
    test_panel = require("quicktest.test_panel")
  end)

  after_each(function()
    package.loaded["nui.popup"] = original_popup
    package.loaded["quicktest"] = original_quicktest
    package.loaded["quicktest.test_panel"] = nil
    vim.cmd("silent! %bwipeout!")
  end)

  it("groups namespaced tests under their suite name", function()
    local source_bufnr = vim.api.nvim_create_buf(false, true)

    test_panel.open(source_bufnr, "pytest", {
      {
        selector = "a.py::TestSuite::test_case_1",
        display_name = "TestSuite::test_case_1",
        row = 1,
        status = "running",
      },
      {
        selector = "a.py::TestSuite::test_case_2",
        display_name = "TestSuite::test_case_2",
        row = 5,
        status = "passed",
      },
      {
        selector = "a.py::test_top_level",
        display_name = "test_top_level",
        row = 9,
        status = "failed",
      },
    })

    local panel_bufnr
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(bufnr) == "quicktest://quicktest-test-list" then
        panel_bufnr = bufnr
        break
      end
    end

    assert.is_not_nil(panel_bufnr)
    assert.are.same({
      "● test_top_level",
      "TestSuite:",
      "  ● test_case_1",
      "  ● test_case_2",
    }, vim.api.nvim_buf_get_lines(panel_bufnr, 0, -1, false))
  end)

  it("adds blank line between test suites", function()
    local source_bufnr = vim.api.nvim_create_buf(false, true)

    test_panel.open(source_bufnr, "pytest", {
      {
        selector = "a.py::Suite1::test_one",
        display_name = "Suite1::test_one",
        row = 1,
        status = "passed",
      },
      {
        selector = "a.py::Suite2::test_two",
        display_name = "Suite2::test_two",
        row = 5,
        status = "passed",
      },
    })

    local panel_bufnr
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(bufnr) == "quicktest://quicktest-test-list" then
        panel_bufnr = bufnr
        break
      end
    end

    assert.is_not_nil(panel_bufnr)
    assert.are.same({
      "Suite1:",
      "  ● test_one",
      "",
      "Suite2:",
      "  ● test_two",
    }, vim.api.nvim_buf_get_lines(panel_bufnr, 0, -1, false))
  end)
end)
