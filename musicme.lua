-- Libraries
local basalt = require("lib/basalt")
if not basalt then error("Basalt wasn't found") end

local v = require("/lib/semver")
if not v then error("semver wasn't found") end

local dfpwm = require("/lib/dfpwm")
if not dfpwm then error("dfpwm wasn't found") end

-- Options
local version = "1.0.0"
local repo = "https://raw.githubusercontent.com/JaredWogan/musicme/master/index.json"
local autoUpdates = true
local indexURL = repo .. "?cb=" .. os.epoch("utc")
local bufferLength = 16
local clientVolume = 1
local serverVolume = 0

-- Channels
local controlChannel = 2561
local bufferChannel = controlChannel + 1
local clientChannel = controlChannel + 2

-- Peripherals
local modem = peripheral.find("modem")
local speaker = peripheral.find("speaker")
local monitor = peripheral.find("monitor")

-- Ensure there is a modem and speaker
if not modem then error("There needs to be a modem attached") end
if not speaker then error("There needs to be a speaker attached") end

-- HTTP Handle (Loads song library)
local handle, msgError = http.get(indexURL)
if not handle then error(msgError) end

local indexJSON = handle.readAll()
handle.close()

local index = textutils.unserialiseJSON(indexJSON)
if not index then error("The index is malformed.", 0) end


-- Check for updates
local function update()
    shell.run("wget run https://raw.githubusercontent.com/JaredWogan/musicme/master/install.lua")
end
if v(version) < v(index.latestVersion) and autoUpdates then
    error("Client outdated... Running Updates", 0)
    update()
end

-- musicme
local musicme = {}
local args = { ... }

local awaitMessage = function(channel, replyChannel, command)
    local e, s, c, rc, msg, d = os.pullEvent("modem_message")
    if command == "any" then
        while c ~= channel and rc ~= replyChannel do
            e, s, c, rc, msg, d = os.pullEvent("modem_message")
        end
        return msg
    end
    if command and command ~= "any" then
        while c ~= channel and rc ~= replyChannel and msg.command ~= command do
            e, s, c, rc, msg, d = os.pullEvent("modem_message")
        end
        return msg
    end
    error("Invalid function arguments: <" .. tostring(channel) .. ", " .. tostring(replyChannel) .. ", " .. command .. ">")
end

local playBuffer = function(buffer, volume)
    if not volume then volume = 1 end
    while not speaker.playAudio(buffer, volume) do os.pullEvent("speaker_audio_empty") end
end

-- Run the speaker client
musicme.client = function(arguments)
    modem.open(bufferChannel)
    modem.open(clientChannel)

    local bufferPlayback = function()
        local msg
        while true do
            msg = awaitMessage(bufferChannel, controlChannel, "buffer")
            if msg.buffer then playBuffer(msg.buffer, clientVolume) end
        end
    end

    local receiveMessage = function()
        local msg
        while true do
            print("Listening for updates")
            msg = awaitMessage(clientChannel, controlChannel, "any")
            -- Start
            if msg.command == "start" then
                print("Starting playback")
            end
            -- Song buffer
            if msg.command == "buffer" then
                print("Received song buffer... playing")
            end
            -- Pause
            if msg.command == "pause" then
                if msg.pause then speaker.stop() end
                print("Received pause command. Pause = " .. tostring(msg.pause))
            end
            -- Stop
            if msg.command == "stop" then
                speaker.stop()
                print("Received stop command")
            end
            -- Volume
            if msg.command == "volume" then
                print("Received volume command. Volume = " ..tostring(clientVolume) .. " -> " .. tostring(msg.volume))
                clientVolume = msg.volume
            end
        end
    end

    parallel.waitForAll(bufferPlayback, receiveMessage)
end

