local sqlite = require("lsqlite3complete")

local source, output, source_identity = ...
assert(type(source) == "string" and source ~= "", "usage: lua tools/cygnet_index.lua SOURCE OUTPUT SOURCE_IDENTITY")
assert(type(output) == "string" and output ~= "", "output path is required")
assert(type(source_identity) == "string" and source_identity ~= "", "source identity is required")
local source_file = assert(io.open(source, "rb"), "Cygnet source does not exist")
source_file:close()

local SCORING = {
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
local RESTART, DAMPING, TOLERANCE, MAXIMUM_ITERATIONS = 0.15, 0.85, 1e-13, 200
local CONTENT_POS = "'NOUN','VERB','ADJ','ADV'"
local temporary = output .. ".tmp"
os.remove(temporary)

local function quote(value) return "'" .. value:gsub("'", "''") .. "'" end

local db = assert(sqlite.open(temporary))
db:busy_timeout(5000)
local function exec(sql) assert(db:exec(sql) == sqlite.OK, db:errmsg()) end
local function scalar(sql)
    local result
    for row in db:nrows(sql) do
        for _, value in pairs(row) do
            result = value
            break
        end
    end
    return result
end

exec("PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA temp_store=MEMORY; PRAGMA foreign_keys=ON")
exec("ATTACH DATABASE " .. quote(source) .. " AS cygnet")
exec([[
CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL) STRICT;
CREATE TABLE concept_mass(synset_rowid INTEGER PRIMARY KEY,mass REAL NOT NULL CHECK(mass>0)) STRICT;
CREATE TABLE languages(
 language TEXT PRIMARY KEY,
 normalization REAL NOT NULL CHECK(normalization>0),
 vocabulary INTEGER NOT NULL CHECK(vocabulary>0)
) STRICT;
CREATE TABLE concept_form_counts(
 language TEXT NOT NULL,
 synset_rowid INTEGER NOT NULL,
 count INTEGER NOT NULL CHECK(count>0),
 PRIMARY KEY(language,synset_rowid)
) STRICT;
CREATE TABLE work_edges(source INTEGER NOT NULL,relation TEXT NOT NULL,target INTEGER NOT NULL,
 PRIMARY KEY(source,relation,target)) WITHOUT ROWID;
CREATE TABLE work_mass(synset INTEGER PRIMARY KEY,value REAL NOT NULL) WITHOUT ROWID;
CREATE TABLE work_next(synset INTEGER PRIMARY KEY,value REAL NOT NULL) WITHOUT ROWID;
]])

