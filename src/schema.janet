(import spork/json :as json)
(import spork/path :as path)
(import spork/base64 :as base64)
(import spork/utf8 :as utf8)

(defn validate [schema bytes &opt discovery]
  (def supplied (json/decode bytes true true))
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
        (put config key (validate (field :fields) (json/encode value) discovery)))
      (when (field :values)
        (each [name item] (pairs value)
          (validate {name (field :values)} (json/encode {name item}) discovery)))
      (if (= :array (field :type))
        (each item value
          (when (= :string (field :items))
            (assert (and (string? item) (> (length item) 0) (not (string/find "\0" item))) "invalid array item"))
          (when (field :choices) (assert (index-of item (field :choices)) "invalid setting choice")))
        (when (field :choices) (assert (index-of value (field :choices)) "invalid setting choice")))))
  config)

(defn configuration [schema bytes &opt discovery]
  (def config (validate schema bytes discovery))
  (assert (<= (config :summary-quota) (config :context-quota)) "summary quota exceeds context quota")
  (when (config :agent)
    (assert (not (get-in config [:agent :agent])) "nested execution profiles are not supported")
    (put config :agent (configuration schema (json/encode (config :agent)) discovery))
    (each key [:source :store :world :file]
      (assert (= (config key) (get-in config [:agent key])) "agent view changes world identity/location")))
  (unless discovery
    (when (config :repl)
      (assert (and (config :file) (= :file (os/stat (config :file) :mode))) "world source is required"))
    (each [name capability] (pairs (config :capabilities))
      (assert (and (peg/match ~(* (some (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")) -1) (string name))
                   (not (index-of name [:self :pa :memory :model :work]))) "invalid capability namespace")
      (assert (= :file (os/stat (capability :module) :mode)) "capability library unavailable"))
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
  (each key [:repl :inference :commit]
    (assert (or (not (saved key)) (current key)) (string "saved permission revoked: " key)))
  (each key [:visibility :permissions]
    (each value (saved key) (assert (index-of value (current key)) "saved grant revoked")))
  (each [name capability] (pairs (saved :capabilities))
    (assert (= (capability :module) (get-in current [:capabilities name :module])) "saved capability revoked"))
  (when (saved :agent)
    (assert (current :agent) "agent execution view revoked"))
  (each [name provider] (pairs (saved :providers))
    (def granted (get-in current [:providers name]))
    (assert (and granted (if (provider :identity) (= (provider :identity) (granted :identity)) (= (provider :url) (granted :url)))) "saved provider revoked"))
  (def config (merge @{} saved {:search (and (saved :search) (current :search))
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
  (when (has-key? value :text)
    (assert (and (string? (value :text)) (> (length (value :text)) 0)) "invalid question"))
  (when (has-key? value :code)
    (assert (and (string? (value :code)) (> (length (value :code)) 0)) "invalid Janet source"))
  (each key [:request]
    (when (has-key? value key)
      (assert (and (string? (value key)) (<= 1 (length (value key)) 256)) "invalid request name")))
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

(def database `
CREATE TABLE runs(
 id INTEGER PRIMARY KEY AUTOINCREMENT CHECK(id<=9007199254740991),source TEXT NOT NULL,
 request TEXT,input TEXT NOT NULL CHECK(json_valid(input)),world TEXT NOT NULL,
 config TEXT NOT NULL CHECK(json_valid(config)),expires REAL NOT NULL,UNIQUE(source,request)
) STRICT;
CREATE INDEX runs_source ON runs(source,id);
CREATE TABLE branches(
 id INTEGER PRIMARY KEY AUTOINCREMENT,run INTEGER NOT NULL REFERENCES runs(id),parent INTEGER REFERENCES branches(id),
 caller INTEGER REFERENCES events(id),entry INTEGER REFERENCES events(id),
 first INTEGER NOT NULL,last INTEGER NOT NULL,history_last INTEGER NOT NULL,
 world TEXT NOT NULL,code TEXT NOT NULL,temporary INTEGER NOT NULL CHECK(temporary IN (0,1)),retired INTEGER NOT NULL DEFAULT 0,
 CHECK(first>=0 AND last>=first AND ((first=0 AND last=0) OR first>0))
) STRICT;
CREATE UNIQUE INDEX root_run ON branches(run) WHERE parent IS NULL;
CREATE UNIQUE INDEX child_admission ON branches(caller) WHERE caller IS NOT NULL;
CREATE INDEX branch_parent ON branches(parent,id);
CREATE TABLE tasks(
 id INTEGER PRIMARY KEY AUTOINCREMENT,source TEXT NOT NULL,run INTEGER REFERENCES runs(id),
 branch INTEGER REFERENCES branches(id),parent INTEGER REFERENCES tasks(id),world TEXT NOT NULL,
 kind TEXT NOT NULL,input TEXT NOT NULL CHECK(json_valid(input)),scope TEXT NOT NULL CHECK(json_valid(scope)),
 retry_policy TEXT NOT NULL CHECK(retry_policy IN ('retry','manual')),retries INTEGER NOT NULL,
 state TEXT NOT NULL DEFAULT 'queued' CHECK(state IN ('queued','running','waiting','done','failed','cancelled','uncertain')),
 checkpoint TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(checkpoint)),result TEXT CHECK(json_valid(result)),
 attempt INTEGER NOT NULL DEFAULT 0,admission INTEGER REFERENCES events(id),outcome INTEGER REFERENCES events(id),
 key TEXT,UNIQUE(source,key)
) STRICT;
CREATE INDEX task_pending ON tasks(state,source,id);
CREATE UNIQUE INDEX active_driver ON tasks(branch) WHERE parent IS NULL AND state IN ('queued','running','waiting');
CREATE INDEX task_parent ON tasks(parent,id);
CREATE TABLE leases(task INTEGER PRIMARY KEY REFERENCES tasks(id),owner TEXT NOT NULL,generation INTEGER NOT NULL,expires REAL NOT NULL) STRICT;
CREATE TABLE events(
 id INTEGER PRIMARY KEY AUTOINCREMENT CHECK(id<=9007199254740991),source TEXT NOT NULL,
 run INTEGER REFERENCES runs(id),branch INTEGER REFERENCES branches(id),parent INTEGER REFERENCES events(id),
 task INTEGER REFERENCES tasks(id),kind TEXT NOT NULL,text TEXT NOT NULL DEFAULT '',data TEXT NOT NULL CHECK(json_valid(data)),
 estimate INTEGER NOT NULL CHECK(estimate>=0),created REAL NOT NULL DEFAULT(unixepoch('subsec'))
) STRICT;
CREATE INDEX event_source ON events(source,id);
CREATE INDEX event_branch ON events(branch,id);
CREATE INDEX event_task ON events(task,id);
CREATE UNIQUE INDEX task_terminal ON events(task) WHERE kind='task-outcome';
CREATE UNIQUE INDEX branch_terminal ON events(branch) WHERE kind='completed';
CREATE UNIQUE INDEX tool_result ON events(task) WHERE kind='tool-result';
CREATE TRIGGER immutable_events_update BEFORE UPDATE ON events BEGIN SELECT raise(ABORT,'immutable events'); END;
CREATE TRIGGER immutable_events_delete BEFORE DELETE ON events BEGIN SELECT raise(ABORT,'immutable events'); END;
CREATE TABLE images(event INTEGER NOT NULL REFERENCES events(id),position INTEGER NOT NULL,mime TEXT NOT NULL,bytes BLOB NOT NULL,PRIMARY KEY(event,position)) WITHOUT ROWID;
CREATE TRIGGER immutable_images_update BEFORE UPDATE ON images BEGIN SELECT raise(ABORT,'immutable images'); END;
CREATE TRIGGER immutable_images_delete BEFORE DELETE ON images BEGIN SELECT raise(ABORT,'immutable images'); END;
CREATE TABLE usage(
 request INTEGER PRIMARY KEY REFERENCES events(id),provider TEXT NOT NULL,model TEXT NOT NULL,
 input INTEGER,output INTEGER,total INTEGER,reasoning INTEGER,cached INTEGER,raw TEXT NOT NULL CHECK(json_valid(raw))
) STRICT;
CREATE UNIQUE INDEX model_terminal ON events(parent) WHERE kind='model-outcome';
CREATE VIEW summaries AS
 SELECT id,source,json_extract(data,'$.world') world,branch,
        json_extract(data,'$.first') first,json_extract(data,'$.last') last,
        text,estimate,json_extract(data,'$.source_estimate') source_estimate,
        json_extract(data,'$.height') height,task
 FROM events WHERE kind='summary';

CREATE UNIQUE INDEX summary_task ON events(task) WHERE kind='summary';
CREATE INDEX summary_range ON events(source,kind,json_extract(data,'$.world'),json_extract(data,'$.first'),json_extract(data,'$.last'));

CREATE TABLE summary_children(
 parent INTEGER NOT NULL REFERENCES events(id),position INTEGER NOT NULL,
 node INTEGER REFERENCES events(id),event INTEGER REFERENCES events(id),
 CHECK((node IS NULL)!=(event IS NULL)),PRIMARY KEY(parent,position)
) WITHOUT ROWID;

CREATE UNIQUE INDEX call_position ON events(task,json_extract(data,'$.position')) WHERE kind='call-admission';
CREATE TRIGGER summary_edge_immutable_update BEFORE UPDATE ON summary_children BEGIN SELECT raise(ABORT,'immutable summary edge'); END;
CREATE TRIGGER summary_edge_immutable_delete BEFORE DELETE ON summary_children BEGIN SELECT raise(ABORT,'immutable summary edge'); END;
CREATE VIRTUAL TABLE event_fts USING fts5(text,content='events',content_rowid='id',tokenize='unicode61 remove_diacritics 0');
CREATE TRIGGER event_index AFTER INSERT ON events WHEN new.kind IN ('user','response','tools','completed','tool-result','artifact','context') BEGIN
 INSERT INTO event_fts(rowid,text) VALUES(new.id,new.text);
END;
CREATE VIRTUAL TABLE event_words USING fts5vocab(event_fts,'instance');
CREATE TABLE lexemes(id INTEGER PRIMARY KEY,source TEXT NOT NULL,term TEXT NOT NULL,UNIQUE(source,term)) STRICT;
CREATE TABLE event_lexemes(event INTEGER NOT NULL REFERENCES events(id),lexeme INTEGER NOT NULL REFERENCES lexemes(id),PRIMARY KEY(event,lexeme)) WITHOUT ROWID;
CREATE INDEX lexeme_events ON event_lexemes(lexeme,event);
CREATE VIRTUAL TABLE lexeme_grams USING fts5(term,content='lexemes',content_rowid='id',tokenize='trigram',detail='none');
CREATE TRIGGER lexeme_index AFTER INSERT ON lexemes BEGIN INSERT INTO lexeme_grams(rowid,term) VALUES(new.id,new.term); END;
CREATE UNIQUE INDEX context_key ON events(source,json_extract(data,'$.key')) WHERE kind='context';
PRAGMA user_version=1;
`)
