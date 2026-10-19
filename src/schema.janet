(import spork/json :as json)
(import spork/path :as path)
(import spork/base64 :as base64)
(import spork/utf8 :as utf8)

(defn validate [schema supplied &opt discovery]
  (assert (dictionary? supplied) "configuration must be an object")
  (def config @{})
  (each key (keys supplied) (assert (has-key? schema key) (string "unknown configuration field " key)))
  (each [key field] (pairs schema)
    (when (has-key? field :default) (put config key (field :default))))
  (merge-into config supplied)
  (each [key field] (pairs schema)
    (assert (or discovery (has-key? config key) (field :optional)) (string "required setting " key))
    (when (has-key? config key)
      (def value (config key))
      (assert (case (field :type)
                :string (and (string? value) (> (length value) 0) (not (string/find "\0" value)))
                :integer (int? value)
                :number (and (number? value) (< (math/abs value) math/inf))
                :boolean (boolean? value)
                :array (indexed? value)
                :dictionary (dictionary? value)
                false) (string "invalid setting " key))
      (when (field :minimum) (assert (>= value (field :minimum)) "setting below minimum"))
      (when (field :maximum) (assert (<= value (field :maximum)) "setting above maximum"))
      (when (and (field :absolute) (not discovery)) (assert (path/abspath? value) "absolute path required"))
      (when (field :fields)
        (put config key (validate (field :fields) value discovery)))
      (when (field :values)
        (put config key (tabseq [[name item] :in (pairs value)]
          name ((validate {name (field :values)} {name item} discovery) name))))
      (if (= :array (field :type))
        (each item value
          (when (= :string (field :items))
            (assert (and (string? item) (> (length item) 0) (not (string/find "\0" item))) "invalid array item"))
          (when (field :choices) (assert (index-of item (field :choices)) "invalid setting choice")))
        (when (field :choices) (assert (index-of value (field :choices)) "invalid setting choice")))))
  config)

