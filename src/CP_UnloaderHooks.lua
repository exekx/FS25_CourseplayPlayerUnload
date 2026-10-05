-- =============================================================
-- FS25_CourseplayPlayerUnload: CP_UnloaderHooks.lua
-- Author: exekx
-- Description: Courseplay integration hooks & ActionEvents
-- =============================================================

-- Network event for multiplayer / dedicated server synchronization
CP_PlayerUnloadEvent = {}
local CP_PlayerUnloadEvent_mt = Class(CP_PlayerUnloadEvent, Event)
InitEventClass(CP_PlayerUnloadEvent, "CP_PlayerUnloadEvent")

function CP_PlayerUnloadEvent.emptyNew()
    local self = Event.new(CP_PlayerUnloadEvent_mt)
    return self
end

function CP_PlayerUnloadEvent.new(vehicle, isToggle)
    local self = CP_PlayerUnloadEvent.emptyNew()
    self.vehicle = vehicle
    self.isToggle = isToggle or false
    return self
end

function CP_PlayerUnloadEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.isToggle = streamReadBool(streamId)
    self:run(connection)
end

function CP_PlayerUnloadEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteBool(streamId, self.isToggle)
end

function CP_PlayerUnloadEvent:run(connection)
    if self.vehicle ~= nil then
        if self.isToggle then
            CP_UnloaderCaller.toggleAutoCall()
        else
            CP_UnloaderCaller.callBestUnloader(self.vehicle, true)
        end
    end
end

CP_UnloaderHooks = {}
CP_UnloaderHooks.isInitialized = false

