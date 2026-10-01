-- =============================================================
-- FS25_CourseplayPlayerUnload: CP_PlayerAdapter.lua
-- Author: exekx
-- Description: Virtual Courseplay Strategy Adapter for human player combines
-- =============================================================

CP_PlayerAdapter = {}
local CP_DATA_FIELDS = {
    assignedUnloader = true,
    unloaderToRendezvous = true,
    unloaderRendezvousWaypointIx = true,
    combine = true,
    vehicle = true,
    virtualCourse = true,
    isVirtualCpStrategy = true,
    remainingTime = true
}

CP_PlayerAdapter_mt = {
    __index = function(t, key)
        local val = CP_PlayerAdapter[key]
        if val ~= nil then
            return val
        end
        -- If this is a data field, return nil
        if CP_DATA_FIELDS[key] then
            return nil
        end
        if key == "getAttachedImplements" then
            return function() return {} end
        end
        -- Safe fallback for any unexpected Courseplay method calls
        if type(key) == "string" and (
            key:sub(1, 2) == "is" or
            key:sub(1, 3) == "get" or
            key:sub(1, 3) == "has" or
            key:sub(1, 4) == "will" or
            key:sub(1, 3) == "can" or
            key:sub(1, 7) == "request" or
            key:sub(1, 2) == "on" or
            key:sub(1, 6) == "should"
        ) then
            return function(...) return false end
        end
        return nil
    end
}

function CP_PlayerAdapter:getAttachedImplements()
    if self.combine and self.combine.getAttachedImplements then
        return self.combine:getAttachedImplements() or {}
    end
    return {}
end

function CP_PlayerAdapter.getDirectionNode(v)
    if v == nil then return nil end
    if v.aiDirectionNode ~= nil and v.aiDirectionNode ~= 0 then
        return v.aiDirectionNode
    end
    if v.spec_aiVehicle and v.spec_aiVehicle.aiDirectionNode and v.spec_aiVehicle.aiDirectionNode ~= 0 then
        return v.spec_aiVehicle.aiDirectionNode
    end
    if v.spec_aiImplement and v.spec_aiImplement.aiDirectionNode and v.spec_aiImplement.aiDirectionNode ~= 0 then
        return v.spec_aiImplement.aiDirectionNode
    end
    if v.components and v.components[1] and v.components[1].node and v.components[1].node ~= 0 then
        return v.components[1].node
    end
    if v.rootNode ~= nil and v.rootNode ~= 0 then
        return v.rootNode
    end
    return nil
end

function CP_PlayerAdapter.getWorkingDirectionNode(combine, vehicle)
    -- 1. Check attached cutter (header) first - 100% points in field working direction!
    local c = combine or vehicle
    if c then
        local spec = c.spec_combine
        if spec and spec.attachedCutters then
            for cutter, _ in pairs(spec.attachedCutters) do
                local node = cutter.aiDirectionNode
                    or (cutter.components and cutter.components[1] and cutter.components[1].node)
                    or cutter.rootNode
                if node and node ~= 0 then
                    return node
                end
            end
        end
        if c.getAttachedImplements then
            for _, impl in pairs(c:getAttachedImplements()) do
                local obj = impl.object
                if obj and (obj.spec_cutter or (obj.typeName and obj.typeName:find("cutter"))) then
                    local node = obj.aiDirectionNode
                        or (obj.components and obj.components[1] and obj.components[1].node)
                        or obj.rootNode
                    if node and node ~= 0 then
                        return node
                    end
                end
            end
        end
    end

    -- 2. If modular combine (e.g. NexCo mounted on NEXAT carrier):
    -- The combine implement itself (NexCo) faces forward into the field, unlike the carrier chassis
    if combine and vehicle and combine ~= vehicle then
        local node = combine.aiDirectionNode
            or (combine.components and combine.components[1] and combine.components[1].node)
            or combine.rootNode
        if node and node ~= 0 then
            return node
        end
    end

    -- 3. Combine direction node
    if combine then
        local node = combine.aiDirectionNode
            or (combine.components and combine.components[1] and combine.components[1].node)
            or combine.rootNode
        if node and node ~= 0 then
            return node
        end
    end

    -- 4. Prime mover / vehicle fallback
    if vehicle then
        return CP_PlayerAdapter.getDirectionNode(vehicle)
    end
    return nil
