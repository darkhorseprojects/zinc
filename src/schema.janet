(import spork/path :as path)
(import spork/base64 :as base64)

(defn project [value fields &opt omit]
  (tabseq [[key item] :pairs value :when (if omit (nil? (index-of key fields)) (index-of key fields))] key item))

(defn validate [schema supplied &opt discovery]
  (assert (dictionary? supplied) "configuration must be an object")
  (def config @{})
  (each key (keys supplied) (assert (has-key? schema key) (string "unknown configuration field " key)))
  (each [key field] (pairs schema) (when (has-key? field :default) (put config key (field :default))))
  (merge-into config supplied)
  (each [key field] (pairs schema)
    (assert (or discovery (has-key? config key) (field :optional)) (string "required setting " key))
    (when (has-key? config key)
      (def value (config key))
      (assert (case (field :type)
                :string (and (string? value) (> (length value) 0) (not (string/find "\0" value)))
                :integer (int? value) :number (and (number? value) (< (math/abs value) math/inf))
                :boolean (boolean? value) :array (indexed? value) :dictionary (dictionary? value) false)
              (string "invalid setting " key))
      (when (field :minimum) (assert (>= (if (indexed? value) (length value) value) (field :minimum)) "setting below minimum"))
      (when (field :maximum) (assert (<= (if (indexed? value) (length value) value) (field :maximum)) "setting above maximum"))
      (when (and (field :absolute) (not discovery)) (assert (path/abspath? value) "absolute path required"))
      (when (field :fields) (put config key (validate (field :fields) value discovery)))
      (when (field :values)
        (put config key (tabseq [[name item] :in (pairs value)] name ((validate {name (field :values)} {name item} discovery) name))))
      (each item (if (= :array (field :type)) value [value])
        (when (and (= :array (field :type)) (= :string (field :items)))
          (assert (and (string? item) (> (length item) 0) (not (string/find "\0" item))) "invalid array item"))
        (when (field :choices) (assert (index-of item (field :choices)) "invalid setting choice")))))
  config)

(defn select [names selections]
  (sorted (distinct (catseq [selection :in selections]
                      (def matches (filter |(or (= selection "*") (= selection $)
                                                (and (string/has-suffix? "/*" selection)
                                                     (string/has-prefix? (string/slice selection 0 (- (length selection) 1)) $))) names))
                      (assert (> (length matches) 0) (string "unknown selection: " selection))
                      matches))))

