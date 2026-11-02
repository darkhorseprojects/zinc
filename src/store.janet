(import sqlite3 :as sql)
(import spork/json :as json)
(import spork/base64 :as base64)
(import spork/utf8 :as utf8)
(import ./schema)

(def- projections `
CREATE TEMP VIEW unresolved_tools AS
  SELECT r.branch,r.id response,json_extract(c.value,'$.id') tool_id
  FROM memory_records r,json_each(r.data,'$.tools') c
  WHERE r.kind='response'
    AND r.id=(SELECT max(id) FROM memory_records WHERE branch=r.branch AND kind='response')
    AND NOT EXISTS(
      SELECT 1 FROM events e
      WHERE e.call=r.task AND e.kind IN ('tool-result','tool-ambiguity')
        AND json_extract(e.data,'$.tool-id')=json_extract(c.value,'$.id')
        AND json_extract(e.data,'$.response')=r.id
    );
CREATE TEMP VIEW invalid_summaries AS WITH RECURSIVE invalid(id) AS (
  SELECT n.id FROM events a JOIN events n ON n.id=json_extract(a.data,'$.invalidates') AND n.kind='summary'
  WHERE a.kind='artifact' AND json_type(a.data,'$.invalidates')='integer'
  UNION SELECT n.id FROM events n,json_each(n.data,'$.children') c JOIN invalid i ON i.id=c.value WHERE n.kind='summary'
)
SELECT id FROM invalid;
CREATE TEMP VIEW memory_records AS WITH records AS (
  SELECT e.id,e.call task,c.run,
    CASE WHEN c.kind='summarize' THEN c.parent ELSE c.id END branch,
    CASE WHEN e.kind='call-result' AND c.kind='code' THEN (
      SELECT id FROM events n WHERE n.call=c.id AND n.kind='call-attempt' ORDER BY id DESC LIMIT 1
    ) ELSE e.parent END parent,
    e.record_kind kind,e.text,e.data,e.estimate,e.author,e.at,e.created,e.body,e.memory,
    CASE WHEN json_type(e.data,'$.message')='object' THEN
      CASE WHEN json_extract(e.data,'$."reasoning-visible"') THEN json_remove(json_extract(e.data,'$.message'),'$.response')
        ELSE json_remove(json_extract(e.data,'$.message'),'$.response','$.reasoning','$.reasoning_content','$.reasoning_details') END
    END public_message
  FROM events e LEFT JOIN calls c ON c.id=e.call
)
SELECT e.*,b.temporary branch_temporary,b.parent branch_parent,
  g.request,CASE WHEN b.temporary=1 THEN 'tmp:'||g.request||'/'||b.id||':'||e.id END label
FROM records e LEFT JOIN main.call_controls b ON b.id=e.branch
LEFT JOIN main.call_controls g ON g.id=e.run;
CREATE TEMP VIEW conversation_records AS
  SELECT e.*,CASE WHEN kind='response' THEN json_remove(json_extract(data,'$.message'),'$.reasoning','$.reasoning_content')
    ELSE json_object('role','tool','tool_call_id',json_extract(data,'$.tool-id'),'content',text) END conversation_message
  FROM memory_records e
  WHERE kind='response' OR kind IN ('tool-result','tool-ambiguity') AND NOT EXISTS(
    SELECT 1 FROM events n WHERE n.call=e.task AND n.id>e.id AND n.kind IN ('tool-result','tool-ambiguity')
      AND json_extract(n.data,'$.response')=json_extract(e.data,'$.response')
      AND json_extract(n.data,'$.tool-id')=json_extract(e.data,'$.tool-id'));
`)

