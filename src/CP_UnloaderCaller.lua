-- =============================================================
-- FS25_CourseplayPlayerUnload: CP_UnloaderCaller.lua
-- Author: exekx
-- Description: Monitors player combine state and dispatches CP unloaders
-- =============================================================

CP_UnloaderCaller = {}
CP_UnloaderCaller.activeCombines = {}
CP_UnloaderCaller.autoCallEnabled = false
CP_UnloaderCaller.callThresholdPercent = 80.0
CP_UnloaderCaller.maxSearchDistance = 600.0
CP_UnloaderCaller.autoCallCooldown = 3000 -- ms
CP_UnloaderCaller.lastAutoCallTime = 0 -- meters

local function showNotification(text)
    print("CP_PlayerUnload: " .. tostring(text))
    if g_currentMission ~= nil then
        if g_currentMission.addIngameNotification and FSBaseMission and FSBaseMission.INGAME_NOTIFICATION_INFO then
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO, text)
        elseif g_currentMission.hud and g_currentMission.hud.addSideNotification then
            g_currentMission.hud:addSideNotification(text)
        elseif g_currentMission.addExtraPrintText then
            g_currentMission:addExtraPrintText(text)
        end
    end
end

function CP_UnloaderCaller.getAdapter(combine)
    if combine == nil then return nil end
    local isAI = combine.getIsAIActive and combine:getIsAIActive()
    if isAI then return nil end

    if CP_UnloaderCaller.activeCombines[combine] == nil then
        CP_UnloaderCaller.activeCombines[combine] = CP_PlayerAdapter.new(combine)

        -- Safely hook instance methods with seamless fallback to original Courseplay methods
        if combine._cpPlayerUnloadOriginals == nil then
            combine._cpPlayerUnloadOriginals = {
                getCpDriveStrategy = combine.getCpDriveStrategy,
                getIsCpActive = combine.getIsCpActive,
                getIsCpDriveToFieldWorkActive = combine.getIsCpDriveToFieldWorkActive
            }

            combine.getCpDriveStrategy = function(self)
                local a = CP_UnloaderCaller.activeCombines[self]
                if a ~= nil then return a end
                local orig = self._cpPlayerUnloadOriginals and self._cpPlayerUnloadOriginals.getCpDriveStrategy
                if orig then return orig(self) end
                if self.spec_cpAIWorker ~= nil then return self.spec_cpAIWorker.driveStrategy end
                return nil
            end

            combine.getIsCpActive = function(self)
                local orig = self._cpPlayerUnloadOriginals and self._cpPlayerUnloadOriginals.getIsCpActive
                if orig then return orig(self) end
                if self.spec_cpAIWorker ~= nil then return self.spec_cpAIWorker.isActive or false end
                return false
            end

            combine.getIsCpDriveToFieldWorkActive = function(self)
                local job = self.getJob and self:getJob()
                if job == nil or job.currentTaskIndex == nil then return false end
                local orig = self._cpPlayerUnloadOriginals and self._cpPlayerUnloadOriginals.getIsCpDriveToFieldWorkActive
                if orig then return orig(self) end
                return false
            end
        end

        print(string.format("CP_PlayerUnload: Attached player adapter to combine '%s'", tostring(combine:getName())))
    end
    return CP_UnloaderCaller.activeCombines[combine]
end

function CP_UnloaderCaller.removeAdapter(combine)
    if combine ~= nil and CP_UnloaderCaller.activeCombines[combine] ~= nil then
        CP_UnloaderCaller.activeCombines[combine] = nil
        print(string.format("CP_PlayerUnload: Removed player adapter from combine '%s'", tostring(combine:getName())))
    end
end

function CP_UnloaderCaller.onUpdateTick(dt)
    if CP_UnloaderHooks and CP_UnloaderHooks.hookRhm then
        CP_UnloaderHooks.hookRhm()
    end
    if g_currentMission == nil or g_currentMission.vehicleSystem == nil then
        return
    end

    local currentVehicles = g_currentMission.vehicleSystem.vehicles
    if currentVehicles == nil then return end

    for _, vehicle in pairs(currentVehicles) do
        local isCombine = vehicle.spec_combine ~= nil
        if isCombine then
            local isAI = (vehicle.getIsAIActive and vehicle:getIsAIActive()) or (vehicle.getJob and vehicle:getJob() ~= nil)
            local adapter = CP_UnloaderCaller.activeCombines[vehicle]

            if isAI then
                if adapter ~= nil then
                    CP_UnloaderCaller.removeAdapter(vehicle)
                end
            else
                local isEntered = (vehicle.getIsEntered and vehicle:getIsEntered()) or (vehicle.getIsControlled and vehicle:getIsControlled())

                if isEntered and adapter == nil then
                    adapter = CP_UnloaderCaller.getAdapter(vehicle)
                end

                if adapter ~= nil then
                    adapter:update(dt)

                    -- Check if assigned unloader is still valid and serving us
                    if adapter.assignedUnloader and type(adapter.assignedUnloader) == "table" then
                        local unloader = adapter.assignedUnloader
                        local unloaderStrategy = (type(unloader.getCpDriveStrategy) == "function") and unloader:getCpDriveStrategy()
                        if unloaderStrategy == nil or (unloaderStrategy.getCombineToUnload and unloaderStrategy:getCombineToUnload() ~= vehicle) then
                            local name = (unloader.getName and unloader:getName()) or "Tractor"
                            print(string.format("CP_PlayerUnload: Unloader '%s' has departed.", tostring(name)))
                            adapter.assignedUnloader = nil
                        end
                    end

                    -- Auto-call evaluation if enabled
                    if isEntered and CP_UnloaderCaller.autoCallEnabled and not adapter.assignedUnloader then
                        local fillPercent = adapter:getFillLevelPercentage()
                        local pipeOpen = adapter:isPipeOpen()

                        if fillPercent >= CP_UnloaderCaller.callThresholdPercent or (fillPercent > 20 and pipeOpen) then
                            CP_UnloaderCaller.callBestUnloader(vehicle, false)
                        end
                    end

                    -- Only remove adapter if combine is empty, player is outside, and no unloader is assigned
                    if not isEntered and not adapter.assignedUnloader and adapter:getFillLevelPercentage() < 1 then
                        CP_UnloaderCaller.removeAdapter(vehicle)
                    end
                end
            end
        end
    end
