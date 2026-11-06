-- Synthetic telemetry only: exercise the actual local selection functions.
dofile("drivers/tests/lua_harness/host_mock.lua")
local f = assert(io.open("drivers/lua/vag_vehicle.lua", "r"))
local source = f:read("*a")
f:close()
local select = assert(load(source .. "\nreturn {index=index_points, lookup=lookup, diagnostics=log_soc_selection}"))()
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

-- Diagnostics retain overwritten rows and explain the selection without raw data.
local points, candidates = select.index({row("s",72,new), row("s",80,old)})
-- Use recognized names for collection, while retaining the duplicate-key test.
points, candidates = select.index({row("s",72,new,"state_of_charge"), row("s",80,old,"state_of_charge")})
assert(#candidates == 2)
select.diagnostics("synthetic.zip", candidates, select.lookup(points,{"s"}))
local logs = table.concat(host._logs, "\n")
assert(logs:find("candidates=2",1,true))
assert(logs:find("selected_row=1 reason=timestamp",1,true))
assert(logs:find("row=2 key=s",1,true))
select.diagnostics("synthetic.zip", {}, nil)
assert(table.concat(host._logs,"\n"):find("reason=no_candidate",1,true))

local equal, equal_candidates = select.index({
    row("s",80,new,"state_of_charge"), row("s",72,new,"state_of_charge")})
select.diagnostics("synthetic.zip", equal_candidates, select.lookup(equal,{"s"}))
assert(table.concat(host._logs,"\n"):find("reason=timestamp_then_dataset_order",1,true))
local missing, missing_candidates = select.index({row("s",72,nil,"state_of_charge")})
select.diagnostics("synthetic.zip", missing_candidates, select.lookup(missing,{"s"}))
assert(table.concat(host._logs,"\n"):find("reason=dataset_order_no_valid_timestamp",1,true))
local many = {}
for i=1,40 do many[i]=row("s",72,new,"state_of_charge") end
local indexed, collected = select.index(many)
select.diagnostics("synthetic.zip", collected, select.lookup(indexed,{"s"}))
assert(table.concat(host._logs,"\n"):find("truncated=8",1,true))
local vin = "WVWZZZTESTVIN0001"
driver_init({vin=vin,brand="volkswagen",cookie="synthetic"})
select.diagnostics("20260926070000_"..vin..".zip", {}, nil)
local masked = host._logs[#host._logs]
assert(not masked:find(vin,1,true))
assert(masked:find("****0001",1,true))
