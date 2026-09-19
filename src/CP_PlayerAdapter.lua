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

function CP_PlayerAdapter.new(combine)
    local self = setmetatable({}, CP_PlayerAdapter_mt)
    self.combine = combine
    self.vehicle = combine
    self.virtualCourse = CP_VirtualCourse.new(combine)
    self.assignedUnloader = nil
    self.unloaderToRendezvous = nil
    self.unloaderRendezvousWaypointIx = 1
    self.isVirtualCpStrategy = true
    self.remainingTime = { getText = function() return "" end }
    return self
end

function CP_PlayerAdapter:update(dt)
    if self.virtualCourse then
        self.virtualCourse:update()
    end
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

function CP_PlayerAdapter:getCurrentCourse()
    return self:getFieldworkCourse()
end

function CP_PlayerAdapter:getTurnCourse()
    return nil
end

function CP_PlayerAdapter:requestToIgnoreProximity(vehicle)
end

function CP_PlayerAdapter:isUnloadFinished()
    local pct = self:getFillLevelPercentage()
    -- Unload finished when grain tank is empty or pipe stopped discharging and fill level is below 90%
    return pct < 1.0 or (not self:isDischarging() and pct < 90)
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
    return false, false
end

function CP_PlayerAdapter:isFull(fillLevelFullPercentage)
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
    return self:isDischarging()
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
    return "PLAYER_HARVESTING"
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
    local spec = self.combine.spec_combine
    if spec ~= nil then
        local fillUnitIndex = spec.fillUnitIndex or 1
        local fillLevel = self.combine:getFillUnitFillLevel(fillUnitIndex) or 0
        local capacity = self.combine:getFillUnitCapacity(fillUnitIndex) or 1
        if capacity > 0 then
            return (fillLevel / capacity) * 100
        end
    end
    return 0
end

function CP_PlayerAdapter:getFillType()
    local spec = self.combine.spec_combine
    if spec ~= nil then
        local fillUnitIndex = spec.fillUnitIndex or 1
        return self.combine:getFillUnitFillType(fillUnitIndex) or FillType.UNKNOWN
    end
    return FillType.UNKNOWN
end

function CP_PlayerAdapter:getPipeOffset(additionalOffsetX, additionalOffsetZ)
    local pipeOffsetX = 5.5
    local pipeOffsetZ = 0.0

    -- 1. Check Courseplay vehicle settings if available
    if self.combine.getCpSettings and self.combine:getCpSettings().pipeOffsetX then
        local valX = self.combine:getCpSettings().pipeOffsetX:getValue()
        local valZ = self.combine:getCpSettings().pipeOffsetZ:getValue()
        if valX and math.abs(valX) > 1.0 then
            pipeOffsetX = valX
            pipeOffsetZ = valZ or 0.0
        end
    -- 2. Physical pipe discharge node measurement in combine reference frame
    elseif self.combine.getCurrentDischargeNode then
        local dischargeNode = self.combine:getCurrentDischargeNode()
        if dischargeNode and dischargeNode.node then
            local refNode = self:getPipeOffsetReferenceNode()
            local dx, _, dz = localToLocal(dischargeNode.node, refNode, 0, 0, 0)
            -- Only use physical coordinates if pipe is actually extended (dx > 3m from center)
            if math.abs(dx) > 3.0 then
                pipeOffsetX = dx
                pipeOffsetZ = dz
            end
        end
    end

    -- Guarantee valid numbers so localToLocal never fails
    pipeOffsetX = pipeOffsetX or 5.5
    pipeOffsetZ = pipeOffsetZ or 0.0

    return pipeOffsetX + (additionalOffsetX or 0), pipeOffsetZ + (additionalOffsetZ or 0), false
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
    return false
end

function CP_PlayerAdapter:getPipeController()
    return nil
end

function CP_PlayerAdapter:isChopper()
    local spec = self.combine.spec_combine
    return spec and spec.isForageHarvester or false
end

function CP_PlayerAdapter:isDischarging()
    if self.combine.getDischargeState then
        return self.combine:getDischargeState() ~= Dischargeable.DISCHARGE_STATE_OFF
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
    local pipeSpec = self.combine.spec_pipe
    if pipeSpec and pipeSpec.currentState ~= nil then
        return pipeSpec.currentState == 2
    end
    return false
end

function CP_PlayerAdapter:willWaitForUnloadToFinish()
    return self.combine:getLastSpeed() < 0.5
end

function CP_PlayerAdapter:isWaitingForUnload()
    return self.combine:getLastSpeed() < 0.5
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
    return false
end

function CP_PlayerAdapter:isOnHeadland(n)
    return false
end

function CP_PlayerAdapter:isTurning()
    if self.combine.rotatedTime then
        return math.abs(self.combine.rotatedTime) > 0.4
    end
    return false
end

function CP_PlayerAdapter:isTurningOnHeadland()
    return false
end

function CP_PlayerAdapter:isAboutToTurn()
    return false
end

function CP_PlayerAdapter:isTurningButNotEndingTurn()
    return false
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
    if self.combine.getDrivingDirection then
        return self.combine:getDrivingDirection() < 0
    end
    return false
end

function CP_PlayerAdapter:isManeuvering()
    return false
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
    local spec = self.combine.spec_combine
    if spec and spec.isForageHarvester then
        return true
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
    local width = 6.0
    local spec = self.combine.spec_combine
    if spec and spec.attachedCutters then
        for cutter, _ in pairs(spec.attachedCutters) do
            if cutter.spec_cutter and cutter.spec_cutter.cuttingWidth then
                width = math.max(width, cutter.spec_cutter.cuttingWidth)
            end
        end
    end
    return width
end

function CP_PlayerAdapter:getPipeOffsetReferenceNode()
    return self.combine:getAIDirectionNode() or self.combine.rootNode
end

function CP_PlayerAdapter:getMeasuredBackDistance()
    if self.combine.size and self.combine.size.length then
        return self.combine.size.length / 2
    end
    return 4.0
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
