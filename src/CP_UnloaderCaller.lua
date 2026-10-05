-- =============================================================
-- FS25_CourseplayPlayerUnload: CP_UnloaderCaller.lua
-- Author: exekx
-- Description: Monitors player combine state and dispatches CP unloaders
-- =============================================================

CP_UnloaderCaller = {}
CP_UnloaderCaller.activeCombines = {}
CP_UnloaderCaller.autoCallEnabled = false
CP_UnloaderCaller.callThresholdPercent = 80.0
CP_UnloaderCaller.maxSearchDistance = 4000.0 -- expanded from 600m to 4000m for large fields (Issue 2)
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

local function isHarvesterObject(obj)
    if obj == nil or obj.isDeleted then return false end
    -- Exclude trailers, grain carts / auger wagons, slurry tanks
    if obj.spec_trailer ~= nil then
        return false
    end
    if obj.spec_combine ~= nil or obj.spec_forageHarvester ~= nil then
        return true
    end
    -- Trailed harvesters (cutters/workareas that are not trailers)
    if (obj.spec_cutter ~= nil or obj.spec_workArea ~= nil) and obj.spec_pipe ~= nil and obj.spec_dischargeable ~= nil then
        return true
    end
    return false
end

function CP_UnloaderCaller.findCombineAndCarrier(vehicle)
    if vehicle == nil or vehicle.isDeleted then return nil, nil end
    -- 1. Vehicle itself is a combine / forage harvester
    if isHarvesterObject(vehicle) then
        return vehicle, vehicle
    end
    -- 2. Carrier vehicle (NEXAT) or tractor with attached harvester
    if vehicle.getAttachedImplements ~= nil then
        for _, impl in pairs(vehicle:getAttachedImplements()) do
            local obj = impl.object
            if isHarvesterObject(obj) then
                return obj, vehicle
            end
            if obj and obj.getAttachedImplements ~= nil then
                for _, subImpl in pairs(obj:getAttachedImplements()) do
                    local subObj = subImpl.object
                    if isHarvesterObject(subObj) then
                        return subObj, vehicle
                    end
                end
            end
        end
    end
    -- 3. Vehicle might be an implement mounted on a carrier (e.g. entered in NexCo)
    if vehicle.getRootVehicle ~= nil then
        local root = vehicle:getRootVehicle()
        if root ~= nil and root ~= vehicle and not root.isDeleted then
            if isHarvesterObject(vehicle) then
                return vehicle, root
            end
            if root.getAttachedImplements ~= nil then
                for _, impl in pairs(root:getAttachedImplements()) do
                    local obj = impl.object
                    if isHarvesterObject(obj) then
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

