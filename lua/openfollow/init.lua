-- openfollow.nvim
-- Follow opencode edits in real-time: highlights changes, 
-- jumps to diffs, watches for new files.

local M = {}

local ns = vim.api.nvim_create_namespace("openfollow")
local state = {
    enabled = false,
    watchers = {},       -- buf -> fs_event handle
    snapshots = {},      -- buf -> lines (pre-change content)
    config = {},
    fade_timers = {},    -- buf -> timer handle
    git_tracker = nil,   -- timer for git status polling
    git_dirty = {},      -- set of files from last git poll
    opened_files = {},   -- files we've already auto-opened (don't re-open if user closes)
}

local defaults = {
    -- How long change highlights stay visible (ms). 0 = persistent until next change.
    fade_ms = 4000,
    -- Jump cursor to first changed line on external edit
    auto_jump = true,
    -- Auto-open files that external tools modify (via git status polling)
    auto_open = true,
    -- How often to poll git status (ms)
    poll_interval_ms = 1000,
    -- Ignore patterns for auto-open (lua patterns matched against relative path)
    ignore_patterns = {
        "^%.git/",
        "^target/",
        "^node_modules/",
        "%.lock$",
        "%.o$",
        "%.so$",
    },
    -- Where to open auto-opened files: "current", "vsplit", "split", "tab"
    open_strategy = "current",
    -- Highlight groups
    hl_added = "OpenFollowAdded",
    hl_changed = "OpenFollowChanged",
    hl_deleted = "OpenFollowDeleted",
    -- Max file size to watch (bytes) — skip huge generated files
    max_file_size = 1024 * 1024,
}

-- Highlights
local function setup_highlights(config)
    -- Soft, non-distracting colors that work on dark backgrounds
    vim.api.nvim_set_hl(0, config.hl_added, { default = true, bg = "#1a3a1a" })
    vim.api.nvim_set_hl(0, config.hl_changed, { default = true, bg = "#2a2a1a" })
    vim.api.nvim_set_hl(0, config.hl_deleted, { default = true, bg = "#3a1a1a" })
end

-- Snapshot: capture buffer content for diffing
local function snapshot(buf)
    if vim.api.nvim_buf_is_valid(buf) then
        state.snapshots[buf] = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end
end

-- Diff + highlight
local function clear_highlights(buf)
    if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
    if state.fade_timers[buf] then
        state.fade_timers[buf]:stop()
        state.fade_timers[buf] = nil
    end
end

local function schedule_fade(buf)
    local fade_ms = state.config.fade_ms
    if fade_ms <= 0 then return end

    if state.fade_timers[buf] then
        state.fade_timers[buf]:stop()
    end

    local timer = vim.uv.new_timer()
    state.fade_timers[buf] = timer
    timer:start(fade_ms, 0, vim.schedule_wrap(function()
        clear_highlights(buf)
    end))
end

local function highlight_changes(buf, old_lines, new_lines)
    clear_highlights(buf)

    local old_text = table.concat(old_lines, "\n") .. "\n"
    local new_text = table.concat(new_lines, "\n") .. "\n"

    -- vim.diff returns unified diff hunks
    local result = vim.diff(old_text, new_text, { result_type = "indices" })
    if not result or #result == 0 then return nil end

    local first_changed_line = nil
    local config = state.config

    for _, hunk in ipairs(result) do
        -- hunk: { old_start, old_count, new_start, new_count }
        local new_start = hunk[3]
        local new_count = hunk[4]
        local old_count = hunk[2]

        if new_count > 0 then
            local hl = (old_count == 0) and config.hl_added or config.hl_changed
            for i = new_start, new_start + new_count - 1 do
                local line_idx = i - 1 -- 0-indexed
                if line_idx >= 0 and line_idx < vim.api.nvim_buf_line_count(buf) then
                    vim.api.nvim_buf_set_extmark(buf, ns, line_idx, 0, {
                        line_hl_group = hl,
                        priority = 50,
                    })
                end
            end
            if not first_changed_line then
                first_changed_line = new_start
            end
        elseif old_count > 0 and new_count == 0 then
            -- Lines were deleted — mark the line where deletion happened
            local line_idx = new_start - 1
            if line_idx >= 0 and line_idx < vim.api.nvim_buf_line_count(buf) then
                vim.api.nvim_buf_set_extmark(buf, ns, line_idx, 0, {
                    line_hl_group = config.hl_deleted,
                    priority = 50,
                    virt_text = {
                        { " ▎-" .. old_count .. " lines", "Comment" },
                    },
                    virt_text_pos = "eol",
                })
            end
            if not first_changed_line then
                first_changed_line = new_start
            end
        end
    end

    schedule_fade(buf)
    return first_changed_line
