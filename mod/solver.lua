local Solver = {}

local function cells_at(board, offsets, x, y)
    local cells = {}
    for i, direction in ipairs(offsets) do
        local cx, cy = x + direction.x, y + direction.y
        if cx < 0 or cy < 0 or cx >= board.width or cy >= board.height then
            return nil
        end
        cells[i] = cy * board.width + cx + 1
    end
    return cells
end

local function neighbors(board, cell)
    local x = (cell - 1) % board.width
    return x > 0 and cell - 1 or 0,
        x + 1 < board.width and cell + 1 or 0,
        cell > board.width and cell - board.width or 0,
        cell <= board.width * (board.height - 1) and cell + board.width or 0
end

local function is_open(board, cell)
    return cell > 0 and not (board.tiles[cell] and board.tiles[cell].solid)
end

local function placement_value(board, piece, cells, space_weight)
    local filled = {}
    for _, cell in ipairs(cells) do filled[cell] = true end
    local value = 0
    local contacts, bordering = {}, {}
    for _, cell in ipairs(cells) do
        local tile = board.tiles[cell]
        if tile then value = value + (tile.reward or 0) end
        local a, b, c, d = neighbors(board, cell)
        for _, other in ipairs({a, b, c, d}) do
            if not filled[other] then
                local near = board.tiles[other]
                if near and near.district then
                    local same_district = near.district == piece.district or near.road or piece.road
                    value = value + (same_district and 1.8 or 0.55)
                    if not contacts[near.actor] then
                        contacts[near.actor] = true
                        value = value + (same_district and 2.3 or 0.8)
                    end
                elseif near and near.water then
                    value = value + (piece.district and 0.9 or 0.3)
                elseif is_open(board, other) then
                    bordering[other] = true
                    value = value - 0.22 * space_weight
                else
                    value = value + 0.25 * space_weight
                end
            end
        end
    end
    for cell in pairs(bordering) do
        local a, b, c, d = neighbors(board, cell)
        local exits, lost = 0, 0
        for _, other in ipairs({a, b, c, d}) do
            if filled[other] then
                lost = lost + 1
            elseif is_open(board, other) then
                exits = exits + 1
            end
        end
        if exits == 0 then value = value - 4.2 * space_weight
        elseif exits == 1 and lost > 0 then value = value - 1.4 * space_weight end
    end
    return value, filled
end

local function future_placements(board, piece)
    local placements = {}
    local seen = {}
    for _, offsets in ipairs(piece.rotations) do
        for y = 0, board.height - 1 do
            for x = 0, board.width - 1 do
                local cells = cells_at(board, offsets, x, y)
                if cells then
                    local open = true
                    for _, cell in ipairs(cells) do
                        if not is_open(board, cell) then open = false; break end
                    end
                    if open then
                        table.sort(cells)
                        local key = table.concat(cells, ",")
                        if not seen[key] then
                            seen[key] = true
                            placements[#placements + 1] = cells
                        end
                    end
                end
            end
        end
    end
    return placements
end

-- 当前一步由游戏校验。后续只估算空位，落子前会重新读取棋盘。
function Solver.choose(board, piece, upcoming, attempt, legal)
    local choices = {}
    local space_weight = 1.15 + 0.28 * (attempt % 4)
    for i, offsets in ipairs(piece.rotations) do
        for y = 0, board.height - 1 do
            for x = 0, board.width - 1 do
                local cells = cells_at(board, offsets, x, y)
                if cells then
                    local value, filled = placement_value(board, piece, cells, space_weight)
                    local rotation = i - 1
                    local variation = ((x * 163 + y * 311 + rotation * 521 + attempt * x * y * 17) % 997) / 997
                    choices[#choices + 1] = {
                        x = x, y = y, rotation = rotation, cells = cells, filled = filled,
                        value = value + variation * (attempt == 0 and 0.08 or 0.7 + attempt * 0.35),
                    }
                end
            end
        end
    end
    table.sort(choices, function(a, b) return a.value > b.value end)

    local futures = {}
    for i, future in ipairs(upcoming) do futures[i] = future_placements(board, future) end

    local best, evaluated = nil, 0
    for _, move in ipairs(choices) do
        if legal(move) then
            for depth, options in ipairs(futures) do
                local fits = 0
                for _, cells in ipairs(options) do
                    local clear = true
                    for _, cell in ipairs(cells) do
                        if move.filled[cell] then clear = false; break end
                    end
                    if clear then fits = fits + 1 end
                end
                if #options > 0 then
                    move.value = move.value + (fits == 0 and -23 / depth or 3 * math.log(fits / #options) / depth)
                end
            end
            if not best or move.value > best.value then best = move end
            evaluated = evaluated + 1
            if evaluated >= 24 then break end
        end
    end
    return best
end

return Solver
