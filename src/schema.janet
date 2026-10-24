(import spork/path :as path)
(import spork/base64 :as base64)
(import spork/json :as json)

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
      (when (field :minimum) (assert (>= value (field :minimum)) "setting below minimum"))
      (when (field :maximum) (assert (<= value (field :maximum)) "setting above maximum"))
      (when (and (field :absolute) (not discovery)) (assert (path/abspath? value) "absolute path required"))
      (when (field :fields) (put config key (validate (field :fields) value discovery)))
      (when (field :values)
        (put config key (tabseq [[name item] :in (pairs value)] name ((validate {name (field :values)} {name item} discovery) name))))
      (each item (if (= :array (field :type)) value [value])
        (when (and (= :array (field :type)) (= :string (field :items)))
          (assert (and (string? item) (> (length item) 0) (not (string/find "\0" item))) "invalid array item"))
        (when (field :choices) (assert (index-of item (field :choices)) "invalid setting choice")))))
  config)

(defn configuration [schema supplied &opt discovery]
  (def config (validate schema supplied discovery))
  (when (config :context-quota)
    (assert (<= (config :summary-quota) (config :context-quota)) "summary quota exceeds context quota"))
  (when (config :agent)
    (assert (not (get-in config [:agent :agent])) "nested execution profiles are not supported")
    (put config :agent (configuration schema (config :agent) discovery))
    (each key [:source :store :world :file]
      (assert (= (config key) (get-in config [:agent key])) "agent view changes world identity/location")))
  (each [name capability] (pairs (config :capabilities))
    (when (capability :module)
      (assert (and (peg/match ~(* (some (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")) -1) (string name))
                   (not (index-of name [:self :pa]))) "invalid capability namespace")))
  (each [name provider] (pairs (config :providers))
    (assert (index-of name [:llama :openrouter]) "unsupported provider")
    (assert (peg/match ~(* (choice "https://" "http://") (some (if-not (set "?#@ \t\r\n") 1)) -1) (provider :url)) "invalid provider base"))
  config)

(defn authorize [schema current saved]
  (each key (keys saved) (assert (has-key? schema key) "unsupported saved configuration"))
  (each key [:source :store :world :file :instructions]
    (assert (= (current key) (saved key)) "saved identity/location differs"))
  (each key [:repl :inference :web-search]
    (assert (or (not (saved key)) (current key)) (string "saved permission revoked: " key)))
  (assert (or (nil? (saved :remote)) (= (saved :remote) (current :remote))) "saved remote changed")
  (each value (saved :visibility) (assert (index-of value (current :visibility)) "saved grant revoked"))
  (each [name capability] (pairs (saved :capabilities))
    (assert (and (has-key? (current :capabilities) name)
                 (= (capability :module) (get-in current [:capabilities name :module]))) "saved capability revoked"))
  (when (saved :agent) (assert (current :agent) "agent execution view revoked"))
  (each [name provider] (pairs (saved :providers))
    (def granted (get-in current [:providers name]))
    (assert (and granted (if (provider :identity) (= (provider :identity) (granted :identity)) (= (provider :url) (granted :url)))) "saved provider revoked"))
  (def config (merge saved {:forbid (distinct (array/concat @[] (saved :forbid) (current :forbid)))
                            :search (and (saved :search) (current :search))
                            :score (max (saved :score) (current :score))
                            :agent (when (saved :agent) (authorize schema (current :agent) (saved :agent)))
                            :capabilities (tabseq [name :in (keys (saved :capabilities))] name (get-in current [:capabilities name]))
                            :providers (tabseq [name :in (keys (saved :providers))] name (get-in current [:providers name]))}))
  (each [key field] (pairs schema)
    (when (and (= :integer (field :type)) (or (saved key) (current key)))
      (put config key
           (if (and (= key :output) (= 0 (min (saved key) (current key))))
             (max (saved key) (current key))
             (min (get saved key math/inf) (get current key math/inf))))))
  config)

(defn failure [code err fiber]
  (def trace @"")
  (with-dyns [:err (fn [bytes] (buffer/push-string trace bytes))] (debug/stacktrace fiber))
  (def value (if (and (dictionary? err) (string? (err :code)) (string? (err :message))) err
                {:code code :message (if (string? err) err (string/format "%n" err))}))
  (merge value {:detail (string (or (value :detail) "") "\n" trace)}))

(defn data [value]
  (json/encode value)
  (postwalk |(if (dictionary? $) (tabseq [[key item] :in (pairs $)] key item) $) value))

(defn request [value fields]
  (assert (dictionary? value) "request must be an object")
  (each key (keys value) (assert (index-of key fields) "unknown request field"))
  (each key [:text :code]
    (when (has-key? value key) (assert (and (string? (value key)) (> (length (value key)) 0)) "invalid inquiry")))
  (each key [:request :author :at :owner :revision]
    (when (has-key? value key)
      (assert (and (string? (value key)) (<= 1 (length (value key)) 256) (not (string/find "\0" (value key)))) "invalid request name")))
  (when (has-key? value :persist) (assert (boolean? (value :persist)) "invalid persistence flag"))
  (when (has-key? value :images)
    (assert (and (indexed? (value :images)) (<= (length (value :images)) 4)) "invalid images")
    (put value :images (map (fn [image]
                              (assert (and (dictionary? image) (deep= (sorted (keys image)) (sorted [:type :data]))
                                           (index-of (image :type) ["image/png" "image/jpeg" "image/webp"]) (string? (image :data))) "invalid image")
                              {:type (image :type) :bytes (buffer (base64/decode (image :data)))}) (value :images))))
  value)

(defn database [&opt temporary]
  (string (unless temporary `
CREATE TABLE call_controls(
 id INTEGER PRIMARY KEY AUTOINCREMENT CHECK(id<=9007199254740991),source TEXT NOT NULL,world TEXT NOT NULL,request TEXT,
 parent INTEGER REFERENCES call_controls(id),root INTEGER REFERENCES call_controls(id),kind TEXT NOT NULL CHECK(kind IN ('text','code','summarize')),
 temporary INTEGER NOT NULL CHECK(temporary IN (0,1)),expires REAL NOT NULL,cancelled INTEGER NOT NULL DEFAULT 0 CHECK(cancelled IN (0,1)),
 state TEXT NOT NULL DEFAULT 'queued' CHECK(state IN ('queued','running','waiting','done','failed','cancelled','uncertain')),
 attempt INTEGER NOT NULL DEFAULT 0,owner TEXT,lease_expires REAL,retries INTEGER NOT NULL DEFAULT 1,key TEXT,
 work_used INTEGER NOT NULL DEFAULT 0,tool_used INTEGER NOT NULL DEFAULT 0,UNIQUE(source,request),UNIQUE(source,key)
) STRICT;
CREATE INDEX call_pending ON call_controls(source,state,id);
CREATE INDEX call_parent ON call_controls(parent,id);
CREATE VIEW live_calls AS SELECT c.* FROM call_controls c JOIN call_controls r ON r.id=coalesce(c.root,c.id)
 WHERE c.state IN ('running','waiting') AND c.lease_expires>unixepoch('subsec') AND c.expires>unixepoch('subsec')
 AND r.expires>unixepoch('subsec') AND NOT c.cancelled AND NOT r.cancelled;
CREATE VIEW running AS SELECT source FROM live_calls WHERE state='running';
PRAGMA user_version=1;
`) (string/replace-all "$schema." (if temporary "journal." "main.") `
CREATE TABLE $schema.call_payloads(
 id INTEGER PRIMARY KEY,parent INTEGER,run INTEGER NOT NULL,kind TEXT NOT NULL,config TEXT CHECK(config IS NULL OR json_valid(config)),
 entry INTEGER,first INTEGER NOT NULL,last INTEGER NOT NULL,history_last INTEGER NOT NULL,world TEXT NOT NULL,
 code TEXT NOT NULL DEFAULT '',file TEXT,origin TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(origin)),temporary INTEGER NOT NULL,
 agent INTEGER NOT NULL,depth INTEGER NOT NULL,visibility TEXT NOT NULL CHECK(json_valid(visibility)),
 checkpoint TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(checkpoint)),
 CHECK(first>=0 AND last>=first AND ((first=0 AND last=0) OR first>0))
) STRICT;
CREATE INDEX $schema.call_history_parent ON call_payloads(parent,id);
CREATE TABLE $schema.events(
 id INTEGER PRIMARY KEY AUTOINCREMENT CHECK(id<=9007199254740991),source TEXT NOT NULL,call INTEGER REFERENCES call_payloads(id),
 parent INTEGER REFERENCES events(id),kind TEXT NOT NULL,text TEXT NOT NULL DEFAULT '',data TEXT NOT NULL CHECK(json_valid(data)),
 author TEXT NOT NULL CHECK(length(author)>0),
 at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%fZ','now')) CHECK(strftime('%Y-%m-%dT%H:%M:%fZ',at) IS at),
 estimate INTEGER NOT NULL CHECK(estimate>=0),created REAL NOT NULL DEFAULT(unixepoch('subsec'))
) STRICT;
CREATE INDEX $schema.event_source ON events(source,id);
CREATE INDEX $schema.event_call ON events(call,id);
CREATE UNIQUE INDEX $schema.call_input ON events(call) WHERE kind IN ('user','summary-input');
CREATE UNIQUE INDEX $schema.call_entry ON events(call,json_extract(data,'$.attempt')) WHERE kind='call-attempt';
CREATE UNIQUE INDEX $schema.call_terminal ON events(call,json_extract(data,'$.attempt')) WHERE kind='call-result';
CREATE UNIQUE INDEX $schema.call_answer ON events(call) WHERE kind='model-outcome' AND json_extract(data,'$.turn')=1 AND json_extract(data,'$.status') IN ('complete','refused','blocked');
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
 WHEN new.kind NOT IN ('user','summary-input','call-attempt','call-result','code-admission','tool-result','tool-ambiguity',
 'model-admission','model-outcome','call-admission','launch-uncertain','summary','interruption','cancelled','artifact','context','save-intent','saved','operation-outcome')
 BEGIN SELECT raise(ABORT,'unsupported event kind'); END;
CREATE VIEW $schema.memory_records AS WITH records AS (
 SELECT e.id,e.source,e.call task,c.run,CASE WHEN c.kind='summarize' THEN c.parent ELSE c.id END branch,
 CASE WHEN e.kind='call-result' AND c.kind='code' THEN (SELECT id FROM events n WHERE n.call=c.id AND n.kind='call-attempt' ORDER BY id DESC LIMIT 1) ELSE e.parent END parent,
 CASE WHEN e.kind='model-outcome' AND json_extract(e.data,'$.turn') THEN
   CASE WHEN json_extract(e.data,'$.status') IN ('complete','refused','blocked') THEN 'completed' ELSE 'response' END
  WHEN e.kind='call-result' AND json_type(e.data,'$.error')='object' THEN 'error'
  WHEN e.kind='call-result' AND c.kind='code' AND json_extract(e.data,'$.state')='done' THEN 'completed'
  WHEN e.kind='call-attempt' AND c.kind='code' THEN 'code-admission' ELSE e.kind END kind,
 CASE WHEN e.kind='user' THEN coalesce(json_extract(e.data,'$.input.text'),'')
  WHEN e.kind='model-outcome' THEN CASE json_type(e.data,'$.message.content') WHEN 'text' THEN json_extract(e.data,'$.message.content')
   WHEN 'array' THEN coalesce((SELECT group_concat(json_extract(p.value,'$.text'),char(10) ORDER BY p.key) FROM json_each(e.data,'$.message.content') p WHERE json_extract(p.value,'$.type')='text'),'')
   ELSE coalesce(json_extract(e.data,'$.message.refusal'),'') END
  WHEN e.kind='call-result' THEN coalesce(json_extract(e.data,'$.error.message'),json_extract(e.data,'$.value'),e.text)
  WHEN e.kind='call-attempt' AND c.kind='code' THEN json_extract(a.data,'$.input.code') ELSE e.text END text,
 e.data,e.estimate,e.author,e.at,e.created,c.kind execution_kind,
 CASE WHEN json_type(e.data,'$.message')='object' THEN CASE WHEN json_extract(e.data,'$."reasoning-visible"') THEN json_extract(e.data,'$.message')
  ELSE json_remove(json_extract(e.data,'$.message'),'$.reasoning','$.reasoning_content','$.reasoning_details') END END public_message
 FROM events e LEFT JOIN call_payloads c ON c.id=e.call LEFT JOIN events a ON a.call=c.id AND a.kind='user'
) SELECT e.*,b.world branch_world,b.file branch_file,b.temporary branch_temporary,b.parent branch_parent,json_extract(a.data,'$.input.request') request,
 CASE WHEN b.temporary=1 THEN 'tmp:'||json_extract(a.data,'$.input.request')||'/'||b.id||':'||e.id END label,
 CASE WHEN e.kind='user' THEN coalesce(nullif(e.text,''),json_extract(e.data,'$.input.code'),'')
  WHEN e.kind IN ('response','completed','model-outcome') AND json_type(e.data,'$.message')='object' THEN e.public_message||char(10)||json_object('status',json_extract(e.data,'$.status'))
  WHEN e.kind IN ('call-admission','operation-outcome','tool-result','tool-ambiguity','cancelled','interruption','save-intent','saved','error','artifact','model-admission','model-outcome','call-result') THEN e.text||char(10)||json_remove(e.data,'$."world-source"') ELSE e.text END body,
 CASE WHEN e.kind IN ('user','context','response','completed','code-admission','tool-result','tool-ambiguity','call-admission','operation-outcome','cancelled','save-intent','saved') THEN 1
  WHEN e.kind IN ('error','interruption') THEN e.execution_kind<>'summarize'
  WHEN e.kind='artifact' THEN json_type(e.data,'$.invalidates') IS NULL ELSE 0 END memory
 FROM records e LEFT JOIN call_payloads b ON b.id=e.branch LEFT JOIN events a ON a.call=e.run AND a.kind='user';
CREATE VIEW $schema.conversation_records AS SELECT e.*,CASE WHEN kind='response' THEN json_extract(data,'$.message') ELSE
 json_object('role','tool','tool_call_id',json_extract(data,'$.tool-id'),'content',text) END conversation_message
 FROM memory_records e WHERE kind='response' OR kind IN ('tool-result','tool-ambiguity') AND NOT EXISTS(
 SELECT 1 FROM events n WHERE n.call=e.task AND n.id>e.id AND n.kind IN ('tool-result','tool-ambiguity')
 AND json_extract(n.data,'$.response')=json_extract(e.data,'$.response') AND json_extract(n.data,'$.tool-id')=json_extract(e.data,'$.tool-id'));
CREATE VIEW $schema.unresolved_tools AS SELECT r.branch,r.id response,json_extract(c.value,'$.id') tool_id FROM memory_records r,json_each(r.data,'$.tools') c
 WHERE r.kind='response' AND r.id=(SELECT max(id) FROM memory_records WHERE branch=r.branch AND kind='response') AND NOT EXISTS(
 SELECT 1 FROM events e WHERE e.call=r.task AND e.kind IN ('tool-result','tool-ambiguity')
 AND json_extract(e.data,'$.tool-id')=json_extract(c.value,'$.id') AND json_extract(e.data,'$.response')=r.id);
CREATE VIEW $schema.invalid_summaries AS WITH RECURSIVE invalid(source,id) AS (
 SELECT n.source,n.id FROM events a JOIN events n ON n.id=json_extract(a.data,'$.invalidates') AND n.source=a.source AND n.kind='summary'
 WHERE a.kind='artifact' AND json_type(a.data,'$.invalidates')='integer'
 UNION SELECT n.source,n.id FROM events n JOIN invalid i ON i.source=n.source,json_each(n.data,'$.children') c WHERE n.kind='summary' AND i.id=c.value
) SELECT id FROM invalid;
CREATE UNIQUE INDEX $schema.summary_call ON events(call) WHERE kind='summary';
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