end

function CP_PlayerAdapter.new(combine, primeMover)
    local self = setmetatable({}, CP_PlayerAdapter_mt)
    self.combine = combine
    self.vehicle = primeMover or combine
    self.isChopperVehicle = CP_PlayerAdapter.checkIsChopper(combine)
    self.virtualCourse = CP_VirtualCourse.new(self.combine, self.vehicle)
    self.assignedUnloader = nil
    self.unloaderToRendezvous = nil
    self.unloaderRendezvousWaypointIx = 1
    self.isVirtualCpStrategy = true
    self.remainingTime = { getText = function() return "" end }
    self.lastPipeOpenState = false
    self.pipeCallEligible = false
    self.lastDepartedTime = 0
    self.isTurningState = false
    self.isReversingState = false
    self.turningUntilTime = 0
    self.lastHeading = nil
    self.turnDirection = 0
    return self
end

function CP_PlayerAdapter:update(dt)
    if self.virtualCourse then
        self.virtualCourse:update()
    end

    local pipeOpen = self:isPipeOpen()
    if pipeOpen and not self.lastPipeOpenState then
        -- Player just unfolded pipe -> mark as eligible for unloader call
        self.pipeCallEligible = true
    elseif not pipeOpen then
        self.pipeCallEligible = false
    end
    self.lastPipeOpenState = pipeOpen

    -- Dynamic turn and maneuver detection for player-driven combine / chopper
    local currentTime = (g_currentMission and g_currentMission.time) or 0
    local vehicle = self.combine or self.vehicle

    -- 1. Normalized steering angle (-1.0 full right, +1.0 full left)
    local steeringAngle = 0
    if vehicle then
        if vehicle.rotatedTime and vehicle.maxRotTime and vehicle.maxRotTime > 0 then
            if vehicle.rotatedTime >= 0 then
                steeringAngle = vehicle.rotatedTime / vehicle.maxRotTime
            elseif vehicle.minRotTime and vehicle.minRotTime < 0 then
                steeringAngle = -vehicle.rotatedTime / vehicle.minRotTime
            end
        elseif vehicle.getSteeringAngle then
            local maxA = vehicle.maxSteeringAngle or 0.6
            if maxA > 0 then
                steeringAngle = (vehicle:getSteeringAngle() or 0) / maxA
            end
        end
    end

    -- 2. Yaw rate / heading change calculation
    local headingRateDegPerSec = 0
    local dirNode = CP_PlayerAdapter.getWorkingDirectionNode(self.combine, self.vehicle)
    if dirNode and dirNode ~= 0 then
        local dx, _, dz = localDirectionToWorld(dirNode, 0, 0, 1)
        local curHeading = math.atan2(dx, dz)
        if self.lastHeading ~= nil and dt and dt > 0 then
            local diff = curHeading - self.lastHeading
            while diff > math.pi do diff = diff - 2 * math.pi end
            while diff < -math.pi do diff = diff + 2 * math.pi end
            headingRateDegPerSec = math.deg(math.abs(diff)) / (dt / 1000.0)
        end
        self.lastHeading = curHeading
    end

    -- 3. Check reversing
    local isReversing = false
    if vehicle then
        if vehicle.getDrivingDirection then
            isReversing = (vehicle:getDrivingDirection() < 0)
        end
        local AIUtil = CP_GetCpClass("AIUtil") or _G.AIUtil
        if not isReversing and AIUtil and AIUtil.isInReverseGear then
            isReversing = AIUtil.isInReverseGear(vehicle)
        end
    end

    -- 4. Evaluate turn state with hysteresis
    local absSteering = math.abs(steeringAngle)
    local isTurnTriggered = false
    if absSteering > 0.28 or headingRateDegPerSec > 10.0 or isReversing then
        isTurnTriggered = true
        self.turningUntilTime = currentTime + 1400
        if absSteering > 0.18 then
            self.turnDirection = (steeringAngle > 0) and 1 or -1
        end
    elseif currentTime < (self.turningUntilTime or 0) then
        if absSteering > 0.15 or headingRateDegPerSec > 5.0 or isReversing then
            self.turningUntilTime = currentTime + 800
            isTurnTriggered = true
        end
    end

    self.isTurningState = isTurnTriggered
    self.isReversingState = isReversing
end

function CP_PlayerAdapter:updateCpStatus(status)
    if status and status.setWaypointData then
        local numWps = 1
        local course = self:getFieldworkCourse()
        if course and course.getNumberOfWaypoints then
            numWps = course:getNumberOfWaypoints() or 1
        end
        status:setWaypointData(1, numWps, "")
    end
end

function CP_PlayerAdapter:registerUnloader(driver)
    if driver then
        self.assignedUnloader = driver.vehicle or driver
    end
end

function CP_PlayerAdapter:deregisterUnloader(driver, noEventSend)
    self:cancelRendezvous()
    self.assignedUnloader = nil
end

function CP_PlayerAdapter:getFieldworkCourse()
    if self.virtualCourse then
        return self.virtualCourse:getCourse()
    end
    return nil
end

function CP_PlayerAdapter:getClosestFieldworkWaypointIx()
    return 1
end

function CP_PlayerAdapter:getRendezvousWaypoint(distAhead)
    distAhead = distAhead or 30
    local course = self:getFieldworkCourse()
    if course == nil then return nil end
    local wpIx = math.max(1, math.min(50, math.floor(distAhead / 2.0) + 1))
    if type(course.getWaypoint) == "function" then
        return course:getWaypoint(wpIx)
    elseif course.waypoints then
        return course.waypoints[wpIx] or course.waypoints[1]
    end
    return nil
end

function CP_PlayerAdapter:getCurrentCourse()
    return self:getFieldworkCourse()
end

function CP_PlayerAdapter:getTurnCourse()
    return nil
end

function CP_PlayerAdapter:requestToIgnoreProximity(vehicle)
end

function CP_PlayerAdapter:isUnloadFinished()
    if self:isChopper() then
        return false
    end
    return self:getFillLevelPercentage() <= 0.1
end

function CP_PlayerAdapter:isWaitingForUnloadAfterCourseEnded()
    return false
end

function CP_PlayerAdapter:isFinishingRow()
    return false
end

function CP_PlayerAdapter:getTurnStartWpIx()
    return 1
end

function CP_PlayerAdapter:getFruitAtSides()
    -- Courseplay uses (fruitLeft + fruitRight) for thresholds in calculateAutoAimPipeOffsetX!
    -- Must return numbers (not booleans) to avoid arithmetic error in Lua.
    return 0, 0
end

function CP_PlayerAdapter:isFull(fillLevelFullPercentage)
    if self:isChopper() then
        return false
    end
    local pct = self:getFillLevelPercentage()
    return pct >= (fillLevelFullPercentage or 90)
end

function CP_PlayerAdapter:isUnloadingOnTheField(checkHeap)
    return false
end

function CP_PlayerAdapter:getFieldUnloadHeap()
    return nil
end

function CP_PlayerAdapter:canDischarge()
    return self:isDischarging() or self:isPipeOpen()
end

function CP_PlayerAdapter:canLoadTrailer(trailer)
    return true
end

function CP_PlayerAdapter:canUnloadWhileMovingAtWaypoint(ix)
    return true
end

function CP_PlayerAdapter:isPipeOnLeft()
    local ox, _ = self:getPipeOffset(0, 0)
    return ox > 0
end

function CP_PlayerAdapter:isPipeInFruit()
    return false
end

