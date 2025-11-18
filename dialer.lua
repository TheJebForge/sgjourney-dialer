-- Constants and helpers
local ADVANCED_CRYSTAL_INTERFACE = "advanced_crystal_interface"
local CRYSTAL_INTERFACE = "crystal_interface"
local BASIC_INTERFACE = "basic_interface"

local SG_CLASSIC = "sgjourney:classic_stargate"
local SG_UNIVERSE = "sgjourney:universe_stargate"
local SG_MILKY_WAY = "sgjourney:milky_way_stargate"
local SG_TOLLAN = "sgjourney:tollan_stargate"
local SG_PEGASUS = "sgjourney:pegasus_stargate"

local NAME_SERVER_CHANNEL = 475
local NAME_SERVER_REPLY = 476

local function isManualStargate(ty)
    return ty == SG_CLASSIC or ty == SG_MILKY_WAY
end

-- Aliases for less typing
local setF = term.setTextColor
local setB = term.setBackgroundColor
local getP = term.getCursorPos
local setP = term.setCursorPos
local setCB = term.setCursorBlink

-- Batteries
function string:split(sep)
    local sep, fields = sep or ":", {}
    local pattern = string.format("([^%s]+)", sep)
    self:gsub(pattern, function(c) fields[#fields+1] = c end)
    return fields
end

-- Find interface and discover capabilities, just to get it out of the way
local stargate = nil
local stargateInfo = {}
local stargateAddress = nil

do
    print("Waiting 1 second for potential unloaded chunks to load")
    sleep(1)
    
    local interfaceVariant = nil

    for _, variant in pairs({
        ADVANCED_CRYSTAL_INTERFACE,
        CRYSTAL_INTERFACE,
        BASIC_INTERFACE
    }) do
        local interface = peripheral.find(variant)

        if interface then
            stargate = interface
            interfaceVariant = variant
            break
        end
    end

    if not stargate then
        error("No Stargate interfaces found!", 1)
    end

    -- Find out if this interface can even dial the gate
    local stargateType = stargate.getStargateType()
    local canEngageSymbol = not not stargate.engageSymbol
    local isManual = isManualStargate(stargateType)
    
    if not canEngageSymbol and not isManual then
        error("The Stargate interface cannot operate this gate! Need at least crystal interface")
    end

    -- Setting stargate info
    stargateInfo = {
        manual = isManual,
        directEngage = canEngageSymbol,
        ty = stargateType,
        interface = interfaceVariant
    }
end

-- Configuration stuff
local config = {}

local function defaultConfig()
    return {
        alwaysEngage = false,
        fallbackAddress = nil
    }
end

local configOptions = {
    alwaysEngage = {
        "Skip rotation for Milky Way and Classic gates",
        "boolean"
    },
    fallbackAddress = {
        "Address that should be used in case Stargate interface can't get the address by itself",
        "address"
    }
}

local function loadConfig()
    local file, err = fs.open("config.json", "r")
    if not file then
        printError("Config doesn't exist!", err)
        return false
    end

    local contents = file.readAll()
    file.close()

    local deserialized, err = textutils.unserializeJSON(contents)
    if not deserialized then
        printError("Failed to read config.json", err)
        return false
    end

    config = deserialized
    return true
end

local function saveConfig()
    local file, err = fs.open("config.json", "w")
    if not file then
        printError("Couldn't open config.json for writing", err)
        return
    end

    file.write(textutils.serializeJSON(config))
    file.close()
end

local function getConfigValue(key)
    if config[key] then
        return config[key]
    else
        return defaultConfig()[key]
    end
end

-- Initial config load
if not loadConfig() then
    config = defaultConfig()
    saveConfig()
end

-- Some angle math
local TAU = math.pi * 2

local function normalizeAngle(angleRadians)
    return angleRadians - TAU * math.floor((angleRadians + math.pi) / TAU)
end

-- Negative number means clockwise is quicker, positive number means anti clockwise is quicker
local function getShortestSymbolDirection(currentSymbol, targetSymbol)
    local src = currentSymbol / 39 * 2 * math.pi
    local dst = targetSymbol / 39 * 2 * math.pi

    return normalizeAngle(dst - src)
end

-- Forward declaration for reporting messages to screen
local reportMessage

-- Forward declaration for modem
local modem

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

local function asyncModemRequest(modem, onReceive, method, ...)
    if not modem.isOpen(NAME_SERVER_REPLY) then
        modem.open(NAME_SERVER_REPLY)
    end

    local requestId = os.getComputerID() .. "-" .. os.clock() .. "-" .. math.random(1000)
    local payload = {
        id = requestId,
        method, ...
    }

    local timeoutTime = 5

    local timeoutTimer = os.startTimer(timeoutTime)
    local timeoutLateTime = os.clock() + timeoutTime

    local cor = coroutine.create(function()
        modem.transmit(NAME_SERVER_CHANNEL, NAME_SERVER_REPLY, payload)

        while true do
            local event = coroutine.yield()

            if event[1] == "timer" and event[2] == timeoutTimer or os.clock() > timeoutLateTime then
                onReceive(false)
                break
            elseif event[1] == "modem_message" then
                local _, _, chan, reply, msg = table.unpack(event)
                
                -- Checking for matching channel
                if chan ~= NAME_SERVER_REPLY or reply ~= NAME_SERVER_CHANNEL then
                    goto continue
                end

                -- Making sure msg is of correct type
                if type(msg) ~= "table" or not msg.id then
                    goto continue
                end

                -- Checking if message was addressed to this
                if msg.id ~= requestId then
                    goto continue
                end

                onReceive(true, table.unpack(msg))
                os.cancelTimer(timeoutTimer)
                break
            end

            ::continue::
        end
    end)

    return cor
end

local function nameRegister(modem, resp)
    return asyncModemRequest(modem, function(success)
        if success then
            resp("Registered with the name server!")
        else
            resp("No response from name server...")
        end
    end, "register", os.getComputerID(), os.getComputerLabel(), stargateAddress)
end

local function addressQuery(modem, search, onReceive)
    return asyncModemRequest(modem, onReceive, "query", search)
end

local function gateListQuery(modem, onReceive)
    return asyncModemRequest(modem, onReceive, "list")
end

local function addWaypointRequest(modem, label, address, onReceive)
    return asyncModemRequest(modem, onReceive, "add", label, address)
end

local function deleteWaypointRequest(modem, label, onReceive)
    return asyncModemRequest(modem, onReceive, "delete", label)
end

-- Request queue
local pendingRequests = {}

local function queueRequest(requestCor)
    table.insert(pendingRequests, requestCor)
end

local function handlePendingRequests(event)
    for i = #pendingRequests, 1, -1 do
        local success = coroutine.resume(pendingRequests[i], event)

        if not success then
            table.remove(pendingRequests, i)
        end
    end
end

-- Stargate state and some functions
local stargateConnected = stargate.isStargateConnected()
local stargateOutgoing = stargate.isStargateDialingOut()

local function resetStargateCoroutinable(callGate)
    if stargateConnected and not stargateOutgoing then
        reportMessage("Can't close incoming connection!")
        return
    end
    
    callGate("disconnectStargate")

    if stargateInfo.manual then
        if stargateInfo.ty == SG_MILKY_WAY and callGate("isChevronOpen") then
            callGate("closeChevron")
        end

        callGate("disconnectStargate")
    end

    stargateConnected = false
end

local function resetStargate()
    resetStargateCoroutinable(function(method, ...)
        return stargate[method](...)
    end)
end

local function parseAddress(address)
    if not address then
        return nil
    end

    local segments = address:split("-")
    local parsedAddress = {}
    local lastNumber = nil

    for _, segment in pairs(segments) do
        local num = tonumber(segment)
        if num then
            table.insert(parsedAddress, num)
            lastNumber = num
        end
    end

    if not lastNumber then
        return nil
    end

    if lastNumber ~= 0 then
        table.insert(parsedAddress, 0)
    end

    return parsedAddress
end

-- Stargate state watcher
local dialCoroutine = nil
local dialCoroutineTimer = nil
local dialCoroutineLateTime = 0

local function watchStargateEvents(event)
    local eventName = event[1]

    if eventName == "stargate_chevron_engaged" then
        local _, _, _, _, incoming = table.unpack(event)
        if incoming then
            stargateConnected = true
            stargateOutgoing = false
        end
    elseif eventName == "stargate_incoming_wormhole" then
        stargateConnected = true
        stargateOutgoing = false
        dialCoroutine = nil
    elseif eventName == "stargate_outgoing_wormhole" then
        stargateConnected = true
        stargateOutgoing = true
        dialCoroutine = nil
    elseif eventName == "stargate_disconnected" or eventName == "stargate_reset" then
        stargateConnected = false
        dialCoroutine = nil
    end
end

-- Dialing code
local function handleDialTimer(event)
    local isTimerEvent = event[1] == "timer" and event[2] == dialCoroutineTimer
    local timerEventIsLate = dialCoroutineTimer and os.clock() > dialCoroutineLateTime

    if (isTimerEvent or timerEventIsLate) and dialCoroutine then
        dialCoroutineTimer = nil
        local resp = { coroutine.resume(dialCoroutine) }

        while true do
            local success = resp[1]
            
            if success then
                local request = resp[2]

                if request == "sleep" then
                    local time = math.max(0.5, tonumber(resp[3]) or 0)
                    dialCoroutineTimer = os.startTimer(time)
                    dialCoroutineLateTime = os.clock() + time
                    break
                elseif request == "stargate" then
                    local func = stargate[resp[3]]

                    if func then
                        local args = {}

                        for i = 4, #resp do
                            table.insert(args, resp[i])
                        end

                        resp = { coroutine.resume(dialCoroutine, func(table.unpack(args))) }
                    else
                        printError("function", resp[3], "not found!")
                        break
                    end
                else
                    dialCoroutine = nil
                    break
                end
            else
                dialCoroutine = nil
                break
            end
        end
    end
end

local function startDialProcess(address, respFunc)
    if stargateConnected then
        respFunc("Gate is already connected to somewhere!")
        return
    end

    if dialCoroutine then
        respFunc("Already dialing!")
        return
    end

    respFunc("Dialing the address...")

    dialCoroutineTimer = os.startTimer(1)
    dialCoroutine = coroutine.create(function()
        local toRotate = (stargateInfo.manual and not getConfigValue("alwaysEngage")) 
            or not stargateInfo.directEngage

        local sleep = function(time)
            coroutine.yield("sleep", time)
        end

        local callGate = function(method, ...)
            return coroutine.yield("stargate", method, ...)
        end

        resetStargateCoroutinable(callGate)
        sleep(0)

        local lastSymbol = 0
        for index, symbol in pairs(address) do
            if toRotate then
                if getShortestSymbolDirection(lastSymbol, symbol) < 0 then
                    callGate("rotateClockwise", symbol)
                else
                    callGate("rotateAntiClockwise", symbol)
                end

                lastSymbol = symbol

                while (not callGate("isCurrentSymbol", symbol)) do
                    sleep(0)
                end

                if stargateInfo.ty == SG_MILKY_WAY then
                    callGate("openChevron")
                    sleep(1)

                    callGate("closeChevron")
                    sleep(1)
                elseif stargateInfo.ty == SG_CLASSIC then
                    callGate("encodeChevron")
                    sleep(1)
                end
            else
                callGate("engageSymbol", symbol)
                sleep(1)
            end
        end

        if callGate("getRecentFeedback") < 0 then
            reportMessage("Failed to dial!")
            return
        end

        while not callGate("isWormholeOpen") do
            sleep(0)
        end

        reportMessage("Dial success!")
    end)
end

local function dialCommand(respFunc, address)
    local parsedAddress = parseAddress(address)

    if not parsedAddress then
        respFunc("Invalid address?")
        return
    end

    startDialProcess(parsedAddress, respFunc)
end

-- Calling functionality
local function callCommand(respFunc, ...)
    if not modem then
        respFunc("There's no wireless modem! Unable to query the name server")
        return
    end

    if stargateConnected then
        respFunc("Gate is already connected to somewhere!")
        return
    end

    if dialCoroutine then
        respFunc("Already dialing!")
        return
    end

    local query = ""
    for _, v in pairs({...}) do
        query = query .. v .. " "
    end
    query = query:sub(1, -2)

    respFunc("Querying name server for '".. query .."'...")

    local function queryReceive(success, address)
        if success then
            if not address then
                reportMessage("Address not found!")
            else
                reportMessage("Found address!", stargate.addressToString(address))
                startDialProcess(address, reportMessage)
            end
        else
            reportMessage("No response from name server!")
        end
    end

    queueRequest(addressQuery(modem, query, queryReceive))
end

-- Label stuff
local function labelCommand(respFunc, ...)
    local args = {...}
    
    if #args > 0 then
        local newLabel = ""
        for _, v in pairs(args) do
            newLabel = newLabel .. v .. " "
        end
        newLabel = newLabel:sub(1, -2)

        os.setComputerLabel(newLabel)
        respFunc("Label set!")

        if modem then
            queueRequest(nameRegister(modem, reportMessage))
        end
    else
        respFunc("Current label:", os.getComputerLabel() or "<not set>")
    end
end

-- List command
local function listCommand(respFunc)
    if not modem then
        respFunc("There's no wireless modem! Unable to query the name server")
        return
    end

    local function listReceive(success, addressTable, waypointTable)
        if not success then
            reportMessage("No response from name server...")
            return
        end

        reportMessage("Waypoints:")
        local waypoints = {}
        for _, entry in pairs(waypointTable) do
            table.insert(waypoints, "'"..entry[1].."'")
        end

        setF(colors.magenta)
        reportMessage(table.unpack(waypoints))
        setF(colors.white)

        reportMessage("\nRegistered gates:")

        local gates = {}
        for _, entry in pairs(addressTable) do
            table.insert(gates, "'"..(entry[2] or entry[1]).."'")
        end

        setF(colors.orange)
        reportMessage(table.unpack(gates))
        setF(colors.white)
    end

    respFunc("Requesting list of stargates...")
    queueRequest(gateListQuery(modem, listReceive))
end

local function waypointCommand(respFunc, op, label, address)
    if not modem then
        respFunc("There's no wireless modem! Unable to query the name server")
        return
    end

    if op == "add" then
        local parsedAddress = parseAddress(address)
        
        if not parsedAddress then
            respFunc("Invalid address")
            return
        end

        local function addReceive(success)
            if success then
                reportMessage("Waypoint added!")
            else
                reportMessage("No response from name server...")
            end
        end

        respFunc("Adding waypoint to name server...")
        queueRequest(addWaypointRequest(modem, label, parsedAddress, addReceive))
    elseif op == "remove" then
        local function deleteReceive(success)
            if success then
                reportMessage("Waypoint deleted!")
            else
                reportMessage("No response from name server...")
            end
        end

        respFunc("Deleting waypoint from name server...")
        queueRequest(deleteWaypointRequest(modem, label, deleteReceive))
    else
        respFunc("Expected 'add' or 'remove' for operation")
    end
end

local function configCommand(respFunc, option, value)
    local function configOptionString(field, info)
        local value = getConfigValue(field)

        if info[2] == "address" then
            return stargate.addressToString(value)
        else
            return tostring(value)
        end
    end

    local function setConfigValue(field, info, value)
        local valueType = info[2]

        if valueType == "boolean" then
            config[field] = value == "true" or value == "y"
            return true
        elseif valueType == "number" then
            local num = tonumber(value)

            if not num then
                return false, "Expected a valid number!"
            end

            config[field] = num
            return true
        elseif valueType == "address" then
            local addr = parseAddress(value)

            if not addr then
                return false, "Invalid address!"
            end

            config[field] = addr
            return true
        end

        return false, "Unsupported type"
    end

    if not option then
        respFunc("Configuration options:")
        for field, info in pairs(configOptions) do
            setF(colors.yellow)
            respFunc("-", field, "(".. info[2] ..")")
            setF(colors.white)
            respFunc(info[1])
        end
    else
        local info = configOptions[option]

        if not info then
            respFunc("Config option not found!")
        else
            if not value then
                respFunc(info[1])
                setF(colors.yellow)
                respFunc("Type:", info[2])
                setF(colors.orange)
                respFunc("Value:", configOptionString(option, info))
                setF(colors.white)
            else
                local success, msg = setConfigValue(option, info, value)

                if success then
                    saveConfig()
                    respFunc("Config value set!")
                else
                    respFunc(msg)
                end
            end
        end
    end
end

-- Code to process commands
local commandCatalog = {
    dial = {
        "dial <dash address>",
        "Dial to specified address",
        dialCommand
    },
    reset = {
        "reset",
        "Disconnects and resets the gate",
        function()
            resetStargate()
            dialCoroutine = nil
        end
    },
    call = {
        "call <query>",
        "Asks the name server for address and dials it. Case insensitive and doesn't mind spaces",
        callCommand
    },
    label = {
        "label [new label]",
        "Gets or sets computer label and reregisters it with the name server. Doesn't mind spaces",
        labelCommand
    },
    list = {
        "list",
        "Requests a list of gates from the name server",
        listCommand
    },
    config = {
        "config [option] [value]",
        "Lists, gets and sets configuration values for the program",
        configCommand
    },
    waypoint = {
        "waypoint add <label> <address> / waypoint remove <label>",
        "Adds or removes waypoints from name server",
        waypointCommand
    },
    id = {
        "id",
        "Prints ID of the computer",
        function(resp)
            resp("This is computer #"..os.getComputerID())
        end
    }
}

commandCatalog.help = {
    "help [command]",
    "Prints all available commands and help for individual commands",
    function(resp, cmd)
        if cmd then
            local command = commandCatalog[cmd]

            if not command then
                resp("No help for the '" .. cmd .. "' command")
                return
            end

            resp(command[2])
            resp()
            resp("Usage:", command[1])
        else
            local commands = {}
            for k, _ in pairs(commandCatalog) do
                table.insert(commands, k)
            end

            resp("Available commands:")
            setF(colors.yellow)
            resp(table.unpack(commands))
            setF(colors.white)
            resp("\nUse 'help <command>' for more info")
        end
    end
}

local function processCommand(line, respFunc)
    local parsed = line:split(" ")
    local command = table.remove(parsed, 1)

    if not command then
        return
    end

    local lookup = commandCatalog[command:lower()]

    if lookup then
        lookup[3](respFunc, table.unpack(parsed))
    else
        respFunc("Unknown command")
    end
end

-- CLI stuff
local PROMPT_PREFIX = "$ "

local scrWidth, scrHeight = term.getSize()
local currentLine = ""
local currentLineCursor = 1

local lineHistory = {""}
local historyPos = 1

local function drawPrompt()
    local _, currentY = getP()
    local lineLen = currentLine:len()
    local prefixLen = PROMPT_PREFIX:len()
    local availableSpace = scrWidth - prefixLen - 1

    setP(1, currentY)
    term.clearLine()
    setF(colors.cyan)
    write(PROMPT_PREFIX)
    setF(colors.white)
    setCB(true)

    if lineLen > availableSpace then
        -- Handle overflow
        local spaceMiddle = math.ceil(availableSpace / 2)

        local lineSlice
        local cursorX
        if currentLineCursor < spaceMiddle then
            -- Show start
            lineSlice = currentLine:sub(1, availableSpace)
            cursorX = currentLineCursor
        elseif currentLineCursor < lineLen - spaceMiddle then
            -- Show middle
            lineSlice = currentLine:sub(currentLineCursor - spaceMiddle + 1, currentLineCursor + spaceMiddle)
            cursorX = spaceMiddle
        else
            -- Show end
            lineSlice = currentLine:sub(lineLen - availableSpace + 1, lineLen)
            cursorX = spaceMiddle - (lineLen - currentLineCursor) + spaceMiddle
        end

        write(lineSlice)
        setP(prefixLen + cursorX, currentY)
    else
        write(currentLine)
        setP(prefixLen + currentLineCursor, currentY)
    end
end

local function printOver(...)
    term.clearLine()
    local _, currentY = getP()
    setP(1, currentY)
    print(...)
    drawPrompt()
end

local function processCliInput(event)
    local eventName = event[1]

    if eventName == "char" then
        local _, character = table.unpack(event)
        currentLine = currentLine:sub(1, currentLineCursor - 1) .. character .. currentLine:sub(currentLineCursor)
        currentLineCursor = currentLineCursor + 1

        drawPrompt()
    elseif eventName == "key" then
        local _, keyCode = table.unpack(event)

        if keyCode == keys.left then
            currentLineCursor = math.max(1, currentLineCursor - 1)
        elseif keyCode == keys.right then
            currentLineCursor = math.min(currentLineCursor + 1, currentLine:len() + 1)
        elseif keyCode == keys.backspace then
            if currentLineCursor > 1 then
                currentLine = currentLine:sub(1, currentLineCursor - 2) .. currentLine:sub(currentLineCursor)
                currentLineCursor = currentLineCursor - 1
            end
        elseif keyCode == keys.delete then
            if currentLineCursor <= currentLine:len() then
                currentLine = currentLine:sub(1, currentLineCursor - 1) .. currentLine:sub(currentLineCursor + 1)
            end
        elseif keyCode == keys.home then
            currentLineCursor = 1
        elseif keyCode == keys["end"] then
            currentLineCursor = currentLine:len() + 1
        elseif keyCode == keys.enter then
            historyPos = #lineHistory
            lineHistory[historyPos] = currentLine
            historyPos = #lineHistory + 1

            print()
            processCommand(currentLine, print)
            currentLine = ""
            currentLineCursor = 1
        elseif keyCode == keys.up or keyCode == keys.down then
            if historyPos >= #lineHistory then
                lineHistory[historyPos] = currentLine
            end

            if keyCode == keys.up then
                historyPos = math.max(1, historyPos - 1)
            else
                historyPos = math.min(#lineHistory, historyPos + 1)
            end
            
            currentLine = lineHistory[historyPos] or ""
            currentLineCursor = currentLine:len() + 1
        end

        drawPrompt()
    elseif eventName == "paste" then
        local _, content = table.unpack(event)

        currentLine = currentLine:sub(1, currentLineCursor - 1) .. content .. currentLine:sub(currentLineCursor)
        currentLineCursor = currentLineCursor + content:len()

        drawPrompt()
    end
end

reportMessage = function(...)
    printOver(...)
end

-- Starting stuff
term.clear()
setP(1, 1)

print("Initializing...")

modem = findWirelessModem()

if not modem then
    printError("No wireless modems found! Call functionality won't work")
end

if modem then
    -- Figure out the gate's address
    if not stargate.getLocalAddress then
        local fallback = getConfigValue("fallbackAddress")

        if fallback then
            stargateAddress = fallback
        else
            write("Unable to find this stargate's address!\nPlease specify the address:\n> ")
            
            local address
            while true do
                address = parseAddress(read())
                if not address then
                    write("Invalid address! Try again: \n> ")
                else
                    break
                end
            end
            
            config.fallbackAddress = address
            saveConfig()
            print("Saved address to config!")

            stargateAddress = address
        end
    else
        stargateAddress = stargate.getLocalAddress()
    end

    if stargateAddress[#stargateAddress] ~= 0 then
        table.insert(stargateAddress, 0)
    end

    -- Registering with the name server
    print("Attempting to register with name server...")
    local registerRequest = nameRegister(modem, print)
    coroutine.resume(registerRequest)

    local antiSleep = os.startTimer(1)
    while coroutine.resume(registerRequest, {os.pullEvent()}) do 
        os.cancelTimer(antiSleep)
        antiSleep = os.startTimer(1)
    end
end

-- Monitor handling
local monitors = { peripheral.find("monitor") }
local monitorCoroutines = {}

do 
    for i, monitor in pairs(monitors) do
        monitorCoroutines[i] = coroutine.create(function()
            local blink = false

            local function redraw()
                local oldTerm = term.current()
                term.redirect(monitor)

                local bg = colors.gray
                local fg = colors.white
                local msg = "Idle"

                if dialCoroutine then
                    bg = colors.yellow
                    fg = colors.black
                    msg = "Dialing..."
                elseif stargateConnected and stargateOutgoing then
                    bg = colors.lime
                    fg = colors.black
                    msg = "Outgoing"
                elseif stargateConnected and not stargateOutgoing then
                    bg = blink and colors.black or colors.red
                    fg = blink and colors.red or colors.black
                    msg = blink and "Ingoing!" or "DO NOT ENTER"
                    blink = not blink
                end

                setF(fg)
                setB(bg)
                term.clear()
                setCB(false)

                local len = msg:len()
                local w, h = term.getSize()
                setP(w / 2 - len / 2 + 1, math.ceil(h / 2))
                write(msg)

                term.redirect(oldTerm)
            end

            local redrawTimer = 0
            local redrawLateTime = 0

            local function restartTimer()
                local time = 1

                redrawTimer = os.startTimer(time)
                redrawLateTime = os.clock() + time
            end

            restartTimer()

            while true do
                local event = coroutine.yield()

                if event[1] == "timer" and event[2] == redrawTimer or os.clock() > redrawLateTime then
                    restartTimer()
                    redraw()
                end
            end
        end)
    end

    print("Found", #monitorCoroutines, "monitor(s)")
end

function handleMonitors(event)
    for _, cor in pairs(monitorCoroutines) do
        coroutine.resume(cor, event)
    end
end

print("About to start...")
sleep(2)
term.clear()
setP(1, 1)
write("Stargate dialer program\nUse 'help' for list of commands\n\n")
drawPrompt()

handleMonitors({})

while true do
    local event = { os.pullEvent() }

    processCliInput(event)
    handleMonitors(event)
    handlePendingRequests(event)
    handleDialTimer(event)
    watchStargateEvents(event)
end