(defn- database [&opt temporary]
  (string `
CREATE TABLE world(id INTEGER PRIMARY KEY CHECK(id=1),file TEXT NOT NULL,origin TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(origin))) STRICT;
CREATE TABLE call_controls(
  id INTEGER PRIMARY KEY AUTOINCREMENT CHECK(id<=9007199254740991),
  request TEXT,
  parent INTEGER REFERENCES call_controls(id),
  root INTEGER REFERENCES call_controls(id),
  kind TEXT NOT NULL CHECK(kind IN ('text','code','summarize')),
  temporary INTEGER NOT NULL CHECK(temporary IN (0,1)),
  expires REAL,
  cancelled INTEGER NOT NULL DEFAULT 0 CHECK(cancelled IN (0,1)),
  state TEXT NOT NULL DEFAULT 'queued' CHECK(state IN ('queued','running','waiting','done','failed','cancelled','uncertain')),
  attempt INTEGER NOT NULL DEFAULT 0,
  owner TEXT,
  lease_expires REAL,
  retries INTEGER NOT NULL DEFAULT 1,
  key TEXT,
  work_used INTEGER NOT NULL DEFAULT 0,
  tool_used INTEGER NOT NULL DEFAULT 0,
  UNIQUE(request),
  UNIQUE(key)
) STRICT;
CREATE INDEX call_pending ON call_controls(state,id);
CREATE INDEX call_parent ON call_controls(parent,id);
CREATE VIEW live_calls AS
  SELECT c.*
  FROM call_controls c JOIN call_controls r ON r.id=coalesce(c.root,c.id)
  WHERE c.state IN ('running','waiting')
    AND c.lease_expires>unixepoch('subsec') AND (c.expires IS NULL OR c.expires>unixepoch('subsec'))
    AND (r.expires IS NULL OR r.expires>unixepoch('subsec')) AND NOT c.cancelled AND NOT r.cancelled;
CREATE VIEW running AS SELECT id FROM live_calls WHERE state='running';
PRAGMA user_version=1;
` (string/replace-all "$schema." "main."
                      (string/replace-all "$parent" (if temporary "" "REFERENCES events(id)") `
CREATE TABLE $schema.call_payloads(
  id INTEGER PRIMARY KEY,
  run INTEGER NOT NULL,
  config TEXT CHECK(config IS NULL OR json_valid(config)),
  entry INTEGER,
  first INTEGER NOT NULL,
  last INTEGER NOT NULL,
  history_last INTEGER NOT NULL,
  origin TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(origin)),
  agent INTEGER NOT NULL,
  depth INTEGER NOT NULL,
  checkpoint TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(checkpoint)),
  CHECK(first>=0 AND last>=first AND ((first=0 AND last=0) OR first>0))
) STRICT;
CREATE TABLE $schema.events(
  id INTEGER PRIMARY KEY AUTOINCREMENT CHECK(id<=9007199254740991),
  call INTEGER REFERENCES call_payloads(id),
  parent INTEGER $parent,
  kind TEXT NOT NULL,
  record_kind TEXT NOT NULL,
  memory INTEGER NOT NULL CHECK(memory IN (0,1)),
  text TEXT NOT NULL DEFAULT '',
  data TEXT NOT NULL CHECK(json_valid(data)),
  body TEXT GENERATED ALWAYS AS (CASE WHEN record_kind IN ('call-admission','operation-outcome','artifact','model-outcome','call-result')
    THEN text||char(10)||json_remove(data,'$.world') ELSE text END) VIRTUAL,
  author TEXT NOT NULL CHECK(length(author)>0),
  at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%fZ','now')) CHECK(strftime('%Y-%m-%dT%H:%M:%fZ',at) IS at),
  estimate INTEGER NOT NULL CHECK(estimate>=0),
  created REAL NOT NULL DEFAULT(unixepoch('subsec'))
) STRICT;
CREATE INDEX $schema.event_call ON events(call,id);
CREATE UNIQUE INDEX $schema.call_input ON events(call) WHERE kind IN ('user','summary-input');
CREATE UNIQUE INDEX $schema.call_entry ON events(call,json_extract(data,'$.attempt')) WHERE kind='call-attempt';
CREATE UNIQUE INDEX $schema.call_terminal ON events(call,json_extract(data,'$.attempt')) WHERE kind='call-result';
CREATE UNIQUE INDEX $schema.call_answer ON events(call)
  WHERE kind='model-outcome' AND json_extract(data,'$.turn')=1
    AND json_extract(data,'$.status') IN ('complete','refused','blocked');
CREATE UNIQUE INDEX $schema.tool_result ON events(parent) WHERE kind='tool-result';
CREATE TRIGGER $schema.immutable_events_update BEFORE UPDATE ON events
  BEGIN SELECT raise(ABORT,'immutable events'); END;
CREATE TRIGGER $schema.immutable_events_delete BEFORE DELETE ON events
  BEGIN SELECT raise(ABORT,'immutable events'); END;
CREATE TABLE $schema.images(
  event INTEGER NOT NULL REFERENCES events(id),
  position INTEGER NOT NULL,
  mime TEXT NOT NULL,
  bytes BLOB NOT NULL,
  PRIMARY KEY(event,position)
) WITHOUT ROWID;
CREATE TRIGGER $schema.immutable_images_update BEFORE UPDATE ON images
  BEGIN SELECT raise(ABORT,'immutable images'); END;
CREATE TRIGGER $schema.immutable_images_delete BEFORE DELETE ON images
  BEGIN SELECT raise(ABORT,'immutable images'); END;
CREATE TABLE $schema.usage(
  request INTEGER PRIMARY KEY REFERENCES events(id),
  provider TEXT NOT NULL,
  model TEXT NOT NULL,
  raw TEXT NOT NULL CHECK(json_valid(raw)),
  input INTEGER GENERATED ALWAYS AS (json_extract(raw,'$.prompt_tokens')) VIRTUAL,
  output INTEGER GENERATED ALWAYS AS (json_extract(raw,'$.completion_tokens')) VIRTUAL,
  total INTEGER GENERATED ALWAYS AS (json_extract(raw,'$.total_tokens')) VIRTUAL,
  reasoning INTEGER GENERATED ALWAYS AS (json_extract(raw,'$.completion_tokens_details.reasoning_tokens')) VIRTUAL,
  cached INTEGER GENERATED ALWAYS AS (json_extract(raw,'$.prompt_tokens_details.cached_tokens')) VIRTUAL
) STRICT;
CREATE TABLE $schema.previews(
  id INTEGER PRIMARY KEY AUTOINCREMENT,request INTEGER NOT NULL REFERENCES events(id),
  delta TEXT NOT NULL CHECK(json_valid(delta))
) STRICT;
CREATE INDEX $schema.preview_request ON previews(request,id);
CREATE UNIQUE INDEX $schema.model_terminal ON events(parent) WHERE kind='model-outcome';
CREATE TRIGGER $schema.event_kind BEFORE INSERT ON events
  WHEN new.kind NOT IN (
    'user','summary-input','call-attempt','call-result','code-admission','tool-result','tool-ambiguity',
    'model-admission','model-outcome','call-admission','launch-uncertain','summary','interruption',
    'cancelled','artifact','context','save-intent','saved','operation-outcome'
  )
  BEGIN SELECT raise(ABORT,'unsupported event kind'); END;
CREATE UNIQUE INDEX $schema.summary_call ON events(call) WHERE kind='summary';
CREATE INDEX $schema.summary_key ON events(json_extract(data,'$.policy'),json_extract(data,'$.children'))
  WHERE kind='summary';
CREATE INDEX $schema.summary_start ON events(json_extract(data,'$.first')) WHERE kind='summary';
CREATE INDEX $schema.summary_invalidations ON events(id)
  WHERE kind='artifact' AND json_type(data,'$.invalidates')='integer';
CREATE VIEW $schema.search_records AS SELECT id,body FROM events WHERE memory;
CREATE VIRTUAL TABLE $schema.event_fts USING fts5(
  body,content='search_records',content_rowid='id',tokenize='unicode61 remove_diacritics 0'
);
CREATE VIRTUAL TABLE $schema.event_words USING fts5vocab(event_fts,'row');
CREATE TRIGGER $schema.event_index AFTER INSERT ON events BEGIN
  INSERT INTO event_fts(rowid,body) SELECT id,body FROM search_records WHERE id=new.id;
END;
CREATE UNIQUE INDEX $schema.context_key ON events(json_extract(data,'$.key')) WHERE kind='context';
`))))

