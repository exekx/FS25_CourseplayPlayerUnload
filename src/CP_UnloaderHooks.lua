-- =============================================================
-- FS25_CourseplayPlayerUnload: CP_UnloaderHooks.lua
-- Author: exekx
-- Description: Courseplay integration hooks & ActionEvents
-- =============================================================

CP_UnloaderHooks = {}
CP_UnloaderHooks.isInitialized = false

function CP_UnloaderHooks.init()
    if CP_UnloaderHooks.isInitialized then return end

    local AIDriveStrategyUnloadCombine = CP_GetCpClass("AIDriveStrategyUnloadCombine")
    local AIDriveStrategyCombineCourse = CP_GetCpClass("AIDriveStrategyCombineCourse")
    local CpAIWorker = CP_GetCpClass("CpAIWorker")
    local PipeController = CP_GetCpClass("PipeController")

    -- Check if Courseplay classes are available yet
    if AIDriveStrategyUnloadCombine == nil and AIDriveStrategyCombineCourse == nil then
        print("CP_PlayerUnload: Courseplay classes not ready yet for hooks, will retry...")
        return
    end

    CP_UnloaderHooks.isInitialized = true

    -- 1. Hook AIDriveStrategyUnloadCombine:hasToWaitForAssignedCombine
    -- Prevents unloader from stopping/waiting when serving a player combine
    if AIDriveStrategyUnloadCombine and AIDriveStrategyUnloadCombine.hasToWaitForAssignedCombine then
        AIDriveStrategyUnloadCombine.hasToWaitForAssignedCombine = Utils.overwrittenFunction(
            AIDriveStrategyUnloadCombine.hasToWaitForAssignedCombine,
            function(self, superFunc)
                if self.combineToUnload and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self.combineToUnload] ~= nil then
                    -- Target is a player combine with our active adapter; it is always valid!
                    return false
                end
                return superFunc(self)
            end
        )
        print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.hasToWaitForAssignedCombine")
    end

    -- 2. Hook AIDriveStrategyUnloadCombine:update
    -- Keeps unloader registered with our player combine adapter even though combine:getIsCpActive() is false
    if AIDriveStrategyUnloadCombine and AIDriveStrategyUnloadCombine.update then
        AIDriveStrategyUnloadCombine.update = Utils.prependedFunction(
            AIDriveStrategyUnloadCombine.update,
            function(self, dt)
                if self.combineToUnload and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self.combineToUnload] ~= nil then
                    local strategy = self.combineToUnload:getCpDriveStrategy()
                    if strategy and strategy.registerUnloader then
                        strategy:registerUnloader(self)
                    end
                end
            end
        )
        print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.update for player combine registration")
    end

    -- 3. Hook AIDriveStrategyUnloadCombine:releaseCombine
    -- Safely deregisters unloader when unloader departs
    if AIDriveStrategyUnloadCombine and AIDriveStrategyUnloadCombine.releaseCombine then
        AIDriveStrategyUnloadCombine.releaseCombine = Utils.prependedFunction(
            AIDriveStrategyUnloadCombine.releaseCombine,
            function(self)
                if self.combineToUnload and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self.combineToUnload] ~= nil then
                    local strategy = self.combineToUnload:getCpDriveStrategy()
                    if strategy and strategy.deregisterUnloader then
                        strategy:deregisterUnloader(self)
                    end
                    self.combineJustUnloaded = self.combineToUnload
                end
            end
        )
        print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.releaseCombine")
    end

    -- 3b. Hook AIDriveStrategyUnloadCombine:isBehindAndAlignedToCombine
    -- For player combines, allows extended chase distance (up to 120m) and wider angle tolerance (45 deg)
    -- so that if the player starts driving after calling the unloader, the tractor will chase and
    -- catch up instead of aborting to idle!
    if AIDriveStrategyUnloadCombine and AIDriveStrategyUnloadCombine.isBehindAndAlignedToCombine then
        AIDriveStrategyUnloadCombine.isBehindAndAlignedToCombine = Utils.overwrittenFunction(
            AIDriveStrategyUnloadCombine.isBehindAndAlignedToCombine,
            function(self, superFunc, debugEnabled)
                if self.combineToUnload and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self.combineToUnload] ~= nil then
                    local CpMathUtil = CP_GetCpClass("CpMathUtil") or _G.CpMathUtil
                    local hasAutoAimPipe = self.combineToUnload:getCpDriveStrategy():hasAutoAimPipe()
                    local dx, _, dz = localToLocal(self.vehicle.rootNode, self:getPipeOffsetReferenceNode(), 0, 0, 0)
                    local pipeOffset = self:getPipeOffset(self.combineToUnload)
                    if dz > (hasAutoAimPipe and -5 or 0) then
                        return false
                    end
                    if not hasAutoAimPipe and not self:isLinedUpWithPipe(dx, dz, pipeOffset, debugEnabled) then
                        return false
                    end
                    local d = MathUtil.vector2Length(dx, dz)
                    local dLimit = 120
                    if d > dLimit then
                        return false
                    end
                    local dirLimit = 45
                    if CpMathUtil and not CpMathUtil.isSameDirection(self.vehicle:getAIDirectionNode(), self.combineToUnload:getAIDirectionNode(), dirLimit) then
                        return false
                    end
                    return true
                end
                return superFunc(self, debugEnabled)
            end
        )
        print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.isBehindAndAlignedToCombine for player combines")
    end

    -- 3c. Hook AIDriveStrategyUnloadCombine:driveToCombine
    -- If player combine started moving while unloader was approaching, seamlessly transition
    -- to unloading / following the moving combine without waiting to hit the old stationary point!
    if AIDriveStrategyUnloadCombine and AIDriveStrategyUnloadCombine.driveToCombine then
        AIDriveStrategyUnloadCombine.driveToCombine = Utils.overwrittenFunction(
            AIDriveStrategyUnloadCombine.driveToCombine,
            function(self, superFunc)
                if self.combineToUnload and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self.combineToUnload] ~= nil then
                    self:checkForCombineProximity()
                    self:setFieldSpeed()
                    self.combineToUnload:getCpDriveStrategy():reconfirmRendezvous()

                    local combineSpeed = (self.combineToUnload.getLastSpeed and self.combineToUnload:getLastSpeed()) or 0
                    local distToLast = (self.course and self.course.getDistanceToLastWaypoint and self.course:getDistanceToLastWaypoint(self.course:getCurrentWaypointIx())) or 0
                    if (combineSpeed > 0.5 or distToLast < 25) and self:isOkToStartUnloadingCombine() then
                        self:startUnloadingCombine()
                        return
                    end
                    return
                end
                return superFunc(self)
            end
        )
        print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.driveToCombine for seamless moving transition")
    end

    -- 3d. Hook AIDriveStrategyUnloadCombine:onLastWaypointPassed
    -- If unloader reaches the old call position and combine has moved/turned, re-target combine
    -- instead of giving up and switching to IDLE!
    if AIDriveStrategyUnloadCombine and AIDriveStrategyUnloadCombine.onLastWaypointPassed then
        AIDriveStrategyUnloadCombine.onLastWaypointPassed = Utils.overwrittenFunction(
            AIDriveStrategyUnloadCombine.onLastWaypointPassed,
            function(self, superFunc)
                if self.state == self.states.DRIVING_TO_COMBINE and self.combineToUnload and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self.combineToUnload] ~= nil then
                    if self:isOkToStartUnloadingCombine() then
                        self:startUnloadingCombine()
                        return
                    else
                        print(string.format("CP_PlayerUnload: Waypoint reached, re-targeting active player combine '%s'", tostring(self.combineToUnload:getName())))
                        local xOffset, zOffset = self:getPipeOffset(self.combineToUnload)
                        zOffset = -self:getCombinesMeasuredBackDistance() - 5
                        self:setNewState(self.states.WAITING_FOR_PATHFINDER)
                        self:startPathfindingToWaitingCombine(xOffset, zOffset)
                        return
                    end
                end
                return superFunc(self)
            end
        )
        print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.onLastWaypointPassed for re-targeting")
    end

    -- 4. Hook AIDriveStrategyCombineCourse.isActiveCpCombine
    if AIDriveStrategyCombineCourse and AIDriveStrategyCombineCourse.isActiveCpCombine then
        AIDriveStrategyCombineCourse.isActiveCpCombine = Utils.overwrittenFunction(
            AIDriveStrategyCombineCourse.isActiveCpCombine,
            function(vehicle, superFunc)
                if vehicle and vehicle.spec_combine and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[vehicle] ~= nil then
                    return true
                end
                return superFunc(vehicle)
            end
        )
        print("CP_PlayerUnload: Hooked AIDriveStrategyCombineCourse.isActiveCpCombine")
    end

    -- 5. Hook CpAIWorker methods
    if CpAIWorker then
        if CpAIWorker.getCpDriveStrategy then
            CpAIWorker.getCpDriveStrategy = Utils.overwrittenFunction(
                CpAIWorker.getCpDriveStrategy,
                function(self, superFunc)
                    if self.spec_combine ~= nil and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self] ~= nil then
                        return CP_UnloaderCaller.activeCombines[self]
                    end
                    return superFunc(self)
                end
            )
            print("CP_PlayerUnload: Hooked CpAIWorker.getCpDriveStrategy")
        end
        if CpAIWorker.getIsCpDriveToFieldWorkActive then
            CpAIWorker.getIsCpDriveToFieldWorkActive = Utils.overwrittenFunction(
                CpAIWorker.getIsCpDriveToFieldWorkActive,
                function(self, superFunc)
                    local job = self.getJob and self:getJob()
                    if job == nil or job.currentTaskIndex == nil then
                        return false
                    end
                    return superFunc(self)
                end
            )
            print("CP_PlayerUnload: Hooked CpAIWorker.getIsCpDriveToFieldWorkActive")
        end
    end

    -- 6. Hook PipeController.moveDependedPipePart with safety guard
    if PipeController and PipeController.moveDependedPipePart then
        PipeController.moveDependedPipePart = Utils.overwrittenFunction(
            PipeController.moveDependedPipePart,
            function(self, superFunc, tool, dt)
                if not self.tempDependedNode or (entityExists and not entityExists(self.tempDependedNode)) then
                    return
                end
                if not tool or not tool.node or (entityExists and not entityExists(tool.node)) then
                    return
                end
                pcall(superFunc, self, tool, dt)
            end
        )
        print("CP_PlayerUnload: Hooked PipeController.moveDependedPipePart with safety guard")
    end

    -- 7. Hook Vehicle base class methods (global fallback)
    if Vehicle then
        if Vehicle.getCpDriveStrategy then
            Vehicle.getCpDriveStrategy = Utils.overwrittenFunction(
                Vehicle.getCpDriveStrategy,
                function(self, superFunc)
                    local s = superFunc(self)
                    if s ~= nil then return s end
                    if self.spec_combine ~= nil and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self] ~= nil then
                        return CP_UnloaderCaller.activeCombines[self]
                    end
                    return nil
                end
            )
        else
            Vehicle.getCpDriveStrategy = function(self)
                if self.spec_combine ~= nil and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self] ~= nil then
                    return CP_UnloaderCaller.activeCombines[self]
                end
                if self.spec_cpAIWorker ~= nil then
                    return self.spec_cpAIWorker.driveStrategy
                end
                return nil
            end
        end

        -- Provide safe fallback only if Vehicle.getIsCpActive doesn't exist (NEVER return true for player combine)
        if not Vehicle.getIsCpActive then
            Vehicle.getIsCpActive = function(self)
                if self.spec_cpAIWorker ~= nil then
                    return self.spec_cpAIWorker.isActive or false
                end
                return false
            end
        end

        if Vehicle.getIsCpDriveToFieldWorkActive then
            Vehicle.getIsCpDriveToFieldWorkActive = Utils.overwrittenFunction(
                Vehicle.getIsCpDriveToFieldWorkActive,
                function(self, superFunc)
                    local job = self.getJob and self:getJob()
                    if job == nil or job.currentTaskIndex == nil then
                        return false
                    end
                    return superFunc(self)
                end
            )
        else
            Vehicle.getIsCpDriveToFieldWorkActive = function(self)
                local job = self.getJob and self:getJob()
                if job == nil or job.currentTaskIndex == nil then
                    return false
                end
                local task = job:getTaskByIndex(job.currentTaskIndex)
                local CpAITaskDriveTo = CP_GetCpClass("CpAITaskDriveTo")
                return task and task.is_a and CpAITaskDriveTo and task:is_a(CpAITaskDriveTo) or false
            end
        end
        print("CP_PlayerUnload: Hooked Vehicle getCpDriveStrategy & getIsCpDriveToFieldWorkActive")
    end

    -- 8. Hook Vehicle & Combine onRegisterActionEvents for input bindings
    if Combine and Combine.onRegisterActionEvents then
        Combine.onRegisterActionEvents = Utils.appendedFunction(
            Combine.onRegisterActionEvents,
            CP_UnloaderHooks.onRegisterActionEvents
        )
    end
    if Vehicle and Vehicle.onRegisterActionEvents then
        Vehicle.onRegisterActionEvents = Utils.appendedFunction(
            Vehicle.onRegisterActionEvents,
            CP_UnloaderHooks.onRegisterActionEvents
        )
    end
    if g_vehicleTypeManager and g_vehicleTypeManager.vehicleTypes then
        for _, typeDef in pairs(g_vehicleTypeManager.vehicleTypes) do
            if SpecializationUtil.hasSpecialization(Combine, typeDef.specializations) then
                SpecializationUtil.registerEventListener(typeDef, "onRegisterActionEvents", CP_UnloaderHooks)
            end
        end
    end
    print("CP_PlayerUnload: Registered vehicle action events")

    -- 9. Explicitly protect rhm_Combine.isAiWorkerActive if FS25_RealisticHarvesting is loaded
    CP_UnloaderHooks.hookRhm()
