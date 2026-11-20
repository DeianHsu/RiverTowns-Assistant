local Achievements = {}
Achievements.__index = Achievements

local write_hook = "/Script/OnlineSubsystemUtils.AchievementWriteCallbackProxy:WriteAchievementProgress"
local cache_class = "/Script/OnlineSubsystemUtils.Default__AchievementBlueprintLibrary"

function Achievements.load(path)
    local catalog = {}
    local file = assert(io.open(path, "r"))
    for line in file:lines() do
        local id, level = line:match("^(ACH_[A-Z]+)\t(LVL[%w_]+)\t")
        assert(id and not catalog[id], "Invalid achievement catalog")
        catalog[id] = level
    end
    file:close()
    return setmetatable({catalog = catalog}, Achievements)
end

-- 观察游戏本身发出的解锁请求。
function Achievements:watch()
    if self.watching then return true end
    self.watching = pcall(RegisterHook, write_hook, function(_, _, _, id, progress)
        if self.attempt and id:get():ToString() == self.attempt.id and progress:get() >= 100 then
            self.attempt.earned = true
        end
    end)
    return self.watching
end

function Achievements.unlocked(world, controller, id)
    local api = StaticFindObject(cache_class)
    if not (api and api:IsValid()) then return false end
    local found, progress = {}, {}
    api:GetCachedAchievementProgress(world, controller, FName(id, 1), found, progress)
    return found.bFoundID == true and (progress.Progress or 0) >= 100
end

local function building(tile)
    return tile and tile.building and not tile.start
end

local function fits(board, move)
    for _, cell in ipairs(move.cells) do
        local tile = board.tiles[cell]
        if tile and tile.solid then return false end
    end
    return true
end