(def interval 0.1)
(defn estimate [bytes] (math/ceil (/ (length bytes) 4)))
(defn query [s statement &opt parameters] (sql/eval (s :db) statement (or parameters [])))

(defmacro transact [s & body]
  (def db (gensym))
  ~(let [,db (,s :db)]
     (if (= ,db (dyn :zinc/transaction)) (do ,;body)
       (do
         (,sql/eval ,db (if (,s :temporary) "BEGIN" "BEGIN IMMEDIATE"))
         (try
           (let [result (with-dyns [:zinc/transaction ,db] ,;body)] (,sql/eval ,db "COMMIT") result)
           ([err] (,sql/eval ,db "ROLLBACK") (error err)))))))

(defn uri [file]
  (def file (if (index-of (os/which) [:windows :mingw]) (string/replace-all "\\" "/" file) file))
  (string "file:" (string/replace-all "?" "%3F" (string/replace-all "#" "%23" (string/replace-all "%" "%25" file)))))

(defn open [config &opt mode]
  (def temporary (or (= mode :temporary) (not (nil? (get-in config [:snapshot :database])))))
  (def file (or (get-in config [:snapshot :database]) (uri (config :store))))
  (def s @{:db (sql/open (if (index-of mode [:observe :worker])
                         (string file (if temporary "&" "?") "mode=" (if (= mode :observe) "ro" "rw")) file))
           :file file :config config :temporary temporary :worlds @{} :profiles @{} :recovery @[0]})
  (try
    (do
      (query s "PRAGMA foreign_keys=ON; PRAGMA trusted_schema=OFF; PRAGMA busy_timeout=5000; PRAGMA temp_store=MEMORY;")
      (unless (index-of mode [:observe :worker])
        (if temporary
          (do
            (query s (database true))
            (query s (string "PRAGMA max_page_count=" (math/floor (/ (config :journal-bytes) (((query s "PRAGMA page_size") 0) :page_size))))))
          (do
            (query s "PRAGMA synchronous=FULL; PRAGMA journal_mode=WAL;")
            (unless (= 1 (((query s "PRAGMA user_version") 0) :user_version))
              (transact s
                (def version (((query s "PRAGMA user_version") 0) :user_version))
                (assert (index-of version [0 1]) "unsupported Zinc database; preserve it and provision a fresh database")
                (when (= version 0) (query s (database)))))
            (query s "INSERT INTO main.world(id,file) VALUES(1,?) ON CONFLICT(id) DO NOTHING" [(config :world)]))))
      (when temporary
        (query s "ATTACH DATABASE ? AS archive" [(string (uri (config :store)) "?mode=ro")])
        (when (= mode :temporary)
          (transact s
            (each name ["world" "call_controls"]
              (query s (string "INSERT INTO main." name " SELECT * FROM archive." name)))
            (put (config :snapshot) :archive-last (((query s "SELECT coalesce(max(id),0) n FROM archive.events") 0) :n))
            (put (config :snapshot) :controls-last (((query s "SELECT coalesce(max(id),0) n FROM main.call_controls") 0) :n))
            (query s "INSERT INTO main.sqlite_sequence(name,seq) VALUES('events',?)" [(get-in config [:snapshot :archive-last])])
            (query s "UPDATE main.call_controls SET state='done',owner=NULL,lease_expires=NULL;")))
        (put s :archive-last (get-in config [:snapshot :archive-last]))
        (each [name key cutoff] [["call_payloads" "id" (get-in config [:snapshot :controls-last])]
                                ["events" "id" (s :archive-last)] ["images" "event" (s :archive-last)] ["usage" "request" (s :archive-last)]]
          (query s (string "CREATE TEMP VIEW " name " AS SELECT * FROM archive." name " WHERE " key "<=" cutoff
                           " UNION ALL SELECT * FROM main." name)))
        (query s (string `CREATE VIRTUAL TABLE temp.archive_words USING fts5vocab(archive,event_fts,'instance');
          CREATE TEMP VIEW event_words AS SELECT term FROM archive_words WHERE doc<=` (s :archive-last) `
            UNION SELECT term FROM main.event_words;`)))
      (assert (first (query s "SELECT name FROM pragma_table_info('events') WHERE name='record_kind'")) "incompatible Zinc layout; preserve it and provision a fresh database")
      (assert (= (config :world) (((query s "SELECT file FROM main.world WHERE id=1") 0) :file)) "history database belongs to another world")
      (query s (string `CREATE TEMP VIEW calls AS SELECT c.id,c.parent,c.root,c.kind,c.temporary,c.expires,c.cancelled,
        c.state,c.attempt,c.owner,c.lease_expires,c.retries,c.key,c.work_used,c.tool_used,c.request request_key,
        coalesce(p.run,c.id) run,g.request request,coalesce(p.config,r.config) config,p.entry,p.first,p.last,p.history_last,p.origin,p.agent,p.depth,p.checkpoint,
        a.id admission,json_extract(a.data,'$.input') input FROM main.call_controls c
        LEFT JOIN call_payloads p ON p.id=c.id LEFT JOIN call_payloads r ON r.id=p.run
        LEFT JOIN main.call_controls g ON g.id=coalesce(p.run,c.id)
        LEFT JOIN events a ON a.call=c.id AND a.kind IN ('user','summary-input');`))
      (query s projections)
      (when (and (not= mode :observe) (get-in config [:snapshot :budget-root]))
        (put s :external-root (get-in config [:snapshot :budget-root]))
        (put s :budget-db (sql/open (string (uri (config :store)) "?mode=rw")))
        (sql/eval (s :budget-db) "PRAGMA busy_timeout=5000;"))
      (when (= mode :observe) (query s "PRAGMA query_only=ON;"))
      s)
    ([err]
      (each key [:budget-db :db] (when (s key) (sql/close (s key))))
      (error err))))

