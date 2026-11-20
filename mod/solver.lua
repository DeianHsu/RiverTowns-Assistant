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
    for index in pairs(board.river_cells) do
        local tile = board.tiles[index]
        if not tile or not tile.building or tile.start then
            local x, y = (index - 1) % board.width, (index - 1) // board.width
            if x > 0 and x + 1 < board.width then add_pair(index - 1, index + 1, index) end
            if y > 0 and y + 1 < board.height then add_pair(index - board.width, index + board.width, index) end
        end
    end
    return crossings
end

local function make_move(board, neighbors, offsets, x, y, rotation)
    local cells, covered = {}, {}
    local sx, sy = 0, 0
    for i, offset in ipairs(offsets) do
        local cx, cy = x + offset.x, y + offset.y
        if cx < 0 or cy < 0 or cx >= board.width or cy >= board.height then return end
        local index = cy * board.width + cx + 1
        cells[i], covered[index] = index, true
        sx, sy = sx + cx, sy + cy
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
    local n = #cells
    return {
        x = x, y = y, rotation = rotation, cells = cells, covered = covered,
        rim = rim, edges = edges, key = table.concat(cells, ","),
        cx = sx / n, cy = sy / n,
    }
end

local function geometry(board, neighbors, piece)
    local size = board.width .. "x" .. board.height
    if piece.size == size then return piece.placements end
    local result = {}
    for order, offsets in ipairs(piece.rotations) do
        local districts = piece.district_rotations and piece.district_rotations[order]
        for y = 0, board.height - 1 do
            for x = 0, board.width - 1 do
                local move = make_move(board, neighbors, offsets, x, y, order - 1)
                if move then
                    if districts then
                        move.district_parts = {}
                        for district, part in pairs(districts) do
                            move.district_parts[district] = make_move(board, neighbors, part, x, y, order - 1)
                        end
                        move.key = move.key .. ":" .. move.district_parts[1].key
                    end
                    result[#result + 1] = move
                end
            end
        end
    end
    piece.size, piece.placements = size, result
    return result
end

local function free(tiles, index)
    return not (tiles[index] and tiles[index].solid)
end

local function will_free(tiles, index)
    local t = tiles[index]
    return not t or not t.solid or (t.geyser and not t.building)
end

local function corruption_can_spread(tiles, cell)
    local tile = tiles[cell]
    return not tile or (not tile.solid and not tile.building and not tile.treasure and not tile.corruption)
end

local function corruption_frontier(board, neighbors)
    local frontier = {}
    for cell, tile in pairs(board.tiles) do
        if tile.corruption then
            for _, around in ipairs(neighbors[cell]) do
                if corruption_can_spread(board.tiles, around) then frontier[around] = true end
            end
        end
    end
    return frontier
end

local function corruption_groups(board, neighbors)
    local groups = {}
    for _, cells in ipairs(board.corruption_sources) do
        local border = {}
        local weight = 1
        for _, cell in ipairs(cells) do
            if cell == board.corruption_focus then weight = 1.75 end
            for _, near in ipairs(neighbors[cell]) do
                local tile = board.tiles[near]
                if not tile or not tile.corruption then border[near] = true end
            end
        end
        groups[#groups + 1] = {size = #cells, border = border, weight = weight}
    end
    return groups
end

local function reachable_from_corruption(tiles, neighbors, frontier)
    local visited, queue = {}, {}
    for cell in pairs(frontier) do
        if corruption_can_spread(tiles, cell) then
            visited[cell] = true
            queue[#queue + 1] = cell
        end
    end
    local index = 1
    while index <= #queue do
        for _, near in ipairs(neighbors[queue[index]]) do
            if not visited[near] and corruption_can_spread(tiles, near) then
                visited[near] = true
                queue[#queue + 1] = near
            end
        end
        index = index + 1
    end
    return #queue
end

local function open_basin(tiles, neighbors, start, basins)
    local basin = {size = 0}
    local queue, index = {start}, 1
    basins[start] = basin
    while index <= #queue do
        for _, near in ipairs(neighbors[queue[index]]) do
            if not basins[near] and corruption_can_spread(tiles, near) then
                basins[near] = basin
                queue[#queue + 1] = near
            end
        end
        index = index + 1
    end
    basin.size = #queue
    return basin
end

local function corruption_penalty(board, tiles, neighbors)
    if not board.corruption_frontier then return 0 end
    if board.corruption_groups then
        local penalty = 0
        local basins, counted = {}, {}
        for _, group in ipairs(board.corruption_groups) do
            local frontier_count = 0
            for cell in pairs(group.border) do
                if corruption_can_spread(tiles, cell) then
                    frontier_count = frontier_count + 1
                    local basin = basins[cell] or open_basin(tiles, neighbors, cell, basins)
                    if not counted[basin] then
                        penalty = penalty + 0.3 * basin.size * board.corruption_weight * group.weight
                        counted[basin] = true
                    end
                end
            end
            if frontier_count == 0 then
                penalty = penalty - 1.2 * group.size * group.weight
            else
                penalty = penalty + 3 * frontier_count * board.corruption_weight * group.weight
            end
        end
        return penalty
    end
    local open = reachable_from_corruption(tiles, neighbors, board.corruption_frontier)
    if open == 0 then return -35 end
    return board.corruption_weight * open
end

local function church_scored(tiles, goal)
    for _, cell in ipairs(goal.cells) do
        local tile = tiles[cell]
        if tile and tile.building and tile.district == 0 then return true end
    end
    return false
end

local function fits_empty(tiles, move)
    for _, cell in ipairs(move.cells) do
        if not free(tiles, cell) then return false end
    end
    return true
end

local function church_moves(board, neighbors, piece, upcoming)
    local worship = {}
    if piece.district == 0 then worship[piece] = true end
    for _, shape in ipairs(upcoming) do
        if shape.district == 0 then worship[shape] = true end
    end
    local options = {}
    for _, goal in ipairs(board.objectives) do
        if goal.kind == "church" and not church_scored(board.tiles, goal) then
            local moves, seen = {}, {}
            for shape in pairs(worship) do
                for r, offsets in ipairs(shape.rotations) do
                    for _, cell in ipairs(goal.cells) do
                        local x, y = (cell - 1) % board.width, (cell - 1) // board.width
                        for _, offset in ipairs(offsets) do
                            local move = make_move(board, neighbors, offsets, x - offset.x, y - offset.y, r - 1)
                            if move and not seen[move.key] and fits_empty(board.tiles, move) then
                                seen[move.key] = true
                                moves[#moves + 1] = move
                            end
                        end
                    end
                end
            end
            if #moves > 0 then options[goal] = moves end
        end
    end
    return options
end

local function church_penalty(board, tiles)
    if not board.church_moves then return 0 end
    local penalty = 0
    for goal, moves in pairs(board.church_moves) do
        if not church_scored(tiles, goal) then
            local fits = false
            for _, move in ipairs(moves) do
                if fits_empty(tiles, move) then fits = true; break end
            end
            if not fits then penalty = penalty + 78 end
        end
    end
    return penalty
end

local function district_link(tile, district)
    return tile and (tile.district == district or (tile.connector and not tile.start))
end

local function clusters(board, tiles, neighbors, district)
    local identifiers, sizes, largest, largest_id, total_area = {}, {}, 0, nil, 0
    local w = board.width
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
                    if district_link(other, district) and not identifiers[near] then
                        identifiers[near] = id
                        queue[#queue + 1] = near
                    end
                end
                local across = board.crossings[index]
                if across then
                    for _, bank in ipairs(across) do
                        local other = tiles[bank.across]
                        if district_link(other, district) and not identifiers[bank.across] then
                            identifiers[bank.across] = id
                            queue[#queue + 1] = bank.across
                        end
                    end
                end
                at = at + 1
            end
            sizes[id] = area
            total_area = total_area + area
            if area > largest then
                largest, largest_id = area, id
            end
        end
    end
    local frontier, frontier_count = {}, 0
    local mx, my, mc = 0, 0, 0
    local wx, wy, wc = 0, 0, 0
    if largest_id then
        for cell, id in pairs(identifiers) do
            local tx, ty = (cell - 1) % w, (cell - 1) // w
            if id == largest_id then
                if tiles[cell].district == district then
                    mx, my, mc = mx + tx, my + ty, mc + 1
                end
                for _, near in ipairs(neighbors[cell]) do
                    if not frontier[near] and free(tiles, near) then
                        frontier[near] = true
                        frontier_count = frontier_count + 1
                    end
                end
                local across = board.crossings[cell]
                if across then
                    for _, bank in ipairs(across) do
                        if not frontier[bank.across] and free(tiles, bank.across) then
                            frontier[bank.across] = true
                            frontier_count = frontier_count + 1
                        end
                    end
                end
            elseif tiles[cell].district == district then
                wx, wy, wc = wx + tx, wy + ty, wc + 1
            end
        end
    end
    return {
        ids = identifiers, sizes = sizes, largest = largest, largest_id = largest_id,
        total_area = total_area, wasted = total_area - largest,
        frontier = frontier, frontier_count = frontier_count,
        main_cx = mc > 0 and (mx / mc) or nil, main_cy = mc > 0 and (my / mc) or nil,
        waste_cx = wc > 0 and (wx / wc) or nil, waste_cy = wc > 0 and (wy / wc) or nil,
    }
end

local function all_district_maps(board, tiles, neighbors)
    return {
        [0] = clusters(board, tiles, neighbors, 0),
        [1] = clusters(board, tiles, neighbors, 1),
        [2] = clusters(board, tiles, neighbors, 2),
    }
end

local function cluster_metrics(move, joined_banks, district_map, base_area)
    local seen, touched, area, hits_largest = {}, 0, base_area, false
    local lid = district_map.largest_id
    for _, cell in ipairs(move.rim) do
        local id = district_map.ids[cell]
        if id and not seen[id] then
            seen[id] = true
            touched = touched + 1
            area = area + district_map.sizes[id]
            if id == lid then hits_largest = true end
        end
    end
    for cell in pairs(joined_banks) do
        local id = district_map.ids[cell]
        if id and not seen[id] then
            seen[id] = true
            touched = touched + 1
            area = area + district_map.sizes[id]
            if id == lid then hits_largest = true end
        end
    end
    return math.max(0, area - district_map.largest), touched, hits_largest
end

local function mixed_district_score(board, tiles, move, maps)
    local value = 0
    for district, part in pairs(move.district_parts) do
        local banks = {}
        for _, cell in ipairs(part.cells) do
            for _, link in ipairs(board.crossings[cell] or {}) do
                if district_link(tiles[link.across], district) then banks[link.across] = true end
            end
        end
        local map = maps[district]
        local gain, touched = cluster_metrics(part, banks, map, #part.cells)
        value = value + 3.2 * gain + 5 * math.max(0, touched - 1)
        if gain == 0 and map.largest > 0 then value = value - 2.8 * #part.cells end
        if board.district_seeds and map.largest < 20 then
            local seed = board.district_seeds[district]
            local distance = math.abs(part.cx - seed.x) + math.abs(part.cy - seed.y)
            value = value - distance * (20 - map.largest) * 0.055
        end
    end
    return value
end

local function has_room(tiles, neighbors, cell)
    for _, adjacent in ipairs(neighbors[cell]) do
        if will_free(tiles, adjacent) then return true end
    end
    return false
end

local function building_distance(board, tiles, x, y)
    local distance = board.width + board.height
    for cell, tile in pairs(tiles) do
        if tile.start or (tile.building and (not board.contain_corruption or not tile.road)) then
            local tx, ty = (cell - 1) % board.width, (cell - 1) // board.width
            distance = math.min(distance, math.abs(tx - x) + math.abs(ty - y))
        end
    end
    return distance
end

local function objective_progress(board, tiles, neighbors)
    local progress = {}
    for _, goal in ipairs(board.objectives) do
        if tiles[goal.anchor] == goal.tile then
            local filled, possible, waiting = 0, 0, 0
            for _, cell in ipairs(goal.cells) do
                local t = tiles[cell]
                if t and t.building and (goal.district == nil or t.district == goal.district) then
                    filled, possible = filled + 1, possible + 1
                elseif t and t.geyser and not t.geyser_active then
                    possible, waiting = possible + 1, waiting + 1
                elseif free(tiles, cell) and (board.has_single or has_room(tiles, neighbors, cell)) then
                    possible = possible + 1
                end
            end
            if filled < goal.need and possible >= goal.need then
                local status = {filled = filled, possible = possible, waiting = waiting}
                local approach_tree = board.large_tree_focus and goal.kind == "tree" and goal.tile.tree_points > 20
                local approach_church = board.contain_corruption and goal.kind == "church"
                local approach_crate_tree = board.contain_corruption and goal.kind == "tree"
                    and (goal.anchor - 1) % board.width >= 20 and board.remaining_pieces > 25
                local approach_small_tree = (board.approach_lighthouse or board.approach_trees)
                    and goal.kind == "tree" and board.remaining_pieces > 15
                if approach_tree or approach_church or approach_crate_tree or approach_small_tree then
                    local gx = (goal.anchor - 1) % board.width
                    local gy = (goal.anchor - 1) // board.width
                    local central_church = approach_church and gx == 14 and gy == 9
                    if central_church then gx = 9 end
                    status.x, status.y, status.distance = gx, gy, building_distance(board, tiles, gx, gy)
                    status.approach_weight = approach_tree and 6 or (central_church and 8
                        or (approach_crate_tree and 3.2 or (approach_small_tree and 2.8 or (gx < 20 and 5.6 or 2.1))))
                    status.check_cells = approach_church or approach_crate_tree
                end
                progress[goal] = status
            end
        end
    end
    local route = board.opening_route
    if route and board.remaining_pieces >= route.remaining then
        for _, point in ipairs(route) do
            local tile = tiles[point.y * board.width + point.x + 1]
            if not tile or (not tile.building and not tile.corruption) then
                progress[route] = {x = point.x, y = point.y, check_cells = true,
                    distance = building_distance(board, tiles, point.x, point.y), approach_weight = route.weight,
                    approach_district = route.district}
                break
            end
        end
    end
    if board.approach_lighthouse then
        for _, cell in ipairs(board.lighthouse_parts) do
            local tile = tiles[cell]
            if not tile or not tile.building then
                local x, y = (cell - 1) % board.width, (cell - 1) // board.width
                local point = {x = x, y = y, check_cells = true,
                    distance = building_distance(board, tiles, x, y), approach_weight = y > 18 and 5.2 or 4.1}
                progress[point] = point
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
        if related then
            for _, goal in ipairs(related) do
                local before = tiles[cell]
                local counts = before and before.building and (goal.district == nil or before.district == goal.district)
                if progress[goal] and not counts and not move.covered[goal.anchor] then
                    if goal.district == nil or piece.district == goal.district then
                        additions[goal] = (additions[goal] or 0) + 1
                    else
                        sealed[goal] = (sealed[goal] or 0) + 1
                    end
                end
            end
        end
    end
    local progress_weight = board.objective_focus and 0.65 or 0.32
    for goal, added in pairs(additions) do
        local start = progress[goal].filled / goal.need
        local finish = math.min(progress[goal].filled + added, goal.need) / goal.need
        local completion = finish == 1 and 0.65 or 0
        value = value + goal.reward * ((finish - start) * (progress_weight + 0.25 * (start + finish)) + completion)
    end
    for goal, lost in pairs(sealed) do
        local status = progress[goal]
        if status and status.possible - lost < goal.need
                and status.filled + (additions[goal] or 0) < goal.need then
            value = value - goal.reward * 0.9
        end
    end
    return value
end

local function active_geyser_points(board, tiles)
    if (board.geyser_active_total or 0) == 0 then return 0, nil end
    local count, seen, list = 0, {}, {}
    local w = board.width
    for cell, actor in pairs(board.geysers) do
        local tile = tiles[cell]
        if tile and tile.geyser_active and not tile.building and not seen[actor] then
            seen[actor] = true
            count = count + 1
            list[count] = {x = (cell - 1) % w, y = (cell - 1) // w}
        end
    end
    if board.chain_geysers then
        for _, point in ipairs(list) do point.distance = w + board.height end
        for cell, tile in pairs(tiles) do
            if tile.building or tile.start then
                local x, y = (cell - 1) % w, (cell - 1) // w
                for _, point in ipairs(list) do
                    point.distance = math.min(point.distance, math.abs(x - point.x) + math.abs(y - point.y))
                end
            end
        end
    end
    return count, list
end

local function has_bridge(board, tiles, river)
    local function occupied(cell)
        return tiles[cell] and tiles[cell].building
    end
    local x = (river - 1) % board.width
    return (x > 0 and x + 1 < board.width and occupied(river - 1) and occupied(river + 1))
        or (occupied(river - board.width) and occupied(river + board.width))
end

local function evaluate(board, tiles, neighbors, move, piece, maps, progress, geysers_left, geyser_pts, rem_pieces, attempt, require_fit)
    local cover, goal, adjacent, contacts, pockets = 0, 0, 0, 0, 0
    local connected = false
    local covered_goals, sealed = {}, {}
    local joined_banks, bridges, bridge_points = {}, {}, 0
    local cross_contacts
    if board.score_crossings then cross_contacts = {} end
    local hit_geysers, tight_geyser_bonus = 0, 0
    local sealed_geyser_penalty = 0
    local touches_connector = false
    local preserve_basin = board.corruption_basin_x and piece.building
        and rem_pieces > board.corruption_start + 4

    for _, cell in ipairs(move.cells) do
        local tile = tiles[cell]
        if require_fit and not free(tiles, cell) then return end
        if board.corruption_frontier and board.corruption_frontier[cell] and piece.building then
            goal = goal + 6.5
        end
        if preserve_basin then
            local x = (cell - 1) % board.width
            goal = goal - 1.7 * math.max(0, x - board.corruption_basin_x + 1)
        end
        if tile and tile.actor and tile.cover ~= 0 and not covered_goals[tile.actor] then
            covered_goals[tile.actor] = true
            cover = cover + (board.contain_corruption and tile.crate and 16 or tile.cover)
        end
        if tile and tile.geyser_active and not tile.building and not covered_goals[tile.actor or cell] then
            covered_goals[tile.actor or cell] = true
            hit_geysers = hit_geysers + 1
            local open_around = 0
            for _, near in ipairs(neighbors[cell]) do
                if free(tiles, near) then open_around = open_around + 1 end
            end
            if open_around <= 1 then tight_geyser_bonus = tight_geyser_bonus + 10 end
        end
        local across = piece.building and board.crossings[cell]
        if across then
            for _, bank in ipairs(across) do
                local opposite = tiles[bank.across]
                if opposite and opposite.building then
                    connected = true
                    if not bridges[bank.river] then
                        bridges[bank.river] = true
                        if not board.score_crossings or not has_bridge(board, tiles, bank.river) then
                            bridge_points = bridge_points + 2
                        end
                    end
                    if cross_contacts and not cross_contacts[bank.across] and not move.edges[bank.across] then
                        cross_contacts[bank.across] = true
                        adjacent = adjacent + opposite.neighbor
                    end
                    if opposite.district == piece.district or opposite.connector or piece.connector then
                        joined_banks[bank.across] = true
                    end
                    if opposite.connector then touches_connector = true end
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
            if tile.connector then touches_connector = true end
        end
        if free(tiles, cell) then
            local open = 0
            for _, near in ipairs(neighbors[cell]) do
                if not move.covered[near] and will_free(tiles, near) then open = open + 1 end
            end
            if open == 0 then
                pockets = pockets + 2
                local related = board.objectives_at[cell]
                if related and not board.has_single then
                    for _, target in ipairs(related) do sealed[target] = (sealed[target] or 0) + 1 end
                end
                if tile and tile.geyser_active and not tile.building and not board.has_single then
                    sealed_geyser_penalty = sealed_geyser_penalty + 45
                end
            elseif open == 1 then
                pockets = pockets + 0.5
            end
        end
    end

    if require_fit and piece.building and not piece.start and not connected then return end

    local district_score = 0
    local choke_penalty = 0
    local rem_dist = board.remaining_districts
    local is_splitting = false

    if piece.district ~= nil then
        local own_map = maps[piece.district]
        local gain, touched, hits_largest = cluster_metrics(move, joined_banks, own_map, #move.cells)
        local dist_weight = attempt % 2 == 1 and 1.95 or 1.75
        if board.bridge_focus then dist_weight = 1.1
        elseif board.objective_focus then dist_weight = dist_weight + 0.9 end
        if board.district_seeds then dist_weight = dist_weight + 0.55 end
        if board.contain_corruption and piece.district == 2 then dist_weight = dist_weight + 0.6 end
        if own_map.largest > 0 then
            if gain > 0 then
                district_score = gain * dist_weight
                if touched >= 2 then
                    district_score = district_score + 6.5 * (touched - 1)
                end
                if own_map.waste_cx and hits_largest then
                    local dist = math.abs(move.cx - own_map.waste_cx) + math.abs(move.cy - own_map.waste_cy)
                    district_score = district_score + 2.2 / (1 + 0.25 * dist)
                end
            elseif touched > 0 then
                is_splitting = true
                district_score = -1.9 * #move.cells
                if own_map.main_cx then
                    local dist = math.abs(move.cx - own_map.main_cx) + math.abs(move.cy - own_map.main_cy)
                    district_score = district_score + 1.8 / (1 + 0.25 * dist)
                end
            else
                is_splitting = true
                district_score = -3.8 * #move.cells
            end
        else
            district_score = #move.cells * 1.4 + (touches_connector and 4.0 or 0)
        end
        if board.district_seeds and own_map.largest < 20 then
            local seed = board.district_seeds[piece.district]
            local distance = math.abs(move.cx - seed.x) + math.abs(move.cy - seed.y)
            district_score = district_score - distance * (20 - own_map.largest) * 0.055
        end

        if not connected then
            district_score = district_score - 6.0
        end

        if rem_dist then
            for d = 0, 2 do
                if d ~= piece.district and (rem_dist[d] or 0) > 0 then
                    local omap = maps[d]
                    if omap.largest > 0 and omap.frontier_count > 0 then
                        local blocked = 0
                        for _, cell in ipairs(move.cells) do
                            if omap.frontier[cell] then blocked = blocked + 1 end
                        end
                        if blocked > 0 then
                            local left = omap.frontier_count - blocked
                            local rem_cells = rem_dist[d]
                            if left <= 0 then
                                choke_penalty = choke_penalty + math.min(36, rem_cells * 1.4)
                            elseif left == 1 then
                                choke_penalty = choke_penalty + math.min(14, rem_cells * 0.55)
                            elseif left == 2 then
                                choke_penalty = choke_penalty + math.min(6, rem_cells * 0.22)
                            end
                        end
                    end
                end
            end
        end
    elseif move.district_parts then
        district_score = mixed_district_score(board, tiles, move, maps)
    elseif piece.connector then
        local total_gain, hub_districts = 0, 0
        for d = 0, 2 do
            local gain, touched = cluster_metrics(move, joined_banks, maps[d], 0)
            total_gain = total_gain + gain
            if touched > 0 then hub_districts = hub_districts + 1 end
        end
        district_score = total_gain * 2.2
        if piece.start then
            local tx, ty = (board.width - 1) * 0.5, (board.height - 1) * 0.5
            local opening = board.opening_center
            if opening then
                tx, ty = opening.x, opening.y
            elseif geyser_pts and #geyser_pts > 0 and #geyser_pts <= 4 then
                local gx, gy = 0, 0
                for _, gp in ipairs(geyser_pts) do gx, gy = gx + gp.x, gy + gp.y end
                tx = tx * 0.35 + (gx / #geyser_pts) * 0.65
                ty = ty * 0.35 + (gy / #geyser_pts) * 0.65
            end
            local dcenter = math.abs(move.cx - tx) + math.abs(move.cy - ty)
            district_score = district_score - dcenter * (opening and opening.weight or 0.85)
        else
            if hub_districts >= 2 then
                local hub_weight = board.objective_focus and 6.5 or 4.5
                district_score = district_score + hub_weight * hub_districts
            elseif total_gain == 0 and hub_districts <= 1 then
                district_score = district_score - 3.5
            end
            if not connected then
                district_score = district_score - 6.0
            end
        end
    end

    local obj_val = objective_gain(board, tiles, move, piece, progress, sealed)
    local raw_bridges = bridge_points
    if board.objective_focus then
        -- 给环绕庙宇留出开局空间，也保留向河对岸扩展街区的方向。
        obj_val = obj_val * (attempt % 2 == 0 and 1.7 or 1.95)
        local bridge_weight = board.bridge_weight
        if not bridge_weight then
            bridge_weight = board.bridge_focus and (attempt % 2 == 0 and 1.65 or 2.1) or 1.5
            if board.score_late_moves then bridge_weight = attempt % 2 == 0 and 2.15 or 1.8 end
        end
        bridge_points = bridge_points * bridge_weight
        local opening = board.temple_opening
        if piece.start and opening then
            for target in pairs(progress) do
                if target.kind == "temple" then
                    local x = (target.anchor - 1) % board.width + opening.x
                    local y = (target.anchor - 1) // board.width + opening.y
                    goal = goal - opening.weight * (math.abs(move.cx - x) + math.abs(move.cy - y))
                    break
                end
            end
        end
    elseif is_splitting and rem_pieces > 10 and obj_val > 0 then
        obj_val = obj_val * 0.45
    end
    goal = goal + obj_val
    if (board.large_tree_focus or board.contain_corruption or board.opening_route or board.approach_trees)
            and not piece.start then
        for _, status in pairs(progress) do
            if status.distance then
                local distance = math.abs(move.cx - status.x) + math.abs(move.cy - status.y)
                if status.check_cells then
                    for _, cell in ipairs(move.cells) do
                        local x, y = (cell - 1) % board.width, (cell - 1) // board.width
                        distance = math.min(distance, math.abs(x - status.x) + math.abs(y - status.y))
                    end
                end
                local weight = status.approach_weight
                if status.approach_district and piece.district ~= status.approach_district and not piece.connector then
                    weight = weight * 0.45
                end
                goal = goal + weight * math.max(0, status.distance - distance)
            end
        end
    end

    if geysers_left > 0 then
        if hit_geysers > 0 then
            local total_g = math.max(board.geyser_total or 1, geysers_left)
            local inactive_g = math.max(0, total_g - (board.geyser_active_total or geysers_left))
            local geyser_val
            if board.chain_geysers and inactive_g > 0 then
                -- 第一波处理完才会开放其余泉眼，尽早为第二波留出拼块。
                local unlock_bonus = hit_geysers >= geysers_left and 30 or 0
                geyser_val = 16 * hit_geysers + unlock_bonus
            elseif inactive_g > 0 then
                if not is_splitting then
                    local finish_wave = hit_geysers >= geysers_left and 11.0 or (geysers_left <= 2 and 5.0 or 0)
                    geyser_val = 7.5 * hit_geysers + finish_wave
                else
                    local late = rem_pieces <= math.ceil(total_g * 0.65) + 4
                    geyser_val = (late and 5.0 or 1.8) * hit_geysers
                end
            else
                local start_r = (total_g - geysers_left) / total_g
                local end_r = math.min(total_g, total_g - geysers_left + hit_geysers) / total_g
                local completion = end_r >= 1 and 0.45 or 0
                geyser_val = 50 * ((end_r - start_r) * (0.75 + 0.45 * (start_r + end_r)) + completion)
                if is_splitting and rem_pieces > geysers_left * 2 + 6 then
                    geyser_val = geyser_val * 0.45
                elseif rem_pieces <= geysers_left * 2 + 4 then
                    geyser_val = geyser_val + 12 * hit_geysers
                end
            end
            goal = goal + geyser_val + tight_geyser_bonus
        elseif board.chain_geysers and not piece.start and geyser_pts then
            local approach = 0
            for _, point in ipairs(geyser_pts) do
                local distance = math.abs(move.cx - point.x) + math.abs(move.cy - point.y)
                approach = math.max(approach, point.distance - distance)
            end
            goal = goal + 5.5 * approach
        elseif not is_splitting and not piece.start and geyser_pts and #geyser_pts > 0 then
            local min_d = 999
            for _, gp in ipairs(geyser_pts) do
                local d = math.abs(move.cx - gp.x) + math.abs(move.cy - gp.y)
                if d < min_d then min_d = d end
            end
            goal = goal + 2.4 / (1 + 0.35 * min_d)
        end
    end
    goal = goal - sealed_geyser_penalty

    local noise = ((move.x * 163 + move.y * 311 + move.rotation * 521 + attempt * move.x * move.y * 17) % 997) / 997
    local space_weight = 0.72 + 0.22 * (attempt % 4)
    local neighbor_weight = 1.12
    if board.neighbor_weight then
        neighbor_weight = board.neighbor_weight
    elseif board.approach_lighthouse then
        neighbor_weight = rem_pieces <= 22 and 1.9 or 1.55
    elseif board.contain_corruption then
        neighbor_weight = rem_pieces <= 24 and 1.8 or 1.4
    elseif board.score_late_moves then
        if next(progress) == nil then neighbor_weight = attempt % 2 == 0 and 1.85 or 1.65
        else neighbor_weight = 1.25 end
    end
    local value = adjacent * neighbor_weight + bridge_points + (cover + goal) * (1 + 0.08 * (attempt % 3))
        + district_score - choke_penalty + 0.50 * contacts + 0.42 * #move.cells - space_weight * pockets
        + noise * (attempt == 0 and 0.02 or 0.22 * attempt)
    return value, adjacent, raw_bridges, board.score_late_moves and neighbor_weight or 1
end

local function reachable_area(board, tiles, neighbors, frontier, limit)
    local visited, queue, head, count = {}, {}, 1, 0
    for cell in pairs(frontier) do
        visited[cell] = true
        count = count + 1
        queue[count] = cell
        if count >= limit then return count end
    end
    while head <= count do
        local curr = queue[head]
        head = head + 1
        for _, near in ipairs(neighbors[curr]) do
            if not visited[near] and will_free(tiles, near) then
                visited[near] = true
                count = count + 1
                queue[count] = near
                if count >= limit then return count end
            end
        end
        local across = board.crossings[curr]
        if across then
            for _, bank in ipairs(across) do
                local dest = bank.across
                if not visited[dest] and will_free(tiles, dest) then
                    visited[dest] = true
                    count = count + 1
                    queue[count] = dest
                    if count >= limit then return count end
                end
            end
        end
    end
    return count
end

local function capacity_penalty(board, tiles, neighbors, maps, rem_dist)
    if not rem_dist then return 0 end
    local penalty = 0
    for d = 0, 2 do
        local rem_cells = rem_dist[d] or 0
        local m = maps[d]
        if rem_cells > 0 and m.largest > 0 then
            local area = reachable_area(board, tiles, neighbors, m.frontier, rem_cells + 2)
            if area < rem_cells then
                penalty = penalty + (rem_cells - area) * 2.0 + 8
            end
        end
    end
    return penalty
end

local function terminal_bonus(board, tiles, neighbors, rem_dist)
    local maps = all_district_maps(board, tiles, neighbors)
    local bonus = -capacity_penalty(board, tiles, neighbors, maps, rem_dist)
        - corruption_penalty(board, tiles, neighbors) - church_penalty(board, tiles)
    local waste_weight = board.objective_focus and 3.2 or 2.0
    if board.score_late_moves then waste_weight = 4.1 end
    if board.split_corruption then waste_weight = 5.0 end
    for d = 0, 2 do
        local m = maps[d]
        bonus = bonus - m.wasted * waste_weight
        if rem_dist and (rem_dist[d] or 0) > 0 and m.largest > 0 then
            if m.frontier_count == 0 then
                bonus = bonus - math.min(28, rem_dist[d] * 1.0)
            elseif m.frontier_count <= 2 then
                bonus = bonus - math.min(10, rem_dist[d] * 0.35)
            end
        end
    end
    return bonus
end

local function packing_penalty(board, tiles, connectors)
    if not board.connector_spots or not connectors or connectors == 0 then return 0 end
    local needed = connectors * board.connector_size
    local covered, count = {}, 0
    for _, move in ipairs(board.connector_spots) do
        local fits = true
        for _, cell in ipairs(move.cells) do
            if not free(tiles, cell) then fits = false; break end
        end
        if fits then
            for _, cell in ipairs(move.cells) do
                if not covered[cell] then
                    covered[cell], count = true, count + 1
                    if count >= needed then return 0 end
                end
            end
        end
    end
    return (needed - count) * 2.5
end

local function search_penalty(board, tiles, neighbors, maps, rem_dist, connectors)
    local penalty = capacity_penalty(board, tiles, neighbors, maps, rem_dist)
    if board.objective_focus then
        for d = 0, 2 do penalty = penalty + maps[d].wasted end
    end
    return penalty + packing_penalty(board, tiles, connectors)
        + corruption_penalty(board, tiles, neighbors) + church_penalty(board, tiles)
end

local function keep_best(ranked, candidate, limit)
    local score = candidate.rank or candidate.value
    if #ranked == limit and score <= (ranked[limit].rank or ranked[limit].value) then return end
    local at = #ranked + 1
    while at > 1 and score > (ranked[at - 1].rank or ranked[at - 1].value) do
        at = at - 1
    end
    table.insert(ranked, at, candidate)
    if #ranked > limit then ranked[limit + 1] = nil end
end

local function apply(board, move, tile, before)
    local after = {}
    for cell, occupant in pairs(before) do after[cell] = occupant end
    if move.district_parts then
        for district, part in pairs(move.district_parts) do
            for _, cell in ipairs(part.cells) do after[cell] = tile.district_tiles[district] end
        end
    else
        for _, cell in ipairs(move.cells) do after[cell] = tile end
    end
    if board.forecast_ruins and tile.building then
        for _, cell in ipairs(move.rim) do
            local ruin = before[cell]
            if ruin and ruin.ruin_floors then
                if ruin.ruin_floors == 1 then
                    after[cell] = board.river_cells[cell]
                else
                    local shorter = {}
                    for field, value in pairs(ruin) do shorter[field] = value end
                    shorter.ruin_floors = ruin.ruin_floors - 1
                    after[cell] = shorter
                end
            end
        end
    end
    return after
end

local function copy_rem(rem_dist, piece)
    if not rem_dist then return nil end
    local next_rem = {[0] = rem_dist[0] or 0, [1] = rem_dist[1] or 0, [2] = rem_dist[2] or 0}
    if piece and piece.district ~= nil then
        next_rem[piece.district] = math.max(0, next_rem[piece.district] - #piece.rotations[1])
    elseif piece and piece.district_area then
        for district, area in pairs(piece.district_area) do
            next_rem[district] = math.max(0, next_rem[district] - area)
        end
    end
    return next_rem
end

local function placement_score(board, tiles, move, piece, maps, next_maps, neighbor_score, bridges)
    local value = neighbor_score + bridges
    for d = 0, 2 do value = value + next_maps[d].largest - maps[d].largest end
    if not piece.building then return value end
    local collected = {}
    for _, cell in ipairs(move.cells) do
        local tile = tiles[cell]
        if tile and tile.actor and tile.cover > 0 and not collected[tile.actor] then
            collected[tile.actor] = true
            value = value + tile.cover
        end
    end
    for _, goal in ipairs(board.objectives) do
        if goal.kind == "tree" and tiles[goal.anchor] == goal.tile and not move.covered[goal.anchor] then
            local before, after = 0, 0
            for _, cell in ipairs(goal.cells) do
                local tile = tiles[cell]
                if tile and tile.building then
                    before, after = before + 1, after + 1
                elseif move.covered[cell] then
                    after = after + 1
                end
            end
            if before < goal.need and after >= goal.need then value = value + goal.tile.tree_points end
        elseif goal.kind == "church" and piece.district == 0 and not church_scored(tiles, goal) then
            for _, cell in ipairs(goal.cells) do
                if move.covered[cell] then value = value + 50; break end
            end
        elseif goal.kind == "lighthouse" then
            local completed, missing = true, false
            for _, cell in ipairs(goal.cells) do
                local tile = tiles[cell]
                if not tile or not tile.building then
                    missing = true
                    if not move.covered[cell] then completed = false; break end
                end
            end
            if completed and missing then value = value + goal.reward end
        end
    end
    return value
end

local function roots(board, neighbors, piece, attempt, legal, native_score)
    local candidates = {}
    local maps = all_district_maps(board, board.tiles, neighbors)
    local progress = objective_progress(board, board.tiles, neighbors)
    local geysers_left, geyser_pts = active_geyser_points(board, board.tiles)
    local rem_pieces = board.remaining_pieces or 20
    local final_move = board.exact_finish and rem_pieces == 1
    local rem_after = board.remaining_districts
    local prefilter = not piece.start
    for _, move in ipairs(geometry(board, neighbors, piece)) do
        local ok = true
        if prefilter then
            for _, cell in ipairs(move.cells) do
                local t = board.tiles[cell]
                if t and t.solid and not t.water then
                    ok = false
                    break
                end
            end
        end
        if ok then
            local value, predicted, bridges, weight = evaluate(board, board.tiles, neighbors, move, piece, maps, progress, geysers_left, geyser_pts, rem_pieces, attempt, false)
            candidates[#candidates + 1] = {move = move, value = value, predicted = predicted, bridges = bridges, weight = weight}
        end
    end
    table.sort(candidates, function(a, b) return a.value > b.value end)

    local beam, seen, visited = {}, {}, 0
    local finishing = board.score_late_moves and rem_pieces <= 16
    local beam_size = board.bridge_focus and 54 or (board.wide_search and 40 or (finishing and 34 or 24))
    local root_limit = finishing and 144 or (board.wide_search and 120 or 80)
    for _, candidate in ipairs(candidates) do
        local move = candidate.move
        if not seen[move.key] and legal(move) then
            seen[move.key] = true
            local live = native_score and native_score(move)
            if live then candidate.value = candidate.value + (live - candidate.predicted) * candidate.weight end
            local next_tiles = apply(board, move, piece, board.tiles)
            local next_maps = all_district_maps(board, next_tiles, neighbors)
            local penalty = search_penalty(board, next_tiles, neighbors, next_maps, rem_after, board.remaining_connectors)
            if final_move or board.exact_tail then
                candidate.value = placement_score(board, board.tiles, move, piece, maps, next_maps,
                    live or candidate.predicted, candidate.bridges)
                if final_move then penalty = corruption_penalty(board, next_tiles, neighbors) end
            elseif finishing then
                local gain = placement_score(board, board.tiles, move, piece, maps, next_maps,
                    live or candidate.predicted, candidate.bridges)
                candidate.value = 0.78 * candidate.value + 0.82 * gain
            end
            keep_best(beam, {
                first = move,
                tiles = next_tiles,
                value = candidate.value,
                rank = candidate.value - penalty,
            }, beam_size)
            visited = visited + 1
            if visited >= root_limit and not final_move then break end
        end
    end
    if #beam == 0 and prefilter then
        candidates = {}
        for _, move in ipairs(geometry(board, neighbors, piece)) do
            local value, predicted, _, weight = evaluate(board, board.tiles, neighbors, move, piece, maps, progress, geysers_left, geyser_pts, rem_pieces, attempt, false)
            candidates[#candidates + 1] = {move = move, value = value, predicted = predicted, weight = weight}
        end
        table.sort(candidates, function(a, b) return a.value > b.value end)
        for _, candidate in ipairs(candidates) do
            local move = candidate.move
            if not seen[move.key] and legal(move) then
                seen[move.key] = true
                local live = native_score and native_score(move)
                if live then candidate.value = candidate.value + (live - candidate.predicted) * candidate.weight end
                local next_tiles = apply(board, move, piece, board.tiles)
                local next_maps = all_district_maps(board, next_tiles, neighbors)
                local penalty = search_penalty(board, next_tiles, neighbors, next_maps, rem_after, board.remaining_connectors)
                keep_best(beam, {
                    first = move,
                    tiles = next_tiles,
                    value = candidate.value,
                    rank = candidate.value - penalty,
                }, beam_size)
                visited = visited + 1
                if visited >= 64 then break end
            end
        end
    end
    return beam
end

local function take_next(board, neighbors, beam, piece, depth, attempt, rem_after, connectors)
    local next_beam = {}
    local available, seen = {}, {}
    for _, move in ipairs(geometry(board, neighbors, piece)) do
        if not seen[move.key] then
            seen[move.key] = true
            local fits = true
            for _, cell in ipairs(move.cells) do
                local tile = board.tiles[cell]
                if not free(board.tiles, cell)
                        and not (board.forecast_ruins and tile.ruin_floors and not board.river_cells[cell]) then
                    fits = false
                    break
                end
            end
            if fits then available[#available + 1] = move end
        end
    end
    local rem_pieces = math.max(1, (board.remaining_pieces or 20) - (depth - 1))
    local pool = {}
    local finishing = board.score_late_moves and (board.remaining_pieces or 20) <= 16
    local pool_size = board.bridge_focus and 132 or (board.wide_search and 88
        or (finishing and 68 or (board.objective_focus and 48 or 32)))
    local move_limit = board.bridge_focus and 10 or (board.wide_search and 8 or 5)
    local beam_size = board.bridge_focus and 64 or (board.wide_search and 36 or (finishing and 30 or 20))
    local weight = (board.bridge_focus and 0.988 or 0.95) ^ (depth - 1)
    for _, state in ipairs(beam) do
        local maps = all_district_maps(board, state.tiles, neighbors)
        local progress = objective_progress(board, state.tiles, neighbors)
        local geysers_left, geyser_pts = active_geyser_points(board, state.tiles)
        local moves = {}
        for _, move in ipairs(available) do
            local value, adjacent, bridges = evaluate(board, state.tiles, neighbors, move, piece, maps,
                progress, geysers_left, geyser_pts, rem_pieces, attempt, true)
            if value then
                keep_best(moves, {move = move, value = value, adjacent = adjacent, bridges = bridges}, move_limit)
            end
        end
        for _, option in ipairs(moves) do
            local added = option.value * weight
            local candidate = {
                first = state.first,
                move = option.move,
                tiles = state.tiles,
                value = state.value + added,
                rank = (board.objective_focus and state.rank or state.value) + added,
            }
            if board.exact_tail then
                candidate.value = state.value
                candidate.rank = state.rank + option.adjacent + option.bridges + 0.28 * option.value
                candidate.maps, candidate.adjacent, candidate.bridges = maps, option.adjacent, option.bridges
            end
            keep_best(pool, candidate, pool_size)
        end
        if #moves == 0 then
            local loss = board.exact_tail and 0 or (board.opening_center and (8 + #piece.rotations[1] * 3) or 8)
            keep_best(pool, {
                first = state.first, tiles = state.tiles, value = state.value - loss * weight,
                rank = (board.objective_focus and state.rank or state.value) - loss * weight,
            }, pool_size)
        end
    end
    for _, state in ipairs(pool) do
        local next_tiles = state.move and apply(board, state.move, piece, state.tiles) or state.tiles
        local next_maps = all_district_maps(board, next_tiles, neighbors)
        local penalty = search_penalty(board, next_tiles, neighbors, next_maps, rem_after, connectors)
        if board.exact_tail then
            if state.move then
                state.value = state.value + placement_score(board, state.tiles, state.move, piece, state.maps,
                    next_maps, state.adjacent, state.bridges)
            end
            if rem_pieces == 1 then penalty = 0 end
        end
        keep_best(next_beam, {
            first = state.first,
            tiles = next_tiles,
            value = state.value,
            rank = state.value - penalty,
        }, beam_size)
    end
    return next_beam
end

local function choose_sapling(board, neighbors, piece, legal)
    local best, best_value = nil, -math.huge
    local seen = {}
    for _, move in ipairs(geometry(board, neighbors, piece)) do
        if not seen[move.key] then
            seen[move.key] = true
            local filled, missing = 0, 0
            for _, cell in ipairs(move.rim) do
                local tile = board.tiles[cell]
                if tile and tile.building then
                    filled = filled + 1
                elseif not tile or (not tile.solid and not tile.objective)
                        or (board.forecast_ruins and tile.ruin_floors) then
                    missing = missing + 1
                end
            end
            local value = filled - 8 * missing + (filled > 0 and missing == 0 and 100 or 0)
            if board.approach_lighthouse and filled == 0 then value = value - 10 end
            if value > best_value and legal(move) then best, best_value = move, value end
        end
    end
    return best
end

-- 对接下来的几块实际拼块做束搜索，每次用游戏校验首步。
function Solver.choose(board, piece, upcoming, attempt, legal, native_score)
    local neighbors = make_neighbors(board.width, board.height)
    if piece.sapling then return choose_sapling(board, neighbors, piece, legal) end
    board.crossings = make_crossings(board)
    if board.contain_corruption then
        board.church_moves = church_moves(board, neighbors, piece, upcoming)
        if board.remaining_pieces <= board.corruption_start then
            board.corruption_frontier = corruption_frontier(board, neighbors)
            board.corruption_weight = (board.corruption_pressure or 1)
                * (0.5 + 0.07 * (board.corruption_start - board.remaining_pieces))
            if board.split_corruption then
                board.corruption_groups = corruption_groups(board, neighbors)
            end
        end
    end
    if board.bridge_focus then
        for _, future in ipairs(upcoming) do
            if future.connector then
                board.connector_size = #future.rotations[1]
                board.connector_spots = {}
                for _, spot in ipairs(geometry(board, neighbors, future)) do
                    local fits = true
                    for _, cell in ipairs(spot.cells) do
                        if not free(board.tiles, cell) then fits = false; break end
                    end
                    if fits then board.connector_spots[#board.connector_spots + 1] = spot end
                end
                break
            end
        end
    end
    local beam = roots(board, neighbors, piece, attempt, legal, native_score)
    if #beam <= 1 or (board.exact_finish and #upcoming == 0) then return beam[1] and beam[1].first end
    local rem_after = board.remaining_districts
    local connectors = board.remaining_connectors or 0
    for index, next_piece in ipairs(upcoming) do
        rem_after = copy_rem(rem_after, next_piece)
        if next_piece.connector then connectors = math.max(0, connectors - 1) end
        beam = take_next(board, neighbors, beam, next_piece, index + 1, attempt, rem_after, connectors)
    end
    local best = beam[1]
    local best_score = best.value + (board.exact_tail and 0 or terminal_bonus(board, best.tiles, neighbors, rem_after))
    for i = 2, #beam do
        local s = beam[i].value + (board.exact_tail and 0 or terminal_bonus(board, beam[i].tiles, neighbors, rem_after))
        if s > best_score then
            best_score = s
            best = beam[i]
        end
    end
    return best.first
end

return Solver
