local function harness(completions, members)
    local records, evaluated, next_id = {}, {}, 0
    package.loaded.pa = nil
    package.loaded["src.store"] = nil
    package.loaded["src.memory"] = nil
    package.loaded["src.run"] = nil
    package.preload.pa = function()
        return {
            eval = function(view, sources, input)
                evaluated[#evaluated + 1] = { view = view, sources = sources, input = input }
                local output = {}
                for index in ipairs(sources) do
                    output[index] = "result " .. index
                end
                return output
            end,
        }
    end
    package.preload["src.store"] = function()
        return function()
            return {
                validate = function() end,
                append = function(_, actor, parent, memory, events)
                    local rows = {}
                    for index, event in ipairs(events) do
                        next_id = next_id + 1
                        local row = {
                            id = next_id,
                            actor = actor,
                            parent = parent,
                            memory = memory,
                            role = event.role,
                            text = event.text,
                        }
                        rows[index], records[#records + 1], parent = row, row, row.id
                    end
                    return rows
                end,
                close = function(self)
                    self.closed = true
                end,
            }
        end
    end
    package.preload["src.memory"] = function()
        return function()
            return {
                context = function()
                    return '{"chronological":[],"semantic":[]}'
                end,
                close = function(self)
                    self.closed = true
                end,
            }
        end
    end
    local preset = { document = {}, members = members or {} }
    local spec = {
        store = {},
        memory = {},
        limits = { record_bytes = 4096, tool_result_bytes = 4096, model_rounds = 8 },
        presets = { safe = preset },
    }
    local model = {
        chat = function()
            assert(#completions > 0, "unexpected model call")
            return table.remove(completions, 1)
        end,
    }
    local entry = {
        document = function() end,
        design = function() end,
        zinc = function() end,
    }
    for name in pairs(preset.members) do
        entry[name] = preset.members[name].call
    end
    local run = assert(loadfile("package/src/run.lua"))()(spec, entry, model, {
        zinc = "instructions",
        presets = { safe = "safe" },
    })
    local function invoke()
        return run({
            actor = "actor",
            imports = {},
            input = "input",
            memory = 0,
            parent = nil,
            preset = preset,
            question = "question",
        })
    end
    return invoke, records, evaluated, entry
end

describe("Zinc execution", function()
    after_each(function()
        for _, name in ipairs({ "pa", "src.run", "src.store", "src.memory" }) do
            package.loaded[name] = nil
            package.preload[name] = nil
        end
    end)

    it("persists ordered reasoning and response events", function()
        local invoke, records = harness({
            { items = { { type = "reasoning", text = "think" } }, last = "reasoning" },
            { items = { { type = "response", text = "answer" } }, last = "response" },
        })
        local result = invoke()
        assert.equals("answer", result.text)
        assert.same({ "user", "assistant", "assistant" }, { records[1].role, records[2].role, records[3].role })
        assert.equals(records[1].id, records[2].parent)
        assert.equals(records[2].id, records[3].parent)
    end)

    it("selects arbitrary preset members and evaluates one ordered batch", function()
        local members = {
            fetch = {
                call = function(input)
                    return input
                end,
                prompt = "fetch prompt",
            },
        }
        local invoke, records, evaluated, entry = harness({
            {
                items = {
                    {
                        type = "tool",
                        calls = { { id = "two", code = "return 'first'" }, { id = "one", code = "return 'second'" } },
                        wire = { { id = "two" }, { id = "one" } },
                    },
                },
                last = "tool",
            },
            { items = { { type = "response", text = "done" } }, last = "response" },
        }, members)
        invoke()
        assert.equals(entry.fetch, evaluated[1].view.fetch)
        assert.is_nil(evaluated[1].view.fs)
        assert.same({ "result 1", "result 2" }, { records[4].text, records[5].text })
        assert.matches("local self, input = ...", evaluated[1].sources[1], 1, true)
    end)

    it("rejects terminal responses with pending tools", function()
        local invoke = harness({
            {
                items = {
                    { type = "tool", calls = { { id = "one", code = "return 'x'" } }, wire = { { id = "one" } } },
                    { type = "response", text = "unsupported" },
                },
                last = "response",
            },
        })
        assert.has_error(invoke, "terminal response has pending tools")
    end)
end)