function CP_UnloaderCaller.cleanupDeletedCombines()
    if CP_UnloaderCaller.activeCombines == nil then return end
    for obj, adapter in pairs(CP_UnloaderCaller.activeCombines) do
        if obj == nil or obj.isDeleted or (adapter and ((adapter.combine and adapter.combine.isDeleted) or (adapter.vehicle and adapter.vehicle.isDeleted))) then
            CP_UnloaderCaller.removeAdapter(obj)
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

    CP_UnloaderCaller.cleanupDeletedCombines()

    local currentVehicles = g_currentMission.vehicleSystem.vehicles
    if currentVehicles == nil then return end

    local currentTime = g_currentMission.time or 0
    local checkedVehicles = {}

    for _, vehicle in pairs(currentVehicles) do
        local combineObj, carrierObj = CP_UnloaderCaller.findCombineAndCarrier(vehicle)
        if combineObj ~= nil and not combineObj.isDeleted and not checkedVehicles[combineObj] then
            checkedVehicles[combineObj] = true
            local primeMover = carrierObj or vehicle
            checkedVehicles[primeMover] = true

            local isAI = (primeMover.getIsAIActive and primeMover:getIsAIActive()) or (combineObj.getIsAIActive and combineObj:getIsAIActive())
            local adapter = CP_UnloaderCaller.activeCombines[primeMover] or CP_UnloaderCaller.activeCombines[combineObj]

            if isAI or primeMover.isDeleted or combineObj.isDeleted then
                if adapter ~= nil then
                    CP_UnloaderCaller.removeAdapter(primeMover)
                    CP_UnloaderCaller.removeAdapter(combineObj)
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

                    if isEntered then
                        adapter.lastEnteredTime = currentTime
                    end

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
                        else
                            -- Track if pipe was opened and if actively discharging with this unloader
                            if pipeOpen then
                                adapter.pipeWasOpenedForUnload = true
                            end
                            if isDischarging then
                                adapter.wasDischargingWithUnloader = true
                            end

                            local unloaderState = unloaderStrategy.state
                            local states = unloaderStrategy.states
                            local isActivelyUnloading = states and (unloaderState == states.UNLOADING_MOVING_COMBINE or unloaderState == states.UNLOADING_STOPPED_COMBINE)
                            local timeSinceAssigned = currentTime - (adapter.assignedTime or currentTime)

                            -- Physical command to DISMISS:
                            -- For normal combines: Dismiss ONLY if unloader was actively unloading or pipe was previously open for unload,
                            -- and now player explicitly folded it (NEVER dismiss while en route or before pipe was ever opened!)
                            if not isChopper then
                                local shouldDismiss = false
                                if adapter.pipeWasOpenedForUnload and not pipeOpen and not isDischarging then
                                    if isActivelyUnloading or adapter.wasDischargingWithUnloader or timeSinceAssigned > 45000 then
                                        shouldDismiss = true
                                    end
                                end

                                if shouldDismiss then
                                    local name = (unloader.getName and unloader:getName()) or "Tractor"
                                    print(string.format("CP_PlayerUnload: Pipe folded by player after unloading, dismissing unloader '%s'", tostring(name)))
                                    if unloaderStrategy.releaseCombine then
                                        unloaderStrategy:releaseCombine()
                                    end
                                    if unloaderStrategy.startWaitingForSomethingToDo then
                                        unloaderStrategy:startWaitingForSomethingToDo()
                                    end
                                    adapter.assignedUnloader = nil
                                    adapter.lastDepartedTime = currentTime
                                    adapter.pipeCallEligible = false
                                    adapter.pipeWasOpenedForUnload = false
                                    adapter.wasDischargingWithUnloader = false
                                end
                            elseif isChopper and not isEntered and (currentTime - (adapter.lastEnteredTime or currentTime)) > 20000 then
                                local name = (unloader.getName and unloader:getName()) or "Tractor"
                                print(string.format("CP_PlayerUnload: Player left chopper, dismissing unloader '%s'", tostring(name)))
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
                    end

                    -- 2. Unloader Call Dispatcher:
                    if isEntered and not adapter.assignedUnloader then
                        local timeSinceDeparted = currentTime - (adapter.lastDepartedTime or 0)
                        local canCall = timeSinceDeparted > 8000
                        local isStopped = (primeMover.getLastSpeed and primeMover:getLastSpeed() < 0.5)

                        local shouldCall = false
                        if isChopper then
                            local isWorking = adapter:isProcessingFruit() or not isStopped
                            if CP_UnloaderCaller.autoCallEnabled and (isWorking or adapter.pipeCallEligible) and canCall then
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
    if combine == nil or combine.isDeleted or combine.rootNode == nil or (entityExists and not entityExists(combine.rootNode)) then return nil end
    local adapter = CP_UnloaderCaller.activeCombines[combine]
    local currentTime = (g_currentMission and g_currentMission.time) or 0
    local AIDriveStrategyUnloadCombine = CP_GetCpClass("AIDriveStrategyUnloadCombine")
    if AIDriveStrategyUnloadCombine == nil then
        print("CP_PlayerUnload: AIDriveStrategyUnloadCombine class could not be resolved from Courseplay environment!")
        return nil
    end

    local bestUnloader = nil
    local bestScore = -math.huge
    local cx, cy, cz = getWorldTranslation(combine.rootNode)
    if cx == nil then return nil end

    local vehicles = g_currentMission.vehicleSystem.vehicles
    for _, v in pairs(vehicles) do
        if v ~= combine and not v.isDeleted then
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
                    elseif strategy.state and strategy.states and (strategy.state == strategy.states.IDLE or strategy.state == strategy.states.WAITING_FOR_SOMETHING_TO_DO) then
                        isAvailable = true
                    end

                    if isAvailable then
                        local unloaderFill = (strategy.getFillLevelPercentage and strategy:getFillLevelPercentage()) or 0
                        if unloaderFill < 98 then
                            if v.rootNode and (entityExists == nil or entityExists(v.rootNode)) then
                                local vx, vy, vz = getWorldTranslation(v.rootNode)
                                if vx ~= nil and vz ~= nil then
                                    local dist = MathUtil.vector2Length(cx - vx, cz - vz)
                                    if dist <= CP_UnloaderCaller.maxSearchDistance then
                                        local isServingField = strategy.isServingPosition and strategy:isServingPosition(cx, cz, 30)
                                        local fieldBonus = isServingField and 5000 or 0
                                        local score = fieldBonus - dist - (unloaderFill * 5)

                                        print(string.format("CP_PlayerUnload: Candidate unloader '%s' at %.1f m (fill: %.1f%%, state: %s, servingField: %s, score: %.1f)",
                                            tostring(v:getName()), dist, unloaderFill, tostring(strategy.state), tostring(isServingField), score))
                                        if score > bestScore then
                                            bestScore = score
                                            bestUnloader = v
                                        end
                                    end
                                end
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

    local currentTime = (g_currentMission and g_currentMission.time) or 0
    local targetVehicle = adapter.vehicle or vehicle

    if adapter.assignedUnloader and type(adapter.assignedUnloader) == "table" then
        local currentUnloader = adapter.assignedUnloader
        local currentStrategy = (type(currentUnloader.getCpDriveStrategy) == "function") and currentUnloader:getCpDriveStrategy()
        local isFull = (currentStrategy and currentStrategy.getFillLevelPercentage and currentStrategy:getFillLevelPercentage() >= 98)

        if isFull then
            -- Assigned unloader is full; clear and find a fresh unloader
            adapter.assignedUnloader = nil
        elseif isManual then
            -- Player manually pressed call button: re-dispatch assigned unloader to current combine position!
            print(string.format("CP_PlayerUnload: Manual re-call for assigned unloader '%s'", tostring(currentUnloader:getName())))
            if currentStrategy and currentStrategy.call then
                local success = currentStrategy:call(targetVehicle, nil)
                if success then
                    adapter.assignedTime = currentTime
                    adapter.pipeWasOpenedForUnload = adapter:isPipeOpen()
                    adapter.wasDischargingWithUnloader = false
                    adapter.pipeCallEligible = false
                    local name = (currentUnloader.getName and currentUnloader:getName()) or "Tractor"
                    local template = (g_i18n and g_i18n:hasText("cp_player_unload_called") and g_i18n:getText("cp_player_unload_called")) or "Courseplay unloader '%s' has been called."
                    showNotification(string.format(template, name))
                    return true
                end
            end
            -- Call failed (e.g. unloader canceled job), clear and search again
            adapter.assignedUnloader = nil
        else
            -- Automatic check: verify unloader is still actively following/approaching
            if currentStrategy then
                local s = currentStrategy.state
                local states = currentStrategy.states
                if s == states.IDLE or s == states.WAITING_FOR_SOMETHING_TO_DO or currentStrategy.combineToUnload ~= targetVehicle then
                    -- Unloader lost the combine or went idle; re-target it to the combine!
                    currentStrategy:call(targetVehicle, nil)
                    return true
                end
            end
            return true
        end
    end

    local unloader = CP_UnloaderCaller.findBestUnloader(targetVehicle)
    if unloader == nil then
        if isManual then
            local text = (g_i18n and g_i18n:hasText("cp_player_unload_no_unloader") and g_i18n:getText("cp_player_unload_no_unloader")) or "No idle Courseplay unloader found in range."
            showNotification(text)
        end
        return false
    end

    local strategy = (type(unloader.getCpDriveStrategy) == "function") and unloader:getCpDriveStrategy()
    if strategy == nil then return false end

    local combineName = (adapter.combine and adapter.combine.getName and adapter.combine:getName()) or tostring(targetVehicle:getName())
    print(string.format("CP_PlayerUnload: Calling unloader '%s' for combine '%s' (carrier: '%s', speed: %.1f km/h, chopper: %s)",
        tostring(unloader:getName()), tostring(combineName), tostring(targetVehicle:getName()), targetVehicle:getLastSpeed(), tostring(adapter:isChopper())))

    -- For choppers, pre-calculate the side offset before Courseplay plans pathfinding,
    -- ensuring pathfinding aims at the lateral clearance position instead of center (x=0)
    if adapter:isChopper() and strategy.calculateAutoAimPipeOffsetX then
        strategy:calculateAutoAimPipeOffsetX(targetVehicle)
    end

    -- ALWAYS call with nil as waypoint for player combines!
    -- This ensures Courseplay's pathfinder routes directly behind the combine (xOffset = pipeOffset, zOffset = -backDistance - 5)
    -- and NEVER drives in front of the combine header!
    local success = strategy:call(targetVehicle, nil)
    print(string.format("CP_PlayerUnload: strategy:call returned: %s", tostring(success)))

    if success then
        adapter.assignedUnloader = unloader
        adapter.assignedTime = currentTime
        adapter.pipeWasOpenedForUnload = adapter:isPipeOpen()
        adapter.wasDischargingWithUnloader = false
        adapter.pipeCallEligible = false
        local name = (unloader.getName and unloader:getName()) or "Tractor"
        local template = (g_i18n and g_i18n:hasText("cp_player_unload_called") and g_i18n:getText("cp_player_unload_called")) or "Courseplay unloader '%s' has been called."
        local text = string.format(template, name)
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
