-- VAG vehicle telemetry (VW / Audi / Škoda / SEAT / Cupra)
-- Emits: Vehicle (DerVehicle)
-- Protocol: HTTPS — VW Group EU Data Act portal
--
-- We Connect / CarNet third-party access is blocked. The remaining
-- owner-accessible door is the EU Data Act portal operated by
-- Volkswagen Group Info Services AG:
--   https://eu-data-act.drivesomethinggreater.com/
-- That portal is not live BMS. After the owner enables a continuous
-- "All Data" request it writes a zipped JSON dataset about every
-- 15 minutes. This driver downloads the newest content file and maps
-- the charging fields Tesla already taught Core: SoC, charge limit,
-- charging_state, time-to-full, freshness.
--
-- Cloud is optional context, never a charging prerequisite. A missing
-- cookie, a sleeping car, or a 15-minute-old zip must not look like
-- a fresh BMS reading and must not stop the wallbox.
--
-- Porsche is not on this portal (VW, Audi, Škoda, SEAT, Cupra, MAN,
-- Bentley, Elli). No wake / charge_start / climatisation — telemetry
-- only. FTW's Lua host has no cookie jar and cannot complete the
-- portal's OIDC form login, so the owner pastes a logged-in session
-- Cookie header. When it expires the driver stops emitting.
--
-- What the site owner must provide:
--   1. A brand account already linked to the car.
--   2. One-time consent on the portal, then
--      Get customised data → continuous → All Data → 15 minutes.
--   3. VIN, brand, and the Cookie header from a logged-in portal tab
--      (DevTools → Network → any portal request → Request Headers).
--
--   drivers:
--     - name: id4
--       lua: drivers/vag_vehicle.lua
--       capabilities:
--         http:
--           allowed_hosts: ["eu-data-act.drivesomethinggreater.com"]
--       config:
--         vin: "WVWZZZ..."
--         brand: volkswagen          # audi | skoda | seat | cupra
--         cookie: "name=value; ..."  # masked via config_secrets
--
-- Keys (GUIDs) and names come from VW's data dictionary ("DataDictionary
-- V5.0, Continuous Data"), as parsed in evcc's vehicle/vw/eudataact, which
-- reads the same portal. As there, the newest point among the candidates
-- wins. battery_state_report.soc is looked up by key only: four points
-- share that name.

DRIVER = {
  host_api_min = 1,
  host_api_max = 1,
  id           = "vag_vehicle",
  name         = "VAG Vehicle (EU Data Act)",
  manufacturer = "Volkswagen Group",
  version      = "0.1.0",
  protocols    = { "http" },
  capabilities = { "vehicle" },
  read_only    = true,
  description  = "Read-only VW / Audi / Škoda / SEAT / Cupra SoC and charge state from the EU Data Act portal. Not live BMS; charging does not need this cloud.",
  homepage     = "https://eu-data-act.drivesomethinggreater.com/",
  http_hosts   = { "eu-data-act.drivesomethinggreater.com" },
  authors      = { "FTW contributors" },
  tested_models = { "ID.3", "ID.4", "Enyaq", "Q4 e-tron" },
  verification_status = "experimental",
  config_secrets = { "cookie" },
}

PROTOCOL = "http"

local BASE_URL = "https://eu-data-act.drivesomethinggreater.com"
-- The portal writes a file about every 15 minutes; asking every 5 is
-- enough. The host keeps the interval last set with set_poll_interval.
local POLL_INTERVAL_MS = 300000
local WATCHDOG_TIMEOUT_S = 600
-- Portal cadence is ~15 min. Keep a last reading visible a little
-- longer than that, then stop so Core's watchdog sees the gap.
local STALE_AFTER_MS = 2700000

local BRANDS = {
  volkswagen = "Volkswagen",
  vw = "Volkswagen",
  volkswagen_passenger_cars = "Volkswagen",
  audi = "Audi",
  skoda = "Skoda",
  seat = "Seat",
  cupra = "Cupra",
}