local function choose_ranked(board, piece, solver, legal, score)
    local ranked = {}
    for index, move in ipairs(solver.placements(board, piece)) do
        if fits(board, move) then
            local points = score(move)
            if points then ranked[#ranked + 1] = {move = move, score = points, index = index} end
        end
    end
    table.sort(ranked, function(a, b)
        if a.score == b.score then return a.index < b.index end
        return a.score > b.score
    end)
    for _, option in ipairs(ranked) do
        if legal(option.move) then return option.move end
    end
end

local function contacts(board, move)
    local count = 0
    for _, cell in ipairs(move.rim) do
        if building(board.tiles[cell]) then count = count + move.edges[cell] end
    end
    return count
end

local function near_cells(board, cell)
    local x, y = (cell - 1) % board.width, (cell - 1) // board.width
    local cells = {}
    if x > 0 then cells[#cells + 1] = cell - 1 end
    if x < board.width - 1 then cells[#cells + 1] = cell + 1 end
    if y > 0 then cells[#cells + 1] = cell - board.width end
    if y < board.height - 1 then cells[#cells + 1] = cell + board.width end
    return cells
end

local function nice(board, piece, solver, legal)
    local expected = 0
    for _, cell in ipairs(piece.rotations[1]) do
        expected = expected + 4
        for _, other in ipairs(piece.rotations[1]) do
            if math.abs(cell.x - other.x) + math.abs(cell.y - other.y) == 1 then expected = expected - 1 end
        end
    end
    return choose_ranked(board, piece, solver, legal, function(move)
        if contacts(board, move) == expected then return 1 end
    end)
end

local function bridges(board, piece, solver, legal)
    local banks = {}
    local function add(left, right, river)
        -- 水道两岸都必须可站建筑。
        local a, b = board.tiles[left], board.tiles[right]
        if (a and (a.water or a.solid and not building(a))) or (b and (b.water or b.solid and not building(b))) then return end
        banks[left] = banks[left] or {}
        banks[right] = banks[right] or {}
        banks[left][#banks[left] + 1] = {other = right, river = river}
        banks[right][#banks[right] + 1] = {other = left, river = river}
    end
    for river in pairs(board.river_cells) do
        local tile = board.tiles[river]
        if not building(tile) then
            local x, y = (river - 1) % board.width, (river - 1) // board.width
            if x > 0 and x < board.width - 1 then add(river - 1, river + 1, river) end
            if y > 0 and y < board.height - 1 then add(river - board.width, river + board.width, river) end
        end
    end
    return choose_ranked(board, piece, solver, legal, function(move)
        local crossed, opened = {}, 0
        for _, cell in ipairs(move.cells) do
            for _, bank in ipairs(banks[cell] or {}) do
                if building(board.tiles[bank.other]) or move.covered[bank.other] then
                    crossed[bank.river] = true
                else
                    opened = opened + 1
                end
            end
        end
        local count = 0
        for _ in pairs(crossed) do count = count + 1 end
        return 16 * count + 4 * opened + 0.25 * contacts(board, move)
    end)
end

local function cover_targets(targets, board, deck, district, solver)
    local choices, cells = {}, {}
    for cell in pairs(targets) do cells[#cells + 1], choices[cell] = cell, {} end
    table.sort(cells)
    for index, piece in ipairs(deck) do
        if piece and piece.district == district then
            local seen = {}
            for _, move in ipairs(solver.placements(board, piece)) do
                if not seen[move.key] and fits(board, move) then
                    seen[move.key] = true
                    local hits = {}
                    for _, cell in ipairs(move.cells) do
                        if targets[cell] then hits[#hits + 1] = cell end
                    end
                    if #hits > 0 then
                        local option = {move = move, hits = #hits, turn = board.remaining_pieces - index + 1}
                        for _, cell in ipairs(hits) do choices[cell][#choices[cell] + 1] = option end
                    end
                end
            end
        end
    end
    for _, options in pairs(choices) do
        table.sort(options, function(a, b)
            if a.hits == b.hits then return a.turn > b.turn end
            return a.hits > b.hits
        end)
    end
    local plan, occupied, visited = {}, {}, 0
    local function search()
        visited = visited + 1
        if visited > 5000 then return false end
        local options
        -- 优先搜索可用拼法最少的目标格。
        for _, cell in ipairs(cells) do
            if not occupied[cell] and (not options or #choices[cell] < #options) then options = choices[cell] end
        end
        if not options then return true end
        for _, option in ipairs(options) do
            if not plan[option.turn] then
                local free = true
                for _, cell in ipairs(option.move.cells) do if occupied[cell] then free = false; break end end
                if free then
                    plan[option.turn] = option.move
                    for _, cell in ipairs(option.move.cells) do occupied[cell] = true end
                    if search() then return true end
                    for _, cell in ipairs(option.move.cells) do occupied[cell] = nil end
                    plan[option.turn] = nil
                end
            end
        end
        return false
    end
    if search() then return plan end
end

local function cover_goal(attempt, board, piece, deck, solver, legal)
    local district, targets, active = 0, {}, {}
    if attempt.id == "ACH_EELFATHER" then
        if not attempt.temple then
            for _, goal in ipairs(board.objectives) do
                if goal.kind == "temple" then attempt.temple = goal.cells; break end
            end
        end
        for _, cell in ipairs(attempt.temple or {}) do
            local tile = board.tiles[cell]
            if not (building(tile) and tile.district == district) then targets[cell], active[cell] = true, true end
        end
    else
        district = 1
        for _, geyser in ipairs(board.geyser_cells) do
            targets[geyser.index] = true
            if geyser.active then active[geyser.index] = true end
        end
    end
    local count = 0
    for _ in pairs(targets) do count = count + 1 end
    attempt.total = attempt.total or count
    attempt.progress = string.format("目标格 %d / %d", attempt.total - count, attempt.total)
    if count == 0 then return nil, false end

    local remaining = board.remaining_pieces
    local plan = attempt.plan
    for turn in pairs(plan or {}) do if turn > remaining then plan[turn] = nil end end
    if not plan or not next(plan) then plan = cover_targets(active, board, deck, district, solver) end
    local next_move = plan and plan[remaining]
    if next_move then
        if legal(next_move) then
            attempt.plan = plan
            return next_move, true
        end
        plan = nil
    end
    attempt.plan = plan
    local reserved = {}
    for turn, move in pairs(plan or {}) do
        if turn < remaining then
            for _, cell in ipairs(move.cells) do reserved[cell] = true end
        end
    end
    return choose_ranked(board, piece, solver, legal, function(move)
        local hit = 0
        for _, cell in ipairs(move.cells) do
            if reserved[cell] then return end
            if targets[cell] then
                if piece.district ~= district or not active[cell] then return end
                hit = hit + 1
            end
        end
        return 30 * hit + contacts(board, move)
    end), true
end

local function ruins(attempt, board, piece, solver, legal)
    local count = 0
    for _, tile in pairs(board.tiles) do if tile.ruin_floors then count = count + 1 end end
    attempt.total = attempt.total or count
    attempt.progress = string.format("已拆除遗迹 %d / %d", attempt.total - count, attempt.total)
    if count == 0 then return nil, false end
    return choose_ranked(board, piece, solver, legal, function(move)
        local hits = 0
        for _, cell in ipairs(move.rim) do
            if board.tiles[cell] and board.tiles[cell].ruin_floors then
                if piece.district ~= 2 then return end
                hits = hits + 1
            end
        end
        return 40 * hits + contacts(board, move)
    end), true
end

local function corruption(attempt, board, piece, last, solver, legal, legal_last)
    if not last then return nil, false end
    local frontier, count = {}, 0
    for _, source in ipairs(board.corruption_sources) do
        for _, cell in ipairs(source) do
            for _, near in ipairs(near_cells(board, cell)) do
                local tile = board.tiles[near]
                if not frontier[near] and (not tile or not (tile.solid or tile.building or tile.corruption or tile.treasure)) then
                    frontier[near], count = true, count + 1
                end
            end
        end
    end
    if count == 0 then return nil, false end
    local function hits(move)
        local n = 0
        for _, cell in ipairs(move.cells) do if frontier[cell] then n = n + 1 end end
        return n
    end
    if board.remaining_pieces == 1 then
        return choose_ranked(board, piece, solver, legal, hits), true
    end
    local final = {}
    for _, move in ipairs(solver.placements(board, last)) do
        local covered = fits(board, move) and hits(move)
        if covered == count and legal_last(move) then
            attempt.progress = "已为最后一块留出封口，正在跳过多余拼块。"
            return nil, true
        elseif covered and covered > 0 then final[#final + 1] = {move = move, hits = covered} end
    end
    attempt.progress = "正在缩小腐化边界，为最后一块保留封口。"
    return choose_ranked(board, piece, solver, legal, function(move)
        local cut = hits(move)
        if cut == count then return end
        if cut == 0 then
            local distance = math.huge
            for cell in pairs(frontier) do
                local x, y = (cell - 1) % board.width, (cell - 1) // board.width
                distance = math.min(distance, math.abs(x - move.cx) + math.abs(y - move.cy))
            end
            return -distance
        end
        local combined = 0
        for _, option in ipairs(final) do
            if option.hits + cut > combined then
                local overlap = false
                for _, cell in ipairs(move.cells) do if option.move.covered[cell] then overlap = true; break end end
                if not overlap then combined = option.hits + cut end
            end
        end
        return 10 * combined + cut
    end), true
end

function Achievements.choose(attempt, board, piece, deck, solver, legal, legal_last)
    if piece.start then
        -- 东侧河段靠近腐化源，可以优先启用这一片河岸。
        local east = {x = 17, y = 10, rotation = 2}
        if attempt.id == "ACH_CORRUPTION" and legal(east) then return east, true end
        return nil, false
    end
    if attempt.id == "ACH_NICE" then
        local move = nice(board, piece, solver, legal)
        return move, move ~= nil
    elseif attempt.id == "ACH_BRIDGES" then
        return bridges(board, piece, solver, legal), true
    elseif attempt.id == "ACH_CORRUPTION" then
        return corruption(attempt, board, piece, deck[#deck], solver, legal, legal_last)
    elseif attempt.id == "ACH_HARDLABOUR" then
        return ruins(attempt, board, piece, solver, legal)
    end
    return cover_goal(attempt, board, piece, deck, solver, legal)
end

return Achievements
