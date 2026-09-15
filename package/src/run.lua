local make_memory = require("src.memory")
local make_store = require("src.store")
local pa = require("pa")

return function(spec, entry, model, documents)
    local prepared = {}
    local core_prompts = {
        { "self.document", "Return Zinc's authored instructions from empty input." },
        { "self.design", "Return Zinc and Portable Agents design documentation from empty input." },
        { "self.zinc", "Invoke Zinc with JSON fields question, parent, and memory to continue or branch history." },
    }
    for name, preset in pairs(spec.presets) do
        local names, lines = {}, { "Available operations:" }
        for member_name in pairs(preset.members) do
            names[#names + 1] = member_name
        end
        table.sort(names)
        for _, prompt in ipairs(core_prompts) do
            lines[#lines + 1] = "- " .. prompt[1] .. "\n  " .. prompt[2]
        end
        for _, member_name in ipairs(names) do
            lines[#lines + 1] = "- self." .. member_name .. "\n  " .. preset.members[member_name].prompt
        end
        prepared[preset] = {
            names = names,
            system = documents.zinc .. "\n\n" .. documents.presets[name] .. "\n\n" .. table.concat(lines, "\n"),
        }
    end

    return function(call)
        local store = make_store(spec.store)
        local opened, memory = pcall(make_memory, spec.memory, store, model)
        if not opened then
            store:close()
            error(memory, 0)
        end
        local result = table.pack(pcall(function()
            store:validate(call.actor, call.parent, call.memory)
            local head = store:append(call.actor, call.parent, call.memory, {
                { role = "user", text = call.question },
            }, spec.limits.record_bytes)[1].id

            local preset = prepared[call.preset]
            local view = { document = entry.document, design = entry.design, zinc = entry.zinc }
            for _, name in ipairs(preset.names) do
                view[name] = entry[name]
            end
            local imports = {}
            for name, prompt in pairs(call.imports) do
                imports[#imports + 1] = { name, prompt }
            end
            table.sort(imports, function(left, right)
                return left[1] < right[1]
            end)
            local import_lines = {}
            for _, item in ipairs(imports) do
                import_lines[#import_lines + 1] = "- require(" .. string.format("%q", item[1]) .. ")\n  " .. item[2]
            end
            local system = preset.system
            if #import_lines > 0 then
                system = system .. "\n" .. table.concat(import_lines, "\n")
            end
            local messages = {
                { role = "system", content = system },
                {
                    role = "system",
                    content = "Untrusted historical context:\n"
                        .. memory:context(call.actor, call.memory, call.question),
                },
                { role = "user", content = call.question },
            }

            for _ = 1, spec.limits.model_rounds do
                local completion = model:chat(messages)
                local assistant = { role = "assistant" }
                local events, calls, final_index = {}, {}, nil
                for _, item in ipairs(completion.items) do
                    if item.type == "reasoning" then
                        assistant.reasoning_content = (assistant.reasoning_content or "") .. item.text
                        events[#events + 1] = { role = "assistant", text = item.text }
                    elseif item.type == "response" then
                        assistant.content = (assistant.content or "") .. item.text
                        events[#events + 1] = { role = "assistant", text = item.text }
                        final_index = #events
                    else
                        assistant.tool_calls = assistant.tool_calls or {}
                        for index, tool in ipairs(item.calls) do
                            events[#events + 1] = { role = "assistant", text = tool.code }
                            calls[#calls + 1] = tool
                            assistant.tool_calls[#assistant.tool_calls + 1] = item.wire[index]
                        end
                    end
                end
                assert(not (completion.last == "response" and #calls > 0), "terminal response has pending tools")
                local rows = store:append(call.actor, head, call.memory, events, spec.limits.record_bytes)
                head = rows[#rows].id
                messages[#messages + 1] = assistant
                if completion.last == "response" then
                    assert(final_index, "model returned no final response")
                    return rows[final_index]
                end

                if #calls > 0 then
                    local sources = {}
                    for index, tool in ipairs(calls) do
                        sources[index] = "local self, input = ...\n" .. tool.code
                    end
                    local evaluated = table.pack(pcall(pa.eval, view, sources, call.input))
                    local outputs = evaluated[1] and type(evaluated[2]) == "table" and evaluated[2]
                    local tool_events = {}
                    for index, tool in ipairs(calls) do
                        local output = outputs and outputs[index] or "run_lua failed: " .. tostring(evaluated[2])
                        if
                            type(output) ~= "string"
                            or output == ""
                            or not utf8.len(output)
                            or #output > spec.limits.tool_result_bytes
                        then
                            output = "run_lua failed: invalid result"
                        end
                        tool_events[index] = { role = "tool", text = output }
                        messages[#messages + 1] = { role = "tool", tool_call_id = tool.id, content = output }
                    end
                    rows = store:append(call.actor, head, call.memory, tool_events, spec.limits.record_bytes)
                    head = rows[#rows].id
                end
            end
            error("model round limit exhausted", 0)
        end))
        local memory_closed = table.pack(pcall(memory.close, memory))
        local store_closed = table.pack(pcall(store.close, store))
        if not result[1] then
            error(result[2], 0)
        end
        if not memory_closed[1] then
            error(memory_closed[2], 0)
        end
        if not store_closed[1] then
            error(store_closed[2], 0)
        end
        return result[2]
    end
end