end

function CP_UnloaderHooks.hookRhm()
    local rhmSpec = nil
    if type(rhm_Combine) == "table" and rhm_Combine.isAiWorkerActive then
        rhmSpec = rhm_Combine
    elseif g_specializationManager then
        local spec = g_specializationManager:getSpecializationByName("rhm_Combine")
            or g_specializationManager:getSpecializationByName("FS25_RealisticHarvesting.rhm_Combine")
        if spec and spec.className and type(spec.className) == "table" and spec.className.isAiWorkerActive then
            rhmSpec = spec.className
        elseif spec and type(spec) == "table" and spec.isAiWorkerActive then
            rhmSpec = spec
        end
    end

    if rhmSpec and not rhmSpec._cpPlayerUnloadHooked then
        rhmSpec._cpPlayerUnloadHooked = true
        rhmSpec.isAiWorkerActive = Utils.overwrittenFunction(
            rhmSpec.isAiWorkerActive,
            function(vehicle, superFunc)
                if vehicle and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[vehicle] ~= nil then
                    if vehicle.getIsAIActive and vehicle:getIsAIActive() then
                        return true
                    end
                    local job = vehicle.getJob and vehicle:getJob()
                    if job ~= nil then
                        return true
                    end
                    return false
                end
                return superFunc(vehicle)
            end
        )
        print("CP_PlayerUnload: Hooked rhm_Combine.isAiWorkerActive (Preserving human player control & independent launch)")
    end
