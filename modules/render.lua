-- modified from https://github.com/rkscv/danmaku/blob/main/danmaku.lua
local msg = require('mp.msg')
local utils = require("mp.utils")
local unpack = unpack or table.unpack

local osd_width, osd_height, pause = 0, 0, true
local overlay_low = mp.create_osd_overlay('ass-events')
local overlay_high = mp.create_osd_overlay('ass-events')
local ass_track_path, ass_track_id = nil, nil
local previous_secondary_sid, previous_secondary_visibility, previous_secondary_ass_override = nil, nil, nil
local ass_track_dirty = true
local ass_track_failed = false
local fallback_notified = false
local changing_secondary = false
local active_render_mode = "overlay"
local overlay_render_timer = nil
local overlay_render_interval, overlay_render_deadline = nil, nil
local overlay_sync_profile_active, overlay_sync_external_override = false, false
local overlay_sync_profile_failed = false
local OVERLAY_SYNC_PROFILE = "danmaku-overlay-sync"
local ass_events_low, ass_events_high = {}, {}
local overlay_high_active, overlay_high_previous = {}, {}
local overlay_high_cache_valid = false
local overlay_high_cache_prefix, overlay_high_cache_width, overlay_high_cache_height = nil, nil, nil
local ass_prefix_cache_key, ass_prefix_cache_value = nil, nil
local overlay_clock_media, overlay_clock_wall, overlay_clock_speed = nil, nil, 1
local overlay_clock_seeking, overlay_clock_cache_paused = false, false

local function is_ass_track_mode()
    return active_render_mode == "ass-track"
end

local function get_video_hdr_state()
    local gamma = mp.get_property("video-params/gamma")
    if gamma == nil or gamma == "" then return nil end
    gamma = tostring(gamma):lower()
    return gamma == "pq" or gamma == "hlg"
end

local function needs_hdr_overlay()
    return options.vf_fps == true and get_video_hdr_state() == true
end

local function is_disabled_sid(value)
    if value == nil or value == false then return true end
    local sid = tostring(value):lower()
    return sid == "" or sid == "no" or sid == "auto" or sid == "0" or sid == "false"
end

local function has_external_secondary_subtitle()
    local sid = mp.get_property_native("secondary-sid")
    if is_disabled_sid(sid) then return false end
    return not ass_track_id or tostring(sid) ~= tostring(ass_track_id)
end

local function get_osd_vertical_geometry()
    local width, height = mp.get_osd_size()
    if not width or width <= 0 or not height or height <= 0 then return nil end

    local dimensions = mp.get_property_native('osd-dimensions', {})
    if type(dimensions) ~= 'table' then return width, height, 0, height end
    local dimensions_height = tonumber(dimensions.h)
    local scale_y = dimensions_height and dimensions_height > 0 and height / dimensions_height or 1
    local top = math.max(0, math.min(height, (tonumber(dimensions.mt) or 0) * scale_y))
    local bottom = math.max(0, math.min(height, height - (tonumber(dimensions.mb) or 0) * scale_y))
    if bottom <= top then return width, height, 0, height end
    return width, height, top, bottom
end

local function get_overlay_font_height(width, height)
    local ratio = width / height
    local render_height = 1080
    local font_size = tonumber(options.fontsize) or 50
    if 1920 / 1080 < ratio then
        render_height = 1920 / ratio
        font_size = font_size - ratio * 2
    end
    return math.max(1, font_size * height / render_height)
end

local function should_use_fullscreen_blackbar_overlay()
    if options.fullscreen_blackbar == false then return false end
    if mp.get_property_native('fullscreen') ~= true then return false end

    local width, _, picture_top = get_osd_vertical_geometry()
    if not width then return false end
    return picture_top >= 1
end

local function desired_render_mode()
    local requested = tostring(options.render_mode or "auto"):lower()
    if requested == "overlay" then return "overlay" end
    if requested ~= "auto" and requested ~= "ass-track" then return "overlay" end
    if needs_hdr_overlay() then return "overlay" end
    if ass_track_failed or has_external_secondary_subtitle() then return "overlay" end
    if requested == "auto" and should_use_fullscreen_blackbar_overlay() then return "overlay" end
    return "ass-track"
end