(defn configuration [schema supplied &opt discovery]
  (def config (validate schema supplied discovery))
  (assert (<= (config :summary-quota) (config :context-quota)) "summary quota exceeds context quota")
  (when (config :agent)
    (assert (not (get-in config [:agent :agent])) "nested execution profiles are not supported")
    (put config :agent (configuration schema (config :agent) discovery))
    (each key [:source :store :world :file]
      (assert (= (config key) (get-in config [:agent key])) "agent view changes world identity/location")))
  (unless discovery
    (when (config :repl)
      (assert (and (config :file) (= :file (os/stat (config :file) :mode))) "world source is required"))
    (each [name capability] (pairs (config :capabilities))
      (when (capability :module)
        (assert (and (peg/match ~(* (some (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")) -1) (string name))
                     (not (index-of name [:self :pa]))) "invalid capability namespace")
        (assert (= :file (os/stat (capability :module) :mode)) "capability library unavailable")))
    (each [name provider] (pairs (config :providers))
      (assert (index-of name [:llama :openrouter]) "unsupported provider")
      (assert (peg/match ~(* (choice "https://" "http://") (some (if-not (set "?#@ \t\r\n") 1)) -1) (provider :url)) "invalid provider base"))
    (when (config :search)
      (each key [:cygnet :stopwords]
        (assert (and (config key) (= :file (os/stat (config key) :mode))) "semantic retrieval requires provisioned Cygnet and stopword files"))))
  config)

(defn authorize [schema current saved]
  (each key (keys saved) (assert (has-key? schema key) "unsupported saved configuration"))
  (each key [:source :store :world :file :instructions]
    (assert (= (current key) (saved key)) "saved identity/location differs"))
  (each key [:repl :inference]
    (assert (or (not (saved key)) (current key)) (string "saved permission revoked: " key)))
  (assert (or (nil? (saved :remote)) (= (saved :remote) (current :remote))) "saved remote changed")
  (each value (saved :visibility) (assert (index-of value (current :visibility)) "saved grant revoked"))
  (each [name capability] (pairs (saved :capabilities))
    (assert (and (has-key? (current :capabilities) name)
                 (= (capability :module) (get-in current [:capabilities name :module]))) "saved capability revoked"))
  (when (saved :agent)
    (assert (current :agent) "agent execution view revoked"))
  (each [name provider] (pairs (saved :providers))
    (def granted (get-in current [:providers name]))
    (assert (and granted (if (provider :identity) (= (provider :identity) (granted :identity)) (= (provider :url) (granted :url)))) "saved provider revoked"))
  (def config (merge @{} saved {:forbid (distinct (array/concat @[] (saved :forbid) (current :forbid)))
                                :search (and (saved :search) (current :search))
                                :agent (when (saved :agent) (authorize schema (current :agent) (saved :agent)))
                                :capabilities (tabseq [name :in (keys (saved :capabilities))] name (get-in current [:capabilities name]))
                                :providers (tabseq [name :in (keys (saved :providers))]
                                             name (get-in current [:providers name]))}))
  (each [key field] (pairs schema)
    (when (= :integer (field :type))
      (put config key
           (if (and (= key :output) (= 0 (min (saved key) (current key))))
             (max (saved key) (current key))
             (min (saved key) (current key))))))
  config)

(defn request [bytes fields]
  (assert (utf8/is-valid? bytes) "invalid request bytes")
  (def value (json/decode bytes true true))
  (assert (dictionary? value) "request must be an object")
  (each key (keys value) (assert (index-of key fields) "unknown request field"))
  (each key [:parent :after :run :task]
    (when (has-key? value key)
      (assert (and (int? (value key)) (<= 0 (value key) 9007199254740991)) "invalid coordinate")))
  (each key [:text :code]
    (when (has-key? value key) (assert (and (string? (value key)) (> (length (value key)) 0)) "invalid inquiry")))
  (each key [:request :author :at :owner]
    (when (has-key? value key)
      (assert (and (string? (value key)) (<= 1 (length (value key)) 256)) "invalid request name")))
  (when (has-key? value :revision)
    (assert (and (string? (value :revision)) (<= 1 (length (value :revision)) 256) (not (string/find "\0" (value :revision)))) "invalid source revision"))
  (when (has-key? value :persist) (assert (boolean? (value :persist)) "invalid persistence flag"))
  (when (has-key? value :memory_range)
    (def range (value :memory_range))
    (assert (dictionary? range) "invalid memory range")
    (each [key id] (pairs range)
      (assert (and (index-of key [:start :end]) (int? id) (<= 0 id 9007199254740991)) "invalid memory range"))
    (assert (or (= 0 (length range)) (and (= 2 (length range)) (<= (range :start) (range :end)) (= (= 0 (range :start)) (= 0 (range :end))))) "memory range requires inclusive start and end"))
  (when (has-key? value :images)
    (assert (and (indexed? (value :images)) (<= (length (value :images)) 4)) "invalid images")
    (each image (value :images)
      (assert (and (dictionary? image) (deep= (sorted (keys image)) (sorted [:type :data])) (index-of (image :type) ["image/png" "image/jpeg" "image/webp"]) (string? (image :data))) "invalid image")
      (def bytes (base64/decode (image :data)))
      (assert (= (base64/encode bytes) (image :data)) "noncanonical image data")))
  value)

(defn database [&opt temporary]
  (string (unless temporary `
CREATE TABLE run_controls(
 id INTEGER PRIMARY KEY AUTOINCREMENT CHECK(id<=9007199254740991),source TEXT NOT NULL,request TEXT,world TEXT NOT NULL,
 expires REAL NOT NULL,root INTEGER REFERENCES run_controls(id),temporary INTEGER NOT NULL DEFAULT 0 CHECK(temporary IN (0,1)),
 cancelled INTEGER NOT NULL DEFAULT 0 CHECK(cancelled IN (0,1)),
 work_used INTEGER NOT NULL DEFAULT 0,tool_used INTEGER NOT NULL DEFAULT 0,UNIQUE(source,request)
) STRICT;
CREATE TABLE task_controls(
 id INTEGER PRIMARY KEY AUTOINCREMENT,source TEXT NOT NULL,run INTEGER NOT NULL REFERENCES run_controls(id),
 parent INTEGER REFERENCES task_controls(id),world TEXT NOT NULL,kind TEXT NOT NULL,
 retry_policy TEXT NOT NULL CHECK(retry_policy IN ('retry','manual')),retries INTEGER NOT NULL DEFAULT 1,
 state TEXT NOT NULL DEFAULT 'queued' CHECK(state IN ('queued','running','waiting','done','failed','cancelled','uncertain')),
 attempt INTEGER NOT NULL DEFAULT 0,owner TEXT,lease_expires REAL,key TEXT,UNIQUE(source,key)
) STRICT;
CREATE INDEX task_pending ON task_controls(state,source,id);
CREATE UNIQUE INDEX active_driver ON task_controls(run) WHERE parent IS NULL AND state IN ('queued','running','waiting');
CREATE INDEX task_parent ON task_controls(parent,id);
CREATE VIEW running AS SELECT t.source FROM task_controls t JOIN run_controls r ON r.id=t.run
 WHERE t.state='running' AND t.lease_expires>unixepoch('subsec') AND r.expires>unixepoch('subsec') AND NOT r.cancelled;
PRAGMA user_version=4;
`) (string/replace-all "$schema." (if temporary "journal." "main.") `
CREATE TABLE $schema.run_payloads(id INTEGER PRIMARY KEY,input TEXT NOT NULL CHECK(json_valid(input)),config TEXT NOT NULL CHECK(json_valid(config))) STRICT;
CREATE TABLE $schema.branches(
 id INTEGER PRIMARY KEY AUTOINCREMENT,run INTEGER NOT NULL REFERENCES run_payloads(id),parent INTEGER REFERENCES branches(id),
 caller INTEGER REFERENCES events(id),entry INTEGER REFERENCES events(id),
 first INTEGER NOT NULL,last INTEGER NOT NULL,history_last INTEGER NOT NULL,
 world TEXT NOT NULL,code TEXT NOT NULL,file TEXT,origin TEXT NOT NULL CHECK(json_valid(origin)),temporary INTEGER NOT NULL CHECK(temporary IN (0,1)),
 agent INTEGER NOT NULL,depth INTEGER NOT NULL CHECK(depth>=0),visibility TEXT NOT NULL CHECK(json_valid(visibility)),
 CHECK(first>=0 AND last>=first AND ((first=0 AND last=0) OR first>0))
) STRICT;
CREATE UNIQUE INDEX $schema.root_run ON branches(run) WHERE parent IS NULL;
CREATE UNIQUE INDEX $schema.child_admission ON branches(caller) WHERE caller IS NOT NULL;
CREATE INDEX $schema.branch_parent ON branches(parent,id);
CREATE TABLE $schema.task_payloads(
 id INTEGER PRIMARY KEY,branch INTEGER NOT NULL REFERENCES branches(id),input TEXT NOT NULL CHECK(json_valid(input)),
 checkpoint TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(checkpoint)),admission INTEGER REFERENCES events(id),outcome INTEGER REFERENCES events(id)
) STRICT;
CREATE TABLE $schema.events(
 id INTEGER PRIMARY KEY AUTOINCREMENT CHECK(id<=9007199254740991),source TEXT NOT NULL,
 run INTEGER REFERENCES run_payloads(id),branch INTEGER REFERENCES branches(id),parent INTEGER REFERENCES events(id),
 task INTEGER REFERENCES task_payloads(id),kind TEXT NOT NULL,text TEXT NOT NULL DEFAULT '',data TEXT NOT NULL CHECK(json_valid(data)),
 author TEXT NOT NULL CHECK(length(author)>0),
 at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%fZ','now')) CHECK(strftime('%Y-%m-%dT%H:%M:%fZ',at) IS at),
 estimate INTEGER NOT NULL CHECK(estimate>=0),created REAL NOT NULL DEFAULT(unixepoch('subsec'))
) STRICT;
CREATE INDEX $schema.event_source ON events(source,id);
CREATE INDEX $schema.event_branch ON events(branch,id);
CREATE INDEX $schema.event_task ON events(task,id);
CREATE UNIQUE INDEX $schema.task_entry ON events(task,json_extract(data,'$.attempt')) WHERE kind='task-attempt';
CREATE UNIQUE INDEX $schema.task_terminal ON events(task) WHERE kind='task-outcome';
CREATE UNIQUE INDEX $schema.branch_terminal ON events(branch) WHERE kind='completed';
CREATE UNIQUE INDEX $schema.tool_result ON events(parent) WHERE kind='tool-result';
CREATE TRIGGER $schema.immutable_events_update BEFORE UPDATE ON events BEGIN SELECT raise(ABORT,'immutable events'); END;
CREATE TRIGGER $schema.immutable_events_delete BEFORE DELETE ON events BEGIN SELECT raise(ABORT,'immutable events'); END;
CREATE TABLE $schema.images(event INTEGER NOT NULL REFERENCES events(id),position INTEGER NOT NULL,mime TEXT NOT NULL,bytes BLOB NOT NULL,PRIMARY KEY(event,position)) WITHOUT ROWID;
CREATE TRIGGER $schema.immutable_images_update BEFORE UPDATE ON images BEGIN SELECT raise(ABORT,'immutable images'); END;
CREATE TRIGGER $schema.immutable_images_delete BEFORE DELETE ON images BEGIN SELECT raise(ABORT,'immutable images'); END;
CREATE TABLE $schema.usage(
 request INTEGER PRIMARY KEY REFERENCES events(id),provider TEXT NOT NULL,model TEXT NOT NULL,
 input INTEGER,output INTEGER,total INTEGER,reasoning INTEGER,cached INTEGER,raw TEXT NOT NULL CHECK(json_valid(raw))
) STRICT;
CREATE UNIQUE INDEX $schema.model_terminal ON events(parent) WHERE kind='model-outcome';
CREATE TRIGGER $schema.event_kind BEFORE INSERT ON events
 WHEN new.kind NOT IN ('user','response','completed','tool-result','tool-ambiguity',
 'task-admission','task-attempt','task-outcome','model-admission','model-outcome','call-admission',
 'launch-uncertain','traceback','summary','interruption','cancelled','artifact','context','error','save-intent','saved','operation-outcome')
 BEGIN SELECT raise(ABORT,'unsupported event kind'); END;
CREATE VIEW $schema.memory_records AS WITH records AS (
 SELECT e.id,e.source,e.run,e.branch,e.parent,e.task,e.kind,
   coalesce(json_extract(m.data,'$.text'),e.text) text,
   CASE WHEN m.id IS NULL THEN e.data ELSE json_patch(m.data,e.data) END data,
   e.estimate,e.author,e.at,e.created
 FROM events e LEFT JOIN events m ON e.kind IN ('response','completed') AND m.kind='model-outcome' AND m.parent=e.parent
), projected AS (
 SELECT e.*,CASE WHEN json_type(data,'$.message')='object' THEN
  CASE WHEN json_extract(data,'$."reasoning-visible"') THEN json_extract(data,'$.message') ELSE json_remove(json_extract(data,'$.message'),'$.reasoning','$.reasoning_content','$.reasoning_details') END END public_message FROM records e
) SELECT e.*,(SELECT 'tmp:'||json_extract(r.input,'$.request')||'/'||b.id||':'||e.id FROM branches b JOIN run_payloads r ON r.id=b.run WHERE b.id=e.branch AND b.temporary=1) label,CASE
   WHEN kind='user' THEN coalesce(nullif(text,''),json_extract(data,'$.input.code'),'')
   WHEN kind IN ('response','completed','model-outcome') AND json_type(data,'$.message')='object'
     THEN public_message || char(10) || json_object('status',json_extract(data,'$.status'))
   WHEN kind IN ('call-admission','operation-outcome','tool-result','tool-ambiguity','cancelled','interruption','save-intent','saved','error','artifact','model-admission','model-outcome','task-outcome')
     THEN text || char(10) || json_remove(data,'$."world-source"')
   ELSE text END body,
   CASE WHEN kind IN ('user','context','response','completed','tool-result','tool-ambiguity','call-admission','operation-outcome','cancelled','save-intent','saved') THEN 1
    WHEN kind='task-admission' THEN json_extract(data,'$.kind')='code'
    WHEN kind IN ('error','interruption') THEN NOT EXISTS(SELECT 1 FROM task_payloads t JOIN events a ON a.id=t.admission WHERE t.id=e.task AND json_extract(a.data,'$.kind')='summarize')
    WHEN kind='artifact' THEN json_type(data,'$.invalidates') IS NULL ELSE 0 END memory
 FROM projected e;
CREATE VIEW $schema.conversation_records AS
 SELECT e.*,CASE WHEN kind='response' THEN json_extract(data,'$.message') ELSE
   json_object('role','tool','tool_call_id',json_extract(data,'$.tool-id'),'content',text) END conversation_message
 FROM memory_records e WHERE kind='response' OR kind IN ('tool-result','tool-ambiguity') AND NOT EXISTS(
   SELECT 1 FROM events n WHERE n.branch=e.branch AND n.id>e.id AND n.kind IN ('tool-result','tool-ambiguity')
     AND json_extract(n.data,'$.response')=json_extract(e.data,'$.response') AND json_extract(n.data,'$.tool-id')=json_extract(e.data,'$.tool-id'));
CREATE VIEW $schema.unresolved_tools AS
 SELECT r.branch,r.id response,json_extract(c.value,'$.id') tool_id FROM memory_records r,json_each(r.data,'$.tools') c
 WHERE r.kind='response' AND r.id=(SELECT max(id) FROM events WHERE branch=r.branch AND kind='response') AND NOT EXISTS(
   SELECT 1 FROM events e WHERE e.branch=r.branch AND e.kind IN ('tool-result','tool-ambiguity')
     AND json_extract(e.data,'$.tool-id')=json_extract(c.value,'$.id') AND json_extract(e.data,'$.response')=r.id);
CREATE VIEW $schema.invalid_summaries AS
 WITH RECURSIVE invalid(source,id) AS (
   SELECT n.source,n.id FROM events a JOIN events n ON n.id=json_extract(a.data,'$.invalidates') AND n.source=a.source AND n.kind='summary'
   WHERE a.kind='artifact' AND json_type(a.data,'$.invalidates')='integer'
   UNION SELECT n.source,n.id FROM events n JOIN invalid i ON i.source=n.source,json_each(n.data,'$.children') c WHERE n.kind='summary' AND i.id=c.value
 ) SELECT id FROM invalid;
CREATE UNIQUE INDEX $schema.summary_task ON events(task) WHERE kind='summary';
CREATE INDEX $schema.summary_key ON events(source,json_extract(data,'$.policy'),json_extract(data,'$.children')) WHERE kind='summary';
CREATE INDEX $schema.summary_start ON events(source,json_extract(data,'$.first')) WHERE kind='summary';
CREATE INDEX $schema.summary_invalidations ON events(source,id) WHERE kind='artifact' AND json_type(data,'$.invalidates')='integer';

CREATE VIEW $schema.search_records AS SELECT id,body FROM memory_records WHERE memory;
CREATE VIRTUAL TABLE $schema.event_fts USING fts5(body,content='search_records',content_rowid='id',tokenize='unicode61 remove_diacritics 0');
CREATE VIRTUAL TABLE $schema.event_words USING fts5vocab(event_fts,'instance');
CREATE TABLE $schema.lexemes(id INTEGER PRIMARY KEY,source TEXT NOT NULL,term TEXT NOT NULL,UNIQUE(source,term)) STRICT;
CREATE TABLE $schema.event_lexemes(event INTEGER NOT NULL REFERENCES events(id),lexeme INTEGER NOT NULL REFERENCES lexemes(id),PRIMARY KEY(event,lexeme)) WITHOUT ROWID;
CREATE INDEX $schema.lexeme_events ON event_lexemes(lexeme,event);
CREATE VIRTUAL TABLE $schema.lexeme_grams USING fts5(term,content='lexemes',content_rowid='id',tokenize='trigram',detail='none');
CREATE TRIGGER $schema.lexeme_index AFTER INSERT ON lexemes BEGIN INSERT INTO lexeme_grams(rowid,term) VALUES(new.id,new.term); END;
CREATE TRIGGER $schema.event_index AFTER INSERT ON events BEGIN
 INSERT INTO event_fts(rowid,body) SELECT id,body FROM search_records WHERE id=new.id;
END;
CREATE UNIQUE INDEX $schema.context_key ON events(source,json_extract(data,'$.key')) WHERE kind='context';
`)))
