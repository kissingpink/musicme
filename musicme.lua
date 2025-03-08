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

-- Channels
local controlChannel = 2561
local connectChannel = controlChannel + 1
local bufferChannel = controlChannel + 2
local startChannel = controlChannel + 3
local pauseChannel = controlChannel + 4
local stopChannel = controlChannel + 5

-- Peripherals
local modem = peripheral.find("modem")
local speaker = peripheral.find("speaker")

-- HTTP Handle (Loads song library)
local handle, msg = http.get(indexURL)
if not handle then error(msg) end

local indexJSON = handle.readAll()
handle.close()

local index = textutils.unserialiseJSON(indexJSON)
if not index then error("The index is malformed.", 0) end


-- Check for updates
local function update()
    shell.run("wget run https://raw.githubusercontent.com/knijn/musicify/main/install.lua")
end
if autoUpdates then
    update()
end
if v(version) < v(index.latestVersion) then
    error("Client outdated... Running Updates", 0)
    update()
end

-- musicme
local musicme = {}
local args = { ... }

-- Ensure there is a modem
if not modem then error("There needs to be a modem attached") end

local awaitMessage = function(channel, replyChannel, message)
    local e, s, c, rc, msg, d = os.pullEvent("modem_message")
    while c ~= channel and rc ~= replyChannel and msg ~= message do
        e, s, c, rc, msg, d = os.pullEvent("modem_message")
    end
end

local playBuffer = function(buffer)
    while not speaker.playAudio(buffer) do os.pullEvent("speaker_audio_empty") end
end

-- Run the speaker client
musicme.client = function(arguments)
    -- Ensure there is a speaker
    if not speaker then error("Speaker not found", 0) end

    modem.open(bufferChannel)
    modem.open(pauseChannel)
    modem.open(stopChannel)

    local paused = false
    local buffer = nil

    local bufferPlayback = function()
        while true do
            if not paused then
                modem.transmit(controlChannel, bufferChannel, true)
                local e, s, c, rc, msg, d = os.pullEvent("modem_message")
                if rc == controlChannel and c == bufferChannel then
                    buffer = msg
                    playBuffer(buffer)
                end
            end
            if paused then
                os.pullEvent("modem_message")
                os.sleep(0.05)
            end
        end
    end

    local receiveMessage = function()
        while true do
            print("Listening for updates")

            local e, s, c, rc, msg, d = os.pullEvent("modem_message")
            if rc == controlChannel then
                -- Start
                if c == startChannel then
                    paused = false
                    buffer = nil
                    print("Starting playback")
                end
                -- Song buffer
                if c == bufferChannel then
                    print("Received song buffer... playing")
                end
                -- Pause
                if c == pauseChannel then
                    paused = msg
                    speaker.stop()
                    print("Received pause command. Paused = " .. tostring(paused))
                end
                -- Stop
                if c == stopChannel then
                    paused = false
                    buffer = nil
                    speaker.stop()
                    print("Received stop command")
                end
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

    if songID.speed == 2 then
        error("Please use 48khz audio in your repository")
    end

    local h, err = http.get({ ["url"] = songID.file, ["binary"] = true, ["redirect"] = true }) -- write in binary mode
    if not h then error("Failed to download song: " .. err) end

    return h
end

