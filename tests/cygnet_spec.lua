local sqlite = require("lsqlite3complete")
local Cygnet = require("src.cygnet")

local paths = {}
local function database()
    local path = os.tmpname()
    os.remove(path)
    paths[#paths + 1] = path
    local directory, name = assert(path:match("^(.*)[/\\]([^/\\]+)$"))
    local db = assert(sqlite.open(path))
    assert(db:exec([[
CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL) STRICT;
CREATE TABLE languages(language TEXT PRIMARY KEY,normalization REAL NOT NULL,vocabulary INTEGER NOT NULL) STRICT;
CREATE TABLE form_scores(language TEXT NOT NULL,form TEXT NOT NULL,probability REAL NOT NULL,PRIMARY KEY(language,form)) WITHOUT ROWID;
CREATE TABLE form_concepts(language TEXT NOT NULL,form TEXT NOT NULL,concept INTEGER NOT NULL,PRIMARY KEY(language,form,concept)) WITHOUT ROWID;
CREATE TABLE concept_terms(concept INTEGER NOT NULL,language TEXT NOT NULL,term TEXT NOT NULL,PRIMARY KEY(concept,language,term)) WITHOUT ROWID;
CREATE TABLE concept_edges(source INTEGER NOT NULL,target INTEGER NOT NULL,PRIMARY KEY(source,target)) WITHOUT ROWID;
INSERT INTO metadata VALUES('format_version','2'),('algorithm','relation-balanced-pagerank-v1'),('maximum_form_tokens','1');
INSERT INTO languages VALUES('en',1,3),('es',0.33,1);
INSERT INTO form_scores VALUES('en','poodle',0.34),('en','dog',0.33),('en','animal',0.33),('es','perro',0.33);
INSERT INTO form_concepts VALUES('en','poodle',1),('en','dog',2),('en','animal',3),('es','perro',2);
INSERT INTO concept_terms VALUES(1,'en','poodle'),(2,'en','dog'),(3,'en','animal'),(2,'es','perro');
INSERT INTO concept_edges VALUES(1,2),(2,3);
]]) == sqlite.OK, db:errmsg())
    assert(db:close() == sqlite.OK)
    return directory, name
end

after_each(function()
    for _, path in ipairs(paths) do
        os.remove(path)
    end
    paths = {}
end)

describe("Cygnet", function()
    it("expands directed concepts by depth and language", function()
        local directory, name = database()
        local cygnet = Cygnet({ cygnet = name }, directory)
        local function expand(token, language, depth)
            return cygnet:expand({
                tokens = { token },
                exact_forms = {},
                semantic_language = language,
                semantic_depth = depth,
                semantic_attention_cutoff = -1e300,
                maximum_terms = 32,
            })
        end
        assert.same({ "poodle" }, expand("poodle", "en", 0))
        assert.same({ "poodle", "dog" }, expand("poodle", "en", 1))
        assert.same({ "poodle", "dog", "animal" }, expand("poodle", "en", 2))
        assert.same({ "perro" }, expand("perro", "es", 2))
        assert.same({}, expand("perro", "en", 2))
        cygnet:close()
    end)
end)
