local UEHelpers = require("UEHelpers")
local session = assert(os.getenv("RIVER_ASSISTANT_SESSION"), "Missing assistant session")
local solver = dofile(assert(os.getenv("RIVER_ASSISTANT_SOURCE")) .. "/solver.lua")

local attempts, cleared, cleared_count = {}, {}, 0
local replay_level
local world_id, phase, detail = nil, "waiting", ""
local current_level, current_score, remaining = "", 0, 0
local thresholds
local pending, failed_move, shape_cache = nil, nil, {}
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
    local safe_detail = tostring(detail):gsub("[\t\r\n]", " ")
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
            if phase == "blocked" then pending, failed_move, next_action, gate_pending = nil, nil, 0, false end
            phase, detail, end_started = "ready", "", nil
        else
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
    local connector = kind == 3 or label:find("bridge") ~= nil or label:find("road") ~= nil
    local neighbor = descriptor.NeighbourScore
    local cover, touch = 0, 0
    if label:find("treasure") or label:find("gold") then cover = 10
    elseif label:find("buildingmaterials") then cover = 30
    elseif label:find("geyser") and not label:find("mother") then
        cover = present(actor) and actor.IsActive == true and 28 or 11
    elseif label:find("crate") then cover = 8 end
    if label:find("tree") then touch = 4.5
    elseif label:find("temple") or label:find("lighthouse") then touch = 5
    elseif label:find("ruin") then touch = 1.5 end
    return {
        district = district, connector = connector, building = district ~= nil or connector,
        start = object_name(descriptor) == "GridEntity_Start",
        water = label:find("river") ~= nil, solid = not descriptor.CanBeSquished,
        neighbor = type(neighbor) == "number" and neighbor or 0,
        cover = cover, touch = touch, actor = present(actor) and actor:GetAddress() or nil,
        objective = label:find("temple") and "temple" or (label:find("tree") and "tree" or nil),
    }
end

local function cell_index(board, cell)
    if cell.X >= 0 and cell.Y >= 0 and cell.X < board.width and cell.Y < board.height then
        return cell.Y * board.width + cell.X + 1
    end
end

local function add_objective(board, actor, tile, anchor)
    if not tile.objective or not anchor or type(actor.IsGrown) ~= "boolean" then return end
    if actor.IsGrown then tile.touch = 0; return end
    local neighbors = actor.NeighbourCells
    if type(neighbors) ~= "userdata" or neighbors:type() ~= "TArray" then return end
    local cells, seen = {}, {}
    for i = 1, #neighbors do
        local index = cell_index(board, unwrap(neighbors[i]))
        if index and not seen[index] then
            seen[index] = true
            cells[#cells + 1] = index
        end
    end
    if #cells == 0 then return end
    if tile.objective == "tree" then tile.cover = -16 end
    tile.touch = 0
    -- 庙宇的每个本体格都要围住。NeighbourCells 给出整个外圈。
    local objective = {cells = cells, need = #cells, kind = tile.objective, anchor = anchor, tile = tile}
    board.objectives[#board.objectives + 1] = objective
    for _, index in ipairs(cells) do
        local related = board.objectives_at[index] or {}
        related[#related + 1] = objective
        board.objectives_at[index] = related
    end
end

local function get_board(grid)
    local board = {
        width = grid.GridColumns, height = grid.GridRows, tiles = {},
        objectives = {}, objectives_at = {},
    }
    for _, item in ipairs(grid:GetAllGridActors()) do
        local actor = unwrap(item)
        if present(actor) and present(actor.GridEntityDescriptor) then
            local category = classify(actor.GridEntityDescriptor, actor)
            local anchor
            for _, point in ipairs(grid:GetGridActorCells(actor)) do
                local index = cell_index(board, unwrap(point))
                if index then
                    anchor = anchor or index
                    local old = board.tiles[index]
                    if not old or category.building or category.start
                            or (not old.building and not old.start and category.solid) then
                        board.tiles[index] = category
                    end
                end
            end
            add_objective(board, actor, category, anchor)
        end
    end
    local temples = 0
    for _, goal in ipairs(board.objectives) do
        if goal.kind == "temple" then temples = temples + 1 end
    end
    for _, goal in ipairs(board.objectives) do
        -- 庙宇完成后乘数增加 0.2，用三星门槛换算本局中这个乘数的大致价值。
        goal.reward = goal.kind == "tree" and 20 or (thresholds and thresholds[3] or 300) * 0.2 / (1 + 0.2 * temples)
    end
    return board
end

local function get_piece(grid, descriptor)
    if not present(descriptor) then return nil end
    local key = descriptor:GetAddress()
    if shape_cache[key] then return shape_cache[key] end
    local piece = classify(descriptor)
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
    for _, popup in ipairs(world_objects("BP_TutorialPopup_C", world)) do
        if popup.IsShown and popup.CanBeClosed then popup:DestroyPopup() end
    end
end

local function go_to(target, level)
    attempts[level] = (attempts[level] or 0) + 1
    target:Select(false)
    target:Start()
    phase, detail, next_action = "travel", level, os.time() + 5
    event("enter", level, attempts[level])
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

local function level_select(world)
    local unplayed, upgrades, retries = {}, {}, {}
    local replay
    local unfinished = 0
    for _, target in ipairs(world_objects("BP_LevelSelectWorldObject_C", world)) do
        local level = target:GetLevelName():ToString()
        if not target.IsCompetitionLevel and level ~= "None" then
            if not target.IsCompleted then unfinished = unfinished + 1 end
            local tries = attempts[level] or 0
            if target.IsUnlocked and tries < retry_limit then
                local option = {target = target, level = level, stars = target.StarCount, tries = tries}
                if level == replay_level and tries == 1 and option.stars < 3 then
                    replay = option
                elseif not target.IsCompleted and tries == 0 then
                    unplayed[#unplayed + 1] = option
                elseif option.stars < 3 and tries == 0 then
                    upgrades[#upgrades + 1] = option
                elseif option.stars < 3 then
                    retries[#retries + 1] = option
                end
            end
        end
    end
    replay_level = nil
    if replay then
        go_to(replay.target, replay.level)
        return
    end
    table.sort(upgrades, function(a, b) return a.level < b.level end)
    table.sort(unplayed, function(a, b) return a.level < b.level end)
    local next_level = upgrades[1] or unplayed[1]
    if next_level then
        go_to(next_level.target, next_level.level)
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
        go_to(retries[1].target, retries[1].level)
    else
        fail("gate-locked")
    end
end

local function ending(world, controller, score)
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
    screen[back_button](screen, screen.LevelSelectButton)
    phase, detail, next_action = "travel", "return", os.time() + 12
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
        ending(world, controller, current_score)
        return
    end
    phase, detail = "solving", ""
    if state.bIsInScoringSequence or cursor.PlaceShapeTimeline:IsPlaying() then return end
    local descriptor = state:PeekNextShape()
    if pending then
        if remaining ~= pending.count or not present(descriptor) or descriptor:GetAddress() ~= pending.descriptor then
            cursor:SetIsPlacePressed(false)
            pending, failed_move = nil, nil
        elseif os.time() <= pending.deadline then
            return
        else
            cursor:SetIsPlacePressed(false)
            if not pending.move or failed_move then fail("placement-no-progress"); return end
            failed_move, pending = pending.move, nil
        end
    end
    if remaining == 0 then return end
    close_tutorial(world)
    local piece = get_piece(grid, descriptor)
    if not piece then fail("shape-unavailable"); return end
    local upcoming, has_single = {}, false
    for i = 1, remaining - 1 do
        local future = get_piece(grid, unwrap(stack[remaining - i]))
        if future then
            if i <= 7 then upcoming[#upcoming + 1] = future end
            if #future.rotations[1] == 1 then has_single = true end
        end
    end
    local board = get_board(grid)
    board.has_single = has_single
    local move = solver.choose(board, piece, upcoming, math.max((attempts[current_level] or 1) - 1, 0),
        function(option)
            if failed_move and option.x == failed_move.x and option.y == failed_move.y
                    and option.rotation == failed_move.rotation then return false end
            return grid:CanPlaceShape(descriptor, placement(option.x, option.y, option.rotation), {}) == 0
        end, neighbor_preview(world, board))
    pending = {move = move, count = remaining, descriptor = descriptor:GetAddress(), deadline = os.time() + 4}
    if not move then
        if failed_move then fail("placement-rejected"); return end
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
    if command ~= "run" then return end
    local world = UEHelpers.GetWorld()
    local controller = UEHelpers.GetPlayerController()
    if not present(world) or not present(controller) then phase = "loading"; return end
    if world:GetAddress() ~= world_id then
        world_id = world:GetAddress()
        current_level = object_name(world)
        current_score, remaining, next_action = 0, 0, os.time() + 2
        thresholds = nil
        pending, failed_move, shape_cache, end_started, gate_pending = nil, nil, {}, nil, false
        phase, detail = "loading", ""
        event("world", current_level)
    end
    if os.time() < next_action then return end
    local controller_class = object_name(controller:GetClass())
    if current_level == "LVL_Credits" then
        phase, detail, command = "finished", "campaign", "pause"
    elseif controller_class == "BP_PlayerController_MainMenu_C" then
        open_world(world, "01")
        phase, detail, next_action = "travel", "story", os.time() + 12
    elseif current_level:find("LVL_LevelSelect_", 1, true) then
        level_select(world)
    elseif controller_class == "PlayerController_EmpireBuilder_C" then
        play(world, controller)
    elseif current_level == "LVL_Epilogue" then
        phase, detail, command = "finished", "campaign", "pause"
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
