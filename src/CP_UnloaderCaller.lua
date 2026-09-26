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
CP_UnloaderCaller.lastAutoCallTime = 0

local function showNotification(text)
    print("CP_PlayerUnload: " .. tostring(text))
    if g_currentMission ~= nil then
        if g_currentMission.showBlinkingWarning then
            g_currentMission:showBlinkingWarning(text, 3000)
        elseif g_currentMission.hud and g_currentMission.hud.addSideNotification then
            g_currentMission.hud:addSideNotification(text)
        elseif g_currentMission.addExtraPrintText then
            g_currentMission:addExtraPrintText(text)
        end
    end
end

function CP_UnloaderCaller.findCombineAndCarrier(vehicle)
    if vehicle == nil then return nil, nil end
    -- 1. Vehicle itself is a combine / forage harvester
    if vehicle.spec_combine ~= nil or vehicle.spec_forageHarvester ~= nil then
        return vehicle, vehicle
    end
    -- 2. Carrier vehicle (NEXAT) or tractor with attached harvester
    if vehicle.getAttachedImplements ~= nil then
        for _, impl in pairs(vehicle:getAttachedImplements()) do
            local obj = impl.object
            if obj ~= nil then
                if obj.spec_combine ~= nil or obj.spec_forageHarvester ~= nil or (obj.spec_pipe ~= nil and obj.spec_dischargeable ~= nil) then
                    return obj, vehicle
                end
                if obj.getAttachedImplements ~= nil then
                    for _, subImpl in pairs(obj:getAttachedImplements()) do
                        local subObj = subImpl.object
                        if subObj ~= nil and (subObj.spec_combine ~= nil or subObj.spec_forageHarvester ~= nil or (subObj.spec_pipe ~= nil and subObj.spec_dischargeable ~= nil)) then
                            return subObj, vehicle
                        end
                    end
                end
            end
        end
    end
    -- 3. Vehicle might be an implement mounted on a carrier (e.g. entered in NexCo)
    if vehicle.getRootVehicle ~= nil then
        local root = vehicle:getRootVehicle()
        if root ~= nil and root ~= vehicle then
            if vehicle.spec_combine ~= nil or vehicle.spec_forageHarvester ~= nil or (vehicle.spec_pipe ~= nil and vehicle.spec_dischargeable ~= nil) then
                return vehicle, root
            end
            if root.getAttachedImplements ~= nil then
                for _, impl in pairs(root:getAttachedImplements()) do
                    local obj = impl.object
                    if obj ~= nil and (obj.spec_combine ~= nil or obj.spec_forageHarvester ~= nil or (obj.spec_pipe ~= nil and obj.spec_dischargeable ~= nil)) then
                        return obj, root
                    end
                end
            end
        end
    end
    return nil, nil
end

function CP_UnloaderCaller.getAdapter(vehicle)
    if vehicle == nil then return nil end
    local combineObj, carrierObj = CP_UnloaderCaller.findCombineAndCarrier(vehicle)
    if combineObj == nil then return nil end
    local primeMover = carrierObj or vehicle

    local isAI = (primeMover.getIsAIActive and primeMover:getIsAIActive()) or (combineObj.getIsAIActive and combineObj:getIsAIActive())
    if isAI then return nil end

    local existing = CP_UnloaderCaller.activeCombines[primeMover] or CP_UnloaderCaller.activeCombines[combineObj]
    if existing ~= nil then
        CP_UnloaderCaller.activeCombines[primeMover] = existing
        CP_UnloaderCaller.activeCombines[combineObj] = existing
        return existing
    end

    local adapter = CP_PlayerAdapter.new(combineObj, primeMover)
    CP_UnloaderCaller.activeCombines[primeMover] = adapter
    CP_UnloaderCaller.activeCombines[combineObj] = adapter

    local function wrap(obj)
        if obj and not obj._cpPlayerUnloadWrapped then
            obj._cpPlayerUnloadWrapped = true
            obj._cpPlayerUnloadOriginals = {
                getCpDriveStrategy = obj.getCpDriveStrategy,
                getIsCpActive = obj.getIsCpActive,
                getIsCpDriveToFieldWorkActive = obj.getIsCpDriveToFieldWorkActive,
                getAIDirectionNode = obj.getAIDirectionNode
            }

            obj.getCpDriveStrategy = function(self)
                local a = CP_UnloaderCaller.activeCombines[self]
                if a ~= nil then return a end
                local orig = self._cpPlayerUnloadOriginals and self._cpPlayerUnloadOriginals.getCpDriveStrategy
                if orig then return orig(self) end
                if self.spec_cpAIWorker ~= nil then return self.spec_cpAIWorker.driveStrategy end
                return nil
            end

            obj.getIsCpActive = function(self)
                local orig = self._cpPlayerUnloadOriginals and self._cpPlayerUnloadOriginals.getIsCpActive
                if orig then return orig(self) end
                if self.spec_cpAIWorker ~= nil then return self.spec_cpAIWorker.isActive or false end
                return false
            end

            obj.getIsCpDriveToFieldWorkActive = function(self)
                local job = self.getJob and self:getJob()
                if job == nil or job.currentTaskIndex == nil then return false end
                local orig = self._cpPlayerUnloadOriginals and self._cpPlayerUnloadOriginals.getIsCpDriveToFieldWorkActive
                if orig then return orig(self) end
                return false
            end

            obj.getAIDirectionNode = function(self)
                local a = CP_UnloaderCaller.activeCombines[self]
                if a and a.getPipeOffsetReferenceNode then
                    local n = a:getPipeOffsetReferenceNode()
                    if n and n ~= 0 then return n end
                end
                local orig = self._cpPlayerUnloadOriginals and self._cpPlayerUnloadOriginals.getAIDirectionNode
                if orig then return orig(self) end
                return CP_PlayerAdapter.getDirectionNode(self)
            end
        end
    end
    wrap(primeMover)
    wrap(combineObj)

    print(string.format("CP_PlayerUnload: Attached player adapter to combine '%s' (carrier: '%s')",
        tostring(combineObj:getName()), tostring(primeMover:getName())))
    return adapter
