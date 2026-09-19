-- =============================================================
-- FS25_CourseplayPlayerUnload: CP_VirtualCourse.lua
-- Author: exekx
-- Description: Generates a virtual forward course for human-driven combines
-- =============================================================

CP_VirtualCourse = {}
CP_VirtualCourse_mt = { __index = CP_VirtualCourse }

function CP_VirtualCourse.new(combine)
    local self = setmetatable({}, CP_VirtualCourse_mt)
    self.combine = combine
    self.course = nil
    self.lastUpdateTime = 0
    self.updateIntervalMs = 500 -- Advance virtual course twice a second
    self:update()
    return self
end

function CP_VirtualCourse:update()
    if self.combine == nil or self.combine.rootNode == nil then
        return nil
    end

    local currentTime = (g_currentMission and g_currentMission.time) or 0
    if self.course ~= nil and (currentTime - self.lastUpdateTime) < self.updateIntervalMs then
        return self.course
    end
    self.lastUpdateTime = currentTime

    local dirNode = self.combine:getAIDirectionNode() or self.combine.rootNode
    local _, yRot, _ = getWorldRotation(dirNode)
    local angleDeg = math.deg(yRot)
    local dx, dz = -math.sin(yRot), -math.cos(yRot)
    local Course = CP_GetCpClass("Course")

    -- Generate 50 points (100 meters) straight ahead in combine coordinate frame
    local rawWaypoints = {}
    for i = 0, 50 do
        local dist = i * 2.0
        local wx, wy, wz = localToWorld(dirNode, 0, 0, dist)
        table.insert(rawWaypoints, {
            x = wx,
            y = wy,
            z = wz,
            angle = angleDeg,
            yRot = yRot,
            dx = dx,
            dz = dz,
            rev = false,
            getIsReverse = function() return false end
        })
    end

    -- Attempt to instantiate official Courseplay Course object
    if Course ~= nil and type(Course) == "table" then
        local success, c = pcall(Course, self.combine, rawWaypoints, true)
        if success and c ~= nil and type(c.copy) == "function" then
            self.course = c
            return self.course
        end
    end

    -- Robust fallback object implementing all required Course methods
    self.course = {
        vehicle = self.combine,
        currentWaypoint = 1,
        lastPassedWaypoint = 1,
        waypoints = rawWaypoints,
        offsetX = 0,
        offsetZ = 0,
        copy = function(s, vehicle)
            local copyCourse = {}
            for k, v in pairs(s) do copyCourse[k] = v end
            copyCourse.vehicle = vehicle or s.vehicle
            return copyCourse
        end,
        setOffset = function(s, ox, oz)
            s.offsetX = ox or 0
            s.offsetZ = oz or 0
        end,
        getCurrentWaypointIx = function() return 1 end,
        getNumberOfWaypoints = function() return #rawWaypoints end,
        intersects = function() return nil end,
        getOffset = function(s) return s.offsetX or 0 end,
        getLastPassedWaypointIx = function() return 1 end,
        isReverseAt = function() return false end,
        getWaypoint = function(s, ix) return rawWaypoints[ix] or rawWaypoints[1] end,
        setCurrentWaypointIx = function(s, ix) s.currentWaypoint = ix end
    }

    return self.course
end

function CP_VirtualCourse:getCourse()
    if self.course == nil then
        self:update()
    end
    return self.course
end