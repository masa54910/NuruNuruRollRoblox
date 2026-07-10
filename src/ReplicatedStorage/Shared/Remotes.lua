-- Shared remote bootstrap helper.
-- Both server and client can require this to use consistent remote names.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = {}
local REMOTE_FOLDER_NAME = "NetworkRemotes"

local function ensureFolder(parent, name)
    local folder = parent:FindFirstChild(name)
    if folder and folder:IsA("Folder") then
        return folder
    end

    folder = Instance.new("Folder")
    folder.Name = name
    folder.Parent = parent
    return folder
end

local function ensureRemoteEvent(parent, name)
    local event = parent:FindFirstChild(name)
    if event and event:IsA("RemoteEvent") then
        return event
    end

    event = Instance.new("RemoteEvent")
    event.Name = name
    event.Parent = parent
    return event
end

local function ensureBindableEvent(parent, name)
    local event = parent:FindFirstChild(name)
    if event and event:IsA("BindableEvent") then
        return event
    end

    event = Instance.new("BindableEvent")
    event.Name = name
    event.Parent = parent
    return event
end

function Remotes.get()
    local sharedFolder = ensureFolder(ReplicatedStorage, "Shared")
    local remotesFolder = ensureFolder(sharedFolder, REMOTE_FOLDER_NAME)

    return {
        RoundState = ensureRemoteEvent(remotesFolder, "RoundState"),
        RoundResult = ensureRemoteEvent(remotesFolder, "RoundResult"),
        GoalScored = ensureRemoteEvent(remotesFolder, "GoalScored"),
        SledInput = ensureRemoteEvent(remotesFolder, "SledInput"),
        DownhillStartRequest = ensureRemoteEvent(remotesFolder, "DownhillStartRequest"),
        GoalReachedServer = ensureBindableEvent(remotesFolder, "GoalReachedServer"),
    }
end

return Remotes
