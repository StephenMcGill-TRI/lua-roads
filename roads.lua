#!/usr/bin/env luajit

-- Usage: ./roads.lua MAP.OSM
-- Show the JSON output:
-- python -m json.tool ../osm/CAM4test.bounds.json
-- jq . ../osm/CAM4test.links.json

local fname = arg[1]
if not fname or not fname:find'.osm' then
  io.stderr:write(
  "Please provide an OSM file", "\n",
  "Usage: lua roads.lua MAP.OSM", "\n"
  )
  os.exit(1)
end

local attr2way = setmetatable({
  name = tostring,
  width = tonumber,
  lanes = tonumber,
  highway = tostring,
  oneway = true,
  id = tostring,
}, {
  __call = function(t, k, v)
    local f = t[k]
    local tf = type(f)
    if tf=='function' then
      return f(v)
    elseif tf=='number' or tf=='boolean' then
      return f
    end
    return
  end
})

-- Node references to keep
local nodes = {}
-- Ways to keep
local ways = {}

local function process_way(w)
  --print(table.concat(w, '\n'))
  local way = {}
  local refs = {}
  while #w>0 do
    local child = table.remove(w)
    local nd_ref = child:match'<nd ref="(%d+)"/>'
    if nd_ref then
      table.insert(refs, nd_ref)
      --nd_refs[nd_ref] = true
    elseif child:find'<tag' then
      local k, v = child:match'<tag k="(.+)"%s*v="(.+)"/>'
      -- Save tags, act as if attribute
      way[k] = attr2way(k, v)
    end
  end
  -- Make our checks
  if (not w.building) and (way.lanes or way.highway) then
    --print(tostring(way.name), way.highway)
    way.refs = refs
    -- Keep these node references
    for i, ref in ipairs(refs) do nodes[ref] = true end
    -- Save the attributes
    for k,v in pairs(w) do way[k] = attr2way(k, v) end
    table.insert(ways, way)
  end
end

local bounds
for line in io.lines(fname) do
  if line:find'%s*<bounds'==1 then
    bounds = {
      minlat = tonumber(line:match'minlat="(%S+)"'),
      minlon = tonumber(line:match'minlon="(%S+)"'),
      maxlat = tonumber(line:match'maxlat="(%S+)"'),
      maxlon = tonumber(line:match'maxlon="(%S+)"'),
    }
    break
  end
end
assert(type(bounds)=='table', 'Did not find the bounds')

local in_way
for line in io.lines(fname) do
  local attr = line:match'<way%s(.*)>'
  if attr then
    assert(not in_way, "Should not be in a way...")
    in_way = {}
    -- Save the attributes
    for key, val in attr:gmatch'(%w+)="(%S+)"' do in_way[key] = val end
  elseif line:find'</way>' then
    assert(type(in_way)=='table', "Should be in a way")
    process_way(in_way)
    in_way = nil
  elseif in_way then
    table.insert(in_way, line)
  end
end
-- Done with attribute saving
attr2way = nil

-- Save some nodes
for line in io.lines(fname) do
  local ref = line:match'<node id="(%d+)"'
  if nodes[ref] then
    local lat = tonumber(line:match'lat="(%S+)"')
    local lon = tonumber(line:match'lon="(%S+)"')
    nodes[ref] = {lat, lon}
  --else print("Discard")
  end
end

