local Live = {}
Live.__index = Live

function Live.connect(session, catalog)
    local levels, by_name = {}, {}
    local file = assert(io.open(catalog, "r"))
    for line in file:lines() do
        local world, level = line:match("^(0[1-4])\t(LVL[%w_]+)\t")
        assert(world and not by_name[level], "Invalid campaign level catalog")
        local entry = {world = world, level = level, index = #levels + 1}
        levels[entry.index], by_name[level] = entry, entry
    end
    file:close()
    assert(#levels > 0, "Empty campaign level catalog")
    local id = os.time() .. "-" .. assert(tostring(levels):match("(%x+)$"))
    return setmetatable({session = session, id = id, levels = levels, by_name = by_name,
        current = "", serial = ""}, Live)
end

function Live:request()
    local file = io.open(self.session .. "/command.tsv", "r")
    if not file then return end
    local line = file:read("*l") or ""
    file:close()
    local id, serial, until_time, action, target = line:match("^(%S+)\t(%x+)\t(%d+)\t(%a+)\t([%w_]*)$")
    if id == self.id and tonumber(until_time) >= os.time() then
        return serial, action, target
    end
end

return Live
