-- Constants
local NAME_SERVER_CHANNEL = 475
local NAME_SERVER_REPLY = 476

-- Batteries
function string:split(sep)
    local sep, fields = sep or ":", {}
    local pattern = string.format("([^%s]+)", sep)
    self:gsub(pattern, function(c) fields[#fields+1] = c end)
    return fields
end

-- Modem stuff
local function findWirelessModem()
    local foundModems = { peripheral.find("modem") }

    for _, v in pairs(foundModems) do
        if v.isWireless() then
            return v
        end
    end

    return nil
end

-- Address table
local addressTable = {}

local function loadAddressTable()
    local file, err = fs.open("addresses.json", "r")
    if not file then
        printError("Address table file doesn't exist!", err)
        return false
    end

    local contents = file.readAll()
    file.close()

    local deserialized, err = textutils.unserializeJSON(contents)
    if not deserialized then
        printError("Failed to read addresses.json", err)
        return false
    end

    addressTable = deserialized
    return true
end

local function saveAddressTable()
    local file, err = fs.open("addresses.json", "w")
    if not file then
        printError("Couldn't open addresses.json for writing", err)
        return
    end

    file.write(textutils.serializeJSON(addressTable))
    file.close()
end

if not loadAddressTable() then
    saveAddressTable()
end

local function registerOrUpdateAddress(id, label, address)
    local found = false

    for _, entry in pairs(addressTable) do
        if entry[1] == id then
            print("Updating #"..id.." label and address")

            entry[2] = label
            entry[3] = address

            found = true
            break
        end
    end

    if not found then
        print("Registering #"..id)
        table.insert(addressTable, {id, label, address})
    end

    saveAddressTable()
end

local function findAddressByIdOrLabel(search)
    search = (search or ""):lower()

    for _, entry in pairs(addressTable) do
        if tostring(entry[1]) == search then
            return entry[3]
        elseif entry[2] and tostring(entry[2]):lower() == search then
            return entry[3]
        end
    end

    return nil
end

-- Address table
local waypointTable = {}

local function loadWaypointTable()
    local file, err = fs.open("waypoints.json", "r")
    if not file then
        printError("Waypoint table file doesn't exist!", err)
        return false
    end

    local contents = file.readAll()
    file.close()

    local deserialized, err = textutils.unserializeJSON(contents)
    if not deserialized then
        printError("Failed to read waypoints.json", err)
        return false
    end

    waypointTable = deserialized
    return true
end

local function saveWaypointTable()
    local file, err = fs.open("waypoints.json", "w")
    if not file then
        printError("Couldn't open waypoints.json for writing", err)
        return
    end

    file.write(textutils.serializeJSON(waypointTable))
    file.close()
end

if not loadWaypointTable() then
    saveWaypointTable()
end

local function addOrUpdateWaypoint(label, address)
    local found = false
    label = label or "Unnamed"

    for _, entry in pairs(waypointTable) do
        if entry[1] == label then
            print("Updating '"..label.."' waypoint's address")

            entry[2] = label
            entry[3] = address

            found = true
            break
        end
    end

    if not found then
        print("Registering '"..label.."'")
        table.insert(waypointTable, {label, address})
    end

    saveWaypointTable()
end

local function deleteWaypoint(label)
    for i = #waypointTable, 1, -1 do
        local entry = waypointTable[i]

        if entry[1] and tostring(entry[1]):lower() == (label or ""):lower() then
            table.remove(i)
        end
    end

    saveWaypointTable()
end

local function findWaypointAddress(search)
    search = (search or ""):lower()

    for _, entry in pairs(waypointTable) do
        print("matching", entry[1], "and", search)
        if entry[1] and tostring(entry[1]):lower() == search then
            return entry[2]
        end
    end

    return nil
end

-- Program body
local modem = findWirelessModem()

if not modem then
    error("Wireless modem is required!", 1)
end

modem.open(NAME_SERVER_CHANNEL)

term.clear()
term.setCursorPos(1,1)

print("Stargate Name Server")
print("Listening to messages...")

while true do
    local _, _, chan, reply, msg = os.pullEvent("modem_message")

    if chan ~= NAME_SERVER_CHANNEL then
        goto continue
    end

    if type(msg) ~= "table" or not msg.id or #msg <= 0 then
        goto continue
    end

    local function respond(...)
        modem.transmit(reply, chan, { id = msg.id, ... })
    end

    local method = msg[1]

    if method == "register" then
        local _, id, label, address = table.unpack(msg)
        registerOrUpdateAddress(id, label, address)
        respond()
    elseif method == "query" then
        local _, search = table.unpack(msg)
        print("Querying for", search)

        local waypoint = findWaypointAddress(search)
        
        if waypoint then
            respond(waypoint)
        else
            respond(findAddressByIdOrLabel(search))
        end
    elseif method == "list" then
        respond(addressTable, waypointTable)
    elseif method == "add" then
        local _, label, address = table.unpack(msg)
        addOrUpdateWaypoint(label, address)
        respond()
    elseif method == "delete" then
        local _, label = table.unpack(msg)
        deleteWaypoint(label)
        respond()
    end

    ::continue::
end