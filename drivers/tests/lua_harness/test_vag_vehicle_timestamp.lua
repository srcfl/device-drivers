-- Synthetic telemetry only: exercise the actual local selection functions.
dofile("drivers/tests/lua_harness/host_mock.lua")
local f = assert(io.open("drivers/lua/vag_vehicle.lua", "r"))
local source = f:read("*a")
f:close()
local select = assert(load(source .. "\nreturn {index=index_points, lookup=lookup}"))()
local function row(key, value, ts, name)
    return {key=key, value=value, timestampUtc=ts, dataFieldName=name}
end
local old = "2026-09-26T04:00:00Z"
local new = "2026-09-26T07:00:00Z"
local cases = {
    {"duplicate key, newest first", {row("s",72,new), row("s",80,old)}, {"s"}},
    {"duplicate key, newest last", {row("s",80,old), row("s",72,new)}, {"s"}},
    {"candidate GUIDs", {row("a",72,new), row("b",80,old)}, {"a","b"}},
    {"candidate priority", {row("a",80,old), row("b",72,new)}, {"a","b"}},
    {"shared name", {row("a",72,new,"s"), row("b",80,old,"s")}, {"s"}},
    {"missing timestamp", {row("s",72,new), row("s",80,nil)}, {"s"}},
    {"invalid timestamp", {row("s",80,"invalid"), row("s",72,new)}, {"s"}},
    {"unknown times fallback", {row("s",80,nil), row("s",72,nil)}, {"s"}},
    {"equal times fallback", {row("s",80,new), row("s",72,new)}, {"s"}},
    {"timezone offset", {row("a",72,"2026-09-26T08:00:01+01:00"), row("b",80,new)}, {"a","b"}},
    {"fractional seconds", {row("s",72,"2026-09-26T07:00:00.900Z"), row("s",80,"2026-09-26T07:00:00.100Z")}, {"s"}},
    {"empty value", {row("s",72,new), row("s","",new)}, {"s"}},
}
for _, c in ipairs(cases) do
    local got = select.lookup(select.index(c[2]), c[3])
    assert(got and got.value == "72", c[1])
end
assert(select.lookup(nil, {"s"}) == nil)
assert(select.lookup(select.index(nil), {"s"}) == nil)
print("vag_vehicle timestamps: ok")
