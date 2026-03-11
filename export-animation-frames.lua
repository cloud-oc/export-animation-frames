--[[

导出动画图层帧
批量选中图层 → 导出时间轴上的所有帧为独立图片文件。
支持去重、自动帧率计算、裁切、缩放。

--]]

------------------------------------------------------------------------
-- 辅助函数
------------------------------------------------------------------------

local function getSep(sprite)
    return string.sub(sprite.filename, 1, 1) == "/" and "/" or "\\"
end

local function dirname(str, sep)
    return str:match("(.*" .. sep .. ")")
end

local function removeExtension(str)
    return str:match("(.+)%..+")
end

local function basename(str, sep)
    return str:match("^.*" .. sep .. "(.+)$") or str
end

-- 递归收集所有非组图层
local function collectLayers(layerGroup, result)
    for _, l in ipairs(layerGroup.layers) do
        if l.isGroup then
            collectLayers(l, result)
        elseif not l.isReference then
            table.insert(result, l)
        end
    end
end

-- 帧对比（用于去重）
local function framesAreEqual(cel1, cel2)
    if not cel1 and not cel2 then return true end
    if not cel1 or not cel2 then return false end
    -- 只通过判断图像引用和位置是否一致判断是否为相同帧
    -- 支持 Aseprite 的延长帧(Pill)或链接帧(Linked Cels)去重
    -- 深度像素循环对比会错误去重人工故意分离复制的画格，且大幅拖慢性能
    if cel1.image == cel2.image and cel1.position.x == cel2.position.x and cel1.position.y == cel2.position.y then
        return true
    end
    return false
end

------------------------------------------------------------------------
-- 导出主逻辑
------------------------------------------------------------------------

local function doExport()
    local sprite = app.activeSprite
    if not sprite then
        app.alert("当前没有活动的精灵图。请先打开一个精灵图后再运行。")
        return
    end

    local sep = getSep(sprite)

    if dirname(sprite.filename, sep) == nil then
        app.alert("当前精灵图未关联到文件。请先保存后再运行。")
        return
    end

    -- 收集所有图层
    local allLayers = {}
    collectLayers(sprite, allLayers)

    if #allLayers == 0 then
        app.alert("当前精灵图中没有可导出的图层。")
        return
    end

    -- 构建图层选择下拉选项
    local LAYER_MODE_SELECTED = "已选图层"
    local LAYER_MODE_VISIBLE  = "所有可见图层"
    local LAYER_MODE_ALL      = "所有图层"

    local layerOptions = {LAYER_MODE_SELECTED, LAYER_MODE_VISIBLE, LAYER_MODE_ALL}
    table.insert(layerOptions, "────────────")
    for _, l in ipairs(allLayers) do
        table.insert(layerOptions, l.name)
    end

    local spriteName = removeExtension(basename(sprite.filename, sep))

    -- 主对话框
    local dlg = Dialog("导出动画图层帧")

    dlg:combobox{
        id = "layer_mode",
        label = "导出图层:",
        option = LAYER_MODE_SELECTED,
        options = layerOptions
    }
    dlg:separator{text = "输出设置"}
    local init_file = ""
    if sprite.filename ~= "" then
        init_file = removeExtension(sprite.filename) .. ".png"
    else
        init_file = "export.png"
    end

    dlg:file{
        id = "directory",
        label = "输出位置:",
        filename = init_file,
        save = true,
        title = "选择输出位置和格式",
        filetypes = {"png", "gif", "jpg"}
    }
    dlg:entry{
        id = "filename",
        label = "文件名格式:",
        text = "{mapname}_{layername}_{fps}_{frame}"
    }
    dlg:slider{
        id = "scale",
        label = "导出缩放:",
        min = 1,
        max = 10,
        value = 1
    }
    dlg:check{
        id = "skip_empty",
        label = "跳过空帧:",
        selected = true
    }
    dlg:check{
        id = "skip_duplicates",
        label = "去除重复帧:",
        selected = false
    }
    dlg:check{
        id = "trim",
        label = "裁切到内容:",
        selected = false
    }

    dlg:separator{text = "占位符说明"}
    dlg:label{text = "{mapname}=文件名  {layername}=图层名"}
    dlg:label{text = "{fps}=帧率  {frame}=帧序号"}

    dlg:separator()
    dlg:button{id = "ok", text = "导出"}
    dlg:button{id = "cancel", text = "取消"}
    dlg:show()

    if not dlg.data.ok then return end

    -- 解析输出目录与格式
    local raw_dir = dlg.data.directory
    if raw_dir == nil or raw_dir == "" then
        app.alert("未指定输出目录。")
        return
    end

    local out_format = raw_dir:match("%.([^%./\\]+)$")
    if out_format == nil or out_format == "" then
        out_format = "png"
    else
        out_format = string.lower(out_format)
    end

    local output_path = raw_dir
    local last_char = string.sub(output_path, -1)
    
    -- 若路径与源文件一致，或以常见文件后缀结尾，则去掉文件名部分提取目录
    if output_path == sprite.filename then
        output_path = dirname(output_path, sep) or ""
    elseif app.fs and app.fs.isFile and app.fs.isFile(output_path) then
        output_path = app.fs.filePath(output_path)
    elseif last_char ~= sep and last_char ~= "/" and last_char ~= "\\" and output_path:match("%.[^/%\\]+$") then
        output_path = dirname(output_path, sep) or output_path
    end

    -- 确保目录以分隔符结尾
    last_char = string.sub(output_path, -1)
    if last_char ~= sep and last_char ~= "/" and last_char ~= "\\" then
        output_path = output_path .. sep
    end

    if output_path == "" then
        app.alert("未指定输出目录。")
        return
    end

    os.execute("mkdir \"" .. output_path .. "\"")

    -- 根据选择模式收集图层
    local selectedLayers = {}
    local mode = dlg.data.layer_mode

    if mode == LAYER_MODE_SELECTED then
        if app.range and app.range.layers then
            for _, l in ipairs(app.range.layers) do
                if not l.isGroup and not l.isReference then
                    table.insert(selectedLayers, l)
                end
            end
        end
        if #selectedLayers == 0 and app.activeLayer and not app.activeLayer.isGroup then
            table.insert(selectedLayers, app.activeLayer)
        end
    elseif mode == LAYER_MODE_VISIBLE then
        for _, l in ipairs(allLayers) do
            if l.isVisible then
                table.insert(selectedLayers, l)
            end
        end
    elseif mode == LAYER_MODE_ALL then
        for _, l in ipairs(allLayers) do
            table.insert(selectedLayers, l)
        end
    else
        -- 选中了某个具体图层名称（跳过分隔线）
        if mode ~= "────────────" then
            for _, l in ipairs(allLayers) do
                if l.name == mode then
                    table.insert(selectedLayers, l)
                    break
                end
            end
        end
    end

    if #selectedLayers == 0 then
        app.alert("未选择任何图层。")
        return
    end

    local scale = dlg.data.scale
    local total_exported = 0
    local total_layers = 0
    local skip_duplicates = dlg.data.skip_duplicates
    local skip_empty = dlg.data.skip_empty

    for _, layer in ipairs(selectedLayers) do
        -- 第一遍：收集该图层的唯一帧
        local unique_frames = {}
        local prev_cel = nil

        for i, frame in ipairs(sprite.frames) do
            local cel = layer:cel(frame.frameNumber)

            if not cel then
                if skip_empty then
                    prev_cel = nil -- 空白帧打断去重连续性，重新比对
                    goto scan_continue
                end
            end

            if skip_duplicates and prev_cel ~= nil and framesAreEqual(cel, prev_cel) then
                goto scan_continue
            end

            prev_cel = cel
            table.insert(unique_frames, {index = i, cel = cel})

            ::scan_continue::
        end

        if #unique_frames == 0 then
            goto layer_continue
        end

        -- 计算帧率
        local total_duration_ms = 0
        for _, frame in ipairs(sprite.frames) do
            total_duration_ms = total_duration_ms + frame.duration * 1000
        end

        local fps = math.floor(#unique_frames / (total_duration_ms / 1000) + 0.5)
        if fps < 1 then fps = 1 end

        -- 第二遍：导出
        for seq, frameData in ipairs(unique_frames) do
            local cel = frameData.cel

            local fname = dlg.data.filename
            fname = fname:gsub("{mapname}", spriteName)
            fname = fname:gsub("{layername}", layer.name)
            fname = fname:gsub("{fps}", tostring(fps))
            fname = fname:gsub("{frame}", tostring(seq))
            fname = fname:gsub("{spritename}", spriteName)
            fname = fname .. "." .. out_format

            local tempSprite = Sprite(sprite.width, sprite.height, sprite.colorMode)
            if cel then
                tempSprite.cels[1].image:drawImage(cel.image, cel.position)
            end

            if scale > 1 then
                tempSprite:resize(tempSprite.width * scale, tempSprite.height * scale)
            end

            if dlg.data.trim and cel then
                app.activeSprite = tempSprite
                app.command.AutocropSprite()
            end

            tempSprite:saveCopyAs(output_path .. fname)
            tempSprite:close()

            total_exported = total_exported + 1
        end

        total_layers = total_layers + 1

        ::layer_continue::
    end

    -- 恢复活动精灵图
    app.activeSprite = sprite

    app.alert("已导出 " .. total_layers .. " 个图层，共 " .. total_exported .. " 帧。")
end

------------------------------------------------------------------------
-- 插件入口
------------------------------------------------------------------------

function init(plugin)
    plugin:newCommand{
        id = "ExportAnimationLayerFrames",
        title = "导出动画图层帧...",
        group = "file_export_1",
        onenabled = function()
            return app.activeSprite ~= nil
        end,
        onclick = function()
            doExport()
        end
    }
end

function exit(plugin)
end