(defn close [s]
  (each key [:budget-db :db] (when (s key) (sql/close (s key)) (put s key nil))))

(defn charge [s work tokens]
  (assert (first (sql/eval (or (s :budget-db) (s :db)) `UPDATE main.call_controls SET work_used=work_used+?,tool_used=tool_used+? WHERE id=?
    AND (?=0 OR (expires IS NULL OR expires>?) AND NOT cancelled) AND work_used+?<=? AND tool_used+?<=? RETURNING id`
                        [work tokens (or (s :external-root) (s :budget-root)) work (os/clock) work ((s :config) :task-quota) tokens ((s :config) :tool-quota)])) "shared call budget exhausted"))

(defn call [s id]
  (def row (first (query s "SELECT * FROM calls WHERE id=?" [id])))
  (assert row "call unavailable") row)

(defn result [s id]
  (def row (call s id))
  (def result (first (query s "SELECT data FROM events WHERE call=? AND kind='call-result' ORDER BY id DESC LIMIT 1" [id])))
  (def data (when result (json/decode (result :data) true true)))
  (merge {:run (row :run) :branch id :state (row :state)
          :value (if (and (= "done" (row :state)) (= "text" (row :kind)))
                   {:text ((first (query s "SELECT text FROM memory_records WHERE branch=? AND kind='completed' ORDER BY id DESC LIMIT 1" [id])) :text)}
                   (get data :value :null))}
         (if (get data :error) {:error (data :error)} {})))

(defn origin [s &opt id]
  (json/decode (if id ((call s id) :origin) (((query s "SELECT origin FROM main.world WHERE id=1") 0) :origin)) true true))

