local UEHelpers = require("UEHelpers")
local session = assert(os.getenv("RIVER_ASSISTANT_SESSION"), "Missing assistant session")
local solver = dofile(assert(os.getenv("RIVER_ASSISTANT_SOURCE")) .. "/solver.lua")
local probe_path = os.getenv("RIVER_ASSISTANT_PROBE")
local probe = probe_path and probe_path ~= "" and dofile(probe_path) or nil
local mode = os.getenv("RIVER_ASSISTANT_MODE")
local managed = mode == "campaign" or mode == "trial"
local locked_level = os.getenv("RIVER_ASSISTANT_TARGET") or ""
local locked_world = os.getenv("RIVER_ASSISTANT_WORLD") or ""
local misses = tonumber(os.getenv("RIVER_ASSISTANT_MISSES")) or 0
local stop_path = os.getenv("RIVER_ASSISTANT_STOP")

local attempts, cleared, cleared_count = {}, {}, 0
local skipped, selected, replay_level = {}, nil, nil
local attempt_number, full_worlds = 0, {}
local world_id, phase, detail = nil, "waiting", ""
local current_level, current_score, remaining = "", 0, 0
local thresholds
local pending, failed_moves, stall_count, shape_cache = nil, {}, 0, {}
local monument_targets = {}
local next_action, end_started, last_status = 0, nil, nil
local gate_pending = false
local command, epoch = "", ""
local retry_limit = 6
local back_button = "BndEvt__WID_EndScreen_WID_Button_K2Node_ComponentBoundEvent_0_OnClicked__DelegateSignature"
local world_path = "/Game/EmpireBuilder/Game/Levels/Build/World_%s/LevelSelect/LVL_LevelSelect_World%s"
local saves_class = "/Game/EmpireBuilder/Utils/BP_SaveGame_ExpandedBlueprintFunctionLibrary.Default__BP_SaveGame_ExpandedBlueprintFunctionLibrary_C"
local gameplay_class = "/Game/EmpireBuilder/Utils/BP_Gameplay_ExpandedBlueprintFunctionLibrary.Default__BP_Gameplay_ExpandedBlueprintFunctionLibrary_C"

local function present(object)
    return type(object) == "userdata" and type(object.IsValid) == "function" and object:IsValid()
end

local function unwrap(value)
    if type(value) == "userdata" then
        local kind = value:type()
        if kind == "LocalUnrealParam" or kind == "RemoteUnrealParam" then return value:get() end
    end
    return value
end

local function object_name(object)
    return present(object) and object:GetFName():ToString() or ""
end

