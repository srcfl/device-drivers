-- Synthetic telemetry only: exercise the actual local selection functions.
dofile("drivers/tests/lua_harness/host_mock.lua")
local f = assert(io.open("drivers/lua/vag_vehicle.lua", "r"))
local source = f:read("*a")
f:close()
local selection = assert(load(source .. "\nreturn {index=index_points, lookup=lookup, diagnostics=log_soc_selection}"))()
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
    local got = selection.lookup(selection.index(c[2]), c[3])
    assert(got and got.value == "72", c[1])
end
for _, invalid in ipairs({
    "2026-13-01T00:00:00Z", "2026-11-31T00:00:00Z", "2026-11-00T00:00:00Z",
    "2027-02-29T00:00:00Z", "2026-10-01T24:00:00Z", "2026-10-01T12:60:00Z",
    "2026-10-01T12:00:60Z", "2026-10-01T12:00:00+24:00", "2026-10-01T12:00:00+01:60",
}) do
    local got = selection.lookup(selection.index({row("s",72,new), row("s",80,invalid)}), {"s"})
    assert(got and got.value == "72", invalid)
end
local leap = selection.lookup(selection.index({
    row("s",72,"2028-02-29T00:00:00Z"), row("s",80,new),
}), {"s"})
assert(leap and leap.value == "72", "valid leap day was rejected")
assert(selection.lookup(nil, {"s"}) == nil)
assert(selection.lookup(selection.index(nil), {"s"}) == nil)
local soc_fields = {"state_of_charge", "hv_soc"}
for _, invalid in ipairs({"N/A", "-1", "101"}) do
    for _, field in ipairs(soc_fields) do
        local indexed, observed = selection.index({
            row("state_of_charge", "73 %", old),
            row(field, invalid, new),
        })
        local chosen = assert(selection.lookup(indexed, soc_fields))
        assert(chosen.value == "73 %" and chosen.ts == old)
        assert(#observed == 2 and observed[2].value == invalid)
    end
    assert(selection.lookup(selection.index({row("state_of_charge", invalid, new)}), soc_fields) == nil)
end
local zero = selection.lookup(selection.index({
    row("state_of_charge", 73, old),
    row("hv_soc", 0, new),
}), soc_fields)
assert(zero and zero.value == "0" and zero.ts == new)
print("vag_vehicle timestamps: ok")

-- Diagnostics retain overwritten rows and explain the selection without raw data.
local points, candidates = selection.index({row("s",72,new), row("s",80,old)})
-- Use recognized names for collection, while retaining the duplicate-key test.
points, candidates = selection.index({row("s",72,new,"state_of_charge"), row("s",80,old,"state_of_charge")})
assert(#candidates == 2)
selection.diagnostics("synthetic.zip", candidates, selection.lookup(points,{"s"}))
local logs = table.concat(host._logs, "\n")
assert(logs:find("candidates=2",1,true))
assert(logs:find("selected_row=1 reason=timestamp",1,true))
assert(logs:find("row=2 key=s",1,true))
selection.diagnostics("synthetic.zip", {}, nil)
assert(table.concat(host._logs,"\n"):find("reason=no_candidate",1,true))

local equal, equal_candidates = selection.index({
    row("s",80,new,"state_of_charge"), row("s",72,new,"state_of_charge")})
selection.diagnostics("synthetic.zip", equal_candidates, selection.lookup(equal,{"s"}))
assert(table.concat(host._logs,"\n"):find("reason=timestamp_then_dataset_order",1,true))
local missing, missing_candidates = selection.index({row("s",72,nil,"state_of_charge")})
selection.diagnostics("synthetic.zip", missing_candidates, selection.lookup(missing,{"s"}))
assert(table.concat(host._logs,"\n"):find("reason=dataset_order_no_valid_timestamp",1,true))
local many = {}
for i=1,40 do many[i]=row("s",72,new,"state_of_charge") end
local indexed, collected = selection.index(many)
selection.diagnostics("synthetic.zip", collected, selection.lookup(indexed,{"s"}))
assert(table.concat(host._logs,"\n"):find("truncated=8",1,true))
local vin = "WVWZZZTESTVIN0001"
driver_init({vin=vin,brand="volkswagen",cookie="synthetic"})
selection.diagnostics("20260926070000_"..vin..".zip", {}, nil)
local masked = host._logs[#host._logs]
assert(not masked:find(vin,1,true))
assert(masked:find("****0001",1,true))
