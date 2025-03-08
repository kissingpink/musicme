local apiURL = "http://api.github.com/repos/JaredWogan/musicme/releases"
local baseRepoURL = "https://raw.githubusercontent.com/JaredWogan/musicme/master"
local args = { ... }
local skipcheck = false

if args and args[1] == "y" then
    skipcheck = true
end

http.request(apiURL)
print("Made request to " .. apiURL)

while true do
    event, url, handle = os.pullEvent()
    if event == "http_failure" then
        shell.run("clear")
        error("Failed to download file: " .. handle)
    end
    if event == "http_success" then
        shell.run("clear")
        print(handle.getResponseCode())
        local data = textutils.unserialiseJSON(handle.readAll())
        local url = data[1].assets[1].browser_download_url

        print("\n\nDownloading musicme from: " .. url .. ", is this okay? (n to cancel, anything else to continue)")
        local input = read()
        if not skipcheck and input == keys.n then
            shell.run("clear")
            error("\n\nCancelled Installation\n\n")
        end

        shell.run("clear")
        print("Installing now")
        shell.run("rm musicify")
        shell.run("wget " .. url)

        print("Downloading libraries right now")
        shell.run("rm /lib/semver.lua")
        shell.run("rm /lib/basalt.lua")
        shell.run("rm /lib/dfpwm.lua")
        shell.run("wget " .. baseRepoURL .. "/lib/semver.lua /lib/semver.lua")
        shell.run("wget " .. baseRepoURL .. "/lib/dfpwm.lua /lib/dfpwm.lua")
        shell.run("wget " .. baseRepoURL .. "/lib/basalt.lua /lib/basalt.lua")
        print("Done!")
        return
    end
end
