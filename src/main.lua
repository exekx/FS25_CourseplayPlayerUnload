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

-- =============================================================
-- FS25 Engine Guards: Fix GIANTS AIVehicleUtil bugs
-- =============================================================
function CP_ApplyEngineGuards()
    if AIVehicleUtil ~= nil and not AIVehicleUtil._cpGuarded then
        AIVehicleUtil._cpGuarded = true

        -- Fix GIANTS bug in AIVehicleUtil.lua:337:
        -- In getAIToolReverserDirectionNode, GIANTS omitted vehicle.getAttachedImplements check!
        -- Any trailer without AttacherJoints (e.g. Krampe SB 30/60) or nil vehicle crashes with:
        -- "attempt to index nil with 'getAttachedImplements'"
        AIVehicleUtil.getAIToolReverserDirectionNode = function(vehicle)
            if vehicle == nil or type(vehicle) ~= "table" then
                return nil
            end
            if vehicle.getAttachedImplements == nil then
                return nil
            end
            local ok, implements = pcall(vehicle.getAttachedImplements, vehicle)
            if not ok or type(implements) ~= "table" then
                return nil
            end
            for _, implement in pairs(implements) do
                if implement and implement.object ~= nil then
                    local reverserNode = nil
                    if implement.object.getAIToolReverserDirectionNode ~= nil then
                        pcall(function()
                            reverserNode = implement.object:getAIToolReverserDirectionNode()
                        end)
                    end

                    local attachedReverserNode = AIVehicleUtil.getAIToolReverserDirectionNode(implement.object)
                    reverserNode = reverserNode or attachedReverserNode

                    if reverserNode ~= nil then
                        return reverserNode
                    end
                end
            end
            return nil
        end

        local orig_allowTurn = AIVehicleUtil.getAttachedImplementsAllowTurnBackward
        if orig_allowTurn then
            AIVehicleUtil.getAttachedImplementsAllowTurnBackward = function(vehicle)
                if vehicle == nil or type(vehicle) ~= "table" or vehicle.getAttachedImplements == nil then
                    return true
                end
                return orig_allowTurn(vehicle)
            end
        end

        local orig_blockTurn = AIVehicleUtil.getAttachedImplementsBlockTurnBackward
        if orig_blockTurn then
            AIVehicleUtil.getAttachedImplementsBlockTurnBackward = function(vehicle)
                if vehicle == nil or type(vehicle) ~= "table" or vehicle.getAttachedImplements == nil then
                    return false
                end
                return orig_blockTurn(vehicle)
            end
        end

        local orig_maxRadius = AIVehicleUtil.getAttachedImplementsMaxTurnRadius
        if orig_maxRadius then
            AIVehicleUtil.getAttachedImplementsMaxTurnRadius = function(vehicle)
                if vehicle == nil or type(vehicle) ~= "table" or vehicle.getAttachedImplements == nil then
                    return -1
                end
                return orig_maxRadius(vehicle)
            end
        end

        print("CP_PlayerUnload: Applied engine safety guards to AIVehicleUtil (fixes GIANTS nil getAttachedImplements bug)")
    end
end

CP_ApplyEngineGuards()

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

    CP_ApplyEngineGuards()
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

