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
                                self.followCourse = Course.createStraightForwardCourse(self.combineToUnload, 250, offset)
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
    -- For player combines and choppers, tractor cab/rootNode is naturally ahead of trailer fill point (dz > 0),
    -- so allow dz up to 15m ahead alongside the combine, extended distance (120m) and wider angle tolerance (50 deg)
    -- so that the unloader never falsely aborts or cancels rendezvous!
    if AIDriveStrategyUnloadCombine and AIDriveStrategyUnloadCombine.isBehindAndAlignedToCombine then
        AIDriveStrategyUnloadCombine.isBehindAndAlignedToCombine = Utils.overwrittenFunction(
            AIDriveStrategyUnloadCombine.isBehindAndAlignedToCombine,
            function(self, superFunc, debugEnabled)
                if self.combineToUnload and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self.combineToUnload] ~= nil then
                    local CpMathUtil = CP_GetCpClass("CpMathUtil") or _G.CpMathUtil
                    local dx, _, dz = localToLocal(self.vehicle.rootNode, self:getPipeOffsetReferenceNode(), 0, 0, 0)
                    local pipeOffset = self:getPipeOffset(self.combineToUnload)
                    
                    -- Tractor pulling a trailer is naturally ahead of the trailer's fill point (dz > 0).
                    -- Only reject if tractor has sped way ahead (> 15m) of combine.
                    if dz > 15 then
                        return false
                    end
                    local tolerance = 1.0 + 0.5 * math.abs(dz)
                    if math.abs(dx - pipeOffset) > tolerance + 1.5 then
                        return false
                    end
                    local d = MathUtil.vector2Length(dx, dz)
                    local dLimit = 120
                    if d > dLimit then
                        return false
                    end
                    local dirLimit = 50
                    local tNode = CP_PlayerAdapter.getDirectionNode(self.vehicle)
                    local cNode = self:getPipeOffsetReferenceNode() or CP_PlayerAdapter.getDirectionNode(self.combineToUnload)
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
    -- Continuously calculates a smooth lookahead target point parallel to the human-driven combine,
    -- eliminating jerky speed oscillations, harsh brake stomping, and fighting with stale waypoints!
    if AIDriveStrategyUnloadCombine and AIDriveStrategyUnloadCombine.driveBesideCombine then
        AIDriveStrategyUnloadCombine.driveBesideCombine = Utils.overwrittenFunction(
            AIDriveStrategyUnloadCombine.driveBesideCombine,
            function(self, superFunc)
                if self.combineToUnload and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self.combineToUnload] ~= nil then
                    local combine = self.combineToUnload
                    local strategy = combine:getCpDriveStrategy()
                    local CpMathUtil = CP_GetCpClass("CpMathUtil") or _G.CpMathUtil

                    -- 1. Measure trailer-to-pipe longitudinal distance (dz)
                    local dz = self:getBestTargetNodeDistanceFromPipe()
                    if dz == nil then
                        local tNode = CP_PlayerAdapter.getDirectionNode(self.vehicle)
                        local _, _, fallbackDz = localToLocal(tNode, self:getPipeOffsetReferenceNode(), 0, 0, 0)
                        dz = -fallbackDz
                    end

                    -- 2. Smooth speed matching:
                    -- Use smoothed combine speed in km/h to prevent frame-to-frame physics micro-jitter
                    local combineSpeed = (combine.getLastSpeed and combine:getLastSpeed()) or (combine.lastSpeedReal * 3600)
                    local isDischarging = strategy and strategy.isDischarging and strategy:isDischarging()
                    local factor = isDischarging and 0.6 or 1.2
                    local isStoppedCombine = combineSpeed < 0.5

                    local targetSpeed
                    if isStoppedCombine then
                        -- When combine is stationary, stop once trailer is within +-0.8m of the pipe spout
                        if math.abs(dz) <= 0.8 then
                            targetSpeed = 0
                        elseif dz > 0.8 then
                            -- Creep forward into position under the spout
                            targetSpeed = math.min(6.0, math.max(2.0, dz * 0.8))
                        else
                            targetSpeed = 0
                        end
                    else
                        -- Moving combine: smooth speed delta clamped to [-6, 10] km/h
                        local speedDelta = (CpMathUtil and CpMathUtil.clamp(dz * factor, -6, 10)) or math.max(-6, math.min(10, dz * factor))
                        targetSpeed = combineSpeed + speedDelta
                        if dz > 0 and targetSpeed < 2 then
                            targetSpeed = 2
                        end
                        if strategy and strategy.isPipeMoving and strategy:isPipeMoving() then
                            targetSpeed = math.min(targetSpeed, combineSpeed + 2)
                        end
                    end
                    self:setMaxSpeed(math.max(0, targetSpeed))

                    -- 3. Continuous smooth lookahead steering point strictly parallel to combine:
                    -- Projects a lookahead goal point that smoothly converges towards pipeOffsetX
                    -- at a gentle slope (max 4.0 deg) and strictly clamps to NEVER steer towards the combine chassis!
                    local refNode = self:getPipeOffsetReferenceNode()
                    local pipeOffsetX, _ = self:getPipeOffset(combine)
                    local tNode = CP_PlayerAdapter.getDirectionNode(self.vehicle)
                    local xTractor, _, dzTractor = localToLocal(tNode, refNode, 0, 0, 0)
                    local lookahead = (self.ppc and self.ppc.getLookaheadDistance and self.ppc:getLookaheadDistance()) or 8.0

                    local dx = pipeOffsetX - xTractor
                    local maxLateralShift = lookahead * 0.07 -- max ~4.0 deg convergence angle
                    local lateralShift = math.max(-maxLateralShift, math.min(maxLateralShift, dx))
                    local targetX = xTractor + lateralShift

                    -- Absolute collision protection against combine chassis/wheels
                    local chassisWidth = (strategy and strategy.getChassisWidth and strategy:getChassisWidth()) or 4.0
                    local minSafeDistance = (chassisWidth / 2) + 1.8

                    if pipeOffsetX < 0 then
                        -- Unloader on right side: X is negative in Giants coordinates
                        -- Never steer closer to combine than pipeOffsetX or minSafeDistance
                        targetX = math.min(targetX, pipeOffsetX)
                        targetX = math.min(targetX, -minSafeDistance)
                    else
                        -- Unloader on left side: X is positive in Giants coordinates
                        -- Never steer closer to combine than pipeOffsetX or minSafeDistance
                        targetX = math.max(targetX, pipeOffsetX)
                        targetX = math.max(targetX, minSafeDistance)
                    end

                    local gx, gy, gz = localToWorld(refNode, targetX, 0, dzTractor + lookahead)
                    return gx, gz
                end
                return superFunc(self)
            end
        )
        print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.driveBesideCombine for smooth tracking")
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

                        -- Calculate clearance: header half-width + tractor half-width + 1.0m safety margin
                        local distanceBetweenVehicles = math.max(
                            (workWidth + tractorWidth) / 2 + 1.0,
                            (harvesterChassisWidth + tractorWidth) / 2 + 1.5
                        )
                        if self.settings and self.settings.combineOffsetX then
                            local manualX = self.settings.combineOffsetX:getValue() or 0
                            distanceBetweenVehicles = distanceBetweenVehicles + math.abs(manualX)
                        end

                        local targetOffsetX = 0
                        local fruitThreshold = 0.2 * 0.5 * (fruitLeft + fruitRight)
                        if strategy.isOnHeadland and strategy:isOnHeadland(1) then
                            targetOffsetX = 0
                        elseif math.abs(fruitRight - fruitLeft) < fruitThreshold and fruitLeft > 5 then
                            -- Substantial crops on both sides -> drive directly behind chopper
                            targetOffsetX = 0
                        elseif fruitLeft > fruitRight then
                            -- Significantly more fruit on left -> drive on clean right side (-X)
                            targetOffsetX = -distanceBetweenVehicles
                        else
                            -- Significantly more fruit on right -> drive on clean left side (+X)
                            targetOffsetX = distanceBetweenVehicles
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

    -- 3g. Hook AIDriveStrategyUnloadCombine:followChopper
    -- Shifts the unloader 5 meters further back alongside forage harvesters,
    -- positioning the trailer directly under the spout and safely away from the header.
    if AIDriveStrategyUnloadCombine and AIDriveStrategyUnloadCombine.followChopper then
        AIDriveStrategyUnloadCombine.followChopper = Utils.overwrittenFunction(
            AIDriveStrategyUnloadCombine.followChopper,
            function(self, superFunc)
                if self.combineToUnload and CP_UnloaderCaller and CP_UnloaderCaller.activeCombines and CP_UnloaderCaller.activeCombines[self.combineToUnload] ~= nil then
                    local combineDirNode = CP_PlayerAdapter.getDirectionNode(self.combineToUnload)
                    local tractorDirNode = CP_PlayerAdapter.getDirectionNode(self.vehicle)
                    local Markers = CP_GetCpClass("Markers") or _G.Markers
                    local CpMathUtil = CP_GetCpClass("CpMathUtil") or _G.CpMathUtil

                    local frontNode = (Markers and Markers.getFrontMarkerNode and Markers.getFrontMarkerNode(self.vehicle)) or tractorDirNode
                    local dx, _, dz = localToLocal(frontNode, combineDirNode, 0, 0, 0)

                    local dFollowProxy = (self.followModeProximitySensor and self.followModeProximitySensor.getClosestObjectDistanceAndRootVehicle and self.followModeProximitySensor:getClosestObjectDistanceAndRootVehicle()) or 100
                    local dProxy = (self.proximityController and self.proximityController.checkBlockingVehicleFront and self.proximityController:checkBlockingVehicleFront()) or 100

                    local manualOffsetZ = (self.settings and self.settings.combineOffsetZ and self.settings.combineOffsetZ:getValue()) or 0
                    -- Shift 5 meters rearward relative to combine cab, plus user-configurable offsetZ
                    local targetZ = -5.0 + manualOffsetZ

                    local speed
                    local sameDirection = (CpMathUtil and CpMathUtil.isSameDirection(tractorDirNode, combineDirNode, 45)) or true
                    local combineSpeed = (self.combineToUnload.getLastSpeed and self.combineToUnload:getLastSpeed()) or (self.combineToUnload.lastSpeedReal * 3600)

                    if sameDirection then
                        local dzError = -(dz - targetZ)
                        if math.abs(dx - self:getAutoAimPipeOffsetX()) > 1.5 then
                            -- Offset error is large, pull slightly back to clear the rear
                            dzError = dzError - 3.0
                        end
                        local targetDistBehind = self.targetDistanceBehindChopper or 10
                        local speedDelta = math.min(dzError, dFollowProxy - targetDistBehind, dProxy - targetDistBehind) * 2
                        speedDelta = (CpMathUtil and CpMathUtil.clamp(speedDelta, -10, 15)) or math.max(-10, math.min(15, speedDelta))
                        speed = combineSpeed + speedDelta
                    else
                        local targetDistBehind = self.targetDistanceBehindChopper or 10
                        local turnSpeed = (self.settings and self.settings.turnSpeed and self.settings.turnSpeed:getValue()) or 15
                        local speedDelta = math.min(dFollowProxy - targetDistBehind, dProxy - targetDistBehind) * 2
                        speed = (CpMathUtil and CpMathUtil.clamp(speedDelta, 0, turnSpeed)) or math.max(0, math.min(turnSpeed, speedDelta))
                    end

                    self:setMaxSpeed(math.max(0, speed))

                    local _, _, dzGoal = localToLocal(tractorDirNode, combineDirNode, 0, 0, 0)
                    local lookahead = (self.ppc and self.ppc.getLookaheadDistance and self.ppc:getLookaheadDistance()) or 8.0
                    local gx, gy, gz = localToWorld(combineDirNode, self:getAutoAimPipeOffsetX(), 0, dzGoal + lookahead)

                    return gx, gz
                end
                return superFunc(self)
            end
        )
        print("CP_PlayerUnload: Hooked AIDriveStrategyUnloadCombine.followChopper for 5m rearward positioning")
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