function CP_PlayerAdapter:isPipeInFruitAt(ix)
    return false
end

function CP_PlayerAdapter:isPipeInFruitAtWaypointNow()
    return false
end

function CP_PlayerAdapter:isAutoDriveWaitingForPipe()
    return false
end

function CP_PlayerAdapter:isChopperWaitingForUnloader()
    return false
end

function CP_PlayerAdapter:isFillableTrailerUnderPipe()
    local combine = self.combine
    if not combine then return false end

    -- 1. Direct check: can combine discharge to object right now?
    if combine.getCurrentDischargeNode and combine.getCanDischargeToObject then
        local dischargeNode = combine:getCurrentDischargeNode()
        if dischargeNode and combine:getCanDischargeToObject(dischargeNode) then
            return true
        end
    end

    -- 2. Check if trailer is targeted by discharge node
    local spec = combine.spec_dischargeable
    if spec and spec.currentDischargeNode and spec.currentDischargeNode.targetObject ~= nil then
        return true
    end

    -- 3. Check pipe raycast / autoAim target
    local pipeSpec = combine.spec_pipe
    if pipeSpec and pipeSpec.targetObject ~= nil then
        return true
    end

    return false
end

function CP_PlayerAdapter:isPipeOpenEnabled()
    return true
end

function CP_PlayerAdapter:isWillingToRendezvous()
    return true
end

function CP_PlayerAdapter:getProximitySensorWidth()
    return self:getWorkWidth()
end

function CP_PlayerAdapter:getStateAsString()
    return self:isChopper() and "PLAYER_CHOPPING" or "PLAYER_HARVESTING"
end

function CP_PlayerAdapter:getWorkingToolPositionsSetting()
    return nil
end

function CP_PlayerAdapter:getAllowReversePathfinding()
    return false
end

function CP_PlayerAdapter:getCanCutterBeTurnedOff()
    return false
end

function CP_PlayerAdapter:isAGoodTrailerInRange()
    return true
end

function CP_PlayerAdapter:isAnyWorkAreaProcessing()
    return self:isProcessingFruit()
end

function CP_PlayerAdapter:isFuelSaveAllowed()
    return false
end

function CP_PlayerAdapter:isProximitySlowDownEnabled()
    return false
end

function CP_PlayerAdapter:shouldHoldInTurnManeuver()
    return false
end

function CP_PlayerAdapter:shouldMakePocket()
    return false
end

function CP_PlayerAdapter:shouldPullBack()
    return false
end

function CP_PlayerAdapter:shouldStopForUnloading()
    return false
end

function CP_PlayerAdapter:shouldWaitAtEndOfRow()
    return false
end

function CP_PlayerAdapter:getMaxSpeed()
    if self.combine and self.combine.getLastSpeed then
        return math.max(self.combine:getLastSpeed(), 0)
    end
    return 0
end

function CP_PlayerAdapter:getClosestFieldworkWaypointIx()
    return 1
end

function CP_PlayerAdapter:getFillLevelPercentage()
    if self:isChopper() then
        return 0
    end
    local spec = self.combine.spec_combine
    if spec ~= nil then
        local fillUnitIndex = spec.fillUnitIndex or 1
        local fillLevel = self.combine:getFillUnitFillLevel(fillUnitIndex) or 0
        local capacity = self.combine:getFillUnitCapacity(fillUnitIndex) or 1
        if capacity > 0 and capacity < 10000000 then
            return (fillLevel / capacity) * 100
        end
    end
    if self.combine.getFillUnits then
        local fillUnits = self.combine:getFillUnits()
        if fillUnits then
            for _, unit in pairs(fillUnits) do
                if unit.capacity and unit.capacity > 0 and unit.capacity < 10000000 then
                    return ((unit.fillLevel or 0) / unit.capacity) * 100
                end
            end
        end
    end
    return 0
end