local function world_objects(class, world, subsystem)
    local result = {}
    for _, object in ipairs(FindAllOf(class) or {}) do
        if present(object) then
            local owner = subsystem and object:GetOuter() or object:GetWorld()
            if present(owner) and owner:GetAddress() == world:GetAddress() then
                result[#result + 1] = object
            end
        end
    end
    return result
end

local function widget(class)
    for _, object in ipairs(FindAllOf(class) or {}) do
        if present(object) and object:GetFullName():find("/Engine/Transient.", 1, true)
                and object:IsVisible() then
            return object
        end
    end
end

local function stars(score)
    if not thresholds then return 0 end
    for star = 3, 1, -1 do
        if score >= thresholds[star] then return star end
    end
    return 0
end

local function write_status()
    local activity = detail
    if activity == "" and selected and selected.level == current_level then
        activity = selected.activity
    end
    local safe_detail = tostring(activity):gsub("[\t\r\n]", " ")
    local data = table.concat({
        phase, current_level, current_score, remaining, cleared_count,
        stars(current_score), thresholds and thresholds[3] or "", safe_detail,
    }, "\t")
    if data == last_status then return end
    local file = io.open(session .. "/status.tsv", "w")
    if file then
        file:write(data, "\n")
        file:close()
        last_status = data
    end
end

local function event(kind, level, value)
    local file = io.open(session .. "/events.tsv", "a")
    if not file then return end
    file:write(kind, "\t", level, "\t", tostring(value or ""), "\n")
    file:close()
end

local function read_command()
    local file = io.open(session .. "/control.txt", "r")
    if not file then return end
    local line = file:read("*l") or ""
    file:close()
    local serial, action = line:match("^(%S+)%s+(%a+)%s*$")
    if serial and serial ~= epoch then
        epoch, command = serial, action
        if action == "run" then
            if phase == "blocked" then pending, failed_moves, stall_count, next_action, gate_pending = nil, {}, 0, 0, false end
            phase, detail, end_started = "ready", "", nil
        elseif action == "pause" then
            phase, detail = "paused", ""
        end
    end
end

local function fail(message)
    phase, detail, command = "blocked", message, "pause"
    event("blocked", current_level, tostring(message):gsub("[\t\r\n]", " "))
end

local function placement(x, y, rotation)
    return {Location = {X = x, Y = y}, Rotation = rotation}
end

local function score_goals(world)
    local lib = StaticFindObject(gameplay_class)
    local row, found = {}, {}
    lib:GetCurrentLevelData(world, row, found)
    local scores = row.Score_48_71A74AD3415C97FD261A348AE3A32A77
    if not found.Found or not scores then return end
    local goals = {
        scores.OneStarThreshold_2_5B9E4E95423FC83E56466EB6195BEDCB,
        scores.TwoStarThreshold_6_0BB2EE9F46F1FE6B717C5F96FCEA8151,
        scores.ThreeStarThreshold_7_9C4904E24A7C7DBC5279AFA3E4C35357,
    }
    if type(goals[1]) == "number" and type(goals[2]) == "number" and type(goals[3]) == "number" then
        return goals
    end
end

local function classify(descriptor, actor)
    local label = object_name(descriptor):lower() .. " " .. object_name(actor):lower()
    local kind = descriptor.DistrictType
    local district = type(kind) == "number" and kind >= 0 and kind <= 2 and kind or nil
    local connector = kind == 3 or kind == 4
        or label:find("wildcard") ~= nil or label:find("bridge") ~= nil or label:find("road") ~= nil
    local neighbor = descriptor.NeighbourScore
    local cover, touch = 0, 0
    local geyser, geyser_active = false, false
    local is_parts = label:find("parts") ~= nil
    local treasure = label:find("treasure") ~= nil or label:find("gold") ~= nil
    local crumbling = label:find("buildingmaterials") ~= nil
    local ruin_floors
    if crumbling and present(actor) and type(actor.Floors) == "number" and type(actor.FloorsSquished) == "number" then
        ruin_floors = math.max(1, actor.Floors - actor.FloorsSquished)
    end
    if treasure then cover = 10
    elseif crumbling then cover = 30
    elseif label:find("geyser") and not label:find("mother") then
        local squished = present(actor) and actor.HasBeenSquished == true
        if not squished then
            geyser = true
            geyser_active = not present(actor) or actor.IsActive ~= false
        end
    elseif label:find("crate") then cover = 8 end
    if not is_parts then
        if label:find("tree") then
            local alive = not present(actor) or (actor.IsGrown ~= true and actor.HasBeenSquished ~= true)
            if alive then
                touch = 4.5
                cover = -45
            end
        elseif label:find("temple") or label:find("lighthouse") then touch = 5
        elseif label:find("ruin") then touch = 1.5 end
    end
    local solid = not descriptor.CanBeSquished
    if geyser_active then solid = false end
    local church = label:find("native_church", 1, true) ~= nil
    local lighthouse_part = is_parts and present(actor)
        and object_name(actor:GetClass()):find("BP_LighthouseParts", 1, true) == 1
    local large_tree = label:find("largetree", 1, true) ~= nil
    return {
        district = district, connector = connector, building = district ~= nil or connector,
        start = object_name(descriptor) == "GridEntity_Start",
        water = label:find("river") ~= nil, solid = solid,
        neighbor = type(neighbor) == "number" and neighbor or 0,
        cover = cover, touch = touch, geyser = geyser, geyser_active = geyser_active,
        geyser_order = geyser and present(actor) and tonumber(actor.GeyserOrder) or nil,
        actor = present(actor) and actor:GetAddress() or nil,
        lighthouse_part = lighthouse_part,
        tree_points = large_tree and 80 or 20,
        corruption = label:find("corruption", 1, true) ~= nil,
        crate = label:find("crate", 1, true) ~= nil,
        treasure = treasure,
        ruin_floors = ruin_floors,
        road = label:find("dirtroad", 1, true) ~= nil,
        temple_part = is_parts and not lighthouse_part
            and (label:find("templeparts") or label:find("lighthouse_parts")) ~= nil,
        objective = church and "church" or ((not is_parts) and
            (label:find("temple") and "temple" or (label:find("tree") and "tree"
                or (label:find("lighthouse") and "lighthouse" or nil))) or nil),
    }
end

local function cell_index(board, cell)
    if cell.X >= 0 and cell.Y >= 0 and cell.X < board.width and cell.Y < board.height then
        return cell.Y * board.width + cell.X + 1
    end
end

local function register_objective(board, tile, cells, anchor, required)
    if tile.objective == "tree" then tile.cover = -45 end
    tile.touch = 0
    local need = type(required) == "number" and required > 0 and math.min(required, #cells) or #cells
    local objective = {cells = cells, need = need, kind = tile.objective, anchor = anchor, tile = tile,
        district = tile.objective == "church" and 0 or nil}
    board.objectives[#board.objectives + 1] = objective
    for _, index in ipairs(cells) do
        local related = board.objectives_at[index] or {}
        related[#related + 1] = objective
        board.objectives_at[index] = related
    end
end

local function open_border(board, footprint)
    local dirs = {{-1, 0}, {1, 0}, {0, -1}, {0, 1}}
    local cells, seen = {}, {}
    for _, index in ipairs(footprint) do seen[index] = true end
    for _, index in ipairs(footprint) do
        local x, y = (index - 1) % board.width, (index - 1) // board.width
        for _, d in ipairs(dirs) do
            local nx, ny = x + d[1], y + d[2]
            if nx >= 0 and nx < board.width and ny >= 0 and ny < board.height then
                local near = ny * board.width + nx + 1
                local t = board.tiles[near]
                if not seen[near] and (not t or t.building or t.geyser or not t.solid) then
                    cells[#cells + 1], seen[near] = near, true
                end
            end
        end
    end
    return cells
end

local function add_objective(board, actor, tile, footprint)
    local anchor = footprint[1]
    if tile.objective == "church" then
        local cells = open_border(board, footprint)
        if #cells > 0 then register_objective(board, tile, cells, anchor, 1) end
        return
    end
    if tile.objective == "lighthouse" then
        local cells = monument_targets[tile.actor] or board.lighthouse_parts
        monument_targets[tile.actor] = cells
        if #cells > 0 then register_objective(board, tile, cells, anchor) end
        return
    end
    if actor.IsGrown == true or actor.HasBeenSquished == true then tile.touch = 0; return end
    if tile.objective == "tree" then tile.cover = -45 end
    local neighbors = actor.NeighbourCells
    local cells, seen = {}, {}
    if type(neighbors) == "userdata" and neighbors:type() == "TArray" then
        for i = 1, #neighbors do
            local index = cell_index(board, unwrap(neighbors[i]))
            if index and not seen[index] then
                seen[index] = true
                cells[#cells + 1] = index
            end
        end
    end
    if #cells == 0 then
        -- 树被间歇泉等实体围住时 NeighbourCells 为空，载入完棋盘后按四邻补算。
        if tile.objective == "tree" then
            board.pending_trees[#board.pending_trees + 1] = {tile = tile, anchor = anchor}
        end
        return
    end
    local required = actor.CellsNeeded
    if tile.objective == "temple" then
        local parts = monument_targets[tile.actor]
        if parts == nil then
            parts = {}
            for _, cell in ipairs(cells) do
                if board.tiles[cell] and board.tiles[cell].temple_part then parts[#parts + 1] = cell end
            end
            if #parts == 0 or (type(required) == "number" and #parts < required) then parts = false end
            monument_targets[tile.actor] = parts
        end
        -- 修复格被建筑覆盖后庙宇仍需计入它们，保留本局最初读到的位置。
        if parts then cells, required = parts, #parts end
    end
    register_objective(board, tile, cells, anchor, required)
end

local function resolve_pending_trees(board)
    for _, item in ipairs(board.pending_trees) do
        local cells = open_border(board, {item.anchor})
        if #cells > 0 then register_objective(board, item.tile, cells, item.anchor) end
    end
end

local function get_board(grid, forecast_ruins)
    local board = {
        width = grid.GridColumns, height = grid.GridRows, tiles = {},
        objectives = {}, objectives_at = {}, geysers = {}, geyser_total = 0, geyser_active_total = 0,
        geyser_cells = {}, pending_trees = {}, lighthouse_parts = {}, river_cells = {},
        forecast_ruins = forecast_ruins, corruption_sources = {},
    }
    local objectives = {}
    for _, item in ipairs(grid:GetAllGridActors()) do
        local actor = unwrap(item)
        if present(actor) and present(actor.GridEntityDescriptor) then
            local category = classify(actor.GridEntityDescriptor, actor)
            if forecast_ruins and category.corruption and object_name(actor:GetClass()) == "BP_InitialCorruption_C"
                    and actor.CorruptionBlocked ~= true then
                local source = actor.CorruptedCells
                if type(source) == "userdata" and source:type() == "TArray" and #source > 0 then
                    local cells = {}
                    for i = 1, #source do
                        local index = cell_index(board, unwrap(source[i]))
                        if index then cells[#cells + 1] = index end
                    end
                    if #cells > 0 then board.corruption_sources[#board.corruption_sources + 1] = cells end
                end
            end
            local footprint = {}
            for _, point in ipairs(grid:GetGridActorCells(actor)) do
                local index = cell_index(board, unwrap(point))
                if index then
                    if category.water then board.river_cells[index] = category end
                    if category.objective then footprint[#footprint + 1] = index end
                    if category.lighthouse_part then board.lighthouse_parts[#board.lighthouse_parts + 1] = index end
                    local old = board.tiles[index]
                    if not old or category.building or category.start
                            or (not old.building and not old.start and category.solid) then
                        board.tiles[index] = category
                    end
                    if category.geyser_active then
                        board.geysers[index] = category.actor or index
                    end
                    if category.geyser then
                        board.geyser_cells[#board.geyser_cells + 1] = {
                            index = index, order = category.geyser_order or -1, active = category.geyser_active,
                        }
                    end
                end
            end
            if category.geyser then board.geyser_total = board.geyser_total + 1 end
            if category.geyser_active then board.geyser_active_total = board.geyser_active_total + 1 end
            if #footprint > 0 then objectives[#objectives + 1] = {actor, category, footprint} end
        end
    end
    for _, entry in ipairs(objectives) do add_objective(board, table.unpack(entry)) end
    resolve_pending_trees(board)
    local temples = 0
    for _, goal in ipairs(board.objectives) do
        if goal.kind == "temple" then temples = temples + 1 end
    end
    local mult = 1 + 0.2 * temples
    for _, goal in ipairs(board.objectives) do
        -- 庙宇完成后乘数增加 0.2，用三星门槛换算本局中这个乘数的大致价值；树复苏给 20 基础分。
        if goal.kind == "lighthouse" then goal.reward = (thresholds and thresholds[3] or 300) / 3
        elseif goal.kind == "church" then goal.reward = 50 * mult
        elseif goal.kind == "tree" then goal.reward = goal.tile.tree_points * mult
        else goal.reward = (thresholds and thresholds[3] or 300) * 0.2 / mult end
    end
    return board
end

-- 多色拼块的格子顺序随旋转保留，各部分分别参与对应街区的连片计分。
local mixed_districts = {
    DA_Multishape_LabRes_Donut = "22221111",
    DA_Multishape_LabRes_DoubleBox = "1111222",
    DA_Multishape_LabRes_DoubleT = "11112222",
    DA_Multishape_LabRes_ThickS = "111222",
    DA_Multishape_LabRes_ThickZ = "111222",
}

local function get_piece(grid, descriptor)
    if not present(descriptor) then return nil end
    local key = descriptor:GetAddress()
    if shape_cache[key] then return shape_cache[key] end
    local piece = classify(descriptor)
    local name = object_name(descriptor)
    piece.sapling = name == "DA_SaplingTree"
    if name:find("DA_Multishape_", 1, true) == 1 then
        piece.building, piece.solid, piece.neighbor = true, true, math.max(1, piece.neighbor)
    end
    piece.cover, piece.touch = 0, 0
    piece.rotations = {}
    for rotation = 0, 3 do
        local offsets = {}
        local points = grid:GetGridShapeCellsOnWorldGrid(descriptor, placement(0, 0, rotation))
        for i = 1, #points do
            local point = unwrap(points[i])
            offsets[i] = {x = point.X, y = point.Y}
        end
        if #offsets == 0 then return nil end
        piece.rotations[rotation + 1] = offsets
    end
    local colours = mixed_districts[name]
    if colours and #colours == #piece.rotations[1] then
        piece.connector = false
        piece.district_area = {[1] = 0, [2] = 0}
        piece.district_rotations = {}
        piece.district_tiles = {
            [1] = {district = 1, building = true, solid = true, neighbor = piece.neighbor, touch = 0, cover = 0},
            [2] = {district = 2, building = true, solid = true, neighbor = piece.neighbor, touch = 0, cover = 0},
        }
        for rotation, offsets in ipairs(piece.rotations) do
            local parts = {[1] = {}, [2] = {}}
            for i, offset in ipairs(offsets) do
                local district = tonumber(colours:sub(i, i))
                local part = parts[district]
                part[#part + 1] = offset
            end
            piece.district_rotations[rotation] = parts
        end
        for district, part in pairs(piece.district_rotations[1]) do piece.district_area[district] = #part end
    end
    shape_cache[key] = piece
    return piece
end

local function neighbor_preview(world, board)
    for _, scorer in ipairs(FindAllOf("AutoScoring_NeighbourScoring_C") or {}) do
        if present(scorer) then
            local owner = scorer:GetOuter()
            local level = present(owner) and owner:GetOuter()
            if present(level) and level:GetAddress() == world:GetAddress() then
                return function(move)
                    local cells = {}
                    for i, cell in ipairs(move.cells) do
                        cells[i] = {X = (cell - 1) % board.width, Y = (cell - 1) // board.width}
                    end
                    local points = {}
                    scorer:CalculateScore(cells, {}, points, {}, {})
                    return points.Score
                end
            end
        end
    end
end

local function close_tutorial(world)
    local busy = false
    for _, popup in ipairs(world_objects("BP_TutorialPopup_C", world)) do
        if popup.IsShown then
            busy = true
            if popup.CanBeClosed then popup:DestroyPopup() end
        end
    end
    return busy
end

local function go_to(option, activity)
    local target, level = option.target, option.level
    attempts[level] = (attempts[level] or 0) + 1
    attempt_number = attempt_number + 1
    selected = {
        level = level, activity = activity, world = current_level:match("World(%d%d)$"),
        number = attempt_number, variant = managed and misses or attempts[level] - 1,
    }
    target:Select(false)
    target:Start()
    phase, detail, next_action = "travel", activity, os.time() + 5
    event("enter", level, attempts[level])
    event("select", level, activity)
end

local function open_world(world, number)
    local gameplay = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    gameplay:OpenLevel(world, FName(world_path:format(number, number), 1), true, "")
end

local function cross_gate(world, gate)
    if gate_pending then fail("world-transition"); return end
    local out = {}
    UEHelpers.GetGameInstance():GetNextWorld(out)
    local name = out.NextWorld
    if type(name) ~= "string" or name == "" then
        name = gate.WorldData.NextWorld_49_E38BC9084D2A7AAC445CDCB5E6EADAD4
    end
    if type(name) == "userdata" and type(name.ToString) == "function" then name = name:ToString() end
    local number = type(name) == "string" and name:match("LVL_LevelSelect_World(%d%d)$")
    local current = current_level:match("World(%d%d)$")
    if not number or not current or tonumber(number) ~= tonumber(current) + 1 then
        fail("world-transition")
        return
    end
    -- 游戏已判定世界门解锁，本地模式直接载入下一张选关地图。
    local saves = StaticFindObject(saves_class)
    saves:SaveHasTraveledThroughGate(current_level, world)
    open_world(world, number)
    gate_pending = true
    phase, detail, next_action = "travel", "gate", os.time() + 18
    event("gate", current_level, number)
end

local function skip_level(level, saved_stars)
    if skipped[level] then return end
    skipped[level] = true
    event("skip", level, saved_stars)
end

local function campaign_select(world)
    local number = current_level:match("World(%d%d)$")
    local total, gold, options, locked = 0, 0, {}, nil
    for _, target in ipairs(world_objects("BP_LevelSelectWorldObject_C", world)) do
        local level = target:GetLevelName():ToString()
        if not target.IsCompetitionLevel and level ~= "None" then
            local option = {target = target, level = level}
            local saved_stars = target.StarCount
            total = total + 1
            if saved_stars >= 3 then
                gold = gold + 1
                skip_level(level, saved_stars)
            elseif target.IsUnlocked then
                options[#options + 1] = option
            end
            if level == locked_level then
                locked = {option = option, stars = saved_stars, unlocked = target.IsUnlocked}
            end
        end
    end
    if total == 0 then fail("campaign-catalog-empty"); return end
    if mode == "trial" or (locked_level ~= "" and locked_world == number) then
        if not locked then fail("campaign-target-missing"); return end
        if mode == "trial" or locked.stars < 3 then
            if not locked.unlocked then fail("campaign-target-locked"); return end
            go_to(locked.option, misses > 0 and "retry" or "upgrade")
            return
        end
        locked_level, locked_world, misses = "", "", 0
    end
    if gold < total then
        if locked_level ~= "" then fail("campaign-progress-changed"); return end
        table.sort(options, function(a, b) return a.level < b.level end)
        if not options[1] then fail("campaign-no-unlocked-level"); return end
        go_to(options[1], options[1].target.IsCompleted and "upgrade" or "new-level")
        return
    end
    full_worlds[number] = total
    event("coverage", number, total)
    if number == "04" then
        local count = 0
        for i = 1, 4 do
            local done = full_worlds[string.format("%02d", i)]
            if not done then fail("campaign-unverified-world"); return end
            count = count + done
        end
        phase, detail, command = "finished", tostring(count), "hold"
        return
    end
    for _, gate in ipairs(world_objects("BP_LevelSelectGate_C", world)) do
        if gate.IsUnlocked then cross_gate(world, gate); return end
    end
    fail("campaign-gate-locked")
end

local function level_select(world)
    if managed then campaign_select(world); return end
    local unplayed, upgrades, retries = {}, {}, {}
    local replay
    local unfinished = 0
    for _, target in ipairs(world_objects("BP_LevelSelectWorldObject_C", world)) do
        local level = target:GetLevelName():ToString()
        if not target.IsCompetitionLevel and level ~= "None" then
            local saved_stars = target.StarCount
            if saved_stars >= 3 then
                skip_level(level, saved_stars)
            else
                local completed = target.IsCompleted
                if not completed then unfinished = unfinished + 1 end
                local tries = attempts[level] or 0
                if target.IsUnlocked and tries < retry_limit then
                    local option = {target = target, level = level, stars = saved_stars, tries = tries}
                    if level == replay_level and tries == 1 then
                        replay = option
                    elseif tries == 0 then
                        local queue = completed and upgrades or unplayed
                        queue[#queue + 1] = option
                    else
                        retries[#retries + 1] = option
                    end
                end
            end
        end
    end
    replay_level = nil
    if replay then
        go_to(replay, "retry")
        return
    end
    table.sort(upgrades, function(a, b) return a.level < b.level end)
    table.sort(unplayed, function(a, b) return a.level < b.level end)
    local next_level = upgrades[1] or unplayed[1]
    if next_level then
        go_to(next_level, upgrades[1] and "upgrade" or "new-level")
        return
    end
    if current_level:match("World04$") and unfinished == 0 then
        phase, detail, command = "finished", "campaign", "pause"
        return
    end
    for _, gate in ipairs(world_objects("BP_LevelSelectGate_C", world)) do
        if gate.IsUnlocked then
            cross_gate(world, gate)
            return
        end
    end
    table.sort(retries, function(a, b)
        if a.stars ~= b.stars then return a.stars < b.stars end
        if a.tries ~= b.tries then return a.tries < b.tries end
        return a.level < b.level
    end)
    if retries[1] then
        go_to(retries[1], "gate-retry")
    else
        fail("gate-locked")
    end
end

local function return_to_map(screen)
    screen[back_button](screen, screen.LevelSelectButton)
    phase, detail, next_action = "travel", "return", os.time() + 12
end

local function log_score_parts(scoring)
    for _, item in ipairs(scoring:GetAddScoringFunctions() or {}) do
        local rule = unwrap(item)
        if present(rule) then event("score-part", object_name(rule:GetClass()), rule.Score) end
    end
    for _, item in ipairs(scoring:GetMultiplierScoringFunctions() or {}) do
        local rule = unwrap(item)
        if present(rule) then event("multiplier", object_name(rule:GetClass()), rule.Multiplier) end
    end
end

local function ending(world, controller, score, scoring)
    phase, detail = "settling", ""
    if not end_started then end_started = {time = os.time(), counted = false} end
    local duration = os.time() - end_started.time
    if duration > 55 then fail("settlement-timeout"); return end
    local screen = widget("WID_EndScreen_C")
    if not screen or not present(screen.LevelSelectButton) then return end
    if controller.DoingScoreCountup then end_started.counted = true; return end
    if duration < 3 or (not end_started.counted and duration < 8)
            or not screen.EndButtons:IsVisible() or not screen.LevelSelectButton:IsVisible() then return end
    local total = screen:GetCurrentTotal()
    if type(total) == "number" then score = math.max(score, total) end
    local recorded = {}
    local saves = StaticFindObject(saves_class)
    if present(saves) then saves:GetCurrentLevelScore(world, recorded) end
    if score > 0 and (recorded.Score or 0) < score then
        if duration > 40 then fail("score-not-saved") end
        return
    end
    if (recorded.Score or 0) > 0 and not cleared[current_level] then
        cleared[current_level], cleared_count = true, cleared_count + 1
    end
    event("settled", current_level, score)
    event("recorded", current_level, recorded.Score or 0)
    if thresholds then
        local achieved = stars(recorded.Score or 0)
        event("stars", current_level, achieved .. "/3 " .. (recorded.Score or 0) .. "/" .. thresholds[3])
        if achieved < 3 and attempts[current_level] == 1 then replay_level = current_level end
    end
    if managed then
        if not (selected and selected.level == current_level and thresholds and thresholds[3] > 0) then
            fail("campaign-score-unavailable")
            return
        end
        local best = recorded.Score or 0
        log_score_parts(scoring)
        event("result", current_level, string.format("%d,%s,%d,%d,%d,%d,%d",
            selected.number, selected.world, score, best, thresholds[3], stars(score), stars(best)))
        end_started.reported = true
        phase, detail, command = "awaiting", "saved", "hold"
        return
    end
    return_to_map(screen)
end

local function play(world, controller)
    local state, cursor = controller.PlayerState, controller.WorldCursor
    local grid = world_objects("GameWorldGrid", world, true)[1]
    local scoring = world_objects("ScoreSubsystem", world, true)[1]
    if not (present(state) and present(cursor) and grid and scoring) then return end
    local stack = state.ShapeStack
    remaining = #stack
    current_score = scoring:CalculateTotalScore()
    if not thresholds then thresholds = score_goals(world) end
    local mode = world.AuthorityGameMode
    if present(mode) and mode.bHasGameEnded == true then
        ending(world, controller, current_score, scoring)
        return
    end
    if probe and probe.on_play then pcall(probe.on_play, session, world, controller, state, cursor, grid, scoring, remaining) end
    phase, detail = "solving", ""
    if close_tutorial(world) then return end
    if state.bIsInScoringSequence or cursor.PlaceShapeTimeline:IsPlaying() then return end
    if controller.BlockCanPlaceShape == true then return end
    local descriptor = state:PeekNextShape()
    if pending then
        if remaining ~= pending.count or not present(descriptor) or descriptor:GetAddress() ~= pending.descriptor then
            cursor:SetIsPlacePressed(false)
            pending, failed_moves, stall_count = nil, {}, 0
        elseif os.time() <= pending.deadline then
            return
        else
            cursor:SetIsPlacePressed(false)
            if probe and probe.on_stall then pcall(probe.on_stall, session, world, controller, state, cursor, grid, remaining, pending.move) end
            stall_count = stall_count + 1
            event("stall", current_level, string.format("%d,%d", remaining, stall_count))
            if not pending.move or stall_count >= 5 then fail("placement-no-progress"); return end
            if pending.retried then
                local m = pending.move
                failed_moves[m.x .. "," .. m.y .. "," .. m.rotation] = true
            end
            pcall(function() cursor:DeselectShape() end)
            pending = nil
            return
        end
    end
    if remaining == 0 then return end
    local piece = get_piece(grid, descriptor)
    if not piece then fail("shape-unavailable"); return end
    local upcoming, has_single = {}, #piece.rotations[1] == 1
    local castle = current_level == "LVL_CastleIsland"
    local church_island = current_level == "LVL_ChurchIsland"
    local nexus = current_level == "LVL09_Nexus"
    local common_ground = current_level == "LVL01_CommonGround"
    local gold_rush = current_level == "LVL02_GoldRush"
    local tree_fort = current_level == "LVL07_TreeFort"
    local corruption_crates = current_level == "LVL_CorruptionCrates"
    local tainted_vault = current_level == "LVL_CorruptionCrumble"
    local river_heart = current_level == "LVL10_TheRiverHeart"
    local epilogue = current_level == "LVL_Epilogue"
    local variant = selected and selected.variant or 0
    local epilogue_endgame = epilogue and remaining <= (variant % 2 == 0 and 18 or 16)
    local vault_close = variant % 2 == 0 and 19 or 21
    local vault_endgame = tainted_vault and remaining <= vault_close
    local heart_close = variant % 2 == 0 and 28 or 31
    local heart_endgame = river_heart and remaining <= heart_close
    local dense_city = common_ground or gold_rush or tree_fort or tainted_vault or river_heart or epilogue
    local tree_route = current_level == "LVL05B_Schism" or current_level == "LVL06B_Crusade"
    local compact = current_level == "LVL_CommonIsles" or current_level == "LVL_SoldSnoble" or tree_route
    local lookahead = (compact or epilogue_endgame) and remaining or ((castle or church_island or nexus or dense_city) and 13
        or (corruption_crates and 10 or 7))
    local remaining_districts = {[0] = 0, [1] = 0, [2] = 0}
    local remaining_connectors = 0
    for i = 1, remaining - 1 do
        local future = get_piece(grid, unwrap(stack[remaining - i]))
        if future then
            if i <= lookahead then upcoming[#upcoming + 1] = future end
            local sz = #future.rotations[1]
            if sz == 1 then has_single = true end
            if future.district ~= nil then
                remaining_districts[future.district] = (remaining_districts[future.district] or 0) + sz
            elseif future.district_area then
                for district, area in pairs(future.district_area) do
                    remaining_districts[district] = remaining_districts[district] + area
                end
            elseif future.connector then
                remaining_connectors = remaining_connectors + 1
            end
        end
    end
    local board = get_board(grid, tainted_vault or river_heart)
    board.objective_focus = castle or church_island or nexus or compact or dense_city or corruption_crates
    board.bridge_focus = compact
    board.large_tree_focus = tree_route or tree_fort or river_heart
    board.score_late_moves = tree_fort or corruption_crates or vault_endgame or river_heart or epilogue
        or (tainted_vault and variant % 2 == 0)
    board.contain_corruption = corruption_crates or vault_endgame or heart_endgame
    board.score_crossings = compact or dense_city or corruption_crates
    board.exact_finish = dense_city or corruption_crates
    board.chain_geysers = nexus
    if castle then
        board.temple_opening = {x = -2, y = variant % 2 == 0 and 1 or -1, weight = 4.8}
    elseif church_island then
        board.temple_opening = {x = 0, y = variant % 2 == 0 and -4 or -6, weight = 4.0}
    elseif common_ground then
        board.opening_center = {x = 7, y = 8, weight = 5.5}
        board.district_seeds = {
            [0] = {x = 12, y = 10},
            [1] = {x = 12, y = 4},
            [2] = {x = 4, y = 10},
        }
    elseif gold_rush then
        board.opening_center = {x = 14, y = 8, weight = 4.5}
        board.district_seeds = {
            [0] = {x = 8, y = 10},
            [1] = {x = 15, y = 11},
            [2] = {x = 12, y = 5},
        }
    elseif tree_fort then
        board.opening_center = {x = 3, y = 9, weight = 4.8}
        board.district_seeds = {
            [0] = {x = 12, y = 6},
            [1] = {x = 11, y = 13},
            [2] = {x = 4, y = variant % 2 == 0 and 10 or 7},
        }
    elseif corruption_crates then
        board.opening_center = variant % 2 == 0 and {x = 14, y = 0, weight = 4.6}
            or {x = 5, y = 9, weight = 4.6}
        board.district_seeds = {
            [0] = {x = 11, y = 5},
            [1] = {x = 6, y = 16},
            [2] = {x = 17, y = 13},
        }
        board.corruption_start = variant % 2 == 0 and 19 or 17
        board.corruption_basin_x = variant % 2 == 0 and 23 or 21
    elseif tainted_vault then
        board.opening_center = {x = 15, y = 12, weight = 6.0}
        board.district_seeds = {
            [0] = {x = 14, y = 13},
            [1] = {x = 9, y = 15},
            [2] = {x = 20, y = 14},
        }
        if variant % 2 == 0 then
            board.opening_route = {{x = 15, y = 4}, {x = 11, y = 1}, weight = 7, remaining = 30}
        else
            board.opening_route = {{x = 2, y = 11}, {x = 2, y = 6}, weight = 8, district = 1, remaining = 24}
        end
        board.wide_search = true
        board.split_corruption = vault_endgame
        board.corruption_start = vault_close
    elseif river_heart then
        board.opening_center = variant % 2 == 0 and {x = 11, y = 13, weight = 8.0}
            or {x = 14, y = 15, weight = 8.0}
        board.district_seeds = {
            [0] = {x = 6, y = 8},
            [1] = {x = 14, y = 18},
            [2] = {x = 14, y = 10},
        }
        board.approach_lighthouse = true
        board.wide_search = true
        board.split_corruption = heart_endgame
        board.corruption_start = heart_close
        board.corruption_pressure = 1.5
        local repaired = #board.lighthouse_parts == 4
        for _, cell in ipairs(board.lighthouse_parts) do
            local tile = board.tiles[cell]
            if not tile or not tile.building then repaired = false; break end
        end
        local north_source = 3 * board.width + 19
        if repaired then
            for _, source in ipairs(board.corruption_sources) do
                for _, cell in ipairs(source) do
                    if cell == north_source then board.corruption_focus = north_source; break end
                end
            end
            if board.corruption_focus then
                board.opening_route = {
                    {x = 16, y = 6}, {x = 20, y = 6},
                    weight = variant % 2 == 0 and 5.5 or 7,
                    district = 2, remaining = 11,
                }
            end
        elseif variant % 2 == 0 then
            board.opening_route = {{x = 6, y = 20}, {x = 2, y = 21}, weight = 4.0, remaining = 39}
        end
        for _, goal in ipairs(board.objectives) do
            if goal.kind == "tree" and goal.tile.tree_points == 20 then goal.reward = goal.reward * 1.5 end
        end
    elseif epilogue then
        board.approach_trees = true
        board.wide_search = true
        board.exact_tail = epilogue_endgame
        board.neighbor_weight = remaining <= 24 and (variant % 2 == 0 and 2.85 or 2.55)
            or (remaining <= 40 and 1.95 or 1.75)
        board.bridge_weight = variant % 2 == 0 and 2.2 or 1.9
        board.district_seeds = {
            [0] = {x = 7, y = 6},
            [1] = {x = variant % 2 == 0 and 10 or 15, y = 12},
            [2] = {x = variant % 2 == 0 and 15 or 9, y = 11},
        }
        if variant % 2 == 0 then
            board.opening_route = {
                {x = 9, y = 12}, {x = 13, y = 12}, {x = 15, y = 12}, {x = 9, y = 8},
                weight = 6, remaining = 41,
            }
        else
            board.opening_route = {{x = 9, y = 12}, {x = 9, y = 8}, {x = 11, y = 5}, weight = 6, remaining = 41}
        end
    end
    board.has_single = has_single
    board.remaining_pieces = remaining
    board.remaining_districts = remaining_districts
    board.remaining_connectors = remaining_connectors
    if managed and selected and not selected.deal then
        local names = {}
        for i = remaining, 1, -1 do names[#names + 1] = object_name(unwrap(stack[i])) end
        event("deal", current_level, table.concat(names, ","))
        local gmap = {}
        for _, g in ipairs(board.geyser_cells) do
            gmap[#gmap + 1] = string.format("%d,%d:%d:%s", (g.index - 1) % board.width,
                (g.index - 1) // board.width, g.order, g.active and "A" or "i")
        end
        if #gmap > 0 then event("geyser-map", current_level, table.concat(gmap, ";")) end
        for _, goal in ipairs(board.objectives) do
            local list = {}
            for _, c in ipairs(goal.cells) do
                list[#list + 1] = string.format("%d,%d", (c - 1) % board.width, (c - 1) // board.width)
            end
            event("objective", current_level, goal.kind .. ":" .. table.concat(list, ";"))
        end
        selected.deal = true
    end
    if board.geyser_total > 0 then
        local sig = board.geyser_active_total .. "/" .. board.geyser_total
        if selected and selected.geyser_sig ~= sig then
            selected.geyser_sig = sig
            event("geyser-state", current_level, sig .. " rem=" .. remaining)
        end
    end
    if corruption_crates and selected then
        selected.church_contacts = selected.church_contacts or {}
        for _, goal in ipairs(board.objectives) do
            if goal.kind == "church" and not selected.church_contacts[goal.anchor] then
                for _, cell in ipairs(goal.cells) do
                    local tile = board.tiles[cell]
                    if tile and tile.district == 0 then
                        selected.church_contacts[goal.anchor] = true
                        event("church-contact", current_level, string.format("%d,%d",
                            (goal.anchor - 1) % board.width, (goal.anchor - 1) // board.width))
                        break
                    end
                end
            end
        end
    end
    local function legal(option)
        if failed_moves[option.x .. "," .. option.y .. "," .. option.rotation] then return false end
        return grid:CanPlaceShape(descriptor, placement(option.x, option.y, option.rotation), {}) == 0
    end
    local planned
    if probe and probe.pick_move and selected and not piece.sapling then
        local ok, value = pcall(probe.pick_move, session, current_level, selected.number,
            object_name(descriptor), remaining, board, piece, legal, scoring)
        if ok then planned = value end
    end
    if planned == "wait" then return end
    local move
    if planned ~= "discard" then
        if type(planned) == "table" and legal(planned) then
            move = planned
        else
            if planned then event("plan-fallback", current_level, remaining) end
            move = solver.choose(board, piece, upcoming, variant, legal, neighbor_preview(world, board))
        end
    end
    pending = {
        move = move, count = remaining, descriptor = descriptor:GetAddress(),
        deadline = os.time() + 5, retried = stall_count > 0,
    }
    if not move then
        if next(failed_moves) ~= nil then fail("placement-rejected"); return end
        state:DiscardShape()
        event("discard", current_level, remaining)
        return
    end
    if object_name(cursor.Descriptor) ~= object_name(descriptor) then cursor:SelectShape() end
    if object_name(cursor.Descriptor) ~= object_name(descriptor) then
        pending = nil
        return
    end
    local target = placement(move.x, move.y, move.rotation)
    cursor:SetCursorWorldLocation(grid:GetTileCenterFromGridLocation(target.Location))
    cursor.Placement, cursor.LastUserPlacement, cursor.LastHoverPlacement = target, target, target
    cursor:SetIsPlacePressed(true)
    cursor:PlaceShape()
    event("place", current_level, string.format("%d,%d,%d,%d", move.x, move.y, move.rotation, remaining))
end

local function step()
    read_command()
    if managed and stop_path then
        local stop = io.open(stop_path, "r")
        if stop then
            stop:close()
            phase, detail, command = "paused", "stopped", "hold"
            return
        end
    end
    if command == "retry" or command == "advance" then
        local screen = widget("WID_EndScreen_C")
        if not (end_started and end_started.reported and screen and present(screen.LevelSelectButton)) then
            fail("campaign-result-screen")
            return
        end
        if command == "retry" then
            locked_world, locked_level, misses = selected.world, selected.level, misses + 1
        else
            locked_world, locked_level, misses = "", "", 0
        end
        command = "run"
        return_to_map(screen)
        return
    end
    if command ~= "run" then return end
    local world = UEHelpers.GetWorld()
    local controller = UEHelpers.GetPlayerController()
    if not present(world) or not present(controller) then phase = "loading"; return end
    if world:GetAddress() ~= world_id then
        world_id = world:GetAddress()
        current_level = object_name(world)
        current_score, remaining, next_action = 0, 0, os.time() + 2
        thresholds = nil
        pending, failed_moves, stall_count, shape_cache, end_started, gate_pending = nil, {}, 0, {}, nil, false
        monument_targets = {}
        phase, detail = "loading", ""
        event("world", current_level)
    end
    if os.time() < next_action then return end
    local controller_class = object_name(controller:GetClass())
    if current_level == "LVL_Credits" then
        if managed then
            fail("campaign-unverified-ending")
        else
            phase, detail, command = "finished", "campaign", "pause"
        end
    elseif controller_class == "BP_PlayerController_MainMenu_C" then
        open_world(world, mode == "trial" and locked_world or "01")
        phase, detail, next_action = "travel", "read-save", os.time() + 12
    elseif current_level:find("LVL_LevelSelect_", 1, true) then
        level_select(world)
    elseif controller_class == "PlayerController_EmpireBuilder_C" then
        play(world, controller)
    elseif current_level == "LVL_Epilogue" then
        if managed then
            fail("campaign-unverified-ending")
        else
            phase, detail, command = "finished", "campaign", "pause"
        end
    else
        fail("unsupported-map:" .. current_level)
    end
end

write_status()
LoopInGameThreadWithDelay(260, function()
    local ok, err = pcall(step)
    if not ok then fail(err) end
    write_status()
end)