(defn append [s scope kind text &opt data parent execution]
  (transact s
            (assert (and (string? text) (utf8/is-valid? text)) "invalid event text")
            (def context (when (scope :branch) (call s (scope :branch))))
            (def task (if (and execution (not= execution (scope :branch))) (call s execution) context))
            (def data (or data {}))
            (def record-kind (cond
              (and (= kind "model-outcome") (data :turn)) (if (index-of (data :status) ["complete" "refused" "blocked"]) "completed" "response")
              (and (= kind "call-result") (dictionary? (data :error))) "error"
              (and (= (get task :kind) "code") (or (= kind "call-attempt") (and (= kind "call-result") (= (data :state) "done"))))
              (if (= kind "call-attempt") "code-admission" "completed") kind))
            (def memory (case record-kind
              "error" (not= (get task :kind) "summarize") "interruption" (not= (get task :kind) "summarize")
              "artifact" (not (has-key? data :invalidates))
              (not (nil? (index-of record-kind ["user" "context" "response" "completed" "code-admission" "tool-result" "tool-ambiguity"
                                               "call-admission" "operation-outcome" "cancelled" "save-intent" "saved"])))))
            (def encoded (string (json/encode (merge data {:world (json/decode (if context (context :origin) (((query s "SELECT origin FROM main.world WHERE id=1") 0) :origin)) true true)}))))
            (assert (utf8/is-valid? encoded) "stored event must be UTF-8 JSON")
            (when (index-of kind ["call-admission" "operation-outcome"]) (charge s 0 (estimate (string text encoded))))
            (def row ((query s "INSERT INTO main.events(call,parent,kind,record_kind,memory,text,data,estimate,author,at) VALUES(?,?,?,?,?,?,?,?,?,coalesce(?,strftime('%Y-%m-%dT%H:%M:%fZ','now'))) RETURNING *"
                             [(or execution (scope :branch)) parent kind record-kind (if memory 1 0) text encoded (estimate (string text encoded))
                              (or (scope :author) (if context (string "self:" (context :request) "/" (context :id)) "system:zinc")) (scope :at)]) 0))
            row))

(defn record [s records]
  (assert (and (indexed? records) (<= (length records) ((s :config) :history-records))) "invalid context batch")
  (transact s
            (map (fn [record]
                   (assert (and (dictionary? record) (= (tuple/slice (sorted (keys record))) [:at :author :key :text])) "invalid context record")
                   (each key [:at :author :key :text] (assert (and (string? (record key)) (> (length (record key)) 0)) "invalid context field"))
                   (assert (<= (length (record :key)) 256) "context key byte ceiling")
                   (def data @{:key (record :key)})
                   (def previous (first (query s `SELECT *,json_remove(data,'$.world') payload FROM events WHERE kind='context' AND json_extract(data,'$.key')=?` [(record :key)])))
                   (if previous
                     (do (assert (and (= (previous :text) (record :text)) (= (previous :author) (record :author)) (= (previous :at) (record :at))
                                      (deep= (json/decode (previous :payload) true true) data)) "context key reused with different data") (previous :id))
                     ((append s {:author (record :author) :at (record :at)} "context" (record :text) data) :id))) records)))

(defn visible [s view &opt order ceiling]
  (if (and (s :temporary) (view :match) (not (view :index)))
    (take (or ceiling 4096)
      (sorted (array/concat @[]
        (visible s (merge view {:index "archive" :last (min (view :last) (s :archive-last))}) order ceiling)
        (visible s (merge view {:index "main" :first (max (view :first) (+ 1 (s :archive-last)))}) order ceiling))
        |(if (= order :recent) (> ($0 :id) ($1 :id)) (< ($0 :id) ($1 :id)))))
    (query s (string `WITH RECURSIVE ancestry(id,through) AS (
    SELECT ?,9007199254740991 UNION ALL SELECT c.parent,min(a.through,c.last) FROM calls c JOIN ancestry a ON c.id=a.id WHERE c.parent IS NOT NULL
  ), members(id) AS (SELECT ? UNION SELECT c.value FROM members m JOIN events n ON n.id=m.id,json_each(n.data,'$.children') c WHERE n.kind='summary')
  SELECT ` (get view :columns "e.*") ` FROM `
                   (if (view :match) (string (get view :index "main") ".event_fts JOIN memory_records e ON e.id=event_fts.rowid") "memory_records e")
                   ` LEFT JOIN main.call_controls b ON b.id=e.branch WHERE `
                   (when (view :match) "event_fts MATCH ? AND ")
                   `e.id BETWEEN ? AND ? AND (e.id<=? OR (e.run=? AND EXISTS(SELECT 1 FROM ancestry a WHERE a.id=e.branch AND e.id<=a.through)))
    AND (e.kind='context' OR b.temporary=0 OR b.id IN (SELECT id FROM ancestry) OR (? AND e.id<=?))
    AND (? IS NULL OR e.kind IN (SELECT value FROM json_each(?))) AND e.id NOT IN (SELECT value FROM json_each(?))`
                   (when (view :memory) " AND e.memory") " ORDER BY "
                   "e.id " (if (= order :recent) "DESC" "ASC") " LIMIT ?")
         (array/concat @[(view :branch) (view :root)] (if (view :match) [(view :match)] [])
                       [(view :first) (view :last)
                        (get view :history-last (view :last)) (view :run) (if (s :temporary) 1 0) (get view :history-last (view :last))
                        (when (view :kinds) 1) (string (json/encode (view :kinds))) (string (json/encode (get view :exclude []))) (or ceiling 4096)]))))