function CP_PlayerAdapter:getFillType()
    local spec = self.combine.spec_combine
    if spec ~= nil then
        local fillUnitIndex = spec.fillUnitIndex or 1
        local ft = self.combine:getFillUnitFillType(fillUnitIndex)
        if ft and ft ~= FillType.UNKNOWN then
            return ft
        end
    end
    if self.combine and self.combine.getCurrentDischargeNode and self.combine.getDischargeFillType then
        local dischargeNode = self.combine:getCurrentDischargeNode()
        if dischargeNode then
            local ft = self.combine:getDischargeFillType(dischargeNode)
            if ft and ft ~= FillType.UNKNOWN then
                return ft
            end
        end
    end
    return FillType.UNKNOWN
end

function CP_PlayerAdapter:getChassisWidth()
    local w = 3.8
    if self.vehicle and self.vehicle.size and self.vehicle.size.width then
        w = math.max(w, self.vehicle.size.width)
    end
    if self.combine and self.combine.size and self.combine.size.width then
        w = math.max(w, self.combine.size.width)
    end
    -- Clamp chassis width to realistic combine body bounds (max 4.5m) so cutter width never blows up pipe offset!
    return math.min(w, 4.5)
end

function CP_PlayerAdapter:getPipeOffset(additionalOffsetX, additionalOffsetZ)
    local pipeOffsetX = nil
    local pipeOffsetZ = 0.0

    -- For choppers (forage harvesters), dynamically check fruit to pick the side without crops
    if self:isChopper() then
        self:checkFruit()
        local side = 1.0
        if (self.fruitLeft or 0) > (self.fruitRight or 0) then
            side = -1.0 -- Fruit on left -> drive on right (-X in Giants coordinate system)
        end
        local defaultWidth = math.max(((self:getWorkWidth() or 6.0) / 2) + 2.5, 4.5)
        pipeOffsetX = side * defaultWidth
        return pipeOffsetX + (additionalOffsetX or 0), pipeOffsetZ + (additionalOffsetZ or 0), self:hasAutoAimPipe()
    end

    -- 1. Physical pipe discharge node measurement from pipe specification
    if self.combine then
        local dischargeNode = nil
        if self.combine.getPipeDischargeNodeIndex and self.combine.getDischargeNodeByIndex then
            local ix = self.combine:getPipeDischargeNodeIndex()
            if ix then
                dischargeNode = self.combine:getDischargeNodeByIndex(ix)
            end
        end
        if not dischargeNode and self.combine.getCurrentDischargeNode then
            dischargeNode = self.combine:getCurrentDischargeNode()
        end

        if dischargeNode and dischargeNode.node then
            local refNode = self:getPipeOffsetReferenceNode()
            local dx, _, dz = localToLocal(dischargeNode.node, refNode, 0, 0, 0)
            -- Only accept physical measurement if pipe is actually unfolded (dx > 3.0m)
            if math.abs(dx) > 3.0 then
                -- Track the maximum unfolded position to avoid using a half-unfolded state
                if self.maxMeasuredPipeOffsetX == nil or math.abs(dx) > math.abs(self.maxMeasuredPipeOffsetX) then
                    self.maxMeasuredPipeOffsetX = dx
                    self.maxMeasuredPipeOffsetZ = dz
                end
                pipeOffsetX = self.maxMeasuredPipeOffsetX
                pipeOffsetZ = self.maxMeasuredPipeOffsetZ or dz
            end
        end
    end

    -- 2. Check Courseplay vehicle settings if pre-calibrated by Courseplay
    if pipeOffsetX == nil and self.combine and self.combine.getCpSettings then
        local cpSettings = self.combine:getCpSettings()
        if cpSettings and cpSettings.pipeOffsetX and cpSettings.pipeOffsetZ then
            local valX = cpSettings.pipeOffsetX:getValue()
            local valZ = cpSettings.pipeOffsetZ:getValue()
            if valX and math.abs(valX) > 2.0 then
                pipeOffsetX = valX
                pipeOffsetZ = valZ or 0.0
            end
        end
    end

    -- 3. Calculate safe lateral clearance based on attached cutter / header width:
    local workWidth = self:getWorkWidth()
    local minSafeFromHeader = 7.5
    if workWidth and workWidth > 0 and not self:isAttachedHarvester() then
        -- Cutter extends (workWidth / 2) to each side.
        -- Standard unloader trailer/tractor width is ~3.0m - 3.4m (half-width ~1.6m).
        -- To give comfortable, safe clearance of ~0.5m - 0.8m between the cutter edge and unloader track:
        -- The unloader center line must be at least (workWidth / 2) + 2.1m!
        minSafeFromHeader = math.max(4.5, (workWidth / 2) + 2.1)
    end

    -- 4. Fallback defaults and comfortable clearance bounds:
    if pipeOffsetX == nil then
        if self:isAttachedHarvester() then
            pipeOffsetX = -6.8
        else
            pipeOffsetX = minSafeFromHeader
        end
        pipeOffsetZ = 0.0
    else
        -- Ensure comfortable clearance: unloader must NEVER drive dangerously close to the cutter or combine body!
        if pipeOffsetX > 0 then
            pipeOffsetX = math.max(pipeOffsetX, minSafeFromHeader)
        elseif pipeOffsetX < 0 then
            pipeOffsetX = math.min(pipeOffsetX, -minSafeFromHeader)
        end
    end

    return pipeOffsetX + (additionalOffsetX or 0), pipeOffsetZ + (additionalOffsetZ or 0), self:hasAutoAimPipe()