-- Control Server
musicme.gui = function(arguments)
    modem.open(controlChannel)
    modem.open(connectChannel)

    -- Create GUI and decoder
    local main = basalt.createFrame()
    local thread = main:addThread()
    local decoder = dfpwm.make_intdecoder()

    -- Variables
    local paused = false
    local currentSong = nil

    -- Song list
    local list = main:addList()
        :setPosition(2, 2)
        :setSize("parent.w - 2", "parent.h - 6")
    for i, o in pairs(index.songs) do list:addItem(index.songs[i].author .. " - " .. index.songs[i].name) end

    -- Automatically update current song whenever screen is clicked
    main:onClick(function() currentSong = index.songs[list:getItemIndex()] end)

    -- Current Track
    local currentlyPlaying = main:addLabel()
        :setPosition(29, "parent.h - 3")
        :setSize("parent.w - 31", 3)
        :setText("Now Playing: ")
    local updateTrack = function(status)
        if currentSong ~= nil then
            currentlyPlaying:setText(status .. ": " .. currentSong.author .. " - " .. currentSong.name)
        end
        if currentSong == nil then
            currentlyPlaying:setText(status, ":")
        end
    end

    -- Functions
    local startPlayback = function()
        local broadcast = function()
            -- local songID = index.songs[list:getItemIndex()]
            local songHandle = getSongHandle(currentSong)
            while true do
                local chunk = songHandle.read(16 * 128)
                if not chunk then
                    updateTrack("Now Playing", nil)
                    break
                end
                local buffer = decoder(chunk)
                modem.transmit(bufferChannel, controlChannel, buffer)

                awaitMessage(controlChannel, bufferChannel, true)
            end
            songHandle.close()
        end
        modem.transmit(pauseChannel, controlChannel, false)
        modem.transmit(startChannel, controlChannel, true)
        thread:start(broadcast)
    end
    local pausePlayback = function()
        paused = not paused
        modem.transmit(pauseChannel, controlChannel, paused)
    end
    local stopPlayback = function()
        modem.transmit(stopChannel, controlChannel, true)
        thread:stop()
    end

    -- Play Button
    local playButton = main:addButton()
        :setPosition(2, "parent.h - 3")
        :setSize(6, 3)
        :setText("Play")
        :setHorizontalAlign("center")
        :setVerticalAlign("center")
        :setBackground(colors.lime)
    local playOnClick = function()
        startPlayback()
        updateTrack("Now Playing")
    end
    playButton:onClick(playOnClick)

    -- Pause Button
    local pauseButton = main:addButton()
        :setPosition(10, "parent.h - 3")
        :setSize(9, 3)
        :setText("Pause")
        :setHorizontalAlign("center")
        :setVerticalAlign("center")
        :setBackground(colors.orange)
    local pauseOnClick = function()
        pausePlayback()
        if paused then
            pauseButton:setText("Unpause")
            pauseButton:setBackground(colors.green)
            updateTrack("Paused")
        end
        if not paused then
            pauseButton:setText("Pause")
            pauseButton:setBackground(colors.orange)
            updateTrack("Now Playing")
        end
    end
    pauseButton:onClick(pauseOnClick)

    -- Stop Button
    local stopButton = main:addButton()
        :setPosition(21, "parent.h - 3")
        :setSize(6, 3)
        :setText("Stop")
        :setHorizontalAlign("center")
        :setVerticalAlign("center")
        :setBackground(colors.red)
    local stopOnClick = function()
        stopPlayback()
        pauseButton:setText("Pause")
        pauseButton:setBackground(colors.orange)
        currentSong = nil
        updateTrack("Now Playing")
    end
    stopButton:onClick(stopOnClick)

    basalt.autoUpdate()
end

musicme.help = function(arguments)
print([[
Usage: <action> [arguments]
Actions:
musicify
    help            -- Displays this message
    info            -- Displays information about Musicify's version and repo
    gui             -- Starts the GUI
    update          -- Updates musicify
    url <url>       -- Play a song from a URL
]])
end

musicme.url = function(arguments)
    if string.find(arguments[1], "youtube") then
        print("Youtube support isn't garuanteed, proceed with caution")
    end
    play(arguments[1])
end

musicme.update = function(arguments)
    print("Updating Musicify, please hold on.")
    update()
end

musicme.shuffle = function(arguments)
    local from = arguments[1] or 1
    local to = arguments[2] or #index.songs
    if tostring(arguments[1]) and not tonumber(arguments[1]) and arguments[1] then -- Check if selection is valid
        error("Please specify arguments in a form like `musicify shuffle 1 5`", 0)
        return
    end
    while true do
        print("Currently in shuffle mode")
        local ranNum = math.random(from, to)
        play(index.songs[ranNum])
    end
end


local command = table.remove(args, 1)
musicme.index = index

if musicme[command] then
    musicme[command](args)
else
    print("Please provide a valid command. For usage, use `musicify help`.")
end
