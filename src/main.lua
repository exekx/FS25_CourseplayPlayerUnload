-- =============================================================
-- FS25_CourseplayPlayerUnload: main.lua
-- Author: exekx
-- Description: Entry point for Courseplay Player Unloader Addon
-- =============================================================

local modDirectory = g_currentModDirectory
local modName = g_currentModName

-- Global Courseplay Class Resolver
function CP_GetCpClass(className)
    local cpModName = (g_modManager and g_modManager.CP_MOD_NAME) or "FS25_Courseplay"
    local cpEnv = _G[cpModName]
    if not cpEnv and getfenv(0) then
        cpEnv = getfenv(0)[cpModName]
    end
    if not cpEnv and g_modManager and g_modManager.getModByName then
        local cpMod = g_modManager:getModByName(cpModName)
        if cpMod and cpMod.environment then
            cpEnv = cpMod.environment
        end
    end
    if not cpEnv then
        cpEnv = _G["Courseplay"]
    end
    if cpEnv and type(cpEnv) == "table" and cpEnv[className] ~= nil then
        return cpEnv[className]
    end
    if _G[className] ~= nil then
        return _G[className]
    end
    return nil
end

source(modDirectory .. "src/CP_VirtualCourse.lua")
source(modDirectory .. "src/CP_PlayerAdapter.lua")
source(modDirectory .. "src/CP_UnloaderCaller.lua")
source(modDirectory .. "src/CP_UnloaderHooks.lua")

local function checkCourseplay()
    if not CP_UnloaderHooks.isInitialized then
        local AIDriveStrategyUnloadCombine = CP_GetCpClass("AIDriveStrategyUnloadCombine")
        if AIDriveStrategyUnloadCombine ~= nil then
            CP_UnloaderHooks.init()
        end
    end
    return CP_UnloaderHooks.isInitialized
end

local function onMissionLoaded(mission, node)
    if mission and mission.cancelLoading then
        return
    end

    print(string.format("CP_PlayerUnload: Initializing '%s' (Author: exekx)...", tostring(modName)))
    if CP_UnloaderHooks and CP_UnloaderHooks.hookRhm then
        CP_UnloaderHooks.hookRhm()
    end
    if checkCourseplay() then
        print("CP_PlayerUnload: Courseplay detected and hooks successfully activated!")
    else
        print("CP_PlayerUnload: Waiting for Courseplay to initialize...")
    end
end

local function onMissionUpdate(dt)
    if not checkCourseplay() then
        return
    end

    local mission = g_currentMission
    local isServer = g_server ~= nil or (mission and ((mission.getIsServer and mission:getIsServer()) or mission.isServer))
    if isServer then
        CP_UnloaderCaller.onUpdateTick(dt)
    end
end

-- Giants Engine Mod Event Listener (standard engine lifecycle)
local CP_PlayerUnloadMod = {}

function CP_PlayerUnloadMod:loadMap(name)
    onMissionLoaded(g_currentMission)
end

function CP_PlayerUnloadMod:update(dt)
    onMissionUpdate(dt)
end

addModEventListener(CP_PlayerUnloadMod)

-- Fallback Mission Hooks (ensures initialization if loadMap was called early)
if Mission00 ~= nil and Mission00.loadMission00Finished ~= nil then
    Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, onMissionLoaded)
elseif FSBaseMission ~= nil and FSBaseMission.onFinishedLoading ~= nil then
    FSBaseMission.onFinishedLoading = Utils.appendedFunction(FSBaseMission.onFinishedLoading, onMissionLoaded)
end