end

function CP_PlayerAdapter:getPipeOffsetFromCourse()
    local ox, oz = self:getPipeOffset(0, 0)
    return ox, oz
end

function CP_PlayerAdapter:getCombine()
    return self.combine
end

function CP_PlayerAdapter:getCombineToUnload()
    return self.combine
end

function CP_PlayerAdapter:isAttachedHarvester()
    return self.vehicle ~= self.combine
end

function CP_PlayerAdapter:getPipeController()
    return nil
end

function CP_PlayerAdapter.checkIsChopper(combine)
    if not combine then return false end
    local ImplementUtil = CP_GetCpClass("ImplementUtil") or _G.ImplementUtil
    if ImplementUtil and ImplementUtil.isChopper then
        return ImplementUtil.isChopper(combine) == true
    end
    local spec = combine.spec_combine
    if spec and spec.isForageHarvester then
        return true
    end
    if combine.typeName and (combine.typeName == "forageHarvester" or combine.typeName:find("forageHarvester") or combine.typeName:find("Chopper")) then
        return true
    end
    if combine.spec_forageHarvester ~= nil then
        return true
    end
    if combine.getFillUnitCapacity and spec and spec.fillUnitIndex then
        local cap = combine:getFillUnitCapacity(spec.fillUnitIndex)
        if cap and (cap > 10000000 or cap == math.huge) then
            return true
        end
    end
    return false
end

function CP_PlayerAdapter:isChopper()
    if self.isChopperVehicle ~= nil then
        return self.isChopperVehicle
    end
    self.isChopperVehicle = CP_PlayerAdapter.checkIsChopper(self.combine)
    return self.isChopperVehicle
end

function CP_PlayerAdapter:isDischarging()
    local combine = self.combine
    if not combine then return false end
    if combine.getDischargeState then
        local Dischargeable = _G.Dischargeable
        if Dischargeable and combine:getDischargeState() ~= Dischargeable.DISCHARGE_STATE_OFF then
            return true
        end
    end
    local spec = combine.spec_dischargeable
    if spec and (spec.isDischarging or (spec.currentDischargeState and spec.currentDischargeState ~= 0)) then
        return true
    end
    local pipeSpec = combine.spec_pipe
    if pipeSpec and pipeSpec.isDischarging then
        return true
    end
    return false
end

function CP_PlayerAdapter:isPipeMoving()
    local pipeSpec = self.combine.spec_pipe
    if pipeSpec and pipeSpec.isMoving ~= nil then
        return pipeSpec.isMoving
    end
    return false