end

function CP_UnloaderCaller.findBestUnloader(combine)
    if combine == nil or combine.rootNode == nil then return nil end
    local AIDriveStrategyUnloadCombine = CP_GetCpClass("AIDriveStrategyUnloadCombine")
    if AIDriveStrategyUnloadCombine == nil then
        print("CP_PlayerUnload: AIDriveStrategyUnloadCombine class could not be resolved from Courseplay environment!")
        return nil
    end

    local bestUnloader = nil
    local bestDistance = CP_UnloaderCaller.maxSearchDistance
    local cx, cy, cz = getWorldTranslation(combine.rootNode)

    local vehicles = g_currentMission.vehicleSystem.vehicles
    for _, v in pairs(vehicles) do
        if v ~= combine then
            local isUnloader = false
            if AIDriveStrategyUnloadCombine.isActiveCpCombineUnloader and AIDriveStrategyUnloadCombine.isActiveCpCombineUnloader(v) then
                isUnloader = true
            elseif v.getIsCpCombineUnloaderActive and v:getIsCpCombineUnloaderActive() then
                isUnloader = true
            end

            if isUnloader then
                local strategy = (type(v.getCpDriveStrategy) == "function") and v:getCpDriveStrategy()
                if strategy then
                    local isAvailable = false
                    if strategy.isAllowedToBeCalled and strategy:isAllowedToBeCalled() then
                        isAvailable = true
                    elseif strategy.isIdle and strategy:isIdle() then
                        isAvailable = true
                    elseif strategy.state and strategy.states and strategy.state == strategy.states.IDLE then
                        isAvailable = true
                    end

                    if isAvailable then
                        local unloaderFill = (strategy.getFillLevelPercentage and strategy:getFillLevelPercentage()) or 0
                        if unloaderFill < 98 then
                            local vx, vy, vz = getWorldTranslation(v.rootNode)
                            local dist = MathUtil.vector2Length(cx - vx, cz - vz)
                            print(string.format("CP_PlayerUnload: Found candidate unloader '%s' at distance %.1f m (fill: %.1f%%, state: %s)",
                                tostring(v:getName()), dist, unloaderFill, tostring(strategy.state)))
                            if dist < bestDistance then
                                bestDistance = dist
                                bestUnloader = v
                            end
                        else
                            print(string.format("CP_PlayerUnload: Unloader '%s' skipped because trailer is full (%.1f%%)", tostring(v:getName()), unloaderFill))
                        end
                    else
                        -- Unloader is busy, skip quietly
                    end
                end
            end
        end
    end

    return bestUnloader
end

function CP_UnloaderCaller.callBestUnloader(combine, isManual)
    local adapter = CP_UnloaderCaller.getAdapter(combine)
    if adapter == nil then return false end

    if adapter.assignedUnloader and type(adapter.assignedUnloader) == "table" then
        if isManual then
            local name = (adapter.assignedUnloader.getName and adapter.assignedUnloader:getName()) or "Tractor"
            local text = string.format(g_i18n:getText("cp_player_unload_called") or "Unloader '%s' is already assigned.", name)
            showNotification(text)
        end
        return true
    end

    local unloader = CP_UnloaderCaller.findBestUnloader(combine)
    if unloader == nil then
        if isManual then
            local text = g_i18n:getText("cp_player_unload_no_unloader") or "No idle Courseplay unloader found in range."
            showNotification(text)
        end
        return false
    end

    local strategy = (type(unloader.getCpDriveStrategy) == "function") and unloader:getCpDriveStrategy()
    if strategy == nil then return false end

    print(string.format("CP_PlayerUnload: Calling unloader '%s' for combine '%s' (speed: %.1f km/h)",
        tostring(unloader:getName()), tostring(combine:getName()), combine:getLastSpeed()))

    -- Dispatch unloader directly to combine
    local success = strategy:call(combine, nil)
    print(string.format("CP_PlayerUnload: strategy:call returned: %s", tostring(success)))

    if success then
        adapter.assignedUnloader = unloader
        local name = (unloader.getName and unloader:getName()) or "Tractor"
        local text = string.format(g_i18n:getText("cp_player_unload_called") or "Courseplay unloader '%s' has been called.", name)
        showNotification(text)
        return true
    end

    return false
end

function CP_UnloaderCaller.toggleAutoCall()
    CP_UnloaderCaller.autoCallEnabled = not CP_UnloaderCaller.autoCallEnabled
    local key = CP_UnloaderCaller.autoCallEnabled and "cp_player_unload_autocall_on" or "cp_player_unload_autocall_off"
    local defaultText = CP_UnloaderCaller.autoCallEnabled and "Auto-call unloader: ENABLED" or "Auto-call unloader: DISABLED"
    showNotification(g_i18n:getText(key) or defaultText)
end