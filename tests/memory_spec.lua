local json = require("lunajson")
local sqlite = require("lsqlite3complete")
local make_memory = assert(loadfile("package/src/memory.lua"))()
local make_store = assert(loadfile("package/src/store.lua"))()

local function paths()
    local store, cygnet = os.tmpname(), os.tmpname()
    os.remove(store)
    os.remove(cygnet)
    local db = assert(sqlite.open(cygnet))
    assert(db:exec([[
CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT);
INSERT INTO metadata VALUES
 ('maximum_form_tokens','2'),('format_version','2'),('algorithm','relation-balanced-pagerank-v1');
CREATE TABLE form_scores(language TEXT,form TEXT,probability REAL);
CREATE TABLE languages(language TEXT,normalization REAL,vocabulary REAL);
CREATE TABLE form_concepts(language TEXT,form TEXT,concept INTEGER);
CREATE TABLE concept_edges(source INTEGER,target INTEGER);
CREATE TABLE concept_terms(concept INTEGER,language TEXT,term TEXT);
INSERT INTO languages VALUES('en',1,1);
INSERT INTO form_scores VALUES('en','portable agent',1);
INSERT INTO form_concepts VALUES('en','portable agent',1);
INSERT INTO concept_terms VALUES(1,'en','portable agent'),(1,'en','mobile worker');
]]) == sqlite.OK, db:errmsg())
    assert(db:close() == sqlite.OK)
    return store, cygnet
end

local function model()
    local value = { token_calls = 0, rerank_calls = 0 }
    function value:tokens(input)
        self.token_calls = self.token_calls + 1
        local count = 0
        for _ in input:gmatch("%S+") do
            count = count + 1
        end
        return count
    end
    function value:rerank(_, passages)
        self.rerank_calls = self.rerank_calls + 1
        local result = {}
        for index in ipairs(passages) do
            result[index] = index
        end
        return result
    end
    return value
end

local function open()
    local store_path, cygnet = paths()
    local store = make_store({ path = store_path })
    local ranking = model()
    local memory = make_memory({
        cygnet = cygnet,
        semantic_language = "en",
        semantic_depth = 1,
        semantic_attention_cutoff = 0,
        chronological_records = 8,
        chronological_tokens = 1024,
        semantic_terms = 16,
        grounding_tokens = 16,
        exact_forms = 4,
        candidates = 8,
        semantic_tokens = 1024,
    }, store, ranking)
    return memory, store, ranking, store_path, cygnet
end

local function add(store, actor, parent, memory, role, text)
    return store:append(actor, parent, memory, { { role = role, text = text } }, 4096)[1]
end

local function close(memory, store, store_path, cygnet)
    memory:close()
    store:close()
    os.remove(store_path)
    os.remove(store_path .. "-shm")
    os.remove(store_path .. "-wal")
    os.remove(cygnet)
end

describe("event retrieval", function()
    it("bounds chronology and Cygnet search by inclusive memory", function()
        local memory, store, _, store_path, cygnet = open()
        local root = add(store, "actor", nil, 0, "user", "root")
        local recalled = add(store, "actor", root.id, root.id, "assistant", "mobile worker fact")
        add(store, "actor", recalled.id, recalled.id, "assistant", "newer hidden fact")
        local context = json.decode(memory:context("actor", recalled.id, "portable agent"))
        local encoded = json.encode(context)
        assert.matches("mobile worker fact", encoded, 1, true)
        assert.not_matches("newer hidden fact", encoded, 1, true)
        assert.matches('"id":' .. recalled.id, encoded)
        close(memory, store, store_path, cygnet)
    end)

    it("presents chronological events oldest first", function()
        local memory, store, _, store_path, cygnet = open()
        local first = add(store, "actor", nil, 0, "user", "first")
        local second = add(store, "actor", first.id, first.id, "assistant", "second")
        local third = add(store, "actor", second.id, second.id, "user", "third")
        local context = json.decode(memory:context("actor", third.id, "unrelated"))
        assert.same({ first.id, second.id, third.id }, {
            context.chronological[1].id,
            context.chronological[2].id,
            context.chronological[3].id,
        })
        close(memory, store, store_path, cygnet)
    end)

    it("does no retrieval work at boundary zero", function()
        local memory, store, ranking, store_path, cygnet = open()
        assert.same({ chronological = {}, semantic = {} }, json.decode(memory:context("actor", 0, "portable agent")))
        assert.equals(0, ranking.token_calls)
        assert.equals(0, ranking.rerank_calls)
        close(memory, store, store_path, cygnet)
    end)
end)