-- Associate waypoints with lat/lon
for i,w in ipairs(ways) do
  local points = {}
  for j,s in ipairs(w.refs) do
    local latlon = nodes[s]
    assert(type(latlon)=='table' and #latlon==2)
    table.insert(points, latlon)
  end
  w.points = points
  
  assert(#w.points==#w.refs)
  --print("\n=====\tWay")
  --for k, v in pairs(w) do
    --if type(v)=='table' then
      --print('#'..k..' = '..#v)
    --else
      --print(k, v)
    --end
  --end
end

-- Format as hashtable
while #ways>0 do
  local w = table.remove(ways)
  local id = assert(w.id)
  w.id = nil
  ways[id] = w
end

-- Find the nodes that are referenced twice
-- TODO: Could do object reference, later... Doing ID list of strings
local intersections = {}; -- Save as Hashtable
for id, way in pairs(ways) do
--print(assert(way.name))
  for i, ref in ipairs(way.refs) do
    if intersections[ref] then
      table.insert(intersections[ref], id)
    else
      intersections[ref] = {id}
    end
  end
end

-- Form the intersections
for ref, ids in pairs(intersections) do
  if #ids < 2 then
    intersections[ref] = nil
  else
    intersections[ref] = {
      point = nodes[ref],
      segments = ids
    }
  end
end

-- Save with cjson for now
local fname_ways = fname:gsub('%.osm','.segments.lua')
local fname_intersections = fname:gsub('%.osm','.links.lua')
assert(fname_ways~=fname, "Cannot overwrite")
assert(fname_intersections~=fname, "Cannot overwrite")





------------------------------------------------
-----------------SPLIT--------------------------
------------------------------------------------
local segments2 = {}
local segments = ways

local function gen_id()
  local id
  repeat
    -- A-Z
    local pref = string.char(math.random(65,65+26-1))
    -- Random number
    id = string.format('%.6f', math.random()):gsub('0%.', pref)
  until not segments2[id]
  return id
end

-- Split the road segment
local function get_split1(segment, intersection)
  local ip
  for i, p in ipairs(segment.points) do
    if eq(p, intersection.point) then
      ip = i
      break
    end
  end
  if not ip then return false, "Could not split" end
  return ip
end
local function get_split(segment, intersection_ref)
  local ip
  for i, ref in ipairs(segment.refs) do
    if ref==intersection_ref then
      ip = i
      break
    end
  end
  if not ip then return false, "Could not split" end
  return ip
end

-- Set the intersection points in the segments
for s, segment in pairs(segments) do
  segment.intersections = {}
  for i=1, #segment.points do segment.intersections[i] = false end
  -- Must include the end points
  segment.intersections[1] = true
  segment.intersections[#segment.points] = true
end
for intersection_ref, intersection in pairs(intersections) do
  local p = intersection.point
  for j, s in ipairs(intersection.segments) do
    local segment = segments[s]
    --local ip = assert(get_split1(segment, intersection))
    local ip = assert(get_split(segment, intersection_ref))
    segment.intersections[ip] = intersection_ref
  end
end

-- Find the split points
local segment_ip_pairs = {}
for ref, segment in pairs(segments) do
  -- This is sorted, too
  local split_ips = {}
  for ip, intersected in ipairs(segment.intersections) do
    if intersected then table.insert(split_ips, ip) end
  end
  local ip_pairs = {}
  for i=1,#split_ips-1 do
    local ip1 = split_ips[i]
    local ip2 = split_ips[i+1]
    table.insert(ip_pairs, {ip1, ip2})
  end
  -- print("Pairs", 1, #segment.intersections)
  -- for i, p in ipairs(ip_pairs) do
  --   print(unpack(p))
  -- end
  
  segment_ip_pairs[ref] = ip_pairs
end


-- Correct everything now
local new_ids = {}
for ref, segment in pairs(segments) do
  for i, ip_pair in ipairs(segment_ip_pairs[ref]) do
    -- Find the next split point
    local ip1, ip2 = unpack(ip_pair)
    -- Split the segment
    local seg_id = gen_id()
    -- Copy all information
    local seg = {}
    for k,v in pairs(segment) do seg[k] = v end
    seg.points = {unpack(segment.points, ip1, ip2)}
    seg.links = {false, false}
    segments2[seg_id] = seg
    table.insert(new_ids, seg_id)
    if segment.intersections[ip1]~=true then
      -- Update the first intersection
      seg.links[1] = segment.intersections[ip1]
      local intersection1 = intersections[segment.intersections[ip1]]
      table.insert(intersection1.segments, seg_id)
    end
    if segment.intersections[ip2]~=true then
      seg.links[2] = segment.intersections[ip2]
      -- Update the second intersection
      local intersection2 = intersections[segment.intersections[ip2]]
      table.insert(intersection2.segments, seg_id)
    end
  end
end

-- Show the final points
for id, intersection in pairs(intersections) do
  --for k,v in pairs(intersection) do print(k) end
  local p = intersection.point
  --print("Point", unpack(p))
  --print("Segments", unpack(intersection.segments))
  local filtered = {}
  for i, s in ipairs(intersection.segments) do
    if s:match'%a%d+' then table.insert(filtered, s) end
  end
  intersection.segments = filtered
  --print("Segments", unpack(intersection.segments))
  local inter = {}
  for i, ref in ipairs(intersection.segments) do
    inter[i] = segments2[ref].name
  end
  --print(table.concat(inter,'\t'))
  intersection.ref = nil
end

for ref, s in pairs(segments2) do
  s.refs = nil
  s.intersections = nil
  --print(ref, s)
  --print(assert(s.name))
  --for k,v in pairs(s) do print(k, type(v)) end
end

local has_json, json = pcall(require, 'cjson')

if has_json then
  local fname_ways = fname:gsub('%.osm','.segments.json')
  local fname_intersections = fname:gsub('%.osm','.links.json')
  local fname_bounds = fname:gsub('%.osm','.bounds.json')
  assert(fname_ways~=fname, "Cannot overwrite")
  assert(fname_intersections~=fname, "Cannot overwrite")
  assert(fname_bounds~=fname, "Cannot overwrite")
  -- Save files
  local f_ways = io.open(fname_ways, 'w')
  f_ways:write(json.encode(segments2))
  f_ways:close()
  local f_intersections = io.open(fname_intersections, 'w')
  f_intersections:write(json.encode(intersections))
  f_intersections:close()
  local f_bounds = io.open(fname_bounds, 'w')
  f_bounds:write(json.encode(bounds))
  f_bounds:close()
  io.stderr:write('Wrote to ', fname_ways, ' ', fname_intersections, ' ', fname_bounds, '\n')
else
  io.stderr:write('Could not write files to a serializer!\n')
end