(defn event [s view id]
  (def row (first (visible s (merge view {:first id :last id}))))
  (assert (and (<= (view :first) id (view :last)) row) "event outside granted history") row)

(defn checkpoint [s &opt value]
  (def current (dyn :zinc/call))
  (assert current "checkpoint requires an executing call")
  (when (s :budget-db)
    (assert (first (sql/eval (s :budget-db) "SELECT id FROM live_calls WHERE id=?" [(s :external-root)])) "parent execution ended"))
  (if value
    (let [encoded (string (json/encode value))]
      (assert (<= (length encoded) (+ ((s :config) :request-bytes) ((s :config) :response-bytes))) "stored checkpoint byte ceiling")
      (assert (first (query s "UPDATE main.call_payloads SET checkpoint=? WHERE id IN (SELECT id FROM main.live_calls WHERE id=? AND owner=?) RETURNING id"
                            [encoded (current :id) (current :owner)])) "call lease lost")
      (put current :checkpoint value))
    (assert (first (query s "SELECT id FROM main.live_calls WHERE id=? AND owner=?" [(current :id) (current :owner)])) "call lease lost")))

(defn publish [s candidate]
  (checkpoint s)
  (def row (call s ((dyn :zinc/call) :id)))
  (assert (= 0 (row :cancelled)) "call cancelled")
  (def updated (string (json/encode candidate)))
  (when (and (nil? (row :parent)) (= 0 (row :temporary)) (nil? ((json/decode (row :input) true true) :revision)))
    (assert (first (query s "UPDATE main.world SET origin=? WHERE id=1 AND origin=? RETURNING id"
                          [updated (row :origin)])) "world changed; retry against the current world"))
  (query s "UPDATE main.call_payloads SET origin=? WHERE id=?" [updated (row :id)])
  (put (dyn :zinc/call) :candidate nil))

(defn view [s id &opt active]
  (default active true)
  (def c (call s id))
  (def view {:run (c :run) :branch id :first (c :first) :last (c :last) :expires (c :expires)
             :history-last (c :history_last) :agent (= 1 (c :agent)) :depth (c :depth)})
  (if active (merge view {:first (if (= 0 (view :first)) (c :admission) (view :first))
                          :last (get (first (visible s (merge view {:last 9007199254740991 :columns "e.id"}) :recent 1)) :id (view :last))}) view))

(defn park [s waiting]
  (def current (dyn :zinc/call))
  (checkpoint s)
  (if waiting
    (first (query s "UPDATE main.call_controls SET state='waiting' WHERE id=? AND owner=? AND state='running' RETURNING id" [(current :id) (current :owner)]))
    (while (and (= 0 (get current :waiters 0))
                (= "waiting" (get (first (query s "SELECT state FROM main.call_controls WHERE id=?" [(current :id)])) :state)))
      (checkpoint s)
      (when (first (query s "UPDATE main.call_controls SET state='running' WHERE id=? AND owner=? AND state='waiting' AND (SELECT count(*) FROM running)<? RETURNING id"
                          [(current :id) (current :owner) ((s :config) :parallel)])) (break))
      (ev/sleep interval))))

(defn claim [s id]
  (transact s
    (when (first (query s `UPDATE main.call_controls SET state='running',attempt=attempt+1,owner=?,lease_expires=?
      WHERE id=? AND state='queued' AND (expires IS NULL OR expires>?) AND NOT cancelled
      AND EXISTS(SELECT 1 FROM main.call_controls r WHERE r.id=coalesce(call_controls.root,call_controls.id) AND (r.expires IS NULL OR r.expires>?) AND NOT r.cancelled)
      AND (parent IS NOT NULL OR temporary=1 OR NOT EXISTS(SELECT 1 FROM main.call_controls c
        WHERE c.id<>call_controls.id AND c.parent IS NULL AND c.temporary=0 AND NOT c.cancelled AND c.state IN ('running','waiting','uncertain')))
      AND (SELECT count(*) FROM running)<? RETURNING id`
                        [(base64/encode (string (os/cryptorand 24))) (+ (os/clock) ((s :config) :lease-seconds)) id (os/clock) (os/clock) ((s :config) :parallel)]))
      (def row (call s id))
      (when (and (nil? (row :parent)) (= 0 (row :temporary)) (= 1 (row :attempt))
                 (nil? ((json/decode (row :input) true true) :revision)))
        (query s "UPDATE main.call_payloads SET origin=(SELECT origin FROM main.world WHERE id=1) WHERE id=?" [id]))
      (call s id))))

(defn heartbeat [[file seconds id owner stop]]
  (def db (sql/open (string file (if (string/find "?" file) "&" "?") "mode=rw")))
  (defer (sql/close db)
    (sql/eval db "PRAGMA busy_timeout=5000;")
    (try (while true
           (assert (first (sql/eval db "UPDATE call_controls SET lease_expires=? WHERE id IN (SELECT id FROM live_calls WHERE id=? AND owner=?) RETURNING id"
                                    [(+ (os/clock) seconds) id owner])) "execution fenced")
           (def tick (ev/chan 1))
           (def done (ev/chan 1))
           (def timer (ev/go (fn [] (ev/sleep (/ seconds 3)) (ev/give tick true)) nil done))
           (def stopped (= stop ((ev/select stop tick) 1)))
           (when stopped (ev/cancel timer :finished))
           (ev/take done)
           (when stopped (break))) ([err] nil))))

