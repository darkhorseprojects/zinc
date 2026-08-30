local json = require("lunajson")
local Retrieval = require("zinc.internal.retrieval")

local OPTIONS = {
    semantic_language = "en",
    semantic_depth = 1,
    semantic_attention_cutoff = 0,
    max_chronological_window_tokens = 100,
    max_retrieval_window_tokens = 1000,
    max_semantic_terms = 512,
    max_grounding_tokens = 4096,
    max_exact_forms = 512,
    max_retrieval_candidates = 64,
}

describe("retrieval", function()
    it("grounds, expands, searches, excludes recent records, and reranks once", function()
        local chronological = {
            { id = 5, role = "assistant", text = "recent" },
            { id = 4, role = "tool", text = string.rep("x", 200) },
            { id = 3, role = "user", text = "older" },
        }
        local candidates = {
            { id = 5, role = "assistant", text = "recent" },
            { id = 1, role = "user", text = "first" },
            { id = 2, role = "tool", text = "second" },
        }
        local store = {}
        function store:before()
            return chronological
        end
        function store:ground(anchor, terms, tokens, exact)
            self.anchor, self.bounds = anchor, { terms, tokens, exact }
            return { terms = { "anchor" }, tokens = { "immutable", "anchor" }, exact_forms = {} }
        end
        function store:search(_, _, terms, maximum)
            self.terms, self.maximum = terms, maximum
            return candidates
        end
        local cygnet = {}
        function cygnet:expand(request)
            self.request = request
            return { "M-17" }
        end
        local models = {}
        function models:encode(value)
            return assert(json.encode(value))
        end
        function models:tokens(value)
            return #value
        end
        function models:rerank(query, passages)
            self.query, self.passages = query, passages
            return { { index = 2, score = 1 }, { index = 1, score = 1 } }, 2
        end
        local retrieval = Retrieval(OPTIONS, store, models, cygnet)
        local context = assert(json.decode(retrieval:start("actor", 6, "immutable anchor")))
        assert.same({ "anchor", "M-17" }, store.terms)
        assert.same({ 512, 4096, 512 }, store.bounds)
        assert.equals(511, cygnet.request.maximum_terms)
        assert.equals("immutable anchor", models.query)
        assert.same({ { id = 5, role = "assistant", text = "recent" } }, context.chronological)
        assert.same({ 1, 2 }, { context.semantic[1].id, context.semantic[2].id })
    end)
end)