end

function CP_UnloaderCaller.removeAdapter(combine)
    if combine ~= nil then
        local adapter = CP_UnloaderCaller.activeCombines[combine]
        if adapter ~= nil then
            if adapter.combine then CP_UnloaderCaller.activeCombines[adapter.combine] = nil end
            if adapter.vehicle then CP_UnloaderCaller.activeCombines[adapter.vehicle] = nil end
            print(string.format("CP_PlayerUnload: Removed player adapter from '%s'", tostring(combine:getName())))
        else
            CP_UnloaderCaller.activeCombines[combine] = nil
        end
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

    local currentTime = g_currentMission.time or 0
    local checkedVehicles = {}

    for _, vehicle in pairs(currentVehicles) do
        local combineObj, carrierObj = CP_UnloaderCaller.findCombineAndCarrier(vehicle)
        if combineObj ~= nil and not checkedVehicles[combineObj] then
            checkedVehicles[combineObj] = true
            local primeMover = carrierObj or vehicle
            checkedVehicles[primeMover] = true

            local isAI = (primeMover.getIsAIActive and primeMover:getIsAIActive()) or (combineObj.getIsAIActive and combineObj:getIsAIActive())
            local adapter = CP_UnloaderCaller.activeCombines[primeMover] or CP_UnloaderCaller.activeCombines[combineObj]

            if isAI then
                if adapter ~= nil then
                    CP_UnloaderCaller.removeAdapter(primeMover)
                end
            else
                local isEntered = (primeMover.getIsEntered and primeMover:getIsEntered())
                    or (primeMover.getIsControlled and primeMover:getIsControlled())
                    or (combineObj.getIsEntered and combineObj:getIsEntered())
                    or (combineObj.getIsControlled and combineObj:getIsControlled())

                if isEntered and adapter == nil then
                    adapter = CP_UnloaderCaller.getAdapter(primeMover)
                end

                if adapter ~= nil then
                    adapter:update(dt)

                    local pipeOpen = adapter:isPipeOpen()
                    local isDischarging = adapter:isDischarging()
                    local fillPercent = adapter:getFillLevelPercentage()
                    local isChopper = adapter:isChopper()

                    -- 1. Check if assigned unloader is still valid and serving us
                    if adapter.assignedUnloader and type(adapter.assignedUnloader) == "table" then
                        local unloader = adapter.assignedUnloader
                        local unloaderStrategy = (type(unloader.getCpDriveStrategy) == "function") and unloader:getCpDriveStrategy()

                        -- Unloader departed or was reassigned elsewhere
                        if unloaderStrategy == nil or (unloaderStrategy.getCombineToUnload and unloaderStrategy:getCombineToUnload() ~= primeMover and unloaderStrategy:getCombineToUnload() ~= combineObj) then
                            local name = (unloader.getName and unloader:getName()) or "Tractor"
                            print(string.format("CP_PlayerUnload: Unloader '%s' has departed.", tostring(name)))
                            adapter.assignedUnloader = nil
                            adapter.lastDepartedTime = currentTime
                            adapter.pipeCallEligible = false
                        -- Physical command to DISMISS: If player folded pipe and is not discharging
                        elseif not pipeOpen and not isDischarging then
                            local name = (unloader.getName and unloader:getName()) or "Tractor"
                            print(string.format("CP_PlayerUnload: Pipe folded by player, dismissing unloader '%s'", tostring(name)))
                            if unloaderStrategy.releaseCombine then
                                unloaderStrategy:releaseCombine()
                            end
                            if unloaderStrategy.startWaitingForSomethingToDo then
                                unloaderStrategy:startWaitingForSomethingToDo()
                            end
                            adapter.assignedUnloader = nil
                            adapter.lastDepartedTime = currentTime
                            adapter.pipeCallEligible = false
                        end
                    end

                    -- 2. Unloader Call Dispatcher:
                    if isEntered and not adapter.assignedUnloader then
                        local timeSinceDeparted = currentTime - (adapter.lastDepartedTime or 0)
                        local canCall = timeSinceDeparted > 8000
                        local isStopped = (primeMover.getLastSpeed and primeMover:getLastSpeed() < 0.5)

                        local shouldCall = false
                        if isChopper then
                            local isWorking = adapter:isProcessingFruit() or not isStopped
                            if pipeOpen and (isWorking or isStopped or adapter.pipeCallEligible) and canCall then
                                shouldCall = true
                            end
                        else
                            -- Grain Combine mode:
                            if isStopped and pipeOpen and fillPercent > 0.5 and canCall then
                                shouldCall = true
                            elseif not isStopped and adapter.pipeCallEligible and fillPercent >= 15.0 and canCall then
                                shouldCall = true
                            elseif CP_UnloaderCaller.autoCallEnabled and fillPercent >= CP_UnloaderCaller.callThresholdPercent and canCall then
                                shouldCall = true
                            end
                        end

                        if shouldCall then
                            if (currentTime - CP_UnloaderCaller.lastAutoCallTime) > CP_UnloaderCaller.autoCallCooldown then
                                CP_UnloaderCaller.lastAutoCallTime = currentTime
                                local called = CP_UnloaderCaller.callBestUnloader(primeMover, false)
                                if called then
                                    adapter.pipeCallEligible = false
                                end
                            end
                        end
                    end

                    -- Only remove adapter if harvester is inactive, player has exited, and no unloader is currently assigned
                    if not isEntered and not adapter.assignedUnloader then
                        if isChopper then
                            if not adapter:isProcessingFruit() and (primeMover.getLastSpeed and primeMover:getLastSpeed() < 0.5) then
                                CP_UnloaderCaller.removeAdapter(primeMover)
                            end
                        else
                            if fillPercent < 1.0 then
                                CP_UnloaderCaller.removeAdapter(primeMover)
                            end
                        end
                    end
                end
            end
        end
    end