end

function CP_UnloaderHooks.onRegisterActionEvents(vehicle, isActiveForInput, isActiveForInputIgnoreSelection)
    if not vehicle or not vehicle.spec_combine then
        return
    end

    if not vehicle.isClient then
        return
    end

    local canRegister = isActiveForInputIgnoreSelection
        or vehicle.isActiveForInputIgnoreSelectionIgnoreAI
        or (vehicle.getIsEntered and vehicle:getIsEntered())

    if not canRegister then
        return
    end

    vehicle._cpPlayerUnloadEvents = vehicle._cpPlayerUnloadEvents or {}
    vehicle:clearActionEventsTable(vehicle._cpPlayerUnloadEvents)

    if InputAction.CP_PLAYER_UNLOAD_CALL then
        local _, eventId = vehicle:addActionEvent(
            vehicle._cpPlayerUnloadEvents,
            InputAction.CP_PLAYER_UNLOAD_CALL,
            vehicle,
            function(v, ...)
                CP_UnloaderCaller.callBestUnloader(v, true)
            end,
            false, true, false, true, nil
        )
        if eventId then
            g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_HIGH)
            local txt = (g_i18n and g_i18n:hasText("input_CP_PLAYER_UNLOAD_CALL") and g_i18n:getText("input_CP_PLAYER_UNLOAD_CALL")) or "Call CP Unloader"
            g_inputBinding:setActionEventText(eventId, txt)
            g_inputBinding:setActionEventActive(eventId, true)
            g_inputBinding:setActionEventTextVisibility(eventId, true)
        end
    end

    if InputAction.CP_PLAYER_UNLOAD_TOGGLE then
        local _, eventId = vehicle:addActionEvent(
            vehicle._cpPlayerUnloadEvents,
            InputAction.CP_PLAYER_UNLOAD_TOGGLE,
            vehicle,
            function(v, ...)
                CP_UnloaderCaller.toggleAutoCall()
            end,
            false, true, false, true, nil
        )
        if eventId then
            g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_NORMAL)
            local txt = (g_i18n and g_i18n:hasText("input_CP_PLAYER_UNLOAD_TOGGLE") and g_i18n:getText("input_CP_PLAYER_UNLOAD_TOGGLE")) or "Toggle Auto-Call"
            g_inputBinding:setActionEventText(eventId, txt)
            g_inputBinding:setActionEventActive(eventId, true)
            g_inputBinding:setActionEventTextVisibility(eventId, true)
        end
    end
end
