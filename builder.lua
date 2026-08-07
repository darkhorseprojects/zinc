return function(document)
    local guide = assert(document.Builder, "Builder document is invalid")
    local builder = {guide = guide.Guide, docs = document}

    function builder:questionnaire(goal)
        assert(type(goal) == "string" and goal ~= "", "goal must be nonempty text")
        return {goal = goal, questions = {table.unpack(guide.Questionnaire)}}
    end

    function builder:template(spec)
        assert(type(spec) == "table", "template specification must be a table")
        for _, name in ipairs({"name", "instructions", "program"}) do assert(type(spec[name]) == "string" and spec[name] ~= "", name .. " is required") end
        local source = "# " .. spec.name .. "\n\n## Instructions\n\n" .. spec.instructions .. "\n\n## Program\n\n```lua\n" .. spec.program .. "\n```\n"
        return {[spec.entry or "agent.md"] = source}
    end

    return builder
end