end

function CP_PlayerAdapter:isPipeOpen()
    if self:isChopper() then
        return true
    end
    local pipeSpec = self.combine.spec_pipe
    if pipeSpec then
        if pipeSpec.unloadingStates and pipeSpec.currentState then
            if pipeSpec.unloadingStates[pipeSpec.currentState] == true then
                return true
            end
        end
        if pipeSpec.currentState ~= nil then
            return pipeSpec.currentState == 2
        elseif pipeSpec.targetState ~= nil then
            return pipeSpec.targetState == 2
        end
    end
    if self:isDischarging() then
        return true
    end
    return false
end

function CP_PlayerAdapter:willWaitForUnloadToFinish()
    if self:isChopper() then
        return false -- Choppers never wait for stationary unload! Always dynamic follow.
    end
    return self.combine:getLastSpeed() < 0.5
end

function CP_PlayerAdapter:isWaitingForUnload()
    -- Always false for player combine so unloader never aborts when player stops
    return false
end

function CP_PlayerAdapter:isReadyToUnload(ignoreFillLevel)
    return true
end

function CP_PlayerAdapter:isWaitingInPocket()
    return false
end

function CP_PlayerAdapter:isWaitingForUnloadAfterPulledBack()
    return false
end

function CP_PlayerAdapter:hasAutoAimPipe()
    -- Return true for forage harvesters so Courseplay uses its native chopper follow mode
    -- with fruit-side detection (avoiding crops), and false for grain combines (fixed pipe).
    return self:isChopper()
end

function CP_PlayerAdapter:isOnHeadland(n)
    return false
end

function CP_PlayerAdapter:isTurning()
    return self.isTurningState == true
end

function CP_PlayerAdapter:isTurningOnHeadland()
    return self.isTurningState == true
end

function CP_PlayerAdapter:isAboutToTurn()
    return self.isTurningState == true
end

function CP_PlayerAdapter:isTurningButNotEndingTurn()
    return self.isTurningState == true
end

function CP_PlayerAdapter:getTurnDirection()
    return self.turnDirection or 0
end

function CP_PlayerAdapter:isTurnForwardOnly()
    return false
end

function CP_PlayerAdapter:getTurnArea()
    return nil, 0
end

function CP_PlayerAdapter:isAboutToReturnFromPocket()
    return false
end

function CP_PlayerAdapter:isReversing()
    return self.isReversingState == true
end

function CP_PlayerAdapter:isManeuvering()
    return self.isTurningState == true
end

function CP_PlayerAdapter:isIdle()
    return false
end

function CP_PlayerAdapter:hold(ms)
end

function CP_PlayerAdapter:requestToMoveForward(vehicle)
end

function CP_PlayerAdapter:ignoreProximityObject(object, vehicle, moveForwards, hitTerrain)
    return false
end

function CP_PlayerAdapter:alwaysNeedsUnloader()
    if self:isChopper() then
        return true
    end
    local spec = self.combine.spec_combine
    if spec and spec.isForageHarvester then
        return true
    end
    if self.combine.getFillUnitCapacity and spec and spec.fillUnitIndex then
        local cap = self.combine:getFillUnitCapacity(spec.fillUnitIndex)
        if cap == nil or cap == 0 or cap > 10000000 or cap == math.huge then
            return true
        end
    end
    return false
end

function CP_PlayerAdapter:isProcessingFruit()
    local spec = self.combine.spec_combine
    if spec and spec.isChopperFilling then
        return true
    end
    if spec and spec.attachedCutters then
        for cutter, _ in pairs(spec.attachedCutters) do
            if cutter.getIsTurnedOn and cutter:getIsTurnedOn() then
                return true
            end
        end
    end
    return self.combine.getIsTurnedOn and self.combine:getIsTurnedOn()
end