local getSongHandle = function(songID)
    if type(songID) == "table" then
        if string.find(songID.file, "flac") or string.find(songID.file, "wav") or string.find(songID.file, "mp3") or string.find(songID.file, "aac") or string.find(songID.file, "opus") or string.find(songID.file, "ogg") then
            songID.file = "https://cc.alexdevs.me/dfpwm?url=" .. textutils.urlEncode(songID.file)
        end
    end

    if type(songID) == "string" then
        local newSongID = {}
        newSongID.file = songID
        newSongID.name = songID
        if string.find(songID, "flac") or string.find(songID, "wav") or string.find(songID, "mp3") or string.find(songID, "aac") or string.find(songID, "opus") or string.find(songID, "ogg") then
            newSongID.file = "https://cc.alexdevs.me/dfpwm?url=" .. textutils.urlEncode(songID)
            newSongID.author = "URL (converting)"
        else
            newSongID.author = "URL"
        end
        songID = newSongID
    end

    local h, err = http.get({ ["url"] = songID.file, ["binary"] = true, ["redirect"] = true }) -- write in binary mode
    if not h then error("Failed to download song: " .. err) end

    return h
end

-- Control Server
musicme.gui = function(arguments)
    -- Set serverVolume if found
    if arguments[2] and tonumber(arguments[2]) then serverVolume = math.min(math.max(tonumber(arguments[2]), 0), 3) end

    -- Open modems
    modem.open(controlChannel)
    modem.open(clientChannel)
    -- Create GUI and decoder
    local main = basalt.createFrame()
    if not main then error("Failed to create basalt frame") end

    local thread = main:addThread()
    local decoder = dfpwm.make_intdecoder()

    -- Variables
    local pause = false
    local playback = false
    local selectedSong = nil

    -- Song list
    local list = main:addList()
        :setPosition(2, 2)
        :setSize("parent.w - 2", "parent.h - 6")
    for i, o in pairs(index.songs) do list:addItem(index.songs[i].author .. " - " .. index.songs[i].name) end

    -- Automatically update current song whenever screen is clicked
    main:onClick(function() selectedSong = index.songs[list:getItemIndex()] end)

    -- Current Track
    local currentlyPlaying = main:addLabel()
        :setPosition(29, "parent.h - 3")
        :setSize("parent.w - 36", 3)
        :setText("Now Playing: ")
    local updateTrack = function(status)
        if selectedSong ~= nil and playback then
            currentlyPlaying:setText(status .. ": " .. selectedSong.author .. " - " .. selectedSong.name)
        end
        if selectedSong == nil or not playback then
            currentlyPlaying:setText(status, ":")
        end
    end

    -- Functions
    local startPlayback = function()
        playback = true
        local broadcast = function()
            local songHandle = getSongHandle(selectedSong)
            while true do
                while pause do os.pullEvent() end
                local chunk = songHandle.read(128 * bufferLength)
                if not chunk then updateTrack("Now Playing") playback = false break end
                local buffer = decoder(chunk)
                modem.transmit(bufferChannel, controlChannel, {command="buffer", buffer=buffer})
                playBuffer(buffer, serverVolume)
            end
            songHandle.close()
        end
        modem.transmit(clientChannel, controlChannel, {command="pause", pause=false})
        modem.transmit(clientChannel, controlChannel, {command="start", start=true})
        thread:start(broadcast)
    end
    local pausePlayback = function()
        pause = not pause
        modem.transmit(clientChannel, controlChannel, {command="pause", pause=pause})
    end
    local stopPlayback = function()
        modem.transmit(clientChannel, controlChannel, {command="stop", stop=true})
        playback = false
        thread:stop()
    end
    local setVolume = function()
        modem.transmit(clientChannel, controlChannel, {command="volume", volume=clientVolume})
    end

    -- Play Button
    local playButton = main:addButton()
        :setPosition(2, "parent.h - 3")
        :setSize(6, 3)
        :setText("Play")
        :setHorizontalAlign("center")
        :setVerticalAlign("center")
        :setBackground(colors.lime)

    -- Pause Button
    local pauseButton = main:addButton()
        :setPosition(10, "parent.h - 3")
        :setSize(9, 3)
        :setText("Pause")
        :setHorizontalAlign("center")
        :setVerticalAlign("center")
        :setBackground(colors.orange)

    -- Stop Button
    local stopButton = main:addButton()
        :setPosition(21, "parent.h - 3")
        :setSize(6, 3)
        :setText("Stop")
        :setHorizontalAlign("center")
        :setVerticalAlign("center")
        :setBackground(colors.red)

    -- Volume Up Button
    local volumeUpButton = main:addButton()
        :setPosition("parent.w - 3", "parent.h - 3")
        :setSize(3, 1)
        :setText("+")
        :setHorizontalAlign("center")
        :setVerticalAlign("center")

    -- Volume Down Button
    local volumeDownButton = main:addButton()
        :setPosition("parent.w - 3", "parent.h - 1")
        :setSize(3, 1)
        :setText("-")
        :setHorizontalAlign("center")
        :setVerticalAlign("center")

    local playOnClick = function()
        startPlayback()
        updateTrack("Now Playing")
        pauseButton:setText("Pause")
        pauseButton:setBackground(colors.orange)
    end
    playButton:onClick(playOnClick)

    local pauseOnClick = function()
        pausePlayback()
        if pause then
            pauseButton:setText("Unpause")
            pauseButton:setBackground(colors.green)
            updateTrack("Paused")
        end
        if not pause then
            pauseButton:setText("Pause")
            pauseButton:setBackground(colors.orange)
            updateTrack("Now Playing")
        end
    end
    pauseButton:onClick(pauseOnClick)

    local stopOnClick = function()
        stopPlayback()
        pause = false
        pauseButton:setText("Pause")
        pauseButton:setBackground(colors.orange)
        selectedSong = nil
        updateTrack("Now Playing")
    end
    stopButton:onClick(stopOnClick)

    local volumeUpOnClick = function()
        clientVolume = math.min(clientVolume + 0.1, 3)
        setVolume()
    end
    volumeUpButton:onClick(volumeUpOnClick)

    local volumeDownOnClick = function()
        clientVolume = math.max(clientVolume - 0.1, 0)
        setVolume()
    end
    volumeDownButton:onClick(volumeDownOnClick)

    basalt.autoUpdate()
