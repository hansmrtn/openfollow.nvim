-- Follow opencode edits in real-time: highlights changes, 
-- jumps to diffs, watches for new files. 

local M = {}

local ns = vim.api.nvim_create_namespace("openfollow")
local state = {
    enabled = false,
    watchers = {},       -- buf -> fs_event handle
    dir_watcher = nil,   -- project directory watcher
    known_files = {},    -- set of known files in project
    snapshots = {},      -- buf -> lines (pre-change content)
    config = {},
    fade_timers = {},    -- buf -> timer handle
}

local defaults = {
    -- How long change highlights stay visible (ms). 0 = persistent until next change.
    fade_ms = 4000,
    -- Jump cursor to first changed line on external edit
    auto_jump = true,
    -- Watch project directory for new files opencode creates
    watch_new_files = true,
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

-- Directory watcher: detect new files opencode creates
local function scan_project_files()
    local files = {}
    local handle = vim.uv.fs_scandir(vim.fn.getcwd())
    if not handle then return files end
    while true do
        local name, typ = vim.uv.fs_scandir_next(handle)
        if not name then break end
        if typ == "file" then
            files[name] = true
        end
    end
    return files
end

local function start_dir_watcher()
    if state.dir_watcher then return end
    local cwd = vim.fn.getcwd()

    state.known_files = scan_project_files()

    local handle = vim.uv.new_fs_event()
    if not handle then return end

    local debounce = vim.uv.new_timer()

    handle:start(cwd, {}, function()
        debounce:start(200, 0, vim.schedule_wrap(function()
            local current = scan_project_files()
            for name, _ in pairs(current) do
                if not state.known_files[name] then
                    vim.notify(
                        string.format("openfollow: new file → %s", name),
                        vim.log.levels.INFO
                    )
                end
            end
            state.known_files = current
        end))
    end)

    state.dir_watcher = { handle = handle, timer = debounce }
end

local function stop_dir_watcher()
    if state.dir_watcher then
        state.dir_watcher.handle:stop()
        state.dir_watcher.timer:stop()
        state.dir_watcher = nil
    end
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

    if state.config.watch_new_files then
        start_dir_watcher()
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

    stop_dir_watcher()
    vim.api.nvim_clear_autocmds({ group = augroup })

    vim.notify("openfollow: off", vim.log.levels.INFO)
end

local function toggle()
    if state.enabled then disable() else enable() end
end

-- Status (for statusline integration)
local function status()
    if not state.enabled then return "" end
    local count = 0
    for _ in pairs(state.watchers) do count = count + 1 end
    return string.format("👁 %d", count)
end

-- Setup
function M.setup(opts)
    state.config = vim.tbl_deep_extend("force", defaults, opts or {})
    setup_highlights(state.config)

    vim.api.nvim_create_user_command("OpenFollow", enable, { desc = "Start following opencode edits" })
    vim.api.nvim_create_user_command("OpenFollowStop", disable, { desc = "Stop following opencode edits" })
    vim.api.nvim_create_user_command("OpenFollowToggle", toggle, { desc = "Toggle opencode follow mode" })
    vim.api.nvim_create_user_command("OpenFollowStatus", function()
        local count = 0
        for _ in pairs(state.watchers) do count = count + 1 end
        vim.notify(
            string.format("openfollow: %s, watching %d buffers",
                state.enabled and "on" or "off", count),
            vim.log.levels.INFO
        )
    end, { desc = "Show openfollow status" })

    -- Convenience keymap
    vim.keymap.set("n", "<leader>of", toggle, { desc = "Toggle openfollow" })
end

M.enable = enable
M.disable = disable
M.toggle = toggle
M.status = status

return M
