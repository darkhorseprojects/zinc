local sqlite = require("lsqlite3complete")

local source, stopwords, output, source_identity = ...
assert(
    type(source) == "string" and source ~= "",
    "usage: lua tools/cygnet_index.lua SOURCE STOPWORDS OUTPUT SOURCE_IDENTITY"
)
local stop_file <close> = assert(io.open(stopwords, "rb"), "stop-word source does not exist")
local words = require("lunajson.decoder")()(stop_file:read("a"))
assert(type(output) == "string" and output ~= "", "output path is required")
assert(type(source_identity) == "string" and source_identity ~= "", "source identity is required")
local source_file = assert(io.open(source, "rb"), "Cygnet source does not exist")
source_file:close()

local RELATIONS = {
    "pertainym",
    "derivation",
    "antonym",
    "participle",
    "also",
    "similar",
    "attribute",
    "domain_topic",
    "has_domain_topic",
    "domain_region",
    "has_domain_region",
    "hypernym",
    "hyponym",
    "mero_part",
    "holo_part",
    "mero_substance",
    "holo_substance",
    "mero_member",
    "holo_member",
    "meronym",
    "holonym",
    "entails",
    "is_entailed_by",
    "causes",
    "is_caused_by",
    "instance_hypernym",
    "instance_hyponym",
}
local CONTENT_POS = "'NOUN','VERB','ADJ','ADV'"
local temporary = output .. ".tmp"
os.remove(temporary)

local function quote(value)
    return "'" .. value:gsub("'", "''") .. "'"
end

local db = assert(sqlite.open(temporary))
db:busy_timeout(5000)
local function exec(sql)
    assert(db:exec(sql) == sqlite.OK, db:errmsg())
end
local function scalar(sql)
    local result
    for row in db:nrows(sql) do
        for _, value in pairs(row) do
            result = value
        end
    end
    return result
end

exec("PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA temp_store=MEMORY; PRAGMA foreign_keys=ON")
exec("ATTACH DATABASE " .. quote(source) .. " AS cygnet")
exec([[
CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL) STRICT;
CREATE TABLE stop_words(language TEXT NOT NULL,term TEXT NOT NULL,PRIMARY KEY(language,term)) WITHOUT ROWID;
CREATE TABLE concept_edges(source INTEGER NOT NULL,target INTEGER NOT NULL,PRIMARY KEY(source,target)) WITHOUT ROWID;
]])
local relation_literals = {}
for _, relation in ipairs(RELATIONS) do
    relation_literals[#relation_literals + 1] = quote(relation)
end
local relation_set = table.concat(relation_literals, ",")
exec(([[
INSERT OR IGNORE INTO concept_edges
SELECT r.source_rowid,r.target_rowid
FROM cygnet.synset_relations r JOIN cygnet.relation_types t ON t.rowid=r.type_rowid
JOIN cygnet.synsets ss ON ss.rowid=r.source_rowid JOIN cygnet.synsets ts ON ts.rowid=r.target_rowid
WHERE t.type IN (%s) AND ss.pos IN (%s) AND ts.pos IN (%s) AND r.source_rowid<>r.target_rowid;
INSERT OR IGNORE INTO concept_edges
SELECT ss.synset_rowid,ts.synset_rowid
FROM cygnet.sense_relations r
JOIN cygnet.senses ss ON ss.rowid=r.source_rowid
JOIN cygnet.senses ts ON ts.rowid=r.target_rowid
JOIN cygnet.relation_types t ON t.rowid=r.type_rowid
JOIN cygnet.synsets sc ON sc.rowid=ss.synset_rowid JOIN cygnet.synsets tc ON tc.rowid=ts.synset_rowid
WHERE t.type IN (%s) AND sc.pos IN (%s) AND tc.pos IN (%s) AND ss.synset_rowid<>ts.synset_rowid;
]]):format(relation_set, CONTENT_POS, CONTENT_POS, relation_set, CONTENT_POS, CONTENT_POS))
local count = assert(scalar("SELECT count(*) FROM cygnet.synsets WHERE pos IN (" .. CONTENT_POS .. ")"))
assert(count > 0, "Cygnet has no content concepts")
local maximum_form_tokens =
    assert(scalar(([[SELECT coalesce(max(length(f.normalized_form)-length(replace(f.normalized_form,' ',''))+1),1)
FROM cygnet.forms f JOIN cygnet.entries e ON e.rowid=f.entry_rowid
WHERE e.pos IN (%s) AND f.normalized_form<>'';]]):format(CONTENT_POS)))
exec(([[
CREATE TABLE form_concepts(language TEXT NOT NULL,form TEXT NOT NULL,concept INTEGER NOT NULL,
 PRIMARY KEY(language,form,concept)) WITHOUT ROWID;
INSERT INTO form_concepts
SELECT DISTINCT l.code,f.normalized_form,s.synset_rowid
FROM cygnet.forms f JOIN cygnet.entries e ON e.rowid=f.entry_rowid
JOIN cygnet.languages l ON l.rowid=e.language_rowid
JOIN cygnet.senses s ON s.entry_rowid=e.rowid
JOIN cygnet.synsets concept ON concept.rowid=s.synset_rowid
WHERE e.pos IN (%s) AND concept.pos IN (%s) AND f.normalized_form<>'';
CREATE INDEX form_concepts_by_concept ON form_concepts(concept,language,form);
]]):format(CONTENT_POS, CONTENT_POS))
local insert_stop = assert(db:prepare("INSERT OR IGNORE INTO stop_words(language,term) VALUES(?,?)"))
for language, terms in pairs(words) do
    for _, term in ipairs(terms) do
        assert(insert_stop:bind_values(language, term) == sqlite.OK, db:errmsg())
        assert(insert_stop:step() == sqlite.DONE, db:errmsg())
        assert(insert_stop:reset() == sqlite.OK, db:errmsg())
    end
end
assert(insert_stop:finalize() == sqlite.OK, db:errmsg())
local metadata = {
    format_version = "5",
    stopwords_revision = "6e8e9a2d1c019ad2a885bcbe157628dea624dfb6",
    stopwords_sha256 = "337af4d57d5fa1fecc2ffcae532e9b9f05db51c74ff18d3dde9572185a3cdae4",
    source_identity = source_identity,
    concepts = tostring(count),
    maximum_form_tokens = tostring(maximum_form_tokens),
}
local statement = assert(db:prepare("INSERT INTO metadata(key,value) VALUES(?,?)"))
for key, value in pairs(metadata) do
    assert(statement:bind_values(key, value) == sqlite.OK, db:errmsg())
    assert(statement:step() == sqlite.DONE, db:errmsg())
    assert(statement:reset() == sqlite.OK, db:errmsg())
end
assert(statement:finalize() == sqlite.OK, db:errmsg())
exec("PRAGMA application_id=1514751817; PRAGMA user_version=5; VACUUM")
assert(db:close() == sqlite.OK, "closing Cygnet index failed")
assert(os.rename(temporary, output))
print(string.format("indexed %d concepts", count))
