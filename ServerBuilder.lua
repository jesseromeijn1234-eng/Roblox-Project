--[[
    ServerBuilder.lua
    ------------------
    Plaats dit als een Script in ServerScriptService.

    WAT HET DOET:
    1. Haalt data.json op via HttpService (jij host dat bestand ergens, bv.
       een GitHub raw-link nadat je fetch_osm_data.py hebt gedraaid).
    2. Bouwt gebouwen (geextrudeerd blok o.b.v. footprint + hoogte),
       wegen (platte strook) en spoorlijnen.
    3. 1 meter uit de data = 1 Roblox stud -> echt 1:1 schaal.
    4. Stuurt voortgang (0-100%) naar het laadscherm via een RemoteEvent.

    VEREIST IN GAME SETTINGS:
    - Home > Game Settings > Security > "Allow HTTP Requests" AAN.

    LET OP:
    - Vervang DATA_URL hieronder door jouw eigen raw-link naar data.json.
    - Dit is v1: gebouwen zijn simpele blokken op basis van de bounding box
      van hun footprint (geen exacte polygonvorm, geen dakvorm). Dat kun je
      later uitbreiden met 3D BAG voor echte dakvormen.
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

-- ===========================================================================
-- INSTELLINGEN — vul hier je 3 GitHub "Raw" links in
-- ===========================================================================
local BUILDINGS_URL_1 = "https://raw.githubusercontent.com/JOUW_GEBRUIKERSNAAM/JOUW_REPO/main/buildings_part1.json"
local BUILDINGS_URL_2 = "https://raw.githubusercontent.com/JOUW_GEBRUIKERSNAAM/JOUW_REPO/main/buildings_part2.json"
local ROADS_RAIL_URL = "https://raw.githubusercontent.com/JOUW_GEBRUIKERSNAAM/JOUW_REPO/main/roads_rail.json"
local BATCH_SIZE = 25 -- hoeveel objecten per frame gebouwd worden (i.v.m. performance)

-- RemoteEvent aanmaken voor voortgangs-updates naar de client
local progressEvent = Instance.new("RemoteEvent")
progressEvent.Name = "BuildProgress"
progressEvent.Parent = ReplicatedStorage

-- Map om alles in op te bergen (netjes voor Explorer)
local mapFolder = Instance.new("Folder")
mapFolder.Name = "AlkmaarMap"
mapFolder.Parent = workspace

local buildingsFolder = Instance.new("Folder", mapFolder)
buildingsFolder.Name = "Buildings"
local roadsFolder = Instance.new("Folder", mapFolder)
roadsFolder.Name = "Roads"
local railFolder = Instance.new("Folder", mapFolder)
railFolder.Name = "Rail"

-- Kleur per gebouwtype (simpele lookup, uit te breiden)
local BUILDING_COLORS = {
    house = Color3.fromRGB(178, 111, 82),
    residential = Color3.fromRGB(178, 111, 82),
    apartments = Color3.fromRGB(150, 150, 160),
    school = Color3.fromRGB(210, 190, 100),
    church = Color3.fromRGB(200, 200, 200),
    industrial = Color3.fromRGB(120, 120, 120),
    retail = Color3.fromRGB(90, 140, 180),
    yes = Color3.fromRGB(190, 160, 140), -- fallback / onbekend type
}

local function getBoundingBox(points)
    local minX, maxX = math.huge, -math.huge
    local minZ, maxZ = math.huge, -math.huge
    for _, p in ipairs(points) do
        minX = math.min(minX, p[1])
        maxX = math.max(maxX, p[1])
        minZ = math.min(minZ, p[2])
        maxZ = math.max(maxZ, p[2])
    end
    return minX, maxX, minZ, maxZ
end

local function createBuilding(b)
    local minX, maxX, minZ, maxZ = getBoundingBox(b.points)
    local width = math.max(maxX - minX, 1)
    local depth = math.max(maxZ - minZ, 1)
    local height = math.max(b.height, 2)

    local part = Instance.new("Part")
    part.Anchored = true
    part.Size = Vector3.new(width, height, depth)
    part.CFrame = CFrame.new(
        (minX + maxX) / 2,
        height / 2,
        (minZ + maxZ) / 2
    )
    part.Color = BUILDING_COLORS[b.type] or BUILDING_COLORS.yes
    part.Material = Enum.Material.Concrete
    part.Name = "Building_" .. b.type
    part.Parent = buildingsFolder
end

local function createSegmentPart(x1, z1, x2, z2, width, yPos, thickness, color, parent, name)
    local dx, dz = x2 - x1, z2 - z1
    local length = math.sqrt(dx * dx + dz * dz)
    if length < 0.05 then return end

    local midX, midZ = (x1 + x2) / 2, (z1 + z2) / 2
    local angle = math.atan2(dx, dz)

    local part = Instance.new("Part")
    part.Anchored = true
    part.Size = Vector3.new(width, thickness, length)
    part.CFrame = CFrame.new(midX, yPos, midZ) * CFrame.Angles(0, angle, 0)
    part.Color = color
    part.Material = Enum.Material.Asphalt
    part.Name = name
    part.Parent = parent
end

local function createRoad(r)
    local yPos = r.tunnel and -6 or 0.1
    for i = 1, #r.points - 1 do
        local p1, p2 = r.points[i], r.points[i + 1]
        createSegmentPart(
            p1[1], p1[2], p2[1], p2[2],
            r.width or 5, yPos, 0.3,
            r.tunnel and Color3.fromRGB(60, 60, 60) or Color3.fromRGB(70, 70, 70),
            roadsFolder, "Road_" .. r.type
        )
    end
end

local function createRail(r)
    local yPos = r.tunnel and -8 or 0.2
    for i = 1, #r.points - 1 do
        local p1, p2 = r.points[i], r.points[i + 1]
        createSegmentPart(
            p1[1], p1[2], p2[1], p2[2],
            2, yPos, 0.3,
            Color3.fromRGB(40, 40, 40),
            railFolder, "Rail"
        )
    end
end

-- ===========================================================================
-- HOOFDPROCES
-- ===========================================================================
local function reportProgress(percent, label)
    progressEvent:FireAllClients(percent, label)
end

local function buildInBatches(list, buildFn, startPercent, endPercent, label)
    local total = #list
    if total == 0 then return end
    for i, item in ipairs(list) do
        buildFn(item)
        if i % BATCH_SIZE == 0 or i == total then
            local pct = startPercent + (endPercent - startPercent) * (i / total)
            reportProgress(math.floor(pct), label)
            task.wait() -- geeft de game een frame om niet te bevriezen
        end
    end
end

local function main()
    reportProgress(0, "Kaartdata downloaden...")

    local function fetchJson(url, label)
        local success, result = pcall(function()
            return HttpService:GetAsync(url)
        end)
        if not success then
            warn("Kon " .. label .. " niet ophalen: " .. tostring(result))
            reportProgress(0, "FOUT: kon " .. label .. " niet downloaden (check de link)")
            return nil
        end
        return HttpService:JSONDecode(result)
    end

    local buildings1 = fetchJson(BUILDINGS_URL_1, "buildings_part1.json")
    if not buildings1 then return end
    reportProgress(5, "Gebouwen deel 1 ontvangen...")

    local buildings2 = fetchJson(BUILDINGS_URL_2, "buildings_part2.json")
    if not buildings2 then return end
    reportProgress(10, "Gebouwen deel 2 ontvangen...")

    local roadsRail = fetchJson(ROADS_RAIL_URL, "roads_rail.json")
    if not roadsRail then return end
    reportProgress(15, "Wegen/spoor ontvangen, gebouwen bouwen...")

    local allBuildings = {}
    for _, b in ipairs(buildings1) do table.insert(allBuildings, b) end
    for _, b in ipairs(buildings2) do table.insert(allBuildings, b) end

    buildInBatches(allBuildings, createBuilding, 15, 65, "Gebouwen bouwen...")
    buildInBatches(roadsRail.roads, createRoad, 65, 90, "Wegen aanleggen...")
    buildInBatches(roadsRail.rail, createRail, 90, 98, "Spoorlijnen aanleggen...")

    reportProgress(100, "Klaar!")
end

main()