local relation_literals = {}
for _, relation in ipairs(SCORING) do
    relation_literals[#relation_literals + 1] = quote(relation)
end
local relation_set = table.concat(relation_literals, ",")
exec(([[
INSERT OR IGNORE INTO work_edges
SELECT r.source_rowid,t.type,r.target_rowid
FROM cygnet.synset_relations r JOIN cygnet.relation_types t ON t.rowid=r.type_rowid
JOIN cygnet.synsets ss ON ss.rowid=r.source_rowid JOIN cygnet.synsets ts ON ts.rowid=r.target_rowid
WHERE t.type IN (%s) AND ss.pos IN (%s) AND ts.pos IN (%s) AND r.source_rowid<>r.target_rowid;
INSERT OR IGNORE INTO work_edges
SELECT ss.synset_rowid,t.type,ts.synset_rowid
FROM cygnet.sense_relations r
JOIN cygnet.senses ss ON ss.rowid=r.source_rowid
JOIN cygnet.senses ts ON ts.rowid=r.target_rowid
JOIN cygnet.relation_types t ON t.rowid=r.type_rowid
JOIN cygnet.synsets sc ON sc.rowid=ss.synset_rowid JOIN cygnet.synsets tc ON tc.rowid=ts.synset_rowid
WHERE t.type IN (%s) AND sc.pos IN (%s) AND tc.pos IN (%s) AND ss.synset_rowid<>ts.synset_rowid;
]]):format(relation_set, CONTENT_POS, CONTENT_POS, relation_set, CONTENT_POS, CONTENT_POS))
exec("CREATE INDEX work_edges_target ON work_edges(target)")
exec(
    "INSERT INTO work_mass SELECT rowid,1.0/(SELECT count(*) FROM cygnet.synsets WHERE pos IN ("
    .. CONTENT_POS
    .. ")) FROM cygnet.synsets WHERE pos IN ("
    .. CONTENT_POS
    .. ")"
)
local count = assert(scalar("SELECT count(*) FROM work_mass"), "Cygnet has no content concepts")
assert(count > 0, "Cygnet has no content concepts")

local iterations
for iteration = 1, MAXIMUM_ITERATIONS do
    local dangling = scalar([[SELECT coalesce(sum(value),0) FROM work_mass m
WHERE NOT EXISTS(SELECT 1 FROM work_edges e WHERE e.source=m.synset)]])
    exec("DELETE FROM work_next")
    exec(([[
INSERT INTO work_next
WITH source_families AS (
 SELECT source,count(DISTINCT relation) count FROM work_edges GROUP BY source
), family_targets AS (
 SELECT source,relation,count(*) count FROM work_edges GROUP BY source,relation
), contribution AS (
 SELECT e.target,sum(%0.17g*m.value/sf.count/ft.count) value
 FROM work_edges e JOIN work_mass m ON m.synset=e.source
 JOIN source_families sf ON sf.source=e.source
 JOIN family_targets ft ON ft.source=e.source AND ft.relation=e.relation
 GROUP BY e.target
)
SELECT m.synset,%0.17g/%d+%0.17g*%0.17g/%d+coalesce(c.value,0)
FROM work_mass m LEFT JOIN contribution c ON c.target=m.synset;
]]):format(DAMPING, RESTART, count, DAMPING, dangling, count))
    local difference = scalar(
        [[SELECT sum(abs(m.value-n.value)) FROM work_mass m JOIN work_next n ON n.synset=m.synset]])
    exec("DELETE FROM work_mass; INSERT INTO work_mass SELECT * FROM work_next")
    if difference <= TOLERANCE then
        iterations = iteration
        break
    end
end
assert(iterations, "Cygnet structural mass did not converge")
exec("INSERT INTO concept_mass SELECT synset,value FROM work_mass")

local maximum_form_tokens = scalar(([[SELECT coalesce(max(length(f.normalized_form)-length(replace(f.normalized_form,' ',''))+1),1)
FROM cygnet.forms f JOIN cygnet.entries e ON e.rowid=f.entry_rowid
WHERE e.pos IN (%s) AND f.normalized_form<>'';]]):format(CONTENT_POS))
exec(([[
INSERT INTO concept_form_counts
SELECT l.code,s.synset_rowid,count(DISTINCT f.normalized_form)
FROM cygnet.senses s JOIN cygnet.entries e ON e.rowid=s.entry_rowid
JOIN cygnet.languages l ON l.rowid=e.language_rowid JOIN cygnet.forms f ON f.entry_rowid=e.rowid
JOIN concept_mass m ON m.synset_rowid=s.synset_rowid
WHERE e.pos IN (%s) AND f.normalized_form<>'' GROUP BY l.code,s.synset_rowid;
INSERT INTO languages(language,normalization,vocabulary)
WITH language_concepts AS (
 SELECT DISTINCT l.code,s.synset_rowid FROM cygnet.entries e
 JOIN cygnet.languages l ON l.rowid=e.language_rowid JOIN cygnet.senses s ON s.entry_rowid=e.rowid
 JOIN cygnet.forms f ON f.entry_rowid=e.rowid
 WHERE e.pos IN (%s) AND f.normalized_form<>''
), normalizations AS (
 SELECT lc.code,sum(m.mass) normalization FROM language_concepts lc
 JOIN concept_mass m ON m.synset_rowid=lc.synset_rowid GROUP BY lc.code
), vocabularies AS (
 SELECT l.code,count(DISTINCT f.normalized_form) vocabulary FROM cygnet.forms f
 JOIN cygnet.entries e ON e.rowid=f.entry_rowid JOIN cygnet.languages l ON l.rowid=e.language_rowid
 WHERE e.pos IN (%s) AND f.normalized_form<>'' GROUP BY l.code
)
SELECT n.code,n.normalization,v.vocabulary FROM normalizations n JOIN vocabularies v ON v.code=n.code
WHERE n.normalization>0 AND v.vocabulary>0;
]]):format(CONTENT_POS, CONTENT_POS, CONTENT_POS))
exec(([[
CREATE TABLE form_scores(language TEXT NOT NULL,form TEXT NOT NULL,probability REAL NOT NULL CHECK(probability>0),PRIMARY KEY(language,form)) WITHOUT ROWID;
CREATE TABLE form_concepts(language TEXT NOT NULL,form TEXT NOT NULL,concept INTEGER NOT NULL,PRIMARY KEY(language,form,concept)) WITHOUT ROWID;
CREATE TABLE concept_terms(concept INTEGER NOT NULL,language TEXT NOT NULL,term TEXT NOT NULL,PRIMARY KEY(concept,language,term)) WITHOUT ROWID;
CREATE TABLE concept_edges(source INTEGER NOT NULL,target INTEGER NOT NULL,PRIMARY KEY(source,target)) WITHOUT ROWID;
WITH mapped AS (
 SELECT DISTINCT l.code language,f.normalized_form form,s.synset_rowid concept
 FROM cygnet.forms f JOIN cygnet.entries e ON e.rowid=f.entry_rowid JOIN cygnet.languages l ON l.rowid=e.language_rowid
 JOIN cygnet.senses s ON s.entry_rowid=e.rowid JOIN concept_mass m ON m.synset_rowid=s.synset_rowid
 WHERE e.pos IN (%s) AND f.normalized_form<>''
)
INSERT INTO form_concepts SELECT language,form,concept FROM mapped;
WITH mapped AS (
 SELECT DISTINCT l.code language,f.normalized_form form,s.synset_rowid concept
 FROM cygnet.forms f JOIN cygnet.entries e ON e.rowid=f.entry_rowid JOIN cygnet.languages l ON l.rowid=e.language_rowid
 JOIN cygnet.senses s ON s.entry_rowid=e.rowid JOIN concept_mass m ON m.synset_rowid=s.synset_rowid
 WHERE e.pos IN (%s) AND f.normalized_form<>''
)
INSERT INTO form_scores
SELECT x.language,x.form,sum(m.mass/c.count) FROM mapped x JOIN concept_mass m ON m.synset_rowid=x.concept
JOIN concept_form_counts c ON c.language=x.language AND c.synset_rowid=x.concept GROUP BY x.language,x.form;
INSERT INTO concept_terms
SELECT DISTINCT s.synset_rowid,l.code,f.normalized_form FROM cygnet.senses s JOIN cygnet.entries e ON e.rowid=s.entry_rowid
JOIN cygnet.languages l ON l.rowid=e.language_rowid JOIN cygnet.forms f ON f.entry_rowid=e.rowid
JOIN concept_mass m ON m.synset_rowid=s.synset_rowid WHERE e.pos IN (%s) AND f.normalized_form<>'';
INSERT INTO concept_edges SELECT DISTINCT source,target FROM work_edges;
CREATE INDEX concept_terms_language_concept ON concept_terms(language,concept);
]]):format(CONTENT_POS, CONTENT_POS, CONTENT_POS))

local metadata = {
    format_version = "2",
    source_identity = source_identity,
    algorithm = "relation-balanced-pagerank-v1",
    restart = tostring(RESTART),
    tolerance = tostring(TOLERANCE),
    iterations = tostring(iterations),
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
exec(
    "DROP TABLE work_edges; DROP TABLE work_mass; DROP TABLE work_next; DROP TABLE concept_mass; DROP TABLE concept_form_counts; PRAGMA application_id=1514751817; PRAGMA user_version=2; VACUUM"
)
assert(db:close() == sqlite.OK, "closing Cygnet index failed")
assert(os.rename(temporary, output))
print(string.format("indexed %d concepts in %d iterations", count, iterations))
