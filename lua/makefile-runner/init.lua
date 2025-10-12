-- Makefile Runner Plugin
-- A Neovim plugin to quickly run Makefile targets in a floating terminal

local M = {}

-- Default configuration
local config = {
	keymap = nil,
	floaterm = {
		width = 0.9,
		height = 0.9,
		wintype = "float",
		position = "center",
		autoclose = 0,
	},
	show_descriptions = true,
	exclude_targets = {}, -- e.g., {'clean', 'distclean'}
	include_hidden = false, -- Include targets starting with _
}

-- Parse Makefile and extract targets with descriptions
local function get_makefile_targets()
	local makefile_path = vim.fn.findfile("Makefile", ".;")

	if makefile_path == "" then
		vim.notify("No Makefile found in current directory or parent directories", vim.log.levels.ERROR)
		return nil
	end

	local targets = {}
	local file = io.open(makefile_path, "r")

	if not file then
		vim.notify("Could not open Makefile", vim.log.levels.ERROR)
		return nil
	end

	local last_comment = nil
	local in_multiline_comment = false

	for line in file:lines() do
		-- Handle multiline comments (lines ending with \)
		if line:match("\\%s*$") then
			in_multiline_comment = true
		end

		-- Capture comment lines as potential descriptions (lines starting with #)
		local comment = line:match("^%s*#%s*(.+)")
		if comment and not in_multiline_comment then
			-- Skip decorative comments (lines with mostly special chars)
			if not comment:match("^[—-=_*#]+") then
				comment = comment:gsub("%s+$", "")
				last_comment = comment
			end
		end

		-- Match target lines (starts with word chars, followed by :)
		if not line:match("^%s") and not line:match("^#") then
			local target, inline_comment = line:match("^([%w_.-]+)%s*:[^#]*##%s*(.+)")

			-- If no inline comment, try matching just the target
			if not target then
				target = line:match("^([%w_.-]+)%s*:")
			end

			if target then
				-- Skip special targets unless include_hidden is true
				local is_hidden = target:match("^[_.]")
				local is_excluded = vim.tbl_contains(config.exclude_targets, target)

				if not is_excluded and (config.include_hidden or not is_hidden) then
					-- Prefer inline comment (##) over previous line comment
					local description = inline_comment or last_comment

					table.insert(targets, {
						name = target,
						description = description,
					})
				end
			end

			-- Reset comment after processing target
			if not line:match("^%s*#") then
				last_comment = nil
			end
		end

		if not line:match("\\%s*$") then
			in_multiline_comment = false
		end
	end

	file:close()

	if #targets == 0 then
		vim.notify("No targets found in Makefile", vim.log.levels.WARN)
		return nil
	end

	return targets
end

-- Build floaterm command with custom options
local function build_floaterm_cmd(target)
	local opts = config.floaterm
	local cmd = string.format(
		"FloatermNew --width=%s --height=%s --wintype=%s --position=%s --autoclose=%s make %s",
		opts.width,
		opts.height,
		opts.wintype,
		opts.position,
		opts.autoclose,
		target
	)
	return cmd
end

-- Execute make command in floaterm
local function run_make_target(target)
	if not target or target == "" then
		return
	end

	-- Check if floaterm is available
	if vim.fn.exists(":FloatermNew") == 0 then
		vim.notify("floaterm plugin not found. Please install it first.", vim.log.levels.ERROR)
		return
	end

	local cmd = build_floaterm_cmd(target)
	vim.cmd(cmd)
end

-- Format target for display
local function format_target(target)
	if config.show_descriptions and target.description then
		return string.format("%-20s # %s", target.name, target.description)
	else
		return target.name
	end
end

-- Show targets with Telescope
function M.show_with_telescope()
	local has_telescope, _ = pcall(require, "telescope")

	if not has_telescope then
		vim.notify("Telescope not found. Please install telescope.nvim", vim.log.levels.ERROR)
		return
	end

	local targets = get_makefile_targets()
	if not targets then
		return
	end

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local entry_display = require("telescope.pickers.entry_display")

	-- Create displayer for formatted output
	local displayer = entry_display.create({
		separator = " ",
		items = {
			{ width = 20 },
			{ remaining = true },
		},
	})

	local make_display = function(entry)
		if config.show_descriptions and entry.value.description then
			return displayer({
				{ entry.value.name, "TelescopeResultsIdentifier" },
				{ entry.value.description, "TelescopeResultsComment" },
			})
		else
			return entry.value.name
		end
	end

	pickers
		.new({}, {
			prompt_title = "Makefile Targets",
			finder = finders.new_table({
				results = targets,
				entry_maker = function(entry)
					return {
						value = entry,
						display = make_display,
						ordinal = entry.name .. (entry.description or ""),
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					run_make_target(selection.value.name)
				end)
				return true
			end,
		})
		:find()
end

-- Show targets with fzf-lua
function M.show_with_fzf()
	local has_fzf, fzf = pcall(require, "fzf-lua")

	if not has_fzf then
		vim.notify("fzf-lua not found. Please install fzf-lua", vim.log.levels.ERROR)
		return
	end

	local targets = get_makefile_targets()
	if not targets then
		return
	end

	-- Format targets for display
	local formatted_targets = {}
	for _, target in ipairs(targets) do
		table.insert(formatted_targets, format_target(target))
	end

	fzf.fzf_exec(formatted_targets, {
		prompt = "Makefile Targets> ",
		actions = {
			["default"] = function(selected)
				if selected and #selected > 0 then
					-- Extract target name from formatted string
					local target_name = selected[1]:match("^(%S+)")
					run_make_target(target_name)
				end
			end,
		},
		fzf_opts = {
			["--delimiter"] = "#",
			["--with-nth"] = "1..",
		},
	})
end

-- Auto-detect which fuzzy finder to use
function M.show()
	local has_telescope = pcall(require, "telescope")
	local has_fzf = pcall(require, "fzf-lua")

	if has_telescope then
		M.show_with_telescope()
	elseif has_fzf then
		M.show_with_fzf()
	else
		vim.notify("Please install either telescope.nvim or fzf-lua", vim.log.levels.ERROR)
	end
end

-- List all targets (for debugging or scripting)
function M.list_targets()
	local targets = get_makefile_targets()
	if not targets then
		return
	end

	print("Available Makefile targets:")
	for _, target in ipairs(targets) do
		if target.description then
			print(string.format("  %-20s # %s", target.name, target.description))
		else
			print(string.format("  %s", target.name))
		end
	end
end

-- Run a specific target by name (for keymaps or commands)
function M.run(target_name)
	if not target_name or target_name == "" then
		vim.notify("Please provide a target name", vim.log.levels.ERROR)
		return
	end

	run_make_target(target_name)
end

-- Setup function for configuration
function M.setup(opts)
	-- Merge user config with defaults
	config = vim.tbl_deep_extend("force", config, opts or {})

	-- Create user commands
	vim.api.nvim_create_user_command("MakeRun", function()
		M.show()
	end, { desc = "Show Makefile targets and run selected target" })

	vim.api.nvim_create_user_command("MakeRunTelescope", function()
		M.show_with_telescope()
	end, { desc = "Show Makefile targets with Telescope" })

	vim.api.nvim_create_user_command("MakeRunFzf", function()
		M.show_with_fzf()
	end, { desc = "Show Makefile targets with fzf-lua" })

	vim.api.nvim_create_user_command("MakeList", function()
		M.list_targets()
	end, { desc = "List all Makefile targets" })

	vim.api.nvim_create_user_command("Make", function(args)
		M.run(args.args)
	end, {
		nargs = 1,
		desc = "Run a specific Makefile target",
		complete = function()
			local targets = get_makefile_targets()
			if not targets then
				return {}
			end
			local names = {}
			for _, target in ipairs(targets) do
				table.insert(names, target.name)
			end
			return names
		end,
	})

	-- Set up keymaps if provided
	if config.keymap then
		vim.keymap.set("n", config.keymap, M.show, { desc = "Run Makefile target" })
	end
end

return M

