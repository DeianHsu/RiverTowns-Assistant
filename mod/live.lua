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
    if file then
        local line = file:read("*l") or ""
        file:close()
        local id, serial, until_time, action, target = line:match("^(%S+)\t(%x+)\t(%d+)\t(%a+)\t([%w_]*)$")
        if id == self.id then self.command = {serial = serial, action = action, target = target, expiry = tonumber(until_time)} end
    end
    -- Windows 替换指令文件时，沿用最近一次有效指令直至它过期。
    local command = self.command
    if command and command.expiry >= os.time() then
        return command.serial, command.action, command.target
    end
end

return Live