local function resolve_render_mode()
    local requested = tostring(options.render_mode or "auto"):lower()
    active_render_mode = desired_render_mode()
    if requested ~= "overlay" and requested ~= "auto" and requested ~= "ass-track" then
        msg.warn("未知的 render_mode=" .. requested .. "，已使用 overlay")
    end
    return active_render_mode
end

local function clear_array(items)
    for i = #items, 1, -1 do
        items[i] = nil
    end
end

local function invalidate_overlay_high_cache()
    overlay_high_cache_valid = false
    overlay_high_cache_prefix, overlay_high_cache_width, overlay_high_cache_height = nil, nil, nil
    clear_array(overlay_high_active)
    clear_array(overlay_high_previous)
end

local function remove_overlay_high()
    overlay_high:remove()
    invalidate_overlay_high_cache()
end

local function get_overlay_fps()
    local fps = math.max(20, math.min(60, tonumber(options.overlay_fps) or 60))
    local display_fps = mp.get_property_number("display-fps")
    if display_fps and display_fps > 0 then
        fps = math.min(fps, display_fps)
    end
    return math.max(1, fps)
end

local function clear_overlay_clock()
    overlay_clock_media = nil
    overlay_clock_wall = nil
    overlay_clock_speed = 1
end

local function get_overlay_clock_speed()
    local speed = mp.get_property_number('speed', 1) or 1
    local correction = mp.get_property_number('video-speed-correction', 1) or 1
    if correction <= 0 then correction = 1 end
    return speed * correction
end

local function reset_overlay_clock(media_time)
    overlay_clock_media = media_time or mp.get_property_number('time-pos')
    overlay_clock_wall = mp.get_time()
    overlay_clock_speed = get_overlay_clock_speed()
    return overlay_clock_media
end

local function rebase_overlay_clock(speed)
    local now = mp.get_time()
    if overlay_clock_media ~= nil and overlay_clock_wall ~= nil
    and not pause and not overlay_clock_seeking and not overlay_clock_cache_paused then
        overlay_clock_media = overlay_clock_media
            + (now - overlay_clock_wall) * overlay_clock_speed
    else
        overlay_clock_media = mp.get_property_number('time-pos')
    end
    overlay_clock_wall = now
    overlay_clock_speed = tonumber(speed) or get_overlay_clock_speed()
end

local function get_overlay_media_time()
    local media_time = mp.get_property_number('time-pos')
    if media_time == nil then
        clear_overlay_clock()
        return nil
    end

    local speed = get_overlay_clock_speed()
    if overlay_clock_media == nil or overlay_clock_wall == nil then
        return reset_overlay_clock(media_time)
    end

    if speed ~= overlay_clock_speed then
        rebase_overlay_clock(speed)
    end

    if pause or overlay_clock_seeking or overlay_clock_cache_paused then
        return reset_overlay_clock(media_time)
    end

    -- time-pos is quantized to decoded video frames.  Extrapolate from a
    -- monotonic playback anchor so a 60 Hz OSD overlay does not repeat the
    -- same coordinate two or three times on 24/30 fps sources.  Seeking,
    -- pausing, cache stalls and speed changes explicitly rebase this clock.
    return overlay_clock_media + (mp.get_time() - overlay_clock_wall) * overlay_clock_speed
end

local function stop_overlay_timer()
    if overlay_render_timer then
        overlay_render_timer:kill()
    end
    overlay_render_interval, overlay_render_deadline = nil, nil
end

local function run_overlay_timer()
    if pause or not ENABLED or COMMENTS == nil or is_ass_track_mode() then
        stop_overlay_timer()
        return
    end

    render()

    -- Anchor updates to an absolute cadence. mpv's periodic timers schedule
    -- from the actual (possibly late) callback time, so occasional delays can
    -- permanently shift the following frames and make horizontal motion feel
    -- uneven. Skip expired slots, but keep the next valid display deadline.
    local now = mp.get_time()
    repeat
        overlay_render_deadline = overlay_render_deadline + overlay_render_interval
    until overlay_render_deadline > now + 0.001
    overlay_render_timer.timeout = math.max(0.001, overlay_render_deadline - now)
    overlay_render_timer:resume()
end

local function start_overlay_timer()
    if pause or not ENABLED or COMMENTS == nil or is_ass_track_mode() then return end
    reset_overlay_clock()
    overlay_render_interval = 1 / get_overlay_fps()
    overlay_render_deadline = mp.get_time() + overlay_render_interval
    if not overlay_render_timer then
        overlay_render_timer = mp.add_timeout(overlay_render_interval, run_overlay_timer, true)
    end
    overlay_render_timer:kill()
    overlay_render_timer.timeout = overlay_render_interval
    overlay_render_timer:resume()
