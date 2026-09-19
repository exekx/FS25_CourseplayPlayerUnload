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

    -- 5. Hook CpAIWorker specialization methods
    -- DO NOT hook CpAIWorker.getIsCpActive - player is NOT an AI worker!
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

    -- 8. Hook Vehicle.onRegisterActionEvents for input bindings
    Vehicle.onRegisterActionEvents = Utils.appendedFunction(
        Vehicle.onRegisterActionEvents,
        CP_UnloaderHooks.onRegisterActionEvents
    )
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
    if not vehicle.spec_combine then
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
            g_inputBinding:setActionEventText(eventId, g_i18n:getText("input_CP_PLAYER_UNLOAD_CALL") or "Call CP Unloader")
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
            g_inputBinding:setActionEventText(eventId, g_i18n:getText("input_CP_PLAYER_UNLOAD_TOGGLE") or "Toggle Auto-Call")
        end
    end
end