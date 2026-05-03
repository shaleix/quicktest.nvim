local fixture_dir = "/root/workspace/quicktest.nvim/tests/support/pytest"

describe("pytest adapter", function()
  local original_plenary_job
  local captured_job_opts
  local pytest

  before_each(function()
    original_plenary_job = package.loaded["plenary.job"]
    package.loaded["plenary.job"] = {
      new = function(_, opts)
        captured_job_opts = opts

        return {
          pid = 42,
          start = function()
          end,
        }
      end,
    }
    package.loaded["quicktest.adapters.pytest"] = nil
    pytest = require("quicktest.adapters.pytest")({})
    captured_job_opts = nil
  end)

  after_each(function()
    package.loaded["quicktest.adapters.pytest"] = nil
    package.loaded["plenary.job"] = original_plenary_job
    vim.cmd("silent! %bwipeout!")
  end)

  local function open_fixture(path)
    vim.cmd("edit " .. path)
    vim.bo.filetype = "python"

    return vim.api.nvim_get_current_buf()
  end

  it("builds an exact selector for top-level test functions", function()
    local path = fixture_dir .. "/test_simple.py"
    local bufnr = open_fixture(path)
    local params = assert(pytest.build_line_run_params(bufnr, { 1, 0 }, { additional_args = nil }))

    assert.are.same("test_fail", params.test_name)
    assert.is_nil(params.ns_name)

    pytest.run(params, function()
    end)

    assert.are.same({ path .. "::test_fail", "-vv" }, captured_job_opts.args)
  end)

  it("builds an exact selector for class test methods", function()
    local path = fixture_dir .. "/test_class_methods.py"
    local bufnr = open_fixture(path)
    local params = assert(pytest.build_line_run_params(bufnr, { 5, 0 }, { additional_args = nil }))

    assert.are.same("TestMath", params.ns_name)
    assert.are.same("test_add", params.test_name)

    pytest.run(params, function()
    end)

    assert.are.same({ path .. "::TestMath::test_add", "-vv" }, captured_job_opts.args)
  end)

  it("lists all test cases in the current file", function()
    local path = fixture_dir .. "/test_class_methods.py"
    local bufnr = open_fixture(path)
    local tests = pytest.list_tests(bufnr)

    assert.are.same({
      {
        id = path .. "::TestMath::test_add",
        row = 4,
        end_row = 7,
        name = "test_add",
        ns_name = "TestMath",
        display_name = "TestMath::test_add",
        selector = path .. "::TestMath::test_add",
      },
      {
        id = path .. "::TestMath::test_add2",
        row = 9,
        end_row = 12,
        name = "test_add2",
        ns_name = "TestMath",
        display_name = "TestMath::test_add2",
        selector = path .. "::TestMath::test_add2",
      },
      {
        id = path .. "::TestString::test_add",
        row = 16,
        end_row = 17,
        name = "test_add",
        ns_name = "TestString",
        display_name = "TestString::test_add",
        selector = path .. "::TestString::test_add",
      },
    }, tests)
  end)

  it("builds file run params with all discovered tests", function()
    local path = fixture_dir .. "/test_simple.py"
    local bufnr = open_fixture(path)
    local params = assert(pytest.build_file_run_params(bufnr, { 1, 0 }, { additional_args = nil }))

    assert.are.same({
      path .. "::test_fail",
      path .. "::test_ok",
    }, vim.tbl_map(function(test)
      return test.selector
    end, params.tests))
  end)
end)