end

local function write_text_file(path, content)
    local file, err = io.open(path, "wb")
    if not file then
        msg.error("写入 ASS 弹幕文件失败: " .. tostring(err))
        return false
    end
    file:write(content)
    file:close()
    return true
end

local function ass_time(seconds)
    seconds = math.max(0, tonumber(seconds) or 0)
    local cs = math.floor(seconds * 100 + 0.5)
    local h = math.floor(cs / 360000)
    cs = cs - h * 360000
    local m = math.floor(cs / 6000)
    cs = cs - m * 6000
    local s = math.floor(cs / 100)
    cs = cs - s * 100
    return string.format("%d:%02d:%02d.%02d", h, m, s, cs)
end

local function ass_style_color(alpha, color)
    return string.format("&H%s%s&", alpha, color)
end

local function get_ass_track_path()
    local dir = nil
    if mp.command_native then
        dir = mp.command_native({ "expand-path", "~~/cache" })
    end
    dir = dir or DANMAKU_PATH or "."
    return utils.join_path(dir, string.format("uosc-danmaku-%s.ass", PID))
end

local function find_ass_track_id()
    local tracks = mp.get_property_native("track-list") or {}
    for _, track in ipairs(tracks) do
        if track.type == "sub" and (track.title == "uosc_danmaku"
        or track["external-filename"] == ass_track_path) then
            return track.id
        end
    end
    return nil
end

local function clear_saved_secondary_state()
    previous_secondary_sid = nil
    previous_secondary_visibility = nil
    previous_secondary_ass_override = nil
end

local function set_secondary_property(name, value, native)
    if value == nil then return end
    changing_secondary = true
    if native then
        mp.set_property_native(name, value)
    else
        mp.set_property(name, value)
    end
    changing_secondary = false
end

local function unload_ass_track(restore_secondary)
    local track_id = ass_track_id
    ass_track_id = nil
    if track_id then
        pcall(mp.commandv, "sub-remove", track_id)
    end
    if restore_secondary and previous_secondary_sid ~= nil then
        set_secondary_property("secondary-sid", previous_secondary_sid, true)
        set_secondary_property("secondary-sub-visibility", previous_secondary_visibility)
        set_secondary_property("secondary-sub-ass-override", previous_secondary_ass_override)
        clear_saved_secondary_state()
    end
    if ass_track_path and file_exists(ass_track_path) then
        os.remove(ass_track_path)
    end
    ass_track_path = nil
end

local function normalize_event_text(text)
    if not text then return nil end
    text = text:gsub("&#%d+;", "")
    text = text:gsub("\\fs(%d+)", function(size)
        local n = tonumber(size) or 0
        return string.format("\\fs%d", math.floor(n * 1.5))
    end)
    return "{\\an8}" .. text
end

local function event_in_display_area(event, displayarea)
    local y
    if event.move then
        y = event.move[2]
    elseif event.pos then
        y = event.pos[2]
    end
    return not y or tonumber(y) <= 1080 * displayarea
end

local function build_ass_track()
    if not COMMENTS or #COMMENTS == 0 then
        return nil
    end

    local opacity = tonumber(options.opacity)
    local alpha = string.format("%02X", (1 - (opacity or 0)) * 255)
    local bold = options.bold and "-1" or "0"
    local fontsize = tonumber(options.fontsize) or 50
    local outline = tonumber(options.outline) or 0
    local shadow = tonumber(options.shadow) or 0
    local displayarea = tonumber(options.displayarea) or 1

    local lines = {
        "[Script Info]",
        "ScriptType: v4.00+",
        "PlayResX: 1920",
        "PlayResY: 1080",
        "ScaledBorderAndShadow: yes",
        "WrapStyle: 2",
        "",
        "[V4+ Styles]",
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding",
        string.format("Style: Default,%s,%d,%s,%s,&H00000000,&H00000000,%s,0,0,0,100,100,0,0,1,%.2f,%.2f,8,0,0,0,1",
            options.fontname, fontsize, ass_style_color(alpha, "FFFFFF"), ass_style_color(alpha, "FFFFFF"),
            bold, outline, shadow),
        "",
        "[Events]",
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
    }

    for _, event in ipairs(COMMENTS) do
        if event_in_display_area(event, displayarea) then
            local text = normalize_event_text(event.text)
            if text then
                table.insert(lines, string.format("Dialogue: %d,%s,%s,Default,,0,0,0,,%s",
                    tonumber(event.layer) or 0,
                    ass_time(event.start_time),
                    ass_time(event.end_time),
                    text))
            end
        end
    end

    return table.concat(lines, "\n") .. "\n"