function CP_PlayerAdapter:getWorkWidth()
    local width = nil
    local spec = self.combine.spec_combine
    if spec and spec.attachedCutters then
        for cutter, _ in pairs(spec.attachedCutters) do
            if cutter.spec_cutter and cutter.spec_cutter.cuttingWidth then
                width = math.max(width or 0, cutter.spec_cutter.cuttingWidth)
            end
        end
    end
    if width == nil and self.combine.getAttachedImplements then
        for _, impl in pairs(self.combine:getAttachedImplements()) do
            local obj = impl.object
            if obj and obj.spec_cutter and obj.spec_cutter.cuttingWidth then
                width = math.max(width or 0, obj.spec_cutter.cuttingWidth)
            end
        end
    end
    if width == nil then
        local AIUtil = CP_GetCpClass("AIUtil") or _G.AIUtil
        if AIUtil and AIUtil.getWidth then
            width = AIUtil.getWidth(self.combine)
        end
    end
    return width or 6.0
end

--- Checks both sides of the combine for crops to tell Courseplay which side is clear
function CP_PlayerAdapter:checkFruit()
    local dirNode = self:getPipeOffsetReferenceNode()
    local workWidth = self:getWorkWidth() or 6.0
    local PathfinderUtil = CP_GetCpClass("PathfinderUtil") or _G.PathfinderUtil

    if PathfinderUtil and PathfinderUtil.hasFruit then
        -- Check left (+workWidth in Giants local space)
        local xl, _, zl = localToWorld(dirNode, workWidth, 0, 0)
        local hasFruitLeft, fruitValLeft = PathfinderUtil.hasFruit(xl, zl, 2, 2)
        self.fruitLeft = (hasFruitLeft and (fruitValLeft or 100)) or 0

        -- Check right (-workWidth in Giants local space)
        local xr, _, zr = localToWorld(dirNode, -workWidth, 0, 0)
        local hasFruitRight, fruitValRight = PathfinderUtil.hasFruit(xr, zr, 2, 2)
        self.fruitRight = (hasFruitRight and (fruitValRight or 100)) or 0
    else
        self.fruitLeft = 0
        self.fruitRight = 0
    end
end

function CP_PlayerAdapter:getFruitAtSides()
    self:checkFruit()
    return self.fruitLeft or 0, self.fruitRight or 0
end

function CP_PlayerAdapter:getPipeOffsetReferenceNode()
    if self:isAttachedHarvester() and self.combine then
        local node = self.combine.aiDirectionNode
            or (self.combine.components and self.combine.components[1] and self.combine.components[1].node)
            or self.combine.rootNode
        if node and node ~= 0 then
            return node
        end
    end
    local node = CP_PlayerAdapter.getDirectionNode(self.vehicle or self.combine)
    if node and node ~= 0 then
        return node
    end
    return (self.combine and self.combine.rootNode) or (self.vehicle and self.vehicle.rootNode)
end

function CP_PlayerAdapter:getMeasuredBackDistance()
    local backDist = 8.0
    local c = self.combine or self.vehicle
    if c and c.size and c.size.length then
        local len = c.size.length
        local offset = (c.size.lengthOffset or 0)
        local dirOffset = 0
        local AIUtil = CP_GetCpClass("AIUtil") or _G.AIUtil
        if AIUtil and AIUtil.getDirectionNodeToRootNodeOffset then
            dirOffset = AIUtil.getDirectionNodeToRootNodeOffset(c) or 0
        end
        backDist = math.max(backDist, (len / 2) - offset + dirOffset)
    end
    return backDist
end

function CP_PlayerAdapter:getAreaToAvoid()
    return nil
end

function CP_PlayerAdapter:reconfirmRendezvous()
end

function CP_PlayerAdapter:cancelRendezvous()
    self.unloaderToRendezvous = nil
end

function CP_PlayerAdapter:onMissedRendezvous(unloader)
    self.unloaderToRendezvous = nil
end

function CP_PlayerAdapter:hasRendezvousWith(vehicle)
    return self.assignedUnloader == vehicle or self.unloaderToRendezvous == vehicle
end