end

-- File change handler
local function on_file_changed(buf)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    if vim.bo[buf].modified then return end -- don't clobber user edits

    local old_lines = state.snapshots[buf]
    if not old_lines then
        -- No snapshot, just reload
        vim.api.nvim_buf_call(buf, function() vim.cmd("checktime") end)
        snapshot(buf)
        return
    end

    -- Reload the buffer from disk
    vim.api.nvim_buf_call(buf, function() vim.cmd("checktime") end)

    -- Get new content
    local new_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    -- Diff and highlight
    local first_line = highlight_changes(buf, old_lines, new_lines)

    -- Auto-jump to first change
    if first_line and state.config.auto_jump then
        -- Only jump if this buffer is visible in a window
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_buf(win) == buf then
                vim.api.nvim_win_set_cursor(win, { first_line, 0 })
                vim.api.nvim_win_call(win, function() vim.cmd("normal! zz") end)
                break
            end
        end
    end

    -- Update snapshot
    state.snapshots[buf] = new_lines

    -- Notification
    local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
    local hunk_count = 0
    local result = vim.diff(
        table.concat(old_lines, "\n") .. "\n",
        table.concat(new_lines, "\n") .. "\n",
        { result_type = "indices" }
    )
    if result then hunk_count = #result end
    if hunk_count > 0 then
        vim.notify(
            string.format("openfollow: %s changed (%d hunks)", name, hunk_count),
            vim.log.levels.INFO
        )
    end
end

-- Buffer watcher
local function watch_buffer(buf)
    if state.watchers[buf] then return end

    local path = vim.api.nvim_buf_get_name(buf)
    if path == "" then return end

    -- Skip large files
    local stat = vim.uv.fs_stat(path)
    if stat and stat.size > state.config.max_file_size then return end

    local handle = vim.uv.new_fs_event()
    if not handle then return end

    -- Take initial snapshot
    snapshot(buf)

    -- Debounce: opencode may write in bursts
    local debounce_timer = vim.uv.new_timer()
    local pending = false

    handle:start(path, {}, function(err)
        if err then return end
        if pending then return end
        pending = true
        debounce_timer:start(100, 0, vim.schedule_wrap(function()
            pending = false
            on_file_changed(buf)
        end))
    end)

    state.watchers[buf] = { handle = handle, timer = debounce_timer }
end

local function unwatch_buffer(buf)
    local w = state.watchers[buf]
    if w then
        w.handle:stop()
        if w.timer then w.timer:stop() end
        state.watchers[buf] = nil
    end
    state.snapshots[buf] = nil
    clear_highlights(buf)
end

-- Git status tracker: auto-open files opencode is touching

--- Check if a path should be ignored
local function is_ignored(rel_path)
    for _, pattern in ipairs(state.config.ignore_patterns) do
        if rel_path:match(pattern) then return true end
    end
    return false
end