(defn configuration [schema supplied &opt discovery]
  (def config (validate schema supplied discovery))
  (when (config :context-quota)
    (assert (<= (config :summary-quota) (config :context-quota)) "summary quota exceeds context quota"))
  (when (config :agent)
    (assert (not (get-in config [:agent :agent])) "nested execution profiles are not supported")
    (put config :agent (configuration schema (config :agent) discovery))
    (each key [:store :world]
      (assert (= (config key) (get-in config [:agent key])) "agent view changes world identity/location")))
  (when-let [repl (config :repl)]
    (put repl :values (select (seq [[key field] :in (pairs schema) :when (field :visible)] (string key)) (repl :values)))
    (each name (keys (repl :imports))
      (assert (and (peg/match ~(* (some (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")) -1) (string name))
                   (not (index-of name [:core :self :pa :fs :http :process :memory :world :zinc]))) "invalid module namespace")))
  (each field [:fs :http :processes]
    (each name (keys (config field))
      (assert (peg/match ~(* (some (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")) -1) (string name)) "invalid resource name")))
  (each [name command] (pairs (config :processes))
    (unless discovery (assert (path/abspath? ((command :argv) 0)) "process executable must be absolute"))
    (each key (keys (command :env)) (assert (not (string/find "=" (string key))) "invalid environment name")))
  (each [name endpoint] (pairs (config :http))
    (def url (endpoint :url))
    (assert (and (peg/match ~(* (choice "https://" "http://")
                                (some (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]"))
                                "/" (any (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-~./")) -1) url)
                 (string/has-suffix? "/" url)
                 (not (find |(index-of $ ["." ".."]) (string/split "/" url)))) "invalid HTTP base"))
  (each [name provider] (pairs (config :providers))
    (assert (index-of name [:llama :openrouter]) "unsupported provider")
    (assert (peg/match ~(* (choice "https://" "http://") (some (if-not (set "?#@ \t\r\n") 1)) -1) (provider :url)) "invalid provider base"))
  config)

(defn authorize [schema current saved]
  (each key (keys saved) (assert (has-key? schema key) "unsupported saved configuration"))
  (each key [:store :world :instructions :identity :ephemeral]
    (assert (= (current key) (saved key)) "saved identity/location differs"))
  (each key [:inference :web-search]
    (assert (or (not (saved key)) (current key)) (string "saved permission revoked: " key)))
  (assert (or (not (saved :repl)) (current :repl)) "saved REPL revoked")
  (assert (= (get-in saved [:repl :setup]) (get-in current [:repl :setup])) "saved REPL setup changed")
  (each key [:bindings :values]
    (each name (get-in saved [:repl key] [])
      (assert (index-of name (get-in current [:repl key])) "saved REPL selection revoked")))
  (each field [:fs :http :processes]
    (each [name grant] (pairs (saved field))
      (assert (deep= grant (get-in current [field name])) "saved resource changed or revoked")))
  (each [name module] (pairs (get-in saved [:repl :imports] {}))
    (assert (deep= module (get-in current [:repl :imports name])) "saved import changed or revoked"))
  (when (saved :agent) (assert (current :agent) "agent execution view revoked"))
  (each [name provider] (pairs (saved :providers))
    (def granted (get-in current [:providers name]))
    (assert (and granted (deep= provider granted)) "saved provider changed or revoked"))
  (def config (merge saved {:memory-retrieval (and (saved :memory-retrieval) (current :memory-retrieval))
                            :score (max (saved :score) (current :score))
                            :agent (when (saved :agent) (authorize schema (current :agent) (saved :agent)))
                            :providers (tabseq [name :in (keys (saved :providers))] name (get-in current [:providers name]))}))
  (each [key field] (pairs schema)
    (when (and (= :integer (field :type)) (or (saved key) (current key)))
      (put config key
           (if (and (field :unlimited) (= 0 (min (get saved key math/inf) (get current key math/inf))))
             (max (saved key) (current key))
             (min (get saved key math/inf) (get current key math/inf))))))
  config)

(defn data [value]
  (postwalk |(if (dictionary? $) (tabseq [[key item] :in (pairs $)] key item) $) value))

(defn request [value fields]
  (assert (dictionary? value) "request must be an object")
  (each key (keys value) (assert (index-of key fields) "unknown request field"))
  (each key [:text :code]
    (when (has-key? value key) (assert (and (string? (value key)) (> (length (value key)) 0)) "invalid inquiry")))
  (each key [:request :author :at :owner :revision]
    (when (has-key? value key)
      (assert (and (string? (value key)) (<= 1 (length (value key)) 256) (not (string/find "\0" (value key)))) "invalid request name")))
  (each key [:persist :queue]
    (when (has-key? value key) (assert (boolean? (value key)) (string "invalid " key " flag"))))
  (when (has-key? value :images)
    (assert (and (indexed? (value :images)) (<= (length (value :images)) 4)) "invalid images")
    (put value :images (map (fn [image]
                              (assert (and (dictionary? image) (deep= (sorted (keys image)) (sorted [:type :data]))
                                           (index-of (image :type) ["image/png" "image/jpeg" "image/webp"]) (string? (image :data))) "invalid image")
                              {:type (image :type) :bytes (buffer (base64/decode (image :data)))}) (value :images))))
  value)

(def projections `
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
      CASE WHEN json_extract(e.data,'$."reasoning-visible"') THEN json_extract(e.data,'$.message')
        ELSE json_remove(json_extract(e.data,'$.message'),'$.reasoning','$.reasoning_content','$.reasoning_details') END
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

(defn database [&opt temporary]
  (string (unless temporary `
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
`) (string/replace-all "$schema." (if temporary "journal." "main.")
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