end

local function render_ass_track()
    unload_ass_track(false)
    if not COMMENTS or #COMMENTS == 0 then
        ass_track_dirty = false
        return true
    end

    local content = build_ass_track()
    if not content then return true end

    ass_track_path = get_ass_track_path()
    if not write_text_file(ass_track_path, content) then
        ass_track_path = nil
        return false, "write-failed"
    end

    if previous_secondary_sid == nil then
        previous_secondary_sid = mp.get_property_native("secondary-sid") or "no"
        previous_secondary_visibility = mp.get_property("secondary-sub-visibility", "yes")
        previous_secondary_ass_override = mp.get_property("secondary-sub-ass-override", "strip")
    end

    local command_ok, command_err = pcall(mp.commandv, "sub-add", ass_track_path, "auto", "uosc_danmaku")
    if not command_ok then
        unload_ass_track(false)
        return false, command_err or "sub-add-failed"
    end
    ass_track_id = find_ass_track_id()
    if ass_track_id then
        set_secondary_property("secondary-sub-visibility", "yes")
        set_secondary_property("secondary-sub-ass-override", "no")
        set_secondary_property("secondary-sid", ass_track_id, true)
        ass_track_dirty = false
        msg.verbose("ASS 弹幕轨已加载: " .. ass_track_path)
        return true
    else
        unload_ass_track(false)
        return false, "track-not-found"
    end
end

local function switch_to_overlay(reason, preserve_current_secondary)
    ass_track_failed = true
    active_render_mode = "overlay"
    stop_overlay_timer()

    if preserve_current_secondary then
        local visibility = previous_secondary_visibility
        local ass_override = previous_secondary_ass_override
        unload_ass_track(false)
        set_secondary_property("secondary-sub-visibility", visibility)
        set_secondary_property("secondary-sub-ass-override", ass_override)
        clear_saved_secondary_state()
    else
        unload_ass_track(true)
    end

    if reason then
        msg.warn("ASS 弹幕轨不可用，已自动切换到兼容渲染: " .. tostring(reason))
        if not fallback_notified and show_message then
            show_message("弹幕已自动切换兼容模式", 3)
            fallback_notified = true
        end
    end
end

local function get_overlay_event_text(event)
    if event._overlay_text then return event._overlay_text end
    local text = (event.text or ""):gsub("\\move%(.-%)", "")
    text = text:gsub("&#%d+;", "")
    text = text:gsub("\\fs(%d+)", function(size)
        local n = tonumber(size) or 0
        return string.format("\\fs%d", math.floor(n * 1.5))
    end)
    event._overlay_text = text
    return text
end

local function get_ass_prefix(fontname, fontsize, alpha)
    local key = table.concat({
        tostring(fontname), tostring(fontsize), tostring(alpha),
        tostring(options.outline), tostring(options.shadow), tostring(options.bold)
    }, "\0")
    if key ~= ass_prefix_cache_key then
        ass_prefix_cache_key = key
        ass_prefix_cache_value = string.format(
            "{\\rDefault\\fn%s\\fs%d\\c&HFFFFFF&\\alpha&H%s\\bord%s\\shad%s\\b%s\\q2}",
            fontname, fontsize, alpha, options.outline, options.shadow,
            options.bold and "1" or "0")
    end
    return ass_prefix_cache_value
end