(defn finish [s row value failure]
  (transact s
            (def owner (first (query s `UPDATE main.call_controls SET state=CASE WHEN state='cancelled' THEN state WHEN ? THEN 'failed' ELSE 'done' END,
              owner=NULL,lease_expires=NULL WHERE id=? AND owner IS ?
              AND (state IN ('running','waiting','uncertain','cancelled') OR (? AND state='queued' AND attempt=0)) RETURNING state`
                                     [(not (nil? failure)) (row :id) (row :owner) (not (nil? failure))])))
            (assert owner "call completion fenced")
            (def state (owner :state))
            (def outcome (merge {:ok (= state "done") :value (if (nil? value) :null value) :state state :attempt (row :attempt)} (or failure {})))
            (append s (view s (if (= "summarize" (row :kind)) (row :parent) (row :id))) "call-result"
                    (if failure (get-in failure [:error :message]) (if (string? value) value "")) outcome nil (row :id))
            outcome))

(defn start [s input config &opt caller origin key]
  (def summary (has-key? input :children))
  (def admitted (schema/project input [:after :images] true))
  (default key (when caller (string (json/encode ["child" (caller :branch) (caller :event)]))))
  (transact s
    (when (dyn :zinc/call) (checkpoint s))
    (def previous (first (query s "SELECT * FROM calls WHERE (? IS NOT NULL AND request_key=?) OR (? IS NOT NULL AND key=?)"
                               [(input :request) (input :request) key key])))
    (if previous
      (do
        (assert (= 0 (previous :cancelled)) "call cancelled")
        (assert (deep= admitted (json/decode (previous :input) true true)) "request ID reused with different work")
        (assert (deep= (query s "SELECT mime AS type,bytes FROM images WHERE event=? ORDER BY position" [(previous :admission)]) (get input :images @[])) "request ID reused with different images")
        (merge previous {:owner nil}))
      (do
        (def latest (first (query s "SELECT e.id FROM memory_records e LEFT JOIN main.call_controls c ON c.id=e.branch WHERE e.kind='context' OR c.temporary=0 ORDER BY e.id DESC LIMIT 1")))
        (def entry (unless summary (get input :parent (if caller (caller :last) (get latest :id 0)))))
        (def last (if summary (caller :last) (get-in input [:memory_range :end] entry)))
        (def earliest (first (query s "SELECT min(id) id FROM memory_records WHERE id<=? AND (kind='context' OR branch IN (SELECT id FROM main.call_controls WHERE temporary=0) AND kind IN ('user','response','completed','tool-result'))" [last])))
        (def first-id (if summary (caller :first) (get-in input [:memory_range :start] (if (= last 0) 0 (if caller (caller :first) (or (earliest :id) last))))))
        (def allowed (or caller {:first 1 :last 9007199254740991}))
        (assert (and (<= 0 first-id last) (= (= first-id 0) (= last 0))) "invalid history range")
        (each id (if summary [] [entry first-id last]) (when (> id 0) (event s allowed id)))
        (when caller (assert (or (= last 0) (<= (caller :first) first-id last (caller :last))) "child history exceeds caller view"))
        (def saved (unless caller (merge config)))
        (when saved
          (when (saved :agent) (put saved :agent (merge (saved :agent))))
          (each profile (filter identity [saved (saved :agent)])
            (put profile :snapshot nil)))
        (def temporary (if (s :temporary) 1 0))
        (when caller (assert (or (= temporary 1) (= 0 ((call s (caller :branch)) :temporary))) "temporary calls cannot create durable descendants"))
        (def depth (if summary (caller :depth) (if caller (+ 1 (caller :depth)) (get-in config [:snapshot :depth] 0))))
        (assert (<= depth (config :task-depth)) "agent recursion ceiling exhausted")
        (def id (((query s "INSERT INTO main.call_controls(request,parent,root,kind,temporary,expires,key,retries) VALUES(?,?,?,?,?,?,?,?) RETURNING id"
                         [(input :request) (or (get-in (dyn :zinc/call) [:id]) (when caller (caller :branch)))
                          (s :budget-root) (cond summary "summarize" (input :code) "code" "text") temporary
                          (if caller (caller :expires)
                            (let [deadline (min (if (= 0 (config :run-seconds)) math/inf (+ (os/clock) (config :run-seconds))) (or (get-in config [:snapshot :deadline]) math/inf))]
                              (unless (= deadline math/inf) deadline))) key (if (= false (input :queue)) 0 1)]) 0) :id))
        (unless (s :budget-root) (put s :budget-root id))
        (def run (if caller (caller :run) id))
        (query s "INSERT INTO main.call_payloads(id,run,config,entry,first,last,history_last,origin,agent,depth) VALUES(?,?,?,?,?,?,?,?,?,?)"
               [id run (when (and saved (not summary)) (string (json/encode saved))) entry first-id last (if caller (caller :history-last) last)
                (string (json/encode (or origin {}))) (if (and caller (caller :agent)) 1 0) depth])
        (def input-event (append s {:branch id :author (input :author) :at (input :at)} (if summary "summary-input" "user") (get input :text (get input :code "")) {:input admitted} (when (and entry (> entry 0)) entry) id))
        (var image-bytes 0)
        (eachp [position image] (get input :images [])
          (def bytes (image :bytes)) (+= image-bytes (length bytes))
          (assert (<= image-bytes (config :image-bytes)) "stored image byte ceiling")
          (query s "INSERT INTO main.images(event,position,mime,bytes) VALUES(?,?,?,?)" [(input-event :id) position (image :type) (buffer bytes)]))
        (charge s 1 (if (input :code) (estimate (input :code)) 0))
        (if (= false (input :queue))
          (or (claim s id)
              (do (finish s (call s id) nil {:error {:code "AgentBusy" :message "Target cannot start immediately."}}) (call s id)))
          (call s id))))))

