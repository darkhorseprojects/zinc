local sqlite = require("lsqlite3")
local uv = require("luv")
local Cygnet = require("src.cygnet")

local roots = {}
local function remove(path)
    local stat = uv.fs_lstat(path)
    if not stat then
        return
    end
    if stat.type == "directory" then
        local scan = assert(uv.fs_scandir(path))
        while true do
            local name = uv.fs_scandir_next(scan)
            if not name then
                break
            end
            remove(path .. "/" .. name)
        end
        assert(uv.fs_rmdir(path))
    else
        assert(uv.fs_unlink(path))
    end
end
local function root()
    local path = assert(uv.fs_mkdtemp((os.getenv("TMPDIR") or "/tmp") .. "/zinc-cygnet-XXXXXX"))
    roots[#roots + 1] = path
    return path
end

after_each(function()
    for _, path in ipairs(roots) do
        remove(path)
    end
    roots = {}
end)

local function databases()
    local directory = root()
    local source, index = directory .. "/cygnet.db", directory .. "/cygnet-index.db"
    local db = assert(sqlite.open(source))
    assert(db:exec([[
CREATE TABLE languages(rowid INTEGER PRIMARY KEY,code TEXT NOT NULL,name TEXT);
CREATE TABLE entries(rowid INTEGER PRIMARY KEY,language_rowid INTEGER NOT NULL,pos TEXT NOT NULL);
CREATE TABLE forms(rowid INTEGER PRIMARY KEY,entry_rowid INTEGER NOT NULL,form TEXT NOT NULL,normalized_form TEXT NOT NULL,rank INTEGER DEFAULT 1);
CREATE INDEX idx_forms_normalized ON forms(normalized_form);
CREATE TABLE synsets(rowid INTEGER PRIMARY KEY,ili TEXT,pos TEXT NOT NULL);
CREATE TABLE senses(rowid INTEGER PRIMARY KEY,entry_rowid INTEGER NOT NULL,synset_rowid INTEGER NOT NULL,sense_index INTEGER DEFAULT 1);
CREATE TABLE relation_types(rowid INTEGER PRIMARY KEY,type TEXT NOT NULL);
CREATE TABLE sense_relations(rowid INTEGER PRIMARY KEY,source_rowid INTEGER NOT NULL,target_rowid INTEGER NOT NULL,type_rowid INTEGER NOT NULL);
CREATE TABLE synset_relations(rowid INTEGER PRIMARY KEY,source_rowid INTEGER NOT NULL,target_rowid INTEGER NOT NULL,type_rowid INTEGER NOT NULL);
INSERT INTO languages VALUES(1,'en','English'),(2,'es','Spanish');
INSERT INTO relation_types VALUES(1,'hypernym');
INSERT INTO synsets VALUES(1,NULL,'NOUN'),(2,NULL,'NOUN'),(3,NULL,'NOUN');
INSERT INTO entries VALUES(1,1,'NOUN'),(2,1,'NOUN'),(3,1,'NOUN'),(4,2,'NOUN');
INSERT INTO forms VALUES(1,1,'poodle','poodle',0),(2,2,'dog','dog',0),(3,3,'animal','animal',0),(4,4,'perro','perro',0);
INSERT INTO senses VALUES(1,1,1,1),(2,2,2,1),(3,3,3,1),(4,4,2,1);
INSERT INTO synset_relations(source_rowid,target_rowid,type_rowid) VALUES(1,2,1),(2,3,1);
]]) == sqlite.OK, db:errmsg())
    assert(db:close() == sqlite.OK)

    db = assert(sqlite.open(index))
    assert(db:exec([[
CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL) STRICT;
CREATE TABLE concept_mass(synset_rowid INTEGER PRIMARY KEY,mass REAL NOT NULL) STRICT;
CREATE TABLE language_statistics(language TEXT PRIMARY KEY,normalization REAL NOT NULL,vocabulary INTEGER NOT NULL,maximum_form_tokens INTEGER NOT NULL) STRICT;
CREATE TABLE concept_form_counts(language TEXT NOT NULL,synset_rowid INTEGER NOT NULL,count INTEGER NOT NULL,PRIMARY KEY(language,synset_rowid)) STRICT;
INSERT INTO metadata VALUES('format_version','1'),('source_identity','fixture'),('algorithm','relation-balanced-pagerank-v1');
INSERT INTO concept_mass VALUES(1,0.34),(2,0.33),(3,0.33);
INSERT INTO language_statistics VALUES('en',1.0,3,1),('es',0.33,1,1);
INSERT INTO concept_form_counts VALUES('en',1,1),('en',2,1),('en',3,1),('es',2,1);
]]) == sqlite.OK, db:errmsg())
    assert(db:close() == sqlite.OK)
    return source, index
end

describe("Cygnet", function()
    it("expands directed concepts by exact depth and language", function()
        local source, index = databases()
        local cygnet = Cygnet.open({ source = source, index = index, source_identity = "fixture" })
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

    it("rejects a mismatched sidecar", function()
        local source, index = databases()
        assert.has_error(function()
            Cygnet.open({ source = source, index = index, source_identity = "wrong" })
        end, "Cygnet source and index identities differ")
    end)
end)