function CP_UnloaderHooks.init()
    if CP_UnloaderHooks.isInitialized then return end

    local AIDriveStrategyUnloadCombine = CP_GetCpClass("AIDriveStrategyUnloadCombine")
    local AIDriveStrategyCombineCourse = CP_GetCpClass("AIDriveStrategyCombineCourse")
    local CpAIWorker = CP_GetCpClass("CpAIWorker")
    local PipeController = CP_GetCpClass("PipeController")
    local CollisionAvoidanceController = CP_GetCpClass("CollisionAvoidanceController")
    local ProximityController = CP_GetCpClass("ProximityController")

    -- Check if Courseplay classes are available yet
    if AIDriveStrategyUnloadCombine == nil and AIDriveStrategyCombineCourse == nil then
        print("CP_PlayerUnload: Courseplay classes not ready yet for hooks, will retry...")
        return
    end

    CP_UnloaderHooks.isInitialized = true

    if CP_ApplyEngineGuards then
        CP_ApplyEngineGuards()
    end

    -- Hook Courseplay Markers & AIUtil to protect against nil vehicle crash
    local Markers = CP_GetCpClass("Markers") or _G.Markers
    if Markers then
        if Markers.getBackMarkerNode then
            Markers.getBackMarkerNode = Utils.overwrittenFunction(
                Markers.getBackMarkerNode,
                function(vehicle, superFunc, ...)
                    if vehicle == nil or type(vehicle) ~= "table" then
                        return nil
                    end
                    return superFunc(vehicle, ...)
                end
            )
        end
        if Markers.getFrontMarkerNode then
            Markers.getFrontMarkerNode = Utils.overwrittenFunction(
                Markers.getFrontMarkerNode,
                function(vehicle, superFunc, ...)
                    if vehicle == nil or type(vehicle) ~= "table" then
                        return nil
                    end
                    return superFunc(vehicle, ...)
                end
            )
        end
        print("CP_PlayerUnload: Hooked Markers with nil vehicle safety guards")
    end

    local AIUtil = CP_GetCpClass("AIUtil") or _G.AIUtil
    if AIUtil and AIUtil.getReverserNode then
        AIUtil.getReverserNode = Utils.overwrittenFunction(
            AIUtil.getReverserNode,
            function(vehicle, superFunc, ...)
                if vehicle == nil or type(vehicle) ~= "table" then
                    return nil, "vehicle is nil"
                end
                return superFunc(vehicle, ...)
            end
        )
        print("CP_PlayerUnload: Hooked AIUtil.getReverserNode with nil vehicle safety guard")
    end

    if AIDriveStrategyUnloadCombine and AIDriveStrategyUnloadCombine.getDistanceFromCombine then
        AIDriveStrategyUnloadCombine.getDistanceFromCombine = Utils.overwrittenFunction(
            AIDriveStrategyUnloadCombine.getDistanceFromCombine,
            function(self, superFunc, combine)
                local targetCombine = combine or self.combineToUnload
                if targetCombine == nil or self.vehicle == nil then
                    return 9999, 9999, 9999
                end
                local backNode = Markers and Markers.getBackMarkerNode and Markers.getBackMarkerNode(targetCombine)
                local frontNode = Markers and Markers.getFrontMarkerNode and Markers.getFrontMarkerNode(self.vehicle)
                if backNode and frontNode and backNode ~= 0 and frontNode ~= 0 then
                    local dx, _, dz = localToLocal(backNode, frontNode, 0, 0, 0)
                    return MathUtil.vector2Length(dx, dz), dx, dz
                end
                return 9999, 9999, 9999
            end
        )
        print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.getDistanceFromCombine with nil safety guard")
    end

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
                if not self or not self.combineToUnload then return end
                if not CP_UnloaderCaller or not CP_UnloaderCaller.activeCombines then return end
                if CP_UnloaderCaller.activeCombines[self.combineToUnload] == nil then return end
                local ok, err = pcall(function()
                    local strategy = self.combineToUnload:getCpDriveStrategy()
                    if strategy and strategy.registerUnloader then
                        strategy:registerUnloader(self)
                    end

                    -- Prevent PPC from shutting down Courseplay with "Left the course, stopped"
                    -- Human players don't follow static pre-recorded courses, so off-track cutouts must be disabled
                    if self.ppc then
                        if self.ppc.disableStopWhenOffTrack then
                            self.ppc:disableStopWhenOffTrack(60000)
                        end
                        if self.ppc.stopWhenOffTrack and not self.ppc._playerUnloadHooked then
                            self.ppc._playerUnloadHooked = true
                            local origGet = self.ppc.stopWhenOffTrack.get
                            self.ppc.stopWhenOffTrack.get = function(swot, ...)
                                if self.combineToUnload and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self.combineToUnload] ~= nil then
                                    return false
                                end
                                return origGet(swot, ...)
                            end
                        end
                    end

                    -- Dynamic forward course extension:
                    -- If we are following the combine and approaching the end of the current course waypoints,
                    -- seamlessly project a new forward course so PPC never runs out of track!
                    if self.state == self.states.UNLOADING_MOVING_COMBINE and self.followCourse then
                        local currentIx = (self.followCourse.getCurrentWaypointIx and self.followCourse:getCurrentWaypointIx()) or 1
                        local numWps = (self.followCourse.getNumberOfWaypoints and self.followCourse:getNumberOfWaypoints()) or 1
                        if (numWps - currentIx) < 15 then
                            local Course = CP_GetCpClass("Course")
                            if Course and Course.createStraightForwardCourse then
                                local offset = self.followingCourseOffset or (self.getFollowingCourseOffset and self:getFollowingCourseOffset(self.combineToUnload)) or 0
                                local refNode = self:getPipeOffsetReferenceNode()
                                self.followCourse = Course.createStraightForwardCourse(self.combineToUnload, 250, offset, refNode)
                                self:startCourse(self.followCourse, 1)
                            end
                        end
                    end
                end)
                if not ok then
                    -- Safely handle Courseplay state transitions
                end
            end
        )
        print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.update for player combine registration & PPC watchdog")
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
    -- Relaxed tolerances for curved field borders and player combines
    if AIDriveStrategyUnloadCombine and AIDriveStrategyUnloadCombine.isBehindAndAlignedToCombine then
        AIDriveStrategyUnloadCombine.isBehindAndAlignedToCombine = Utils.overwrittenFunction(
            AIDriveStrategyUnloadCombine.isBehindAndAlignedToCombine,
            function(self, superFunc, debugEnabled)
                if self.combineToUnload and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self.combineToUnload] ~= nil then
                    local strategy = self.combineToUnload:getCpDriveStrategy()
                    local hasAutoAim = strategy and strategy.hasAutoAimPipe and strategy:hasAutoAimPipe()
                    local CpMathUtil = CP_GetCpClass("CpMathUtil") or _G.CpMathUtil
                    local tNode = CP_PlayerAdapter.getDirectionNode(self.vehicle)
                    local cNode = self:getPipeOffsetReferenceNode() or CP_PlayerAdapter.getDirectionNode(self.combineToUnload)
                    local dx, _, dz = localToLocal(tNode, cNode, 0, 0, 0)
                    local pipeOffset = self:getPipeOffset(self.combineToUnload)
                    local d = MathUtil.vector2Length(dx, dz)
                    
                    if hasAutoAim then
                        -- For forage harvesters (choppers):
                        if dz > -2.0 then
                            return false
                        end
                        if d > 50 then
                            return false
                        end
                        if math.abs(dx - pipeOffset) > 5.0 then
                            return false
                        end
                    else
                        -- For grain combines:
                        -- Allows tractor pulling trailer to track smoothly alongside on curves without false drops
                        if dz > 15.0 then
                            return false
                        end
                        if d > 65 then
                            return false
                        end
                        if math.abs(dx - pipeOffset) > 6.0 then
                            return false
                        end
                    end

                    local dirLimit = 60
                    if CpMathUtil and not CpMathUtil.isSameDirection(tNode, cNode, dirLimit) then
                        return false
                    end
                    return true
                end
                return superFunc(self, debugEnabled)
            end
        )
        print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.isBehindAndAlignedToCombine for player combines")
    end

    -- 3b_2. Hook AIDriveStrategyUnloadCombine:isInFrontAndAlignedToMovingCombine
    -- Ensures unloader tracking alongside on curved swaths is never aborted by Courseplay
    if AIDriveStrategyUnloadCombine and AIDriveStrategyUnloadCombine.isInFrontAndAlignedToMovingCombine then
        AIDriveStrategyUnloadCombine.isInFrontAndAlignedToMovingCombine = Utils.overwrittenFunction(
            AIDriveStrategyUnloadCombine.isInFrontAndAlignedToMovingCombine,
            function(self, superFunc, debugEnabled)
                if self.combineToUnload and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self.combineToUnload] ~= nil then
                    local CpMathUtil = CP_GetCpClass("CpMathUtil") or _G.CpMathUtil
                    local tNode = CP_PlayerAdapter.getDirectionNode(self.vehicle)
                    local cNode = self:getPipeOffsetReferenceNode() or CP_PlayerAdapter.getDirectionNode(self.combineToUnload)
                    local dx, _, dz = localToLocal(tNode, cNode, 0, 0, 0)
                    local pipeOffset = self:getPipeOffset(self.combineToUnload)
                    if dz < -5.0 then
                        return false
                    end
                    local d = MathUtil.vector2Length(dx, dz)
                    if d > 65 then
                        return false
                    end
                    if math.abs(dx - pipeOffset) > 6.0 then
                        return false
                    end
                    local dirLimit = 60
                    if CpMathUtil and not CpMathUtil.isSameDirection(tNode, cNode, dirLimit) then
                        return false
                    end
                    return true
                end
                return superFunc(self, debugEnabled)
            end
        )
        print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.isInFrontAndAlignedToMovingCombine for player combines")
    end

    -- 3c. Hook AIDriveStrategyUnloadCombine:driveToCombine
    -- Only transitions to unloading when actually in close proximity (<30m) to avoid premature unloader loss
    if AIDriveStrategyUnloadCombine and AIDriveStrategyUnloadCombine.driveToCombine then
        AIDriveStrategyUnloadCombine.driveToCombine = Utils.overwrittenFunction(
            AIDriveStrategyUnloadCombine.driveToCombine,
            function(self, superFunc)
                if self.combineToUnload and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self.combineToUnload] ~= nil then
                    self:checkForCombineProximity()
                    self:setFieldSpeed()
                    self.combineToUnload:getCpDriveStrategy():reconfirmRendezvous()

                    local distToLast = (self.course and self.course.getDistanceToLastWaypoint and self.course:getDistanceToLastWaypoint(self.course:getCurrentWaypointIx())) or 0
                    local d = 9999
                    if self.vehicle and self.vehicle.rootNode and self.combineToUnload and self.combineToUnload.rootNode then
                        d = calcDistanceFrom(self.vehicle.rootNode, self.combineToUnload.rootNode)
                    end
                    if (d < 30 or distToLast < 20) and self:isOkToStartUnloadingCombine() then
                        self:startUnloadingCombine()
                        return
                    end
                    return
                end
                return superFunc(self)
            end
        )
        print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.driveToCombine for proximity-verified moving transition")
    end

    -- 3d. Hook AIDriveStrategyUnloadCombine:onLastWaypointPassed
    -- If unloader reaches the old call position and combine has moved/turned, re-target combine
    -- instead of giving up and switching to IDLE!
    if AIDriveStrategyUnloadCombine and AIDriveStrategyUnloadCombine.onLastWaypointPassed then
        AIDriveStrategyUnloadCombine.onLastWaypointPassed = Utils.overwrittenFunction(
            AIDriveStrategyUnloadCombine.onLastWaypointPassed,
            function(self, superFunc)
                if (self.state == self.states.DRIVING_TO_COMBINE or self.state == self.states.DRIVING_TO_MOVING_COMBINE)
                   and self.combineToUnload and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self.combineToUnload] ~= nil then
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

    -- 3d_2. Hook AIDriveStrategyUnloadCombine:startPathfindingToWaitingCombine
    -- Ensures the pathfinder ignores the combine, its carrier (NEXAT), and attached headers/cutters,
    -- allowing safe pathfinding to wide modular combines without false collision rejections.
    if AIDriveStrategyUnloadCombine and AIDriveStrategyUnloadCombine.startPathfindingToWaitingCombine then
        AIDriveStrategyUnloadCombine.startPathfindingToWaitingCombine = Utils.overwrittenFunction(
            AIDriveStrategyUnloadCombine.startPathfindingToWaitingCombine,
            function(self, superFunc, xOffset, zOffset)
                if self.combineToUnload and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self.combineToUnload] ~= nil then
                    local PathfinderContext = CP_GetCpClass("PathfinderContext") or _G.PathfinderContext
                    local CpFieldUtil = CP_GetCpClass("CpFieldUtil") or _G.CpFieldUtil
                    local PathfinderUtil = CP_GetCpClass("PathfinderUtil") or _G.PathfinderUtil

                    -- Ignore player combine, carrier, and all attached implements (e.g. 14m header, NexCo)
                    local ignoreVehicles = {}
                    local function addVeh(v)
                        if not v then return end
                        table.insert(ignoreVehicles, v)
                        if v.getAttachedImplements then
                            for _, impl in pairs(v:getAttachedImplements()) do
                                if impl.object then
                                    table.insert(ignoreVehicles, impl.object)
                                    if impl.object.getAttachedImplements then
                                        for _, subImpl in pairs(impl.object:getAttachedImplements()) do
                                            if subImpl.object then table.insert(ignoreVehicles, subImpl.object) end
                                        end
                                    end
                                end
                            end
                        end
                    end
                    addVeh(self.combineToUnload)
                    if self.combineToUnload.getRootVehicle then
                        addVeh(self.combineToUnload:getRootVehicle())
                    end
                    local strategy = self.combineToUnload:getCpDriveStrategy()
                    if strategy and strategy.hasAutoAimPipe and strategy:hasAutoAimPipe() then
                        if not xOffset or math.abs(xOffset) < 1.0 then
                            self:calculateAutoAimPipeOffsetX(self.combineToUnload)
                            xOffset = self:getAutoAimPipeOffsetX()
                        end
                        zOffset = -self:getCombinesMeasuredBackDistance() - 5
                    end

                    local context = PathfinderContext(self.vehicle)
                    local maxFruit = self:getMaxFruitPercent(self:getPipeOffsetReferenceNode(), xOffset, zOffset)
                    context:maxFruitPercent(maxFruit)
                    context:offFieldPenalty(self:getOffFieldPenalty(self.combineToUnload))
                    context:useFieldNum(CpFieldUtil and CpFieldUtil.getFieldNumUnderVehicle and CpFieldUtil.getFieldNumUnderVehicle(self.combineToUnload))
                    context:areaToAvoid(nil)
                    context:vehiclesToIgnore(ignoreVehicles)
                    local poly = (self.vehicle.cpGetFieldPolygon and self.vehicle:cpGetFieldPolygon())
                    local maxIter = (PathfinderUtil and PathfinderUtil.getMaxIterationsForFieldPolygon and PathfinderUtil.getMaxIterationsForFieldPolygon(poly)) or 5000
                    context:maxIterations(maxIter)

                    self.pathfinderController:registerListeners(self, self.onPathfindingDoneToWaitingCombine,
                            self.onPathfindingFailedToStationaryTarget, self.onPathfindingObstacleAtStart)
                    self.pathfinderController:findPathToNode(context, self:getPipeOffsetReferenceNode(), xOffset or 0, zOffset or 0, 3)
                    return
                end
                return superFunc(self, xOffset, zOffset)
            end
        )
        print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.startPathfindingToWaitingCombine")
    end

    -- 3d_3. Hook AIDriveStrategyUnloadCombine:onPathfindingFailedToStationaryTarget
    -- Prevents stopping/cancelling the Courseplay unloader job with "No path found" when serving player combines
    if AIDriveStrategyUnloadCombine and AIDriveStrategyUnloadCombine.onPathfindingFailedToStationaryTarget then
        AIDriveStrategyUnloadCombine.onPathfindingFailedToStationaryTarget = Utils.overwrittenFunction(
            AIDriveStrategyUnloadCombine.onPathfindingFailedToStationaryTarget,
            function(self, superFunc, ...)
                if self.combineToUnload and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self.combineToUnload] ~= nil then
                    print(string.format("CP_PlayerUnload: Pathfinding to player combine '%s' could not find clear path, holding and retrying...", tostring(self.combineToUnload:getName())))
                    if self.startWaitingForSomethingToDo then
                        self:startWaitingForSomethingToDo()
                    end
                    return
                end
                return superFunc(self, ...)
            end
        )
        print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.onPathfindingFailedToStationaryTarget")
    end

    -- 3e. Hook AIDriveStrategyUnloadCombine:driveBesideCombine
    -- Directly tracks combine and pipe position, handing over cleanly to Courseplay's PPC when close (dz <= 5)
    -- and smoothly matching speed whether moving or stationary.
    if AIDriveStrategyUnloadCombine and AIDriveStrategyUnloadCombine.driveBesideCombine then
        AIDriveStrategyUnloadCombine.driveBesideCombine = Utils.overwrittenFunction(
            AIDriveStrategyUnloadCombine.driveBesideCombine,
            function(self, superFunc)
                if self.combineToUnload and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self.combineToUnload] ~= nil then
                    local combine = self.combineToUnload
                    local strategy = combine:getCpDriveStrategy()
                    if strategy and strategy.hasAutoAimPipe and strategy:hasAutoAimPipe() then
                        return self:followChopper()
                    end
                    local CpMathUtil = CP_GetCpClass("CpMathUtil") or _G.CpMathUtil

                    -- 1. Measure trailer-to-pipe longitudinal distance (dz)
                    local dz = self:getBestTargetNodeDistanceFromPipe()
                    if dz == nil then
                        local tNode = CP_PlayerAdapter.getDirectionNode(self.vehicle)
                        local _, _, fallbackDz = localToLocal(tNode, self:getPipeOffsetReferenceNode(), 0, 0, 0)
                        dz = -fallbackDz - 4.0
                    end

                    -- 2. Speed matching:
                    local combineSpeed = (combine.getLastSpeed and combine:getLastSpeed()) or (combine.lastSpeedReal * 3600)
                    if combineSpeed < 0.5 then
                        combineSpeed = 0
                    end
                    local isDischarging = strategy and strategy.isDischarging and strategy:isDischarging()
                    local factor = isDischarging and 0.75 or 1.5
                    local speedDelta = (CpMathUtil and CpMathUtil.clamp(dz * factor, -10, 15)) or math.max(-10, math.min(15, dz * factor))
                    local speed = combineSpeed + speedDelta

                    if combineSpeed == 0 then
                        -- Combine is stopped: stop dead under the spout once dz <= 0.2m
                        if dz <= 0.2 then
                            speed = 0
                        elseif speed < 2 then
                            speed = 2
                        end
                    else
                        -- Combine is moving: keep moving with combine
                        if dz > 0 and speed < 2 then
                            speed = 2
                        end
                    end

                    if strategy and strategy.isPipeMoving and strategy:isPipeMoving() then
                        speed = math.min(speed, combineSpeed + 2)
                    end
                    self:setMaxSpeed(math.max(0, speed))

                    -- 3. Dynamic Curved Path Tracking & Turn Waiting:
                    local isTurning = false
                    if strategy and strategy.isTurning then
                        isTurning = strategy:isTurning()
                    end
                    if isTurning then
                        self:setMaxSpeed(0)
                        local tNode = CP_PlayerAdapter.getDirectionNode(self.vehicle)
                        local gx, gy, gz = localToWorld(tNode, 0, 0, 5)
                        return gx, gz
                    end

                    -- Always dynamically guide tractor along the combine's real-time heading and curved path!
                    local refNode = self:getPipeOffsetReferenceNode() or CP_PlayerAdapter.getWorkingDirectionNode(combine)
                    local pipeOffsetX, _ = self:getPipeOffset(combine)
                    local tNode = CP_PlayerAdapter.getDirectionNode(self.vehicle)
                    local _, _, dzTractor = localToLocal(tNode, refNode, 0, 0, 0)
                    local lookahead = (self.ppc and self.ppc.getLookaheadDistance and self.ppc:getLookaheadDistance()) or 7.5
                    local gx, gy, gz = localToWorld(refNode, pipeOffsetX, 0, dzTractor + lookahead)
                    return gx, gz
                end
                return superFunc(self)
            end
        )
        print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.driveBesideCombine for smooth tracking")
    end

    -- 3e_stopped_1. Hook AIDriveStrategyUnloadCombine:startUnloadingStoppedCombine
    -- For choppers: ensures a stopped chopper never launches a grain combine unload course
    -- directly towards the cab/pipe, but always follows dynamically in chopper mode.
    if AIDriveStrategyUnloadCombine and AIDriveStrategyUnloadCombine.startUnloadingStoppedCombine then
        AIDriveStrategyUnloadCombine.startUnloadingStoppedCombine = Utils.overwrittenFunction(
            AIDriveStrategyUnloadCombine.startUnloadingStoppedCombine,
            function(self, superFunc)
                if self.combineToUnload and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self.combineToUnload] ~= nil then
                    local strategy = self.combineToUnload:getCpDriveStrategy()
                    if strategy and strategy.hasAutoAimPipe and strategy:hasAutoAimPipe() then
                        self:startCourseFollowingCombine()
                        return
                    end
                end
                return superFunc(self)
            end
        )
        print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.startUnloadingStoppedCombine")
    end

    -- 3e_stopped_2. Hook AIDriveStrategyUnloadCombine:unloadStoppedCombine
    -- For choppers: redirects any stopped combine unload state directly to followChopper.
    if AIDriveStrategyUnloadCombine and AIDriveStrategyUnloadCombine.unloadStoppedCombine then
        AIDriveStrategyUnloadCombine.unloadStoppedCombine = Utils.overwrittenFunction(
            AIDriveStrategyUnloadCombine.unloadStoppedCombine,
            function(self, superFunc)
                if self.combineToUnload and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self.combineToUnload] ~= nil then
                    local strategy = self.combineToUnload:getCpDriveStrategy()
                    if strategy and strategy.hasAutoAimPipe and strategy:hasAutoAimPipe() then
                        self:setNewState(self.states.UNLOADING_MOVING_COMBINE)
                        return self:followChopper()
                    end
                end
                return superFunc(self)
            end
        )
        print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.unloadStoppedCombine")
    end

    -- 3e_2. Hook CollisionAvoidanceController:findPotentialCollisions
    -- Prevents unloader from stopping with a false collision warning against its own assigned player combine!
    if CollisionAvoidanceController and CollisionAvoidanceController.findPotentialCollisions then
        CollisionAvoidanceController.findPotentialCollisions = Utils.overwrittenFunction(
            CollisionAvoidanceController.findPotentialCollisions,
            function(self, superFunc)
                local ok, _ = pcall(function()
                    local CpMathUtil = CP_GetCpClass("CpMathUtil") or _G.CpMathUtil
                    for _, vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
                        local isAssignedCombine = false
                        if self.strategy and self.strategy.combineToUnload then
                            local target = self.strategy.combineToUnload
                            local targetRoot = (target.getRootVehicle and target:getRootVehicle()) or target
                            local vRoot = (vehicle.getRootVehicle and vehicle:getRootVehicle()) or vehicle
                            if vehicle == target or vRoot == targetRoot then
                                isAssignedCombine = true
                            end
                        end

                        if not isAssignedCombine and AIDriveStrategyCombineCourse.isActiveCpCombine(vehicle) then
                            local d = calcDistanceFrom(self.vehicle.rootNode, vehicle.rootNode)
                            if d < (self.range or 50) then
                                local myCourse = self.strategy and self.strategy.getCurrentCourse and self.strategy:getCurrentCourse()
                                local otherStrategy = vehicle.getCpDriveStrategy and vehicle:getCpDriveStrategy()
                                local otherCourse = otherStrategy and otherStrategy.getCurrentCourse and otherStrategy:getCurrentCourse()
                                if myCourse and otherCourse and myCourse.intersects then
                                    local myDistanceToCollision, otherDistanceToCollision = myCourse:intersects(otherCourse, self.lookahead or 25, true)
                                    if myDistanceToCollision and otherDistanceToCollision then
                                        local fieldSpeed = (self.strategy.getFieldSpeed and self.strategy:getFieldSpeed()) or 5.5
                                        if fieldSpeed <= 0.1 then fieldSpeed = 5.5 end
                                        local myEte = myDistanceToCollision / fieldSpeed
                                        local otherSpeed = (vehicle.lastSpeedReal and vehicle.lastSpeedReal * 1000) or 0
                                        local otherEte = 999999
                                        if otherSpeed > 0.05 then
                                            otherEte = otherDistanceToCollision / otherSpeed
                                        elseif CpMathUtil and CpMathUtil.divide then
                                            otherEte = CpMathUtil.divide(otherDistanceToCollision, otherSpeed)
                                        end

                                        if math.abs(myEte - otherEte) < (self.eteDiffThreshold or 8) then
                                            self.warningVehicle = vehicle
                                            self.warning:set(true, self.clearWarningDelayMs or 3000)
                                            return
                                        end
                                    end
                                end
                            end
                        end
                    end
                    if self.warningVehicle and not self.warning:get() then
                        self.warningVehicle = nil
                    end
                end)
            end
        )
        print("CP_PlayerUnload: Hooked CollisionAvoidanceController.findPotentialCollisions to ignore assigned combine")
    end

    -- 3e_3. Hook AIDriveStrategyUnloadCombine:ignoreProximityObject
    -- Ignores player combine and its wide attached implements (e.g. 15.2m cutter header) during approach & unloading
    if AIDriveStrategyUnloadCombine and AIDriveStrategyUnloadCombine.ignoreProximityObject then
        AIDriveStrategyUnloadCombine.ignoreProximityObject = Utils.overwrittenFunction(
            AIDriveStrategyUnloadCombine.ignoreProximityObject,
            function(self, superFunc, object, vehicle, moveForwards, hitTerrain)
                if self.combineToUnload and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self.combineToUnload] ~= nil then
                    local targetCombine = self.combineToUnload
                    local targetRoot = (targetCombine.getRootVehicle and targetCombine:getRootVehicle()) or targetCombine
                    local isTarget = false

                    if vehicle ~= nil then
                        local vRoot = (vehicle.getRootVehicle and vehicle:getRootVehicle()) or vehicle
                        if vehicle == targetCombine or vRoot == targetRoot then
                            isTarget = true
                        end
                    end
                    if not isTarget and object ~= nil then
                        if object == targetCombine or object == targetRoot then
                            isTarget = true
                        elseif object.getRootVehicle and object:getRootVehicle() == targetRoot then
                            isTarget = true
                        end
                    end

                    if isTarget then
                        if self.state == self.states.UNLOADING_MOVING_COMBINE or
                           self.state == self.states.UNLOADING_STOPPED_COMBINE or
                           self.state == self.states.DRIVING_TO_COMBINE or
                           self.state == self.states.DRIVING_TO_MOVING_COMBINE then
                            return true
                        end
                    end
                end
                return superFunc(self, object, vehicle, moveForwards, hitTerrain)
            end
        )
        print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.ignoreProximityObject for combine & cutter clearance")
    end

    -- 3e_4. Hook ProximityController:ignoreObject (ensures all sensor packs ignore player combine & header)
    if ProximityController and ProximityController.ignoreObject then
        ProximityController.ignoreObject = Utils.overwrittenFunction(
            ProximityController.ignoreObject,
            function(self, superFunc, object, vehicle, moveForwards, hitTerrain)
                if self.vehicle and self.vehicle.getCpDriveStrategy then
                    local strategy = self.vehicle:getCpDriveStrategy()
                    if strategy and strategy.combineToUnload and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[strategy.combineToUnload] ~= nil then
                        local targetCombine = strategy.combineToUnload
                        local targetRoot = (targetCombine.getRootVehicle and targetCombine:getRootVehicle()) or targetCombine
                        local isTarget = false

                        if vehicle ~= nil then
                            local vRoot = (vehicle.getRootVehicle and vehicle:getRootVehicle()) or vehicle
                            if vehicle == targetCombine or vRoot == targetRoot then
                                isTarget = true
                            end
                        end
                        if not isTarget and object ~= nil then
                            if object == targetCombine or object == targetRoot then
                                isTarget = true
                            elseif object.getRootVehicle and object:getRootVehicle() == targetRoot then
                                isTarget = true
                            end
                        end

                        if isTarget then
                            local s = strategy.state
                            if s == strategy.states.UNLOADING_MOVING_COMBINE or
                               s == strategy.states.UNLOADING_STOPPED_COMBINE or
                               s == strategy.states.DRIVING_TO_COMBINE or
                               s == strategy.states.DRIVING_TO_MOVING_COMBINE then
                                return true
                            end
                        end
                    end
                end
                return superFunc(self, object, vehicle, moveForwards, hitTerrain)
            end
        )
        print("CP_PlayerUnload: Hooked ProximityController.ignoreObject for combine & cutter clearance")
    end

    -- 3f. Hook AIDriveStrategyUnloadCombine:calculateAutoAimPipeOffsetX
    -- Courseplay's original calculateAutoAimPipeOffsetX uses the harvester's base chassis width (AIUtil.getWidth),
    -- which is only ~3.2m, completely ignoring the wide cutter/header (e.g. 7.5m Kemper).
    -- This hook ensures distanceBetweenVehicles takes the actual header cutting width into account,
    -- giving plenty of clearance so the unloader never hits the header!
    if AIDriveStrategyUnloadCombine and AIDriveStrategyUnloadCombine.calculateAutoAimPipeOffsetX then
        AIDriveStrategyUnloadCombine.calculateAutoAimPipeOffsetX = Utils.overwrittenFunction(
            AIDriveStrategyUnloadCombine.calculateAutoAimPipeOffsetX,
            function(self, superFunc, harvester)
                if harvester and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[harvester] ~= nil then
                    local strategy = harvester:getCpDriveStrategy()
                    if strategy and strategy.hasAutoAimPipe and strategy:hasAutoAimPipe() then
                        local fruitLeft, fruitRight = strategy:getFruitAtSides()
                        local AIUtil = CP_GetCpClass("AIUtil") or _G.AIUtil
                        local CpSlowChangingObject = CP_GetCpClass("CpSlowChangingObject") or _G.CpSlowChangingObject

                        local workWidth = (strategy.getWorkWidth and strategy:getWorkWidth()) or 6.0
                        local tractorWidth = (AIUtil and AIUtil.getWidth and AIUtil.getWidth(self.vehicle)) or 3.0
                        local harvesterChassisWidth = (AIUtil and AIUtil.getWidth and AIUtil.getWidth(harvester)) or 3.2

                        -- Calculate clearance: header half-width + tractor half-width + 1.2m safety margin
                        local distanceBetweenVehicles = math.max(
                            (workWidth + tractorWidth) / 2 + 1.2,
                            (harvesterChassisWidth + tractorWidth) / 2 + 1.8
                        )
                        if self.settings and self.settings.combineOffsetX then
                            local manualX = self.settings.combineOffsetX:getValue() or 0
                            distanceBetweenVehicles = distanceBetweenVehicles + math.abs(manualX)
                        end

                        local targetOffsetX = 0
                        local fruitThreshold = 0.2 * 0.5 * (fruitLeft + fruitRight)
                        if strategy.isOnHeadland and strategy:isOnHeadland(1) then
                            targetOffsetX = 0
                        elseif (fruitLeft > 3 or fruitRight > 3) and math.abs(fruitRight - fruitLeft) < fruitThreshold then
                            -- Substantial crops on both sides -> drive directly behind chopper
                            targetOffsetX = 0
                        elseif fruitLeft > fruitRight + 1.5 then
                            -- Significantly more fruit on left -> drive on clean right side (-X)
                            targetOffsetX = -distanceBetweenVehicles
                        elseif fruitRight > fruitLeft + 1.5 then
                            -- Significantly more fruit on right -> drive on clean left side (+X)
                            targetOffsetX = distanceBetweenVehicles
                        else
                            local manualX = (self.settings and self.settings.combineOffsetX and self.settings.combineOffsetX:getValue()) or 0
                            if math.abs(manualX) > 0.5 then
                                -- User explicitly configured combineOffsetX with a sign in Courseplay settings!
                                -- Positive manualX -> Left side (+X)
                                -- Negative manualX -> Right side (-X)
                                targetOffsetX = (manualX > 0) and distanceBetweenVehicles or -distanceBetweenVehicles
                            else
                                -- Default for windrows/swaths: Stay on whichever side the unloader is currently located relative to the harvester!
                                local hNode = CP_PlayerAdapter.getDirectionNode(harvester)
                                local dx, _, _ = localToLocal(self.vehicle.rootNode, hNode, 0, 0, 0)
                                if dx < 0 then
                                    targetOffsetX = -distanceBetweenVehicles
                                else
                                    targetOffsetX = distanceBetweenVehicles
                                end
                            end
                        end

                        if not self.autoAimPipeOffsetX then
                            if CpSlowChangingObject then
                                self.autoAimPipeOffsetX = CpSlowChangingObject(targetOffsetX, 0)
                            else
                                self.autoAimPipeOffsetX = {
                                    val = targetOffsetX,
                                    get = function(s) return s.val end,
                                    confirm = function(s, v) s.val = v end
                                }
                            end
                        else
                            if self.autoAimPipeOffsetX.confirm then
                                self.autoAimPipeOffsetX:confirm(targetOffsetX, 2000, 0.3)
                            end
                        end
                        return self:getAutoAimPipeOffsetX()
                    end
                end
                return superFunc(self, harvester)
            end
        )
        print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.calculateAutoAimPipeOffsetX for header clearance")
    end

    -- 3f_2. Hook AIDriveStrategyUnloadCombine:unloadMovingChopper
    -- Directs moving chopper unloading directly to our enhanced followChopper,
    -- preventing Courseplay from attempting AI waypoint turnaround courses for player combines.
    if AIDriveStrategyUnloadCombine and AIDriveStrategyUnloadCombine.unloadMovingChopper then
        AIDriveStrategyUnloadCombine.unloadMovingChopper = Utils.overwrittenFunction(
            AIDriveStrategyUnloadCombine.unloadMovingChopper,
            function(self, superFunc)
                if self.combineToUnload and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self.combineToUnload] ~= nil then
                    if self:changeToUnloadWhenTrailerFull() then
                        return
                    end
                    if self:isInDeadlock() then
                        self:startMovingBackFromCombine(self.states.MOVING_BACK, self.combineToUnload)
                        return
                    end
                    return self:followChopper()
                else
                    return superFunc(self)
                end
            end
        )
        print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.unloadMovingChopper")
    end

    -- 3g. Hook AIDriveStrategyUnloadCombine:followChopper
    -- Ensures the unloader stays ~5m behind chopper discharge point under the spout,
    -- stops cleanly during player combine turns, and smoothly follows the combine on swaths.
    if AIDriveStrategyUnloadCombine then
        if AIDriveStrategyUnloadCombine.followChopper then
            AIDriveStrategyUnloadCombine.followChopper = Utils.overwrittenFunction(
                AIDriveStrategyUnloadCombine.followChopper,
                function(self, superFunc)
                    if not self.combineToUnload then
                        return nil, nil
                    end
                    if CP_PlayerAdapter.isPlayerCombine(self.combineToUnload) then
                        local combineDirNode = CP_PlayerAdapter.getWorkingDirectionNode(self.combineToUnload) or CP_PlayerAdapter.getDirectionNode(self.combineToUnload)
                        local tractorDirNode = CP_PlayerAdapter.getDirectionNode(self.vehicle)
                        local Markers = CP_GetCpClass("Markers") or _G.Markers
                        local CpMathUtil = CP_GetCpClass("CpMathUtil") or _G.CpMathUtil

                        local frontNode = (Markers and Markers.getFrontMarkerNode and Markers.getFrontMarkerNode(self.vehicle)) or tractorDirNode
                        local dx, _, dz = localToLocal(frontNode, combineDirNode, 0, 0, 0)

                        local dFollowProxy = (self.followModeProximitySensor and self.followModeProximitySensor.getClosestObjectDistanceAndRootVehicle and self.followModeProximitySensor:getClosestObjectDistanceAndRootVehicle()) or 100
                        local dProxy = (self.proximityController and self.proximityController.checkBlockingVehicleFront and self.proximityController:checkBlockingVehicleFront()) or 100

                        local combineStrategy = self.combineToUnload:getCpDriveStrategy()
                        local isTurning = false
                        if combineStrategy and combineStrategy.isTurning then
                            isTurning = combineStrategy:isTurning()
                        end

                        if isTurning then
                            -- =========================================================================
                            -- COMBINE IS TURNING: GIVE FULL SPACE TO COMPLETE THE TURN!
                            -- The unloader STOPS in place at the end of the previous swath.
                            -- Wheels stay straight, zero collision risk, zero interference.
                            -- =========================================================================
                            self:setMaxSpeed(0)
                            local gx, gy, gz = localToWorld(tractorDirNode, 0, 0, 5)
                            return gx, gz
                        end

                        -- =========================================================================
                        -- NORMAL FOLLOWING & SWATH TRACKING (v1.1.3.0 Proven Dynamic Follow)
                        -- =========================================================================
                        local manualOffsetZ = (self.settings and self.settings.combineOffsetZ and self.settings.combineOffsetZ:getValue()) or 0
                        local targetZ = -5.0 + manualOffsetZ
                        local targetX = self:getAutoAimPipeOffsetX()

                        local sameDirection = (CpMathUtil and CpMathUtil.isSameDirection(tractorDirNode, combineDirNode, 45)) or false
                        local combineSpeed = (self.combineToUnload.getLastSpeed and self.combineToUnload:getLastSpeed()) or (self.combineToUnload.lastSpeedReal * 3600)

                        local speed
                        if sameDirection then
                            local dzError = -(dz - targetZ)
                            if math.abs(dx - targetX) > 1.5 then
                                -- Offset error is large, pull slightly back to clear the rear
                                dzError = dzError - 3.0
                            end
                            local targetDistBehind = self.targetDistanceBehindChopper or 10
                            local speedDelta = math.min(dzError, dFollowProxy - targetDistBehind, dProxy - targetDistBehind) * 2
                            speedDelta = (CpMathUtil and CpMathUtil.clamp(speedDelta, -10, 15)) or math.max(-10, math.min(15, speedDelta))
                            speed = combineSpeed + speedDelta
                        else
                            local targetDistBehind = self.targetDistanceBehindChopper or 10
                            local turnSpeed = (self.settings and self.settings.turnSpeed and self.settings.turnSpeed:getValue()) or 12
                            local speedDelta = math.min(dFollowProxy - targetDistBehind, dProxy - targetDistBehind) * 2
                            speed = (CpMathUtil and CpMathUtil.clamp(speedDelta, 0, turnSpeed)) or math.max(0, math.min(turnSpeed, speedDelta))
                        end

                        self:setMaxSpeed(math.max(0, speed))

                        local _, _, dzGoal = localToLocal(tractorDirNode, combineDirNode, 0, 0, 0)
                        local lookahead = (self.ppc and self.ppc.getLookaheadDistance and self.ppc:getLookaheadDistance()) or 8.0
                        local gx, gy, gz = localToWorld(combineDirNode, targetX, 0, dzGoal + lookahead)

                        return gx, gz
                    end
                    return superFunc(self)
                end
            )
            print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.followChopper for 5m rearward positioning & turn waiting")
        end

        -- Intercept startChopperTurn, handleChopper180Turn and handleChopperHeadlandTurn for player combines:
        -- Never transition to course-following turn states that deadlock without waypoints!
        if AIDriveStrategyUnloadCombine.startChopperTurn then
            AIDriveStrategyUnloadCombine.startChopperTurn = Utils.overwrittenFunction(
                AIDriveStrategyUnloadCombine.startChopperTurn,
                function(self, superFunc, combineStrategy)
                    if self.combineToUnload and CP_PlayerAdapter.isPlayerCombine(self.combineToUnload) then
                        return
                    end
                    return superFunc(self, combineStrategy)
                end
            )
            print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.startChopperTurn")
        end

        if AIDriveStrategyUnloadCombine.handleChopper180Turn then
            AIDriveStrategyUnloadCombine.handleChopper180Turn = Utils.overwrittenFunction(
                AIDriveStrategyUnloadCombine.handleChopper180Turn,
                function(self, superFunc, ...)
                    if self.combineToUnload and CP_PlayerAdapter.isPlayerCombine(self.combineToUnload) then
                        self:setNewState(self.states.UNLOADING_MOVING_COMBINE)
                        return self:followChopper()
                    end
                    return superFunc(self, ...)
                end
            )
            print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.handleChopper180Turn")
        end

        if AIDriveStrategyUnloadCombine.handleChopperHeadlandTurn then
            AIDriveStrategyUnloadCombine.handleChopperHeadlandTurn = Utils.overwrittenFunction(
                AIDriveStrategyUnloadCombine.handleChopperHeadlandTurn,
                function(self, superFunc, ...)
                    if self.combineToUnload and CP_PlayerAdapter.isPlayerCombine(self.combineToUnload) then
                        self:setNewState(self.states.UNLOADING_MOVING_COMBINE)
                        return self:followChopper()
                    end
                    return superFunc(self, ...)
                end
            )
            print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.handleChopperHeadlandTurn")
        end
    end

    -- 4. Hook AIDriveStrategyCombineCourse.isActiveCpCombine
    if AIDriveStrategyCombineCourse and AIDriveStrategyCombineCourse.isActiveCpCombine then
        AIDriveStrategyCombineCourse.isActiveCpCombine = Utils.overwrittenFunction(
            AIDriveStrategyCombineCourse.isActiveCpCombine,
            function(vehicle, superFunc)
                if vehicle and (vehicle.spec_combine or vehicle.spec_forageHarvester) and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[vehicle] ~= nil then
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
                    if CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self] ~= nil then
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
                    if CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self] ~= nil then
                        return CP_UnloaderCaller.activeCombines[self]
                    end
                    return nil
                end
            )
        else
            Vehicle.getCpDriveStrategy = function(self)
                if CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self] ~= nil then
                    return CP_UnloaderCaller.activeCombines[self]
                end
                if self.spec_cpAIWorker ~= nil then
                    return self.spec_cpAIWorker.driveStrategy
                end
                return nil
            end
        end

        -- Provide safe fallback only if Vehicle.getIsCpActive doesn't exist (NEVER return true for player combine)
        if not Vehicle.getAIDirectionNode then
            Vehicle.getAIDirectionNode = function(self)
                local adapter = CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self]
                if adapter and adapter.getPipeOffsetReferenceNode then
                    local n = adapter:getPipeOffsetReferenceNode()
                    if n and n ~= 0 then return n end
                end
                if self.aiDirectionNode ~= nil and self.aiDirectionNode ~= 0 then
                    return self.aiDirectionNode
                end
                if self.spec_aiVehicle and self.spec_aiVehicle.aiDirectionNode and self.spec_aiVehicle.aiDirectionNode ~= 0 then
                    return self.spec_aiVehicle.aiDirectionNode
                end
                if self.spec_aiImplement and self.spec_aiImplement.aiDirectionNode and self.spec_aiImplement.aiDirectionNode ~= 0 then
                    return self.spec_aiImplement.aiDirectionNode
                end
                if self.components and self.components[1] and self.components[1].node and self.components[1].node ~= 0 then
                    return self.components[1].node
                end
                return self.rootNode
            end
        end

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

    -- 8. Hook Vehicle & Harvesters onRegisterActionEvents for input bindings
    if Combine and Combine.onRegisterActionEvents then
        Combine.onRegisterActionEvents = Utils.appendedFunction(
            Combine.onRegisterActionEvents,
            CP_UnloaderHooks.onRegisterActionEvents
        )
    end
    if ForageHarvester and ForageHarvester.onRegisterActionEvents then
        ForageHarvester.onRegisterActionEvents = Utils.appendedFunction(
            ForageHarvester.onRegisterActionEvents,
            CP_UnloaderHooks.onRegisterActionEvents
        )
    end
    if Drivable and Drivable.onRegisterActionEvents then
        Drivable.onRegisterActionEvents = Utils.appendedFunction(
            Drivable.onRegisterActionEvents,
            CP_UnloaderHooks.onRegisterActionEvents
        )
    end
    if Enterable and Enterable.onRegisterActionEvents then
        Enterable.onRegisterActionEvents = Utils.appendedFunction(
            Enterable.onRegisterActionEvents,
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
            if SpecializationUtil.hasSpecialization(Combine, typeDef.specializations)
                or (ForageHarvester and SpecializationUtil.hasSpecialization(ForageHarvester, typeDef.specializations))
                or (Drivable and SpecializationUtil.hasSpecialization(Drivable, typeDef.specializations)) then
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
    if not vehicle or CP_UnloaderCaller == nil or CP_UnloaderCaller.findCombineAndCarrier == nil then
        return
    end

    local combineObj, _ = CP_UnloaderCaller.findCombineAndCarrier(vehicle)
    if combineObj == nil then
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
                if g_server ~= nil then
                    CP_UnloaderCaller.callBestUnloader(v, true)
                else
                    g_client:getServerConnection():sendEvent(CP_PlayerUnloadEvent.new(v, false))
                end
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
                if g_server ~= nil then
                    CP_UnloaderCaller.toggleAutoCall()
                else
                    g_client:getServerConnection():sendEvent(CP_PlayerUnloadEvent.new(v, true))
                end
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