-- SoC / limit / state / remaining-time ids from the Data Act dictionary.
-- Name fallbacks stay for datasets that omit the GUID.
local SOC_IDS = {
  "162c2a75-edf4-3990-b8ed-7c600b3dbc40", -- battery_level_HV.battery_level_HV.value
  "ac1108b1-b8cc-3db9-a663-03d387e42223", -- battery_level_HV.value
  "ae0294b4-1286-3e98-a818-1485b8d88430", -- state_of_charge
  "f89ed652-d104-3fa6-b7e2-ab7543309e7b", -- hv_soc
  "506cb83e-f99f-3af3-bbeb-0429b69a78d9", -- battery_state_report.soc (ID.3)
  "0a18a053-b4b0-3db1-be44-a6c5dba629b1", -- Enyaq soc
  "battery_level_HV.value",
  "state_of_charge",
  "hv_soc",
}
local LIMIT_IDS = {
  "76acaa98-37ef-3466-b013-21c77ed343ae", -- settings.target_soc
  "settings.target_soc",
}
local BCAM_THRESHOLD_IDS = {
  "battery_care_mode.charge_bcam_threshold",
}
local BCAM_ACTIVE_IDS = {
  "setting.bcam_activation",
}
local CHARGE_STATE_IDS = {
  "9da735bb-c5d5-39f8-bf53-0fa2a367aa8f",
  "96c211b4-f8fb-3f40-b7cf-6a1cd12cce6d",
  "charging_state",
  "charging_state_report.current_charge_state",
}
local SCENARIO_IDS = {
  "charging_state_report.charging_scenario",
}
local PLUG_IDS = {
  "c111830c-f959-30d2-859a-ea996190d864",
  "37d8c0c0-9677-3823-8b32-d0a5001cb0d0",
  "plug_state",
  "charging_plug1_connectionstate",
}
local TTF_IDS = {
  "cf28f7d9-6201-30b8-82e5-a461968d30dc",
  "remaining_charging_time",
}

local vin = nil
local brand_name = nil
local cookie = nil
local request_id = nil
local last_file = nil
-- Newest content file at the first listing after start (false: there was
-- none). The host has no wall clock, so its age is unknown.
local baseline_file = nil
local last = {
  ts_ms = 0,
  soc = nil,
  charge_limit = nil,
  charging_state = nil,
  time_to_full = nil,
  known_age = false,
}

---------------------------------------------------------------------------
-- ZIP + raw DEFLATE (Lua 5.1). The host returns the portal zip as a
-- string and has no unzip helper.
---------------------------------------------------------------------------

local function u16le(s, i)
  local a, b = string.byte(s, i, i + 1)
  if not b then return nil end
  return a + b * 256
end

local function u32le(s, i)
  local lo = u16le(s, i)
  local hi = u16le(s, i + 2)
  if not lo or not hi then return nil end
  return lo + hi * 65536
end

-- A dataset larger than this is refused rather than inflated: the charging
-- fields need far less, and every driver shares the host's memory.
local MAX_JSON_BYTES = 4194304
-- DEFLATE back-references reach at most this far back.
local WINDOW = 32768

