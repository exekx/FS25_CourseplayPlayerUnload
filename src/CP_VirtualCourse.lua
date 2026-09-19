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
    self.updateIntervalMs = 500 -- Regenerate/advance course twice a second
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
    local Course = CP_GetCpClass(Course)

    if Course and Course.createStraightForwardCourse then
        -- Generate 150 meters of straight waypoints ahead of player combine
        self.course = Course.createStraightForwardCourse(self.combine, 150, 0, dirNode)
    elseif Course and Course.createFromNode then
        self.course = Course.createFromNode(self.combine, dirNode, 0, 0, 150, 5, false)
    end

    return self.course
end

function CP_VirtualCourse:getCourse()
    if self.course == nil then
        self:update()
    end
    if self.course == nil then
        -- Safe fallback object with required Course API methods
        return {
            currentWaypoint = 1,
            lastPassedWaypoint = 1,
            waypoints = {
                { x = 0, z = 0, dToHere = 0, rev = false },
                { x = 0, z = 100, dToHere = 100, rev = false }
            },
            getCurrentWaypointIx = function() return 1 end,
            getNumberOfWaypoints = function() return 2 end,
            intersects = function() return nil end,
            getOffset = function() return 0 end,
            getLastPassedWaypointIx = function() return 1 end,
            isReverseAt = function() return false end
        }
    end
    return self.course
end