local function realtime_position_text(event, pos, displayarea)
    local event_text = get_overlay_event_text(event)
    if not event.move then
        local _, current_y = unpack(event.pos or {})
        if not current_y or tonumber(current_y) > displayarea then return end
        if event.style ~= "SP" and event.style ~= "MSG" then
            return "{\\an8}" .. event_text
        else
            return "{\\an7}" .. event_text
        end
    end

    local x1, y1, x2, y2 = unpack(event.move)
    -- 计算移动的时间范围
    local duration = math.max(0.001, event.end_time - event.start_time)  --mean: options.scrolltime
    local progress = (pos - event.start_time) / duration  -- 移动进度 [0, 1]

    -- 计算当前坐标
    local current_x = tonumber(x1 + (x2 - x1) * progress)
    local current_y = tonumber(y1 + (y2 - y1) * progress)

    -- 移除 \move 标签并应用当前坐标
    if current_y > displayarea then return end
    if event.style ~= "SP" and event.style ~= "MSG" then
        return string.format("{\\pos(%.1f,%.1f)\\an8}%s", current_x, current_y, event_text)
    else
        return string.format("{\\pos(%.1f,%.1f)\\an7}%s", current_x, current_y, event_text)
    end
end

local function static_overlay_ass(event, ass_prefix, displayarea)
    local _, current_y = unpack(event.pos or {})
    if not current_y or tonumber(current_y) > displayarea then return end
    if event._overlay_static_prefix ~= ass_prefix then
        local alignment = (event.style ~= "SP" and event.style ~= "MSG")
            and "{\\an8}" or "{\\an7}"
        event._overlay_static_prefix = ass_prefix
        event._overlay_static_ass = ass_prefix .. alignment .. get_overlay_event_text(event)
    end
    return event._overlay_static_ass
end

function render(pos_arg)
    if COMMENTS == nil then return end
    if is_ass_track_mode() then
        if ass_track_dirty or not ass_track_id then
            local ok, reason = render_ass_track()
            if ok then return end
            switch_to_overlay(reason, false)
        else
            return
        end
    end

    local pos
    if pos_arg == nil then
        pos = get_overlay_media_time()
    else
        pos = pos_arg
    end

    if not pos then
        overlay_low:remove()
        remove_overlay_high()
        return
    end

    local fontname = options.fontname
    local fontsize = options.fontsize
    local opacity = tonumber(options.opacity)
    local alpha = string.format("%02X", (1 - (opacity or 0)) * 255)

    local width, height = 1920, 1080
    local ratio = osd_width / osd_height
    if width / height < ratio then
        height = width / ratio
        fontsize = options.fontsize - ratio * 2
    end

    clear_array(ass_events_low)
    clear_array(ass_events_high)
    clear_array(overlay_high_active)
    local max_display = math.max(options.scrolltime, options.fixtime)
    local window_start = pos - max_display

    -- 跳过已结束的弹幕
    local lo = binary_search(COMMENTS, window_start, function(item) return item.start_time end)

    local ass_prefix = get_ass_prefix(fontname, fontsize, alpha)

    for i = lo, #COMMENTS do
        local event = COMMENTS[i]
        if not event then break end

        if event.start_time > pos then break end  -- 后续弹幕提前退出
        if event.end_time >= pos then
            if event.layer == nil or tonumber(event.layer) == 0 then
                local text = realtime_position_text(event, pos, height * options.displayarea)
                if text then
                    ass_events_low[#ass_events_low + 1] = ass_prefix .. text
                end
            else
                local ass_text = static_overlay_ass(event, ass_prefix, height * options.displayarea)
                if ass_text then
                    overlay_high_active[#overlay_high_active + 1] = event
                end
            end
        end
    end

    -- 写入低层（滚动）和高层（顶/底）overlay，并设置 z 值以控制堆叠
    overlay_low.res_x = width
    overlay_low.res_y = height
    overlay_low.z = 0
    overlay_low.data = table.concat(ass_events_low, '\n')
    overlay_low:update()

    local high_changed = not overlay_high_cache_valid
        or overlay_high_cache_prefix ~= ass_prefix
        or overlay_high_cache_width ~= width
        or overlay_high_cache_height ~= height
        or #overlay_high_active ~= #overlay_high_previous
    if not high_changed then
        for i = 1, #overlay_high_active do
            if overlay_high_active[i] ~= overlay_high_previous[i] then
                high_changed = true
                break
            end
        end
    end
    if high_changed then
        clear_array(ass_events_high)
        clear_array(overlay_high_previous)
        for i = 1, #overlay_high_active do
            local event = overlay_high_active[i]
            ass_events_high[i] = event._overlay_static_ass
            overlay_high_previous[i] = event
        end
        overlay_high.res_x = width
        overlay_high.res_y = height
        overlay_high.z = 1
        overlay_high.data = table.concat(ass_events_high, '\n')
        overlay_high:update()
        overlay_high_cache_valid = true
        overlay_high_cache_prefix = ass_prefix
        overlay_high_cache_width = width
        overlay_high_cache_height = height
    end

    -- Overlay mode rebuilds the moving ASS payload at up to 60 Hz.  A small
    -- incremental collection here prevents those short-lived strings from
    -- accumulating into a larger, visible collection pause every few seconds.
    collectgarbage('step', 32)
end

function render_danmaku(from_menu, no_osd)
    if ENABLED and (from_menu or get_danmaku_visibility()) then
        ass_track_dirty = true
        if not no_osd then
            show_loaded(true)
        end
        toggle_danmaku_switch("on")
        show_danmaku_func()
    else
        show_message("")
        hide_danmaku_func()
    end
end

local function filter_state(label, name)
    local filters = mp.get_property_native("vf") or {}
    for _, filter in pairs(filters) do
        if filter.label == label or filter.name == name
        or (name and filter.params and filter.params[name] ~= nil) then
            return true
        end
    end
    return false
end

local function has_moving_danmaku()
    if type(COMMENTS) ~= "table" then return false end
    for _, event in ipairs(COMMENTS) do
        if event and event.move then return true end
    end
    return false
end

local function restore_overlay_display_sync(reset_override)
    if overlay_sync_profile_active then
        local ok, err = pcall(mp.commandv, "apply-profile", OVERLAY_SYNC_PROFILE, "restore")
        if not ok then
            msg.warn("恢复弹幕 overlay 显示同步失败: " .. tostring(err))
        end
        overlay_sync_profile_active = false
    end
    if reset_override then
        overlay_sync_external_override = false
    end
end

local function overlay_sync_session_active()
    return options.overlay_display_sync == true
        and ENABLED and type(COMMENTS) == "table" and #COMMENTS > 0
        and get_danmaku_visibility() and not is_ass_track_mode()
        and has_moving_danmaku()
end

local function overlay_display_sync_eligible()
    if not overlay_sync_session_active() or filter_state("danmaku") then return false end

    local display_fps = mp.get_property_number("display-fps")
    local video_fps = mp.get_property_number("estimated-vf-fps")
    if not display_fps or display_fps < 58 or not video_fps or video_fps <= 0 then
        return false
    end

    local target_fps = math.min(get_overlay_fps(), display_fps)
    if video_fps >= target_fps - 1 then return false end

    -- Avoid fighting the existing speed-dependent video-sync auto profile.
    local speed = mp.get_property_number("speed", 1) or 1
    return speed >= 0.96 and speed <= 1.04
end

local function sync_overlay_display_mode()
    if not overlay_sync_session_active() then
        restore_overlay_display_sync(true)
        return
    end

    local current = tostring(mp.get_property("video-sync", "audio")):lower()
    if overlay_sync_profile_active and current ~= "display-vdrop" then
        -- The user or another profile changed the mode while we were active.
        -- copy-equal restoration preserves that newer value; do not reapply
        -- until the current overlay session has ended.
        restore_overlay_display_sync(false)
        overlay_sync_external_override = true
        return
    end

    if not overlay_display_sync_eligible() then
        restore_overlay_display_sync(false)
        return
    end
    if overlay_sync_profile_active or overlay_sync_external_override then return end

    -- Existing display-* modes already redraw at the display cadence. Only
    -- upgrade mpv's default audio timing; never override a user-selected mode.
    if current:find("display-", 1, true) == 1 or current ~= "audio" then return end

    local ok, err = pcall(mp.commandv, "apply-profile", OVERLAY_SYNC_PROFILE)
    local applied = ok and tostring(mp.get_property("video-sync", "")):lower() == "display-vdrop"
    if applied then
        overlay_sync_profile_active = true
        overlay_sync_profile_failed = false
        msg.verbose("低帧率 overlay 弹幕已启用显示器同步重绘")
    else
        pcall(mp.commandv, "apply-profile", OVERLAY_SYNC_PROFILE, "restore")
        if not overlay_sync_profile_failed then
            msg.warn("无法启用弹幕 overlay 显示同步: " .. tostring(err or "profile unavailable"))
            overlay_sync_profile_failed = true
        end
    end
end

local function remove_danmaku_fps_filter()
    if filter_state("danmaku") then
        mp.commandv("vf", "remove", "@danmaku")
    end
end

local function sync_danmaku_fps_filter()
	-- Overlay mode owns its own render cadence and must never alter the video
	-- frame rate. Keep this hard guard even if a stale config still says yes.
	if not is_ass_track_mode() then
		remove_danmaku_fps_filter()
		return
	end

    -- Until the source transfer is known, avoid touching the video filter
    -- chain. This prevents a short-lived fps filter from being inserted during
    -- HDR initialization and then removed again once PQ/HLG metadata arrives.
    if not options.vf_fps or get_video_hdr_state() ~= false then
        remove_danmaku_fps_filter()
        return
    end

    local display_fps = mp.get_property_number('display-fps')
    -- container-fps is not changed by our own fps filter. Falling back keeps
    -- streams without a nominal rate compatible with the previous behavior.
    local video_fps = mp.get_property_number('container-fps')
        or mp.get_property_number('estimated-vf-fps')
    if (display_fps and display_fps < 58) or (video_fps and video_fps > 58) then
        remove_danmaku_fps_filter()
        return
    end

    if not filter_state("danmaku", "fps") then
        mp.commandv("vf", "append", string.format("@danmaku:fps=fps=%s", options.fps))
    end
end

function show_danmaku_func()
    mp.set_property_bool(HAS_DANMAKU, type(COMMENTS) == "table" and #COMMENTS > 0)
    set_danmaku_visibility(true)
    resolve_render_mode()
    render()
    if is_ass_track_mode() then
        stop_overlay_timer()
        overlay_low:remove()
        remove_overlay_high()
    elseif not pause then
        start_overlay_timer()
    end
    sync_danmaku_fps_filter()
    sync_overlay_display_mode()
end

function hide_danmaku_func()
    restore_overlay_display_sync(true)
    stop_overlay_timer()
    unload_ass_track(true)
    mp.set_property_bool(HAS_DANMAKU, false)
    set_danmaku_visibility(false)
    overlay_low:remove()
    remove_overlay_high()
    if filter_state("danmaku") then
        mp.commandv("vf", "remove", "@danmaku")
    end
end

function refresh_danmaku_renderer()
    ass_track_dirty = true
    ass_track_failed = false
    fallback_notified = false
    if ENABLED and COMMENTS ~= nil and get_danmaku_visibility() then
        show_danmaku_func()
    end
end

local layout_mode_timer = mp.add_timeout(0.08, function()
    if not ENABLED or COMMENTS == nil or not get_danmaku_visibility() then return end
    local next_mode = desired_render_mode()
    if next_mode == active_render_mode then return end

    stop_overlay_timer()
    if next_mode == "overlay" then
        unload_ass_track(true)
        active_render_mode = "overlay"
        render()
        if not pause then start_overlay_timer() end
        if needs_hdr_overlay() then
            msg.verbose("检测到 HDR 视频，已切换到不修改视频帧率的 overlay 弹幕")
        else
            msg.verbose("检测到全屏顶部黑边，已切换到 overlay 连续布局")
        end
    else
        overlay_low:remove()
        remove_overlay_high()
        active_render_mode = "ass-track"
        ass_track_dirty = true
        render()
        msg.verbose("已恢复原生 ASS 弹幕布局")
    end
	-- Gamma/layout changes can switch from overlay back to the optional ASS
	-- compatibility path asynchronously. Reconcile its legacy fps setting only
	-- after the new mode is active; overlay remains protected by the hard guard.
	sync_danmaku_fps_filter()
    sync_overlay_display_mode()
end, true)

local function schedule_layout_mode_refresh()
    layout_mode_timer:kill()
    layout_mode_timer:resume()
end

local message_overlay = mp.create_osd_overlay('ass-events')
message_overlay.z = 2100
local message_timer = mp.add_timeout(3, function()
    message_overlay:remove()
end, true)

function show_message(text, time)
    message_timer.timeout = time or 3
    message_timer:kill()
    message_overlay:remove()
    local message = string.format("{\\an%d\\pos(%d,%d)}%s", options.message_anlignment,
       options.message_x, options.message_y, text)
    local width, height = 1920, 1080
    local ratio = osd_width / osd_height
    if width / height < ratio then
        height = width / ratio
    end
    message_overlay.res_x = width
    message_overlay.res_y = height
    message_overlay.data = message
    message_overlay:update()
    message_timer:resume()
end

mp.observe_property('osd-width', 'number', function(_, value)
    osd_width = value or osd_width
    schedule_layout_mode_refresh()
end)
mp.observe_property('osd-height', 'number', function(_, value)
    osd_height = value or osd_height
    schedule_layout_mode_refresh()
end)
mp.observe_property('osd-dimensions', 'native', function()
    schedule_layout_mode_refresh()
end)
mp.observe_property('fullscreen', 'bool', function()
    schedule_layout_mode_refresh()
end)
mp.observe_property('video-params/gamma', 'string', function()
    local active = ENABLED and COMMENTS ~= nil and get_danmaku_visibility()
    if active then
        sync_danmaku_fps_filter()
        schedule_layout_mode_refresh()
    elseif get_video_hdr_state() ~= false then
        remove_danmaku_fps_filter()
    end
    sync_overlay_display_mode()
end)
mp.observe_property('display-fps', 'number', function() sync_overlay_display_mode() end)
mp.observe_property('estimated-vf-fps', 'number', function() sync_overlay_display_mode() end)
mp.observe_property('container-fps', 'number', function()
    if ENABLED and COMMENTS ~= nil and get_danmaku_visibility() then
        sync_danmaku_fps_filter()
    end
end)
mp.observe_property('display-hidpi-scale', 'number', function() schedule_layout_mode_refresh() end)
mp.observe_property('pause', 'bool', function(_, value)
    if value ~= nil then
        pause = value
    end
    if ENABLED then
        if pause then
            reset_overlay_clock()
            stop_overlay_timer()
        elseif COMMENTS ~= nil and not is_ass_track_mode() then
            reset_overlay_clock()
            render()
            start_overlay_timer()
        end
    end
end)

mp.observe_property('speed', 'number', function(_, value)
    if value ~= nil then
        rebase_overlay_clock()
    end
    sync_overlay_display_mode()
end)

mp.observe_property('video-speed-correction', 'number', function(_, value)
    if value ~= nil then
        rebase_overlay_clock()
    end
end)

mp.observe_property('seeking', 'bool', function(_, value)
    overlay_clock_seeking = value == true
    reset_overlay_clock()
end)

mp.observe_property('paused-for-cache', 'bool', function(_, value)
    overlay_clock_cache_paused = value == true
    reset_overlay_clock()
end)

mp.observe_property('secondary-sid', 'native', function(_, value)
    if changing_secondary or not ass_track_id or not is_ass_track_mode() then return end
    if tostring(value) == tostring(ass_track_id) then return end

    switch_to_overlay(nil, true)
    if ENABLED and COMMENTS ~= nil and get_danmaku_visibility() then
        msg.verbose("检测到用户选择第二字幕，弹幕已切换到 overlay")
        sync_overlay_display_mode()
        render()
        start_overlay_timer()
        show_message("检测到双字幕，弹幕已切换兼容模式", 3)
    end
end)

mp.register_event('playback-restart', function(event)
    if event.error then
        return msg.error(event.error)
    end
    if ENABLED and COMMENTS ~= nil then
        if not is_ass_track_mode() then
            reset_overlay_clock()
            render()
        end
    end
end)

mp.add_hook("on_unload", 50, function()
    COMMENTS, DELAY = nil, 0
    restore_overlay_display_sync(true)
    stop_overlay_timer()
    unload_ass_track(true)
    ass_track_dirty = true
    ass_track_failed = false
    fallback_notified = false
    active_render_mode = "overlay"
    clear_overlay_clock()
    overlay_clock_seeking, overlay_clock_cache_paused = false, false
    ass_prefix_cache_key, ass_prefix_cache_value = nil, nil
    clear_array(ass_events_low)
    clear_array(ass_events_high)
    overlay_low:remove()
    remove_overlay_high()
    mp.set_property_bool(HAS_DANMAKU, false)
    mp.set_property_native(DELAY_PROPERTY, 0)
    if filter_state("danmaku") then
        mp.commandv("vf", "remove", "@danmaku")
    end

    local files_to_remove = {
        file1 = utils.join_path(DANMAKU_PATH, "temp-" .. PID .. ".mp4"),
        file2 = get_ass_track_path(),
    }

    if options.save_danmaku then
        save_danmaku(true)
    end

    for _, file in pairs(files_to_remove) do
        if file_exists(file) then
            os.remove(file)
        end
    end

    DANMAKU = {sources = {}, count = 1}
    mp.set_property_native(DANMAKU_COUNT, 0)
    refresh_danmaku_button()
end)