local function inflate_raw(src)
  local pos = 1
  local bitbuf, bitcnt = 0, 0
  -- The newest bytes stay one per slot for back-references. Older text is
  -- flushed into chunks, so the table does not grow with the dataset.
  local out, n = {}, 0
  local chunks, flushed = {}, 0

  local function flush()
    local keep = n - WINDOW
    chunks[#chunks + 1] = table.concat(out, "", 1, keep)
    flushed = flushed + keep
    for i = 1, WINDOW do out[i] = out[keep + i] end
    for i = WINDOW + 1, n do out[i] = nil end
    n = WINDOW
  end

  -- Called between symbols, never inside a copy, so indices stay valid.
  local function room()
    if n >= 4 * WINDOW then flush() end
    return flushed + n <= MAX_JSON_BYTES
  end

  local function pull_byte()
    if pos > #src then return nil end
    local b = string.byte(src, pos)
    pos = pos + 1
    return b
  end

  local function bits(n)
    while bitcnt < n do
      local b = pull_byte()
      if b == nil then return nil end
      bitbuf = bitbuf + b * (2 ^ bitcnt)
      bitcnt = bitcnt + 8
    end
    local v = bitbuf % (2 ^ n)
    bitbuf = math.floor(bitbuf / (2 ^ n))
    bitcnt = bitcnt - n
    return v
  end

  local function align()
    bitbuf, bitcnt = 0, 0
  end

  local function build_tree(lengths)
    local max_len = 0
    for i = 1, #lengths do
      if lengths[i] > max_len then max_len = lengths[i] end
    end
    local bl_count = {}
    for i = 0, max_len do bl_count[i] = 0 end
    for i = 1, #lengths do
      local l = lengths[i]
      if l > 0 then bl_count[l] = bl_count[l] + 1 end
    end
    local next_code = {}
    local code = 0
    bl_count[0] = 0
    for len = 1, max_len do
      code = (code + bl_count[len - 1]) * 2
      next_code[len] = code
    end
    local by_len = {}
    for i = 1, #lengths do
      local l = lengths[i]
      if l > 0 then
        if not by_len[l] then by_len[l] = {} end
        by_len[l][next_code[l]] = i - 1
        next_code[l] = next_code[l] + 1
      end
    end
    return by_len, max_len
  end

  local function decode(tree, max_len)
    local code = 0
    for len = 1, max_len do
      local b = bits(1)
      if b == nil then return nil end
      code = code * 2 + b
      local row = tree[len]
      if row and row[code] ~= nil then
        return row[code]
      end
    end
    return nil
  end

  local LEN_EXTRA = {
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
  }
  local LEN_BASE = {
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
  }
  local DIST_EXTRA = {
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
  }
  local DIST_BASE = {
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
    8193, 12289, 16385, 24577,
  }

  local function fixed_lit_lengths()
    local lengths = {}
    for i = 0, 143 do lengths[i + 1] = 8 end
    for i = 144, 255 do lengths[i + 1] = 9 end
    for i = 256, 279 do lengths[i + 1] = 7 end
    for i = 280, 287 do lengths[i + 1] = 8 end
    return lengths
  end

  local function fixed_dist_lengths()
    local lengths = {}
    for i = 1, 32 do lengths[i] = 5 end
    return lengths
  end

  local CL_ORDER = {
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
  }

  local function read_dynamic()
    local hlit = bits(5)
    local hdist = bits(5)
    local hclen = bits(4)
    if not hlit or not hdist or not hclen then return nil end
    hlit, hdist, hclen = hlit + 257, hdist + 1, hclen + 4
    local cl_lengths = {}
    for i = 1, 19 do cl_lengths[i] = 0 end
    for i = 1, hclen do
      local n = bits(3)
      if n == nil then return nil end
      cl_lengths[CL_ORDER[i] + 1] = n
    end
    local cl_tree, cl_max = build_tree(cl_lengths)
    local function read_lengths(count)
      local lengths = {}
      local i = 1
      local prev = 0
      while i <= count do
        local sym = decode(cl_tree, cl_max)
        if sym == nil then return nil end
        if sym < 16 then
          lengths[i] = sym
          prev = sym
          i = i + 1
        else
          local reps, fill
          if sym == 16 then
            local extra = bits(2)
            if extra == nil then return nil end
            reps, fill = extra + 3, prev
          elseif sym == 17 then
            local extra = bits(3)
            if extra == nil then return nil end
            reps, fill = extra + 3, 0
          else
            local extra = bits(7)
            if extra == nil then return nil end
            reps, fill = extra + 11, 0
          end
          for _ = 1, reps do
            lengths[i] = fill
            i = i + 1
          end
          if fill ~= 0 then prev = fill end
        end
      end
      return lengths
    end
    local lit = read_lengths(hlit)
    local dist = read_lengths(hdist)
    if not lit or not dist then return nil end
    return lit, dist
  end

  local function inflate_block(lit_tree, lit_max, dist_tree, dist_max)
    while true do
      if not room() then return nil, "dataset too large" end
      local sym = decode(lit_tree, lit_max)
      if sym == nil then return nil end
      if sym < 256 then
        n = n + 1
        out[n] = string.char(sym)
      elseif sym == 256 then
        return true
      else
        local li = sym - 256
        if li < 1 or li > #LEN_BASE then return nil end
        local extra = bits(LEN_EXTRA[li])
        if extra == nil then return nil end
        local length = LEN_BASE[li] + extra
        local dsym = decode(dist_tree, dist_max)
        if dsym == nil or dsym < 0 or dsym > 29 then return nil end
        extra = bits(DIST_EXTRA[dsym + 1])
        if extra == nil then return nil end
        local dist = DIST_BASE[dsym + 1] + extra
        local start = n - dist + 1
        if start < 1 then return nil end
        for i = 0, length - 1 do
          n = n + 1
          out[n] = out[start + i]
        end
      end
    end
  end

  while true do
    local bfinal = bits(1)
    local btype = bits(2)
    if bfinal == nil or btype == nil then return nil end
    if btype == 0 then
      align()
      if pos + 3 > #src then return nil end
      local len = u16le(src, pos)
      local nlen = u16le(src, pos + 2)
      pos = pos + 4
      if not len or not nlen or (len + nlen) ~= 65535 then return nil end
      if pos + len - 1 > #src then return nil end
      -- One byte per slot so later length/distance copies stay correct.
      for j = pos, pos + len - 1 do
        n = n + 1
        out[n] = string.sub(src, j, j)
      end
      pos = pos + len
      if not room() then return nil, "dataset too large" end
    elseif btype == 1 or btype == 2 then
      local lit, dist
      if btype == 1 then
        lit, dist = fixed_lit_lengths(), fixed_dist_lengths()
      else
        lit, dist = read_dynamic()
        if not lit then return nil end
      end
      local lit_tree, lit_max = build_tree(lit)
      local dist_tree, dist_max = build_tree(dist)
      local ok, why = inflate_block(lit_tree, lit_max, dist_tree, dist_max)
      if not ok then
        return nil, why
      end
    else
      return nil
    end
    if bfinal == 1 then
      chunks[#chunks + 1] = table.concat(out, "", 1, n)
      return table.concat(chunks)
    end
  end
end

local function zip_extract_json(blob)
  if type(blob) ~= "string" or blob == "" then
    return nil, "empty zip"
  end
  local first = blob:match("^%s*(.)")
  if first == "{" or first == "[" then
    if #blob > MAX_JSON_BYTES then return nil, "dataset too large" end
    return blob
  end
  local i = 1
  while i + 30 <= #blob do
    if string.sub(blob, i, i + 3) ~= "PK\003\004" then
      i = i + 1
    else
      local flags = u16le(blob, i + 6)
      local method = u16le(blob, i + 8)
      local comp_size = u32le(blob, i + 18)
      local name_len = u16le(blob, i + 26)
      local extra_len = u16le(blob, i + 28)
      if not flags or not method or not comp_size or not name_len or not extra_len then
        return nil, "truncated zip header"
      end
      local name_at = i + 30
      local data_at = name_at + name_len + extra_len
      local name = string.sub(blob, name_at, name_at + name_len - 1)
      -- Flag bit 3: the sizes follow the data, and this header says 0.
      -- Streaming writers such as Java's ZipOutputStream do that. DEFLATE
      -- marks its own end, so such an entry inflates from here on.
      local streamed = math.floor(flags / 8) % 2 == 1 and comp_size == 0
      if name:lower():match("%.json$") then
        if method == 8 then
          local payload
          if streamed then
            payload = string.sub(blob, data_at)
          else
            payload = string.sub(blob, data_at, data_at + comp_size - 1)
            if #payload < comp_size then
              return nil, "truncated zip payload"
            end
          end
          local raw, ierr = inflate_raw(payload)
          if not raw then return nil, ierr or "deflate failed" end
          return raw
        elseif method == 0 and not streamed then
          if comp_size > MAX_JSON_BYTES then return nil, "dataset too large" end
          local payload = string.sub(blob, data_at, data_at + comp_size - 1)
          if #payload < comp_size then
            return nil, "truncated zip payload"
          end
          return payload
        else
          return nil, "unsupported zip entry (method " .. tostring(method) .. ")"
        end
      end
      -- A streamed entry has no size to skip by; scan for the next header.
      if streamed then
        i = data_at
      else
        i = data_at + comp_size
      end
    end
  end
  return nil, "no json document in dataset"
end

---------------------------------------------------------------------------
-- HTTP + mapping
---------------------------------------------------------------------------

local function safe_http_get(url, headers)
  local ok, resp, err = pcall(host.http_get, url, headers)
  if not ok then return nil, tostring(resp) end
  return resp, err
end

local function safe_json_decode(body)
  if body == nil then return nil, "empty" end
  local ok, data, derr = pcall(host.json_decode, body)
  if not ok then return nil, tostring(data) end
  if data == nil then return nil, tostring(derr or "empty JSON") end
  return data
end

local function auth_headers(extra)
  local h = {
    ["Accept"] = "application/json",
    ["Cookie"] = cookie,
  }
  if extra then
    for k, v in pairs(extra) do
      h[k] = v
    end
  end
  return h
end

local function api_get(path, extra)
  return safe_http_get(BASE_URL .. path, auth_headers(extra))
end

-- The newest point among the candidates wins; on a tie, the earlier
-- candidate. Points are numbered in dataset order.
local function lookup(points, ids)
  if not points then return nil end
  local best = nil
  for i = 1, #ids do
    local p = points[ids[i]]
    if p and p.value ~= nil and p.value ~= "" and (best == nil or p.seq > best.seq) then
      best = p
    end
  end
  return best
end

local function num(value)
  if type(value) == "number" then return value end
  if type(value) ~= "string" then return nil end
  return tonumber(value:match("[-+]?%d+%.?%d*"))
end

local function lower(s)
  if type(s) ~= "string" then return "" end
  return string.lower(s)
end

local function upper(s)
  if type(s) ~= "string" then return "" end
  return string.upper(s)
end

local function index_points(data)
  local points = {}
  if type(data) ~= "table" then return points end
  for i = 1, #data do
    local dp = data[i]
    if type(dp) == "table" and dp.value ~= nil and tostring(dp.value) ~= "" then
      local rec = {
        value = tostring(dp.value),
        key = dp.key,
        name = dp.dataFieldName or dp.DataFieldName,
        seq = i,
      }
      if rec.key and rec.key ~= "" then points[rec.key] = rec end
      if rec.name and rec.name ~= "" then points[rec.name] = rec end
    end
  end
  return points
end

-- Tesla-shaped vocabulary Core ranks in telemetry.VehicleConnectedRank.
local function map_charging_state(points)
  local plug = lookup(points, PLUG_IDS)
  local plugged = plug and lower(plug.value) == "connected" or false

  local cs = lookup(points, CHARGE_STATE_IDS)
  if cs then
    local u = upper(cs.value)
    local l = lower(cs.value)
    if string.find(u, "CHARGING_HV", 1, true)
        or l == "charging"
        or l == "conservationcharging"
        or u == "CHARGE_STATE_CONSERVATION_CHARGING" then
      return "Charging"
    end
  end

  local sc = lookup(points, SCENARIO_IDS)
  if sc then
    local u = upper(sc.value)
    if string.sub(u, -7) == "_ACTIVE" then
      return "Charging"
    end
    if string.sub(u, -9) == "_FINISHED" then
      if plugged then return "Complete" end
      return "Disconnected"
    end
  end

  if plug then
    if plugged then return "Stopped" end
    return "Disconnected"
  end
  return nil
end

local function parse_dataset(blob)
  local json, err = zip_extract_json(blob)
  if not json then return nil, err end
  local decoded, derr = safe_json_decode(json)
  if not decoded then return nil, derr end
  local rows = decoded.Data or decoded.data
  return index_points(rows)
end

local function dataset_name(entry)
  if type(entry) ~= "table" then return nil end
  return entry.name or entry.Name
end

local function content_datasets(list)
  local out = {}
  if type(list) ~= "table" then return out end
  local rows = list
  if list.files then rows = list.files end
  if list.Files then rows = list.Files end
  for i = 1, #rows do
    local name = dataset_name(rows[i])
    if type(name) == "string"
        and not string.find(string.lower(name), "_no_content_found.zip", 1, true) then
      out[#out + 1] = rows[i]
    end
  end
  return out
end

local function dataset_time(entry)
  if type(entry) ~= "table" then return "" end
  local t = entry.createdOn or entry.CreatedOn or entry.created_on
  if type(t) == "string" and t ~= "" then return t end
  return dataset_name(entry) or ""
end

-- Portal list order is not a contract. evcc sorts by createdOn; we do the
-- same and fall back to the file name (ISO-ish prefix).
local function newest_dataset(list)
  local content = content_datasets(list)
  if #content == 0 then return nil end
  local best, best_t = content[1], dataset_time(content[1])
  for i = 2, #content do
    local t = dataset_time(content[i])
    if t >= best_t then
      best, best_t = content[i], t
    end
  end
  return best
end

local function emit_reading(soc, limit, state, ttf, fresh, stale)
  host.emit("vehicle", {
    soc = soc,
    charge_limit_pct = limit,
    charging_state = state,
    time_to_full_min = ttf,
    stale = stale,
    soc_fresh = fresh,
  })
end

local function emit_last()
  if last.soc == nil then return end
  local age = host.millis() - last.ts_ms
  if age > STALE_AFTER_MS then
    return
  end
  emit_reading(
    last.soc, last.charge_limit, last.charging_state, last.time_to_full,
    false, not last.known_age or age > (STALE_AFTER_MS / 2))
end

local function remember(soc, limit, state, ttf, known_age)
  last.soc = soc
  last.charge_limit = limit
  last.charging_state = state
  last.time_to_full = ttf
  last.known_age = known_age
  last.ts_ms = host.millis()
end

local function resolve_brand(raw)
  if type(raw) ~= "string" or raw == "" then return nil, "brand required" end
  local key = string.lower(raw)
  key = key:gsub("š", "s"):gsub("%s+", "_")
  if key == "porsche" then
    return nil, "Porsche is not on the VW Group EU Data Act portal"
  end
  local name = BRANDS[key]
  if not name then
    return nil, "unknown brand (volkswagen|audi|skoda|seat|cupra)"
  end
  return name
end

local function normalize_cookie(raw)
  if type(raw) ~= "string" then return nil end
  local s = raw:gsub("^%s+", ""):gsub("%s+$", "")
  s = s:gsub("^[Cc]ookie:%s*", "")
  if s == "" then return nil end
  return s
end

local function ensure_request_id()
  if request_id and request_id ~= "" then return request_id end
  local body, err = api_get(
    "/proxy_api/euda-apim/datarequest/vehicles/" .. vin .. "/metadata/partial")
  if err then return nil, err end
  local data, derr = safe_json_decode(body)
  if not data then return nil, derr end
  local id = data.Identifier or data.identifier
  if type(id) ~= "string" or id == "" then
    return nil, "no data request configured for vehicle"
  end
  request_id = id
  return request_id
end

function driver_init(config)
  if not config then
    host.log("error", "vag: config required (vin + brand + cookie)")
    return
  end
  local err
  brand_name, err = resolve_brand(config.brand)
  if not brand_name then
    host.log("error", "vag: " .. tostring(err))
    return
  end
  vin = config.vin
  if type(vin) == "string" then
    vin = vin:gsub("%s+", ""):upper()
  end
  if type(vin) ~= "string" or vin == "" then
    host.log("error", "vag: `vin` required")
    return
  end
  -- Bind identity even when the session cookie is missing so the site
  -- still sees the car. Cloud is not a charging prerequisite.
  host.set_make(brand_name)
  host.set_sn(vin)
  cookie = normalize_cookie(config.cookie or config.session_cookie)
  if not cookie then
    host.log("error", "vag: `cookie` required — paste the portal Cookie header after enabling the 15-minute All Data request. Charging does not need this cloud.")
    return
  end
  if host.set_watchdog_timeout_s then
    host.set_watchdog_timeout_s(WATCHDOG_TIMEOUT_S)
  end
  host.set_poll_interval(500)
  host.log("info", "vag: telemetry-only EU Data Act driver brand=" ..
    brand_name .. " vin=" .. vin)
end

function driver_poll()
  host.set_poll_interval(POLL_INTERVAL_MS)
  if not vin or not cookie or not brand_name then
    return POLL_INTERVAL_MS
  end

  local id, iderr = ensure_request_id()
  if not id then
    local es = tostring(iderr)
    if es:match("HTTP 401") or es:match("HTTP 403") then
      host.log("warn", "vag: portal session expired — refresh config.cookie. Charging continues without vehicle cloud.")
    elseif es:match("HTTP 404") or es:match("no data request") then
      host.log("warn", "vag: no continuous data request — enable All Data / 15 min on the EU Data Act portal")
    else
      host.log("warn", "vag: metadata failed: " .. es)
    end
    emit_last()
    return POLL_INTERVAL_MS
  end

  local list_body, lerr = api_get(
    "/proxy_api/euda-apim/datadelivery/vehicles/" .. vin .. "/" .. id .. "/list",
    { type = "partial" })
  if lerr then
    local es = tostring(lerr)
    if es:match("HTTP 401") or es:match("HTTP 403") then
      host.log("warn", "vag: portal session expired — refresh config.cookie. Charging continues without vehicle cloud.")
      request_id = nil
    elseif es:match("HTTP 404") then
      host.log("debug", "vag: no dataset files yet")
    else
      host.log("warn", "vag: list failed: " .. es)
    end
    emit_last()
    return POLL_INTERVAL_MS
  end

  local list, derr = safe_json_decode(list_body)
  if not list then
    host.log("warn", "vag: list json failed: " .. tostring(derr))
    emit_last()
    return POLL_INTERVAL_MS
  end

  local ds = newest_dataset(list)
  local name = ds and dataset_name(ds) or nil
  -- The newest file at the first listing can be hours old if the car has
  -- slept since. Only a file that appears after it is a new observation.
  if baseline_file == nil then
    baseline_file = name or false
  end
  if not ds or last_file == name then
    emit_last()
    return POLL_INTERVAL_MS
  end

  local zip, zerr = api_get(
    "/proxy_api/euda-apim/datadelivery/vehicles/" .. vin .. "/" .. id .. "/download",
    { type = "partial", filename = name })
  if zerr then
    host.log("warn", "vag: download failed: " .. tostring(zerr))
    emit_last()
    return POLL_INTERVAL_MS
  end
  -- Read each file once, even one that turns out useless.
  last_file = name

  local points, perr = parse_dataset(zip)
  if not points then
    host.log("warn", "vag: dataset decode failed: " .. tostring(perr))
    emit_last()
    return POLL_INTERVAL_MS
  end

  local soc_p = lookup(points, SOC_IDS)
  local soc = soc_p and num(soc_p.value) or nil
  if soc == nil then
    host.log("debug", "vag: dataset had no SoC field")
    emit_last()
    return POLL_INTERVAL_MS
  end

  local limit_ids = LIMIT_IDS
  local bcam = lookup(points, BCAM_ACTIVE_IDS)
  if bcam and bcam.value == "BCAM_ACTIVATION_ACTIVATED" then
    limit_ids = {
      LIMIT_IDS[1], LIMIT_IDS[2],
      BCAM_THRESHOLD_IDS[1],
    }
  end
  local limit_p = lookup(points, limit_ids)
  local limit = limit_p and num(limit_p.value) or nil
  local ttf_p = lookup(points, TTF_IDS)
  local ttf = ttf_p and num(ttf_p.value) or nil
  if ttf == 65535 then ttf = nil end
  local state = map_charging_state(points)

  local known_age = name ~= baseline_file
  remember(soc, limit, state, ttf, known_age)
  host.log("info", "vag: " .. (known_age and "emit" or "first file since start, age unknown, stale:") ..
    " soc=" .. tostring(soc) ..
    " limit=" .. tostring(limit) ..
    " state=" .. tostring(state) ..
    " file=" .. tostring(name))
  if known_age then
    emit_reading(soc, limit, state, ttf, true, false)
  else
    emit_last()
  end
  return POLL_INTERVAL_MS
end

function driver_default_mode()
  -- Telemetry only: no output to reset. Charging does not use this cloud.
end

function driver_cleanup()
  vin = nil
  brand_name = nil
  cookie = nil
  request_id = nil
  last_file = nil
  baseline_file = nil
  last.soc = nil
  last.charge_limit = nil
  last.charging_state = nil
  last.time_to_full = nil
  last.known_age = false
  last.ts_ms = 0
end