end

musicme.help = function(arguments)
print([[
All computers running musicme must have a modem and speaker attached.
The GUI server computer defaults to being muted.

Usage: <action> [arguments]
Actions:
musicme
    help                -- Displays this message
    gui <serverVolume>  -- Starts the GUI. Will automatically detect monitors.
    client              -- Runs the client.
    update              -- Updates musicme
    startup <arg>       -- Creates a startup file. Specify whether it is for 'client' or for 'gui'
]])
end

musicme.update = function(arguments)
    print("Updating Musicify, please hold on.")
    update()
end

musicme.monitor = function(arguments)
    if not monitor then print("A monitor must be attached") return end

    local scale = 0.5
    if arguments[1] then scale = arguments[1] end
    if not ((2 * scale) % 1) then scale = 0.5 end
    monitor.setTextScale(scale)

    if arguments[2] then serverVolume = arguments[2] end

    shell.run("monitor " .. peripheral.getName(monitor) .. " musicme gui monitor " .. tostring(serverVolume))
end

musicme.startup = function(arguments)
    local mode = table.remove(arguments, 1)
    print(mode)
    if mode ~= "client" and mode ~= "gui" then
        print("Must indicate whether startup file is for GUI or for client.")
        print("Use 'musicme help' for help")
        return
    end
    if fs.exists("startup.lua") then
        fs.move("startup.lua", "/old.musicme/startup.lua")
    end
    if mode == "client" then
        fs.copy("/lib/clientStartup.lua", "startup.lua")
    end
    if mode == "gui" then
        fs.copy("/lib/clientStartup.lua", "startup.lua")
    end
    print("startup.lua created successfully")
end

shell.run("clear")
local command = table.remove(args, 1)
if monitor and command == "gui" and args[1] ~= "monitor" then
    musicme["monitor"](args)
elseif musicme[command] then
    musicme[command](args)
else
    print("Please provide a valid command. For usage, use `musicime help`.")
end