(defn recover [s]
  (def now (os/clock))
  (def recovery-query `SELECT c.*,min(coalesce(c.expires,1e999),coalesce(r.expires,1e999))<=? expired,
    EXISTS(SELECT 1 FROM events a WHERE a.id=json_extract(p.checkpoint,'$.request') AND a.kind='model-admission'
      AND NOT EXISTS(SELECT 1 FROM events o WHERE o.parent=a.id AND o.kind='model-outcome')) pending_model,
    json_extract(p.checkpoint,'$.runtime') native_runtime
    FROM main.call_controls c JOIN main.call_controls r ON r.id=coalesce(c.root,c.id)
    LEFT JOIN call_payloads p ON p.id=c.id
    WHERE (?=0 OR c.temporary=1) AND
    (c.state IN ('queued','running','waiting') AND min(coalesce(c.expires,1e999),coalesce(r.expires,1e999))<=? OR c.state IN ('running','waiting') AND c.lease_expires<=?) ORDER BY c.id`)
  (def recovery-parameters [now (if (s :temporary) 1 0) now now])
  (when (first (query s (string recovery-query " LIMIT 1") recovery-parameters))
    (transact s
      (each row (query s recovery-query recovery-parameters)
        (def expired (= 1 (row :expired)))
        (def unstarted (and expired (= 0 (row :attempt))))
        (def retry (and (= 0 (row :temporary)) (not expired) (not= "code" (row :kind)) (> (row :retries) 0) (= 0 (row :pending_model)) (not= 1 (row :native_runtime))))
        (def state (cond unstarted "cancelled" retry "queued" "uncertain"))
        (when (= 0 (row :temporary))
          (append s (view s (if (= "summarize" (row :kind)) (row :parent) (row :id))) "interruption"
                  (if unstarted "Deadline expired before execution." "Interrupted execution; effects may have happened.")
                  {:state state :attempt (row :attempt)} nil (row :id)))
        (query s "UPDATE main.call_controls SET state=?,retries=retries-?,owner=CASE WHEN ? THEN NULL ELSE owner END,lease_expires=CASE WHEN ? THEN NULL ELSE lease_expires END WHERE id=?"
               [state (if retry 1 0) (or retry unstarted) (or retry unstarted) (row :id)])))))

(defn abort [s value]
  (assert (and (not= (nil? (value :run)) (nil? (value :request))) (string? (value :reason)) (<= (length (value :reason)) 2048)) "abort requires run or request and reason")
  (transact s
            (when (value :request)
              (query s "INSERT INTO main.call_controls(request,kind,temporary,expires,state,cancelled) VALUES(?,'text',0,?,'cancelled',1) ON CONFLICT(request) DO NOTHING"
                     [(value :request) (os/clock)]))
            (def row (first (query s "SELECT * FROM calls WHERE request_key IS NOT NULL AND (id=? OR request_key=?)" [(value :run) (value :request)])))
            (assert row "run unavailable")
            (def completed (= "done" (row :state)))
            (unless completed
              (query s "UPDATE main.call_controls SET cancelled=1 WHERE id=?" [(row :id)])
              (def affected (query s `UPDATE main.call_controls SET state='cancelled' WHERE state IN ('queued','running','waiting','uncertain')
        AND (id=? OR root=? AND (?=0 OR temporary=1)) RETURNING id,kind,attempt`
                                   [(row :id) (or (row :root) (row :id)) (row :temporary)]))
              (when (and (= 0 (row :temporary)) (row :admission)
                         (not (first (query s "SELECT id FROM events WHERE call=? AND kind='cancelled'" [(row :id)]))))
                (append s {:branch (row :id)} "cancelled" "Interrupted. Performed effects are not rolled back; running effects may still finish."
                        {:reason (value :reason) :tasks-at-request affected})))
            {:run (row :id) :state (if completed "completed" "cancelled")}))