--- Get set of currently open buffer paths (relative to cwd)
local function get_open_buffer_paths()
    local cwd = vim.fn.getcwd() .. "/"
    local open = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) then
            local name = vim.api.nvim_buf_get_name(buf)
            if name:sub(1, #cwd) == cwd then
                open[name:sub(#cwd + 1)] = buf
            end
        end
    end
    return open
end

--- Parse git status --porcelain into a set of dirty file paths
local function parse_git_dirty(callback)
    vim.system(
        { "git", "status", "--porcelain", "-uall" },
        { text = true, cwd = vim.fn.getcwd() },
        function(result)
            local dirty = {}
            if result.code == 0 and result.stdout then
                for line in result.stdout:gmatch("[^\n]+") do
                    -- porcelain format: "XY filename" or "XY orig -> renamed"
                    local status_code = line:sub(1, 2)
                    local file = line:sub(4)
                    -- Handle renames: "R  old -> new"
                    local arrow = file:find(" %-> ")
                    if arrow then
                        file = file:sub(arrow + 4)
                    end
                    -- Only track modified/added, not deleted
                    if not status_code:match("^.D") and not status_code:match("^D") then
                        dirty[file] = status_code:gsub("%s", "")
                    end
                end
            end
            vim.schedule(function() callback(dirty) end)
        end
    )
end

--- Open a file and start watching it
local function auto_open_file(rel_path)
    local abs_path = vim.fn.getcwd() .. "/" .. rel_path

    -- Check file size
    local stat = vim.uv.fs_stat(abs_path)
    if not stat or stat.size > state.config.max_file_size then return end
    if stat.type ~= "file" then return end

    local strategy = state.config.open_strategy
    if strategy == "vsplit" then
        vim.cmd("vsplit " .. vim.fn.fnameescape(abs_path))
    elseif strategy == "split" then
        vim.cmd("split " .. vim.fn.fnameescape(abs_path))
    elseif strategy == "tab" then
        vim.cmd("tabedit " .. vim.fn.fnameescape(abs_path))
    else
        vim.cmd("edit " .. vim.fn.fnameescape(abs_path))
    end

    -- The buffer is now open — the BufReadPost autocmd will start watching it
    local buf = vim.fn.bufnr(abs_path)
    if buf ~= -1 then
        snapshot(buf)
    end
end

--- Single poll cycle
local function poll_git_status()
    if not state.enabled then return end

    parse_git_dirty(function(dirty)
        if not state.enabled then return end

        local open_bufs = get_open_buffer_paths()
        local prev_dirty = state.git_dirty

        for file, status_code in pairs(dirty) do
            if not is_ignored(file) then
                local is_new_dirty = not prev_dirty[file]
                local is_open = open_bufs[file] ~= nil
                local was_auto_opened = state.opened_files[file]

                if not is_open and not was_auto_opened then
                    -- File is dirty but not open — auto-open it
                    state.opened_files[file] = true
                    auto_open_file(file)
                    vim.notify(
                        string.format("openfollow: opened %s [%s]", file, status_code),
                        vim.log.levels.INFO
                    )
                elseif is_new_dirty and is_open then
                    -- File is open and newly dirty — the fs_event watcher
                    -- handles the diff/highlight, but notify about it
                    vim.notify(
                        string.format("openfollow: %s modified externally [%s]", file, status_code),
                        vim.log.levels.INFO
                    )
                end
            end
        end

        -- Track files that are no longer dirty (user or opencode committed/reset)
        for file, _ in pairs(prev_dirty) do
            if not dirty[file] and state.opened_files[file] then
                state.opened_files[file] = nil
            end
        end

        state.git_dirty = dirty
    end)
end

local function start_git_tracker()
    if state.git_tracker then return end

    -- Initial snapshot of git state so we only react to *new* changes
    parse_git_dirty(function(dirty)
        state.git_dirty = dirty
        -- Mark already-dirty files so we don't auto-open pre-existing changes
        for file, _ in pairs(dirty) do
            state.opened_files[file] = true
        end
    end)

    local timer = vim.uv.new_timer()
    timer:start(state.config.poll_interval_ms, state.config.poll_interval_ms, vim.schedule_wrap(function()
        poll_git_status()
    end))
    state.git_tracker = timer
end

local function stop_git_tracker()
    if state.git_tracker then
        state.git_tracker:stop()
        state.git_tracker = nil
    end
    state.git_dirty = {}
    state.opened_files = {}
end

-- Enable / Disable
local augroup = vim.api.nvim_create_augroup("openfollow", { clear = true })

local function enable()
    if state.enabled then return end
    state.enabled = true

    setup_highlights(state.config)

    -- Watch all current buffers
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted then
            watch_buffer(buf)
        end
    end

    -- Watch new buffers as they open
    vim.api.nvim_create_autocmd("BufReadPost", {
        group = augroup,
        callback = function(ev)
            if state.enabled then
                watch_buffer(ev.buf)
            end
        end,
    })

    -- Re-snapshot after user saves (so follow tracks from the latest save)
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = augroup,
        callback = function(ev)
            if state.enabled then
                snapshot(ev.buf)
                clear_highlights(ev.buf)
            end
        end,
    })

    -- Clean up on buffer delete
    vim.api.nvim_create_autocmd("BufDelete", {
        group = augroup,
        callback = function(ev)
            unwatch_buffer(ev.buf)
        end,
    })

    if state.config.auto_open then
        start_git_tracker()
    end

    vim.notify("openfollow: on", vim.log.levels.INFO)
end

local function disable()
    if not state.enabled then return end
    state.enabled = false

    -- Stop all watchers
    for buf, _ in pairs(state.watchers) do
        unwatch_buffer(buf)
    end

    stop_git_tracker()
    vim.api.nvim_clear_autocmds({ group = augroup })

    vim.notify("openfollow: off", vim.log.levels.INFO)
end

local function toggle()
    if state.enabled then disable() else enable() end
end

-- Status (for statusline integration)
local function status()
    if not state.enabled then return "" end
    local watch_count = 0
    for _ in pairs(state.watchers) do watch_count = watch_count + 1 end
    local dirty_count = 0
    for _ in pairs(state.git_dirty) do dirty_count = dirty_count + 1 end
    return string.format("👁 %d 🔧%d", watch_count, dirty_count)
end

-- Setup
function M.setup(opts)
    state.config = vim.tbl_deep_extend("force", defaults, opts or {})
    setup_highlights(state.config)

    vim.api.nvim_create_user_command("OpenFollow", enable, { desc = "Start following opencode edits" })
    vim.api.nvim_create_user_command("OpenFollowStop", disable, { desc = "Stop following opencode edits" })
    vim.api.nvim_create_user_command("OpenFollowToggle", toggle, { desc = "Toggle opencode follow mode" })
    vim.api.nvim_create_user_command("OpenFollowStatus", function()
        local watch_count = 0
        for _ in pairs(state.watchers) do watch_count = watch_count + 1 end
        local dirty_count = 0
        for _ in pairs(state.git_dirty) do dirty_count = dirty_count + 1 end
        vim.notify(
            string.format("openfollow: %s, watching %d buffers, %d dirty files",
                state.enabled and "on" or "off", watch_count, dirty_count),
            vim.log.levels.INFO
        )
    end, { desc = "Show openfollow status" })

    -- List all files opencode has touched
    vim.api.nvim_create_user_command("OpenFollowFiles", function()
        if vim.tbl_isempty(state.git_dirty) then
            vim.notify("openfollow: no dirty files", vim.log.levels.INFO)
            return
        end
        local items = {}
        local open_bufs = get_open_buffer_paths()
        for file, sc in pairs(state.git_dirty) do
            local indicator = open_bufs[file] and "●" or "○"
            table.insert(items, string.format("%s [%s] %s", indicator, sc, file))
        end
        table.sort(items)
        vim.ui.select(items, { prompt = "openfollow — dirty files (● open, ○ not open):" }, function(choice)
            if not choice then return end
            local file = choice:match("%] (.+)$")
            if file then
                vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.getcwd() .. "/" .. file))
            end
        end)
    end, { desc = "List and jump to files opencode has touched" })

    -- Convenience keymap
    vim.keymap.set("n", "<leader>of", toggle, { desc = "Toggle openfollow" })
end

M.enable = enable
M.disable = disable
M.toggle = toggle
M.status = status

return M