end

function CP_UnloaderCaller.findBestUnloader(combine)
    if combine == nil or combine.rootNode == nil then return nil end
    local adapter = CP_UnloaderCaller.activeCombines[combine]
    local currentTime = (g_currentMission and g_currentMission.time) or 0
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
            elseif v.getIsAIActive and v:getIsAIActive() then
                -- Fallback check: Courseplay active driver flag
                local strategy = (type(v.getCpDriveStrategy) == "function") and v:getCpDriveStrategy()
                if strategy and (strategy.isACombineUnloadAIDriver or (strategy.states and strategy.states.UNLOADING_MOVING_COMBINE ~= nil)) then
                    isUnloader = true
                end
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
                    end
                end
            end
        end
    end

    return bestUnloader
end

function CP_UnloaderCaller.callBestUnloader(vehicle, isManual)
    local adapter = CP_UnloaderCaller.getAdapter(vehicle)
    if adapter == nil then return false end

    local targetVehicle = adapter.vehicle or vehicle

    if adapter.assignedUnloader and type(adapter.assignedUnloader) == "table" then
        if isManual then
            local name = (adapter.assignedUnloader.getName and adapter.assignedUnloader:getName()) or "Tractor"
            local text = string.format(g_i18n:getText("cp_player_unload_called") or "Unloader '%s' is already assigned.", name)
            showNotification(text)
        end
        return true
    end

    local unloader = CP_UnloaderCaller.findBestUnloader(targetVehicle)
    if unloader == nil then
        if isManual then
            local text = g_i18n:getText("cp_player_unload_no_unloader") or "No idle Courseplay unloader found in range."
            showNotification(text)
        end
        return false
    end

    local strategy = (type(unloader.getCpDriveStrategy) == "function") and unloader:getCpDriveStrategy()
    if strategy == nil then return false end

    local combineName = (adapter.combine and adapter.combine.getName and adapter.combine:getName()) or tostring(targetVehicle:getName())
    print(string.format("CP_PlayerUnload: Calling unloader '%s' for combine '%s' (carrier: '%s', speed: %.1f km/h, chopper: %s)",
        tostring(unloader:getName()), tostring(combineName), tostring(targetVehicle:getName()), targetVehicle:getLastSpeed(), tostring(adapter:isChopper())))

    local isMoving = (targetVehicle.getLastSpeed and targetVehicle:getLastSpeed() > 0.5)
    local rendezvousWp = (isMoving and adapter.getRendezvousWaypoint and adapter:getRendezvousWaypoint(35)) or nil
    local success = false
    if rendezvousWp ~= nil then
        success = strategy:call(targetVehicle, rendezvousWp)
    end
    if not success then
        success = strategy:call(targetVehicle, nil)
    end
    print(string.format("CP_PlayerUnload: strategy:call returned: %s (moving: %s)", tostring(success), tostring(isMoving)))

    if success then
        adapter.assignedUnloader = unloader
        adapter.pipeCallEligible = false
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
    local defaultText = CP_UnloaderCaller.autoCallEnabled and "Auto-call unloader (80%): ENABLED" or "Auto-call unloader (80%): DISABLED"
    local msg = (g_i18n and g_i18n:hasText(key) and g_i18n:getText(key)) or defaultText
    showNotification(msg)
end
