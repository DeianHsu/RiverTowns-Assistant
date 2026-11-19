local Solver = {}

local function make_neighbors(width, height)
    local neighbors = {}
    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local cell = y * width + x + 1
            local adjacent = {}
            if x > 0 then adjacent[#adjacent + 1] = cell - 1 end
            if x + 1 < width then adjacent[#adjacent + 1] = cell + 1 end
            if y > 0 then adjacent[#adjacent + 1] = cell - width end
            if y + 1 < height then adjacent[#adjacent + 1] = cell + width end
            neighbors[cell] = adjacent
        end
    end
    return neighbors
end

local function make_crossings(board)
    local crossings = {}
    local function add_pair(first, second, river)
        local a, b = crossings[first] or {}, crossings[second] or {}
        a[#a + 1], b[#b + 1] = {across = second, river = river}, {across = first, river = river}
        crossings[first], crossings[second] = a, b
    end
    for index, tile in pairs(board.tiles) do
        if tile.water and not tile.building then
            local x, y = (index - 1) % board.width, (index - 1) // board.width
            if x > 0 and x + 1 < board.width then add_pair(index - 1, index + 1, index) end
            if y > 0 and y + 1 < board.height then add_pair(index - board.width, index + board.width, index) end
        end
    end
    return crossings
end

local function make_move(board, neighbors, offsets, x, y, rotation)
    local cells, covered = {}, {}
    for i, offset in ipairs(offsets) do
        local cx, cy = x + offset.x, y + offset.y
        if cx < 0 or cy < 0 or cx >= board.width or cy >= board.height then return end
        local index = cy * board.width + cx + 1
        cells[i], covered[index] = index, true
    end
    local rim, edges = {}, {}
    for _, cell in ipairs(cells) do
        for _, near in ipairs(neighbors[cell]) do
            if not covered[near] then
                if not edges[near] then rim[#rim + 1] = near end
                edges[near] = (edges[near] or 0) + 1
            end
        end
    end
    table.sort(cells)
    return {
        x = x, y = y, rotation = rotation, cells = cells, covered = covered,
        rim = rim, edges = edges, key = table.concat(cells, ","),
    }
end

local function geometry(board, neighbors, piece)
    local size = board.width .. "x" .. board.height
    if piece.size == size then return piece.placements end
    local result = {}
    for order, offsets in ipairs(piece.rotations) do
        for y = 0, board.height - 1 do
            for x = 0, board.width - 1 do
                local move = make_move(board, neighbors, offsets, x, y, order - 1)
                if move then result[#result + 1] = move end
            end
        end
    end
    piece.size, piece.placements = size, result
    return result
end

local function clusters(board, tiles, neighbors, district)
    local identifiers, sizes, largest = {}, {}, 0
    for cell, tile in pairs(tiles) do
        if tile.district == district and not identifiers[cell] then
            local id = #sizes + 1
            local queue, at, area = {cell}, 1, 0
            identifiers[cell] = id
            while at <= #queue do
                local index = queue[at]
                if tiles[index].district == district then area = area + 1 end
                for _, near in ipairs(neighbors[index]) do
                    local other = tiles[near]
                    if other and (other.district == district or other.connector) and not identifiers[near] then
                        identifiers[near] = id
                        queue[#queue + 1] = near
                    end
                end
                local across = board.crossings[index]
                if across then
                    for _, bank in ipairs(across) do
                        local other = tiles[bank.across]
                        if other and (other.district == district or other.connector)
                                and not identifiers[bank.across] then
                            identifiers[bank.across] = id
                            queue[#queue + 1] = bank.across
                        end
                    end
                end
                at = at + 1
            end
            sizes[id], largest = area, math.max(largest, area)
        end
    end
    return {ids = identifiers, sizes = sizes, largest = largest}
end

local function cluster_gain(move, joined_banks, district_map, area)
    local seen = {}
    for _, cell in ipairs(move.rim) do
        local id = district_map.ids[cell]
        if id and not seen[id] then
            seen[id] = true
            area = area + district_map.sizes[id]
        end
    end
    for cell in pairs(joined_banks) do
        local id = district_map.ids[cell]
        if id and not seen[id] then
            seen[id] = true
            area = area + district_map.sizes[id]
        end
    end
    return math.max(0, area - district_map.largest)
end

local function district_maps(board, tiles, neighbors, piece)
    local result = {}
    if piece.district then result[1] = clusters(board, tiles, neighbors, piece.district)
    elseif piece.connector then
        for district = 0, 2 do result[district + 1] = clusters(board, tiles, neighbors, district) end
    end
    return result
end

local function free(tiles, index)
    return not (tiles[index] and tiles[index].solid)
end

local function has_room(tiles, neighbors, cell)
    for _, adjacent in ipairs(neighbors[cell]) do
        if free(tiles, adjacent) then return true end
    end
    return false
end

local function objective_progress(board, tiles, neighbors)
    local progress = {}
    for _, goal in ipairs(board.objectives) do
        if tiles[goal.anchor] == goal.tile then
            local filled, possible = 0, 0
            for _, cell in ipairs(goal.cells) do
                if tiles[cell] and tiles[cell].building then
                    filled, possible = filled + 1, possible + 1
                elseif free(tiles, cell) and (board.has_single or has_room(tiles, neighbors, cell)) then
                    possible = possible + 1
                end
            end
            if filled < goal.need and possible >= goal.need then
                progress[goal] = {filled = filled, possible = possible}
            end
        end
    end
    return progress
end

local function objective_gain(board, tiles, move, piece, progress, sealed)
    if not piece.building or next(progress) == nil then return 0 end
    local additions, value = {}, 0
    for _, cell in ipairs(move.cells) do
        local related = board.objectives_at[cell]
        if related and (not tiles[cell] or not tiles[cell].building) then
            for _, goal in ipairs(related) do
                if progress[goal] and not move.covered[goal.anchor] then
                    additions[goal] = (additions[goal] or 0) + 1
                end
            end
        end
    end
    for goal, added in pairs(additions) do
        local start = progress[goal].filled / goal.need
        local finish = math.min(progress[goal].filled + added, goal.need) / goal.need
        local completion = finish == 1 and 0.4 or 0
        value = value + goal.reward * ((finish - start) * (0.35 + 0.25 * (start + finish)) + completion)
    end
    for goal, lost in pairs(sealed) do
        local status = progress[goal]
        if status and status.possible - lost < goal.need
                and status.filled + (additions[goal] or 0) < goal.need then
            value = value - goal.reward * 0.8
        end
    end
    return value
end

local function evaluate(board, tiles, neighbors, move, piece, maps, progress, attempt, require_fit)
    local cover, goal, adjacent, contacts, pockets = 0, 0, 0, 0, 0
    local connected = false
    local covered_goals, sealed = {}, {}
    local joined_banks, bridges, bridge_points = {}, {}, 0
    for _, cell in ipairs(move.cells) do
        local tile = tiles[cell]
        if require_fit and not free(tiles, cell) then return end
        if tile and tile.actor and tile.cover ~= 0 and not covered_goals[tile.actor] then
            covered_goals[tile.actor] = true
            cover = cover + tile.cover
        end
        local across = piece.building and board.crossings[cell]
        if across then
            for _, bank in ipairs(across) do
                local opposite = tiles[bank.across]
                if opposite and opposite.building then
                    connected = true
                    if opposite.district == piece.district or opposite.connector or piece.connector then
                        joined_banks[bank.across] = true
                        if not bridges[bank.river] then
                            bridges[bank.river] = true
                            bridge_points = bridge_points + 2
                        end
                    end
                end
            end
        end
    end
    for _, cell in ipairs(move.rim) do
        local tile = tiles[cell]
        if tile then
            adjacent = adjacent + tile.neighbor
            goal = goal + tile.touch * move.edges[cell]
            if tile.building or tile.start then
                connected = true
                contacts = contacts + move.edges[cell]
            end
        end
        if free(tiles, cell) then
            local open = 0
            for _, near in ipairs(neighbors[cell]) do
                if not move.covered[near] and free(tiles, near) then open = open + 1 end
            end
            if open == 0 then
                pockets = pockets + 2
                local related = board.objectives_at[cell]
                if related and not board.has_single then
                    for _, target in ipairs(related) do sealed[target] = (sealed[target] or 0) + 1 end
                end
            elseif open == 1 then
                pockets = pockets + 0.5
            end
        end
    end
    if require_fit and piece.building and not connected then return end
    goal = goal + objective_gain(board, tiles, move, piece, progress, sealed)
    local district_gain = 0
    for _, map in ipairs(maps) do
        district_gain = district_gain + cluster_gain(move, joined_banks, map, piece.district and #move.cells or 0)
    end
    local noise = ((move.x * 163 + move.y * 311 + move.rotation * 521 + attempt * move.x * move.y * 17) % 997) / 997
    local space_weight = 0.65 + 0.24 * (attempt % 4)
    local value = adjacent + bridge_points + (cover + goal) * (1 + 0.13 * (attempt % 3))
        + district_gain * 1.25 + 0.35 * contacts + 0.42 * #move.cells - space_weight * pockets
        + noise * (attempt == 0 and 0.02 or 0.28 * attempt)
    return value, adjacent
end

local function keep_best(ranked, candidate, limit)
    if #ranked == limit and candidate.value <= ranked[limit].value then return end
    local at = #ranked + 1
    while at > 1 and candidate.value > ranked[at - 1].value do
        at = at - 1
    end
    table.insert(ranked, at, candidate)
    if #ranked > limit then ranked[limit + 1] = nil end
end

local function apply(move, tile, before)
    local after = {}
    for cell, occupant in pairs(before) do after[cell] = occupant end
    for _, cell in ipairs(move.cells) do after[cell] = tile end
    return after
end

local function roots(board, neighbors, piece, attempt, legal, native_score)
    local candidates = {}
    local maps = district_maps(board, board.tiles, neighbors, piece)
    local progress = objective_progress(board, board.tiles, neighbors)
    for _, move in ipairs(geometry(board, neighbors, piece)) do
        local value, predicted = evaluate(board, board.tiles, neighbors, move, piece, maps, progress, attempt, false)
        candidates[#candidates + 1] = {move = move, value = value, predicted = predicted}
    end
    table.sort(candidates, function(a, b) return a.value > b.value end)

    local beam, seen, visited = {}, {}, 0
    for _, candidate in ipairs(candidates) do
        local move = candidate.move
        if not seen[move.key] and legal(move) then
            seen[move.key] = true
            local live = native_score and native_score(move)
            if live then candidate.value = candidate.value + live - candidate.predicted end
            keep_best(beam, {
                first = move,
                tiles = apply(move, piece, board.tiles),
                value = candidate.value,
            }, 16)
            visited = visited + 1
            if visited >= 32 then break end
        end
    end
    return beam
end

local function take_next(board, neighbors, beam, piece, depth, attempt)
    local next_beam = {}
    local available, seen = {}, {}
    for _, move in ipairs(geometry(board, neighbors, piece)) do
        if not seen[move.key] then
            seen[move.key] = true
            local fits = true
            for _, cell in ipairs(move.cells) do
                if not free(board.tiles, cell) then
                    fits = false
                    break
                end
            end
            if fits then available[#available + 1] = move end
        end
    end
    for _, state in ipairs(beam) do
        local maps = district_maps(board, state.tiles, neighbors, piece)
        local progress = objective_progress(board, state.tiles, neighbors)
        local moves = {}
        for _, move in ipairs(available) do
            local value = evaluate(board, state.tiles, neighbors, move, piece, maps, progress, attempt, true)
            if value then keep_best(moves, {move = move, value = value}, 4) end
        end
        local weight = 0.95 ^ (depth - 1)
        for _, option in ipairs(moves) do
            keep_best(next_beam, {
                first = state.first,
                move = option.move,
                tiles = state.tiles,
                value = state.value + option.value * weight,
            }, 16)
        end
        if #moves == 0 then
            keep_best(next_beam, {
                first = state.first, tiles = state.tiles, value = state.value - 8 * weight,
            }, 16)
        end
    end
    for _, state in ipairs(next_beam) do
        if state.move then state.tiles = apply(state.move, piece, state.tiles) end
    end
    return next_beam
end

-- 对接下来的几块实际拼块做束搜索，每次用游戏校验首步。
function Solver.choose(board, piece, upcoming, attempt, legal, native_score)
    local neighbors = make_neighbors(board.width, board.height)
    board.crossings = make_crossings(board)
    local beam = roots(board, neighbors, piece, attempt, legal, native_score)
    if #beam <= 1 then return beam[1] and beam[1].first end
    for index, next_piece in ipairs(upcoming) do
        beam = take_next(board, neighbors, beam, next_piece, index + 1, attempt)
    end
    return beam[1].first
end

return Solver
