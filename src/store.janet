(import sqlite3 :as sql)
(import spork/json :as json)
(import spork/base64 :as base64)
(import spork/path :as path)
(import jsec/crypto :as crypto)
(import ./schema)

(def interval 0.1)
(def- directory (path/dirname (dyn :source)))
(def- layout (string (slurp (path/join directory "store.sql"))))
(defn digest [bytes] (string/join (map |(string/format "%02x" $) (string/bytes (crypto/digest :sha256 bytes)))))
(defn estimate [bytes] (math/ceil (/ (length bytes) 4)))
(defn uuid [] (string/join (map |(string/format "%02x" $) (os/cryptorand 24))))

(defn uri [file]
  (def file (if (index-of (os/which) [:windows :mingw]) (string/replace-all "\\" "/" file) file))
  (string "file:" (string/replace-all "?" "%3F" (string/replace-all "#" "%23" (string/replace-all "%" "%25" file)))))

(defn query [s statement &opt parameters]
  (map (fn [row] (if (string? (row :data)) (merge row {:data (json/decode (row :data) true)}) row))
       (sql/eval (s :db) statement (or parameters []))))

(defmacro transact [s & body]
  (with-syms [changed result]
    ~(if (= (,s :db) (dyn :zinc/transaction)) (do ,;body)
       (do
         (,sql/eval (,s :db) "BEGIN IMMEDIATE")
         (def ,changed @[false])
         (def ,result (try
           (let [value (with-dyns [:zinc/transaction (,s :db) :zinc/changed ,changed] ,;body)]
             (,sql/eval (,s :db) "COMMIT") value)
           ([err] (,sql/eval (,s :db) "ROLLBACK") (error err))))
         (when (,changed 0)
           (each channel (get ,s :signals [])
             (unless (ev/full channel) (ev/give channel true))))
         ,result))))

(defn open [config &opt readonly file]
  (def file (or file (uri (config :store))))
  (def temporary (not (nil? (string/find "vfs=memdb" file))))
  (def s @{:db (sql/open (string file (when readonly (string (if (string/find "?" file) "&" "?") "mode=ro"))))
           :file file :temporary temporary :config config :profiles @{}})
  (try
    (do
      (query s "PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000; PRAGMA trusted_schema=OFF; PRAGMA temp_store=MEMORY;")
      (unless readonly
        (unless temporary (query s "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;"))
        (transact s
          (unless (first (query s "SELECT name FROM sqlite_schema WHERE name='events'"))
            (query s layout)
            (query s "INSERT INTO events(key,kind,data) VALUES('store','store',?)" [(schema/encode {:id (uuid)})]))))
      (query s `CREATE TEMP VIEW published AS SELECT e.*,CASE WHEN e.kind<>'result' OR NOT EXISTS(
        SELECT 1 FROM events r WHERE r.parent=e.parent AND (
          (r.kind='return' AND (json_extract(e.data,'$.state')='done' OR json_extract(r.data,'$.state')<>'done'))
          OR (r.kind='diagnostic' AND json_extract(r.data,'$.error')=json_extract(e.data,'$.error'))))
        THEN e.id END publication FROM events e;`)
      (when readonly (query s "PRAGMA query_only=ON"))
      (put s :identity (get-in (first (query s "SELECT data FROM events WHERE key='store'")) [:data :id])) s)
    ([err] (sql/close (s :db)) (error err))))

(defn close [s] (sql/close (s :db)))

(defn temporary [config]
  (def s (open config nil (string "file:/zinc-" (uuid) "?vfs=memdb")))
  (try
    (do
      (query s (string "PRAGMA max_page_count=" (math/floor (/ (config :journal-bytes) (((query s "PRAGMA page_size") 0) :page_size)))))
      (query s "ATTACH DATABASE ? AS archive" [(string (uri (config :store)) "?mode=ro&vfs="
        (if (index-of (os/which) [:windows :mingw]) "win32" "unix"))])
      (transact s
        (query s "INSERT INTO images SELECT * FROM archive.images WHERE hash IN (SELECT image FROM archive.events)")
        (query s "INSERT INTO events(id,parent,key,kind,data,image,created) SELECT id,parent,key,kind,data,image,created FROM archive.events WHERE key IS NOT 'store' ORDER BY id")
        (query s "INSERT INTO worlds SELECT * FROM archive.worlds"))
      (query s "DETACH DATABASE archive")
      (put s :floor (((query s "SELECT max(id) id FROM events") 0) :id)) s)
    ([err] (close s) (error err))))

(defn image [s value &opt encoded]
  (def bytes (if encoded value (schema/encode value)))
  (assert (<= (length bytes) ((s :config) :journal-bytes)) "stored value byte ceiling")
  (def hash (digest bytes))
  (query s "INSERT OR IGNORE INTO images(hash,bytes) VALUES(?,?)" [hash (buffer bytes)]) hash)

(defn restore [s hash]
  (def row (first (query s "SELECT * FROM images WHERE hash=?" [hash])))
  (assert row "stored value is unavailable")
  (json/decode (row :bytes) true))

(defn event [s id]
  (def row (first (query s "SELECT * FROM events WHERE id=?" [id])))
  (assert row "event unavailable") row)

(defn inquiry [s id]
  (first (query s `WITH RECURSIVE ancestors AS (
    SELECT * FROM events WHERE id=? UNION ALL SELECT e.* FROM events e JOIN ancestors a ON e.id=a.parent
  ) SELECT * FROM ancestors WHERE kind='task' AND json_extract(data,'$.type')='inquiry' ORDER BY id DESC LIMIT 1` [id])))

(defn tree [s id &opt after mode]
  (def scope (when id (inquiry s id)))
  (def caller (when scope (inquiry s (scope :parent))))
  (query s `WITH RECURSIVE members(id,task,inquiry,caller) AS (
    SELECT id,CASE WHEN kind='task' THEN id END,
      CASE WHEN kind='task' AND json_extract(data,'$.type')='inquiry' THEN id ELSE ? END,?
      FROM events WHERE id=? OR (? IS NULL AND parent IS NULL AND kind='task' AND id>?)
    UNION ALL SELECT e.id,CASE WHEN e.kind='task' THEN e.id ELSE m.task END,
      CASE WHEN e.kind='task' AND json_extract(e.data,'$.type')='inquiry' THEN e.id ELSE m.inquiry END,
      CASE WHEN e.kind='task' AND json_extract(e.data,'$.type')='inquiry' THEN m.inquiry ELSE m.caller END
      FROM events e JOIN members m ON e.parent=m.id
  ) SELECT e.id,e.parent,e.key,e.kind,e.text,e.image,e.created,e.publication,
    CASE WHEN e.kind='model' THEN json_remove(e.data,'$.request') ELSE json_remove(e.data,'$.raw') END data,
    m.task,m.inquiry,m.caller,json_extract(owner.data,'$.type') AS "task-type",parent.kind AS "parent-kind",
    CASE WHEN e.kind='result' AND parent.kind='operation' THEN json_object('arguments',json_extract(parent.data,'$.arguments'),
      'name',json_extract(parent.data,'$.name')) END operation
    FROM published e JOIN members m ON m.id=e.id LEFT JOIN events owner ON owner.id=m.task LEFT JOIN events parent ON parent.id=e.parent
    WHERE e.id>? AND (?=0 OR m.inquiry IS ? OR m.inquiry IS NULL
      OR (m.caller IS ? AND e.kind='result' AND (
        (parent.kind='model' AND json_extract(e.data,'$.turn')=1
          AND (json_extract(e.data,'$.status') IN ('complete','refused','blocked') OR json_type(e.data,'$.error')='object'))
        OR (parent.kind='task' AND e.parent=m.inquiry))))
    AND (?=0 OR (json_extract(owner.data,'$.type')<>'summary' AND e.publication IS NOT NULL AND (
      e.kind IN ('return','output','fiber','artifact','diagnostic','notice')
      OR (e.kind='result' AND e.parent<>? AND (parent.kind IN ('operation','task')
        OR (parent.kind='model' AND m.caller IS ? AND json_extract(e.data,'$.turn')=1
          AND (json_extract(e.data,'$.status') IN ('complete','refused','blocked') OR json_type(e.data,'$.error')='object')))))))
    ORDER BY e.id` [(get scope :id) (get caller :id) id id (get s :floor 0) (or after 0)
      (if mode 1 0) (get scope :id) (get scope :id) (if (= mode :changes) 1 0) id (get scope :id)]))

(defn owners [s rows]
  (tabseq [row :in (query s "SELECT id,parent,json_remove(data,'$.input') data FROM events WHERE id IN (SELECT value FROM json_each(?))"
    [(schema/encode (distinct (map |($ :task) rows)))])] (row :id) row))

(defn task [s id]
  (first (query s `WITH RECURSIVE ancestors AS (
    SELECT * FROM events WHERE id=? UNION ALL SELECT e.* FROM events e JOIN ancestors a ON e.id=a.parent
  ) SELECT * FROM ancestors WHERE kind='task' ORDER BY id DESC LIMIT 1` [id])))

(defn root [s id]
  (first (query s `WITH RECURSIVE ancestors AS (
    SELECT * FROM events WHERE id=? UNION ALL SELECT e.* FROM events e JOIN ancestors a ON e.id=a.parent
  ) SELECT * FROM ancestors WHERE kind='task' ORDER BY id LIMIT 1` [id])))

(defn result [s id] (first (query s "SELECT * FROM events WHERE parent=? AND kind='result'" [id])))
(defn progress [s id] (first (query s "SELECT data FROM claims WHERE task=?" [id])))
(defn turn [s id]
  (first (query s `SELECT m.* FROM events m WHERE m.parent=? AND m.kind='model' AND json_extract(m.data,'$.turn')=1
    AND NOT EXISTS(SELECT 1 FROM events r JOIN events t ON t.parent=r.id AND t.kind='turn'
      WHERE r.parent=m.id AND r.kind='result') ORDER BY m.id LIMIT 1` [id])))

(defn outcome [s id]
  (or (first (query s "SELECT * FROM events WHERE parent=? AND kind IN ('return','result') ORDER BY id LIMIT 1" [id]))
    (when-let [response (first (query s `SELECT r.* FROM events m JOIN events r ON r.parent=m.id AND r.kind='result'
      WHERE m.parent=? AND m.kind='model' AND json_extract(m.data,'$.turn')=1
      AND (json_extract(r.data,'$.status') IN ('complete','refused','blocked') OR json_type(r.data,'$.error')='object')
      AND EXISTS(SELECT 1 FROM events t WHERE t.parent=r.id AND t.kind='turn') ORDER BY r.id DESC LIMIT 1` [id]))]
      (merge response {:data (merge {:state (get-in response [:data :state])
        :text (get-in response [:data :text] (get-in response [:data :error :message]))
        :value (if (get-in response [:data :error]) :null (schema/project (response :data) [:text :status]))}
        (schema/project (response :data) [:error]))}))))

(defn handle [s task]
  {:script (task :id) :store (s :identity) :request (get-in task [:data :request]) :persist (not (s :temporary))})

(defn pending [s &opt id]
  (query s `WITH RECURSIVE members(id) AS (
    SELECT id FROM events WHERE id=? OR (? IS NULL AND parent IS NULL AND kind='task' AND id>?)
    UNION ALL SELECT e.id FROM events e JOIN members m ON e.parent=m.id
  ) SELECT e.* FROM events e JOIN members m ON m.id=e.id WHERE e.kind IN ('task','operation')
    AND NOT EXISTS(SELECT 1 FROM events r WHERE r.parent=e.id AND r.kind='result')
    AND (json_extract(e.data,'$.type') IS NOT 'inquiry'
      OR NOT EXISTS(SELECT 1 FROM claims c WHERE c.task=e.id AND json_extract(c.data,'$.wait.changes')=1)
      OR EXISTS(SELECT 1 FROM events m WHERE m.parent=e.id AND m.kind='model' AND json_extract(m.data,'$.turn')=1
        AND NOT EXISTS(SELECT 1 FROM events r JOIN events t ON t.parent=r.id AND t.kind='turn'
          WHERE r.parent=m.id AND r.kind='result'))) ORDER BY e.id`
    [id id (get s :floor 0)]))

(defn work [s &opt lane]
  (def roots (distinct (map |((root s ($ :id)) :id) (pending s))))
  (query s `SELECT * FROM events WHERE id IN (SELECT value FROM json_each(?))
    AND (? IS NULL OR json_extract(data,'$.input.lane')=?) ORDER BY id` [(schema/encode roots) lane lane]))

(defn busy? [s id]
  (or (find |(not= id ($ :id)) (pending s id))
    (first (query s "SELECT id FROM events t WHERE kind='task' AND json_extract(data,'$.input.notify')=? AND NOT EXISTS(SELECT 1 FROM events r WHERE r.parent=t.id AND r.kind='result') LIMIT 1" [id]))))

(defn changes [s id after] (tree s id after :changes))

(defn check [s id]
  (assert (not (result s id)) {:code "TaskClosed" :message "Task ended."})
  (def current (event s id))
  (assert (= (get-in current [:data :epoch]) (get (first (query s "SELECT epoch FROM worlds WHERE name=?" [(get-in current [:data :world])])) :epoch))
          {:code "TaskReplaced" :message "World was rewound."})
  (def expires (get-in current [:data :expires]))
  (assert (or (nil? expires) (> expires (os/clock))) {:code "DeadlineExceeded" :message "Task deadline expired."}))

(defn append [s parent kind data &opt key image]
  (transact s
    (when (dyn :zinc/task) (check s ((dyn :zinc/task) :id)))
    (def bytes (schema/encode data))
    (def previous (when key (first (query s "SELECT * FROM events WHERE key=?" [key]))))
    (if previous
      (do (assert (and (= parent (previous :parent)) (= kind (previous :kind)) (= image (previous :image))
                       (= bytes (schema/encode (previous :data)))) "event key reused with different work") previous)
      (do
        (when (and (dyn :zinc/task) (index-of kind ["task" "model" "operation" "result" "return" "output" "fiber"]))
          (def usage (first (query s `WITH RECURSIVE members(id) AS (
            SELECT ? UNION ALL SELECT e.id FROM events e JOIN members m ON e.parent=m.id
          ) SELECT count(CASE WHEN e.kind IN ('task','model','operation') THEN 1 END) work,
            coalesce(sum(CASE WHEN e.kind IN ('operation','result','return','output','fiber') AND json_extract(e.data,'$.type') IS NOT 'model'
              THEN (length(CAST(e.data AS BLOB))+3)/4 ELSE 0 END),0) tools
            FROM events e JOIN members m ON m.id=e.id` [((root s ((dyn :zinc/task) :id)) :id)])))
          (when (index-of kind ["task" "model" "operation"])
            (assert (< (usage :work) ((s :config) :task-quota)) "work quota exhausted"))
          (when (and (not (data :error)) (index-of kind ["operation" "result" "return" "output" "fiber"]) (not= "model" (data :type)))
            (assert (<= (+ (estimate bytes) (usage :tools)) ((s :config) :tool-quota)) "tool output quota exhausted")))
        (assert (<= (length bytes) (+ ((s :config) :request-bytes) ((s :config) :response-bytes))) "event byte ceiling")
        (def row (first (query s "INSERT INTO events(parent,key,kind,data,image) VALUES(?,?,?,?,?) RETURNING *" [parent key kind bytes image])))
        (put (dyn :zinc/changed) 0 true)
        (def owner (when parent (task s parent)))
        (def response (and owner (not= "summary" (get-in owner [:data :type]))
          (get (first (query s "SELECT publication FROM published WHERE id=?" [(row :id)])) :publication)
          (or (index-of kind ["return" "output" "fiber" "artifact" "diagnostic" "notice"])
            (and (= kind "result") (not= "model" (data :type)))
            (and (= kind "result") (data :turn)
              (or (data :error) (index-of (data :status) ["complete" "refused" "blocked"]))))))
        (when response
          (def target (inquiry s (if (or (= "model" (data :type))
            (and (= kind "result") (= "inquiry" (get-in owner [:data :type])) (= parent (owner :id)))) (owner :parent) parent)))
          (when target
            (query s `INSERT INTO claims(task,data) SELECT ?,'{}'
              WHERE NOT EXISTS(SELECT 1 FROM events WHERE parent=? AND kind='result')
              ON CONFLICT(task) DO UPDATE SET data=json_remove(claims.data,'$.wait')` [(target :id) (target :id)]))
          (when-let [notify (get-in owner [:data :input :notify])]
            (unless (result s notify)
              (append s notify "notice" {:source (row :id)} (string "notice:" notify ":" (row :id)))))) row))))

(defn advance [s data]
  (transact s
    (def id ((dyn :zinc/task) :id))
    (check s id)
    (query s "UPDATE claims SET data=? WHERE task=?" [(schema/encode data) id])))

(defn finish [s id state value &opt failure]
  (transact s
    (def outcome (or (result s id) (append s id "result"
      (merge {:state state :value (if (nil? value) :null value) :text (cond failure (string (failure :code) ": " (failure :message)) (string? value) value (schema/encode value))}
        (if failure {:error failure} {})) (string "result:" id))))
    (query s "DELETE FROM claims WHERE task=?" [id]) outcome))

(defn point [s value &opt world]
  (def row (first (query s "SELECT * FROM events WHERE (kind IN ('world','rewind') OR (kind='artifact' AND json_extract(data,'$.type')='world-image')) AND (CAST(id AS TEXT)=? OR image=?) AND (? IS NULL OR json_extract(data,'$.world')=?) ORDER BY id DESC LIMIT 1" [(string value) (string value) world world])))
  (assert row "choose a committed world publication ID or image hash") row)

(defn configure [s]
  (transact s
    (each profile (filter identity [(s :config) (get-in s [:config :agent])])
    (each [name spec] (pairs (profile :worlds))
      (unless (first (query s "SELECT name FROM worlds WHERE name=?" [(string name)]))
        (def source (when (spec :from) (point s (spec :from))))
        (def row (append s nil "world" {:world (string name) :from (get source :id)} nil
          (if source (source :image)
            (image s (marshal [1 janet/version janet/build janet/config-bits [] nil] @{}) true))))
        (query s "INSERT INTO worlds(name,head) VALUES(?,?)" [(string name) (row :id)]))))))

(defn world-image [s world &opt through]
  (def row (if through (point s through world)
    (event s ((first (query s "SELECT head FROM worlds WHERE name=?" [world])) :head))))
  (assert (= world (get-in row [:data :world])) "publication belongs to another world")
  (def stored (first (query s "SELECT bytes FROM images WHERE hash=?" [(row :image)])))
  (assert stored "world image is unavailable")
  (def snapshot (unmarshal (stored :bytes) @{}))
  (assert (and (tuple? snapshot) (= 6 (length snapshot)) (= 1 (snapshot 0))
    (= janet/version (snapshot 1)) (= janet/build (snapshot 2)) (= janet/config-bits (snapshot 3)))
    "world image requires its original Janet runtime")
  [row snapshot])

(defn view [s world &opt through]
  (def [row snapshot] (world-image s world through))
  (def bindings (snapshot 4))
  {:world world :revision (row :id) :hash (row :image) :bindings bindings
   :summary (string "World " world " · #" (row :id) " · " (row :image))
   :text (string/join (distinct (map (fn [binding]
     (assert (string? (binding :source)) (string "source was not recorded for " (binding :name)))
     (binding :source))
     (sorted bindings |(< [($0 :script) ($0 :form) ($0 :name)] [($1 :script) ($1 :form) ($1 :name)])))) "\n\n")})

(defn publish [s bytes expected aliases]
  (assert (<= (length bytes) ((s :config) :world-bytes)) "world byte ceiling")
  (def snapshot (unmarshal bytes @{}))
  (unmarshal (snapshot 5)
    (merge load-image-dict (tabseq [key :in aliases] key @{})))
  (def row (transact s
    (def current (dyn :zinc/task))
    (def world (get-in current [:data :world]))
    (def head ((first (query s "SELECT head FROM worlds WHERE name=?" [world])) :head))
    (def conflict (not= expected head))
    (def row (append s (current :id) (if conflict "artifact" "world")
      {:world world :type "world-image" :expected expected :actual head
       :text (if conflict "World changed; candidate image retained without replacing the current world."
         (string "Published " (length (snapshot 4)) " world bindings."))}
      nil (image s bytes true)))
    (unless conflict (query s "UPDATE worlds SET head=? WHERE name=?" [(row :id) world]))
    row))
  (when (= "artifact" (row :kind))
    (error {:code "WorldChanged" :message "World changed; candidate image was retained."
      :context {:candidate (row :id) :hash (row :image)
        :world (get-in row [:data :world]) :expected (get-in row [:data :expected])
        :actual (get-in row [:data :actual])}}))
  {:world (get-in row [:data :world]) :revision (row :id) :hash (row :image)})

(defn start [s input config &opt parent]
  (assert (or (not (config :ephemeral)) (s :temporary)) "ephemeral profiles require a RAM store")
  (assert (not= (nil? (input :text)) (nil? (input :code))) "supply exactly one of text or code")
  (assert (if (input :text) (config :inference) (config :janet)) "execution is not granted")
  (assert (<= (length (get input :code "")) (config :source-bytes)) "source byte ceiling")
  (assert (<= (sum (map |(length (base64/decode ($ :data))) (get input :images []))) (config :image-bytes)) "input image byte ceiling")
  (def key (get input :request (uuid)))
  (transact s
    (if-let [previous (first (query s "SELECT * FROM events WHERE key=?" [(string "task:" key)]))]
      (do
        (def transient [:request :store :session :connector :deadline :author])
        (assert (and (= parent (previous :parent))
          (= (get input :author (config :handle)) (get-in previous [:data :author]))
          (= (schema/encode (schema/project input transient true))
             (schema/encode (schema/project (get-in previous [:data :input]) transient true)))) "request key reused with different work")
        previous)
      (do
        (def caller (when parent (task s parent)))
        (def root (when caller (root s (caller :id))))
        (when caller
          (assert (< (((query s `WITH RECURSIVE ancestors AS (
            SELECT * FROM events WHERE id=? UNION ALL SELECT e.* FROM events e JOIN ancestors a ON e.id=a.parent
          ) SELECT count(*) n FROM ancestors WHERE kind='task'` [parent]) 0) :n) (config :task-depth)) "task depth exhausted"))
        (def last (get input :parent (or parent (((query s "SELECT coalesce(max(id),0) id FROM events") 0) :id))))
        (assert (and (int? last) (>= last 0)) "parent must be a nonnegative event ID")
        (when (> last 0) (event s last))
        (def bounds (get input :memory_range {:start (if (= last 0) 0 1) :end last}))
        (assert (and (dictionary? bounds) (= (tuple/slice (sorted (keys bounds))) [:end :start])
          (int? (bounds :start)) (int? (bounds :end)) (<= 0 (bounds :start) (bounds :end) last)
          (= (= 0 (bounds :start)) (= 0 (bounds :end)))) "invalid memory range")
        (when (> (bounds :end) 0) (event s (bounds :end)))
        (when (and caller (not (input :summary))) (assert (<= last parent) "child history exceeds its admission point"))
        (def world (get input :world (if caller (get-in caller [:data :world]) (config :world))))
        (assert (has-key? (config :worlds) (keyword world)) "world is not granted")
        (when-let [target (input :notify)]
          (def inquiry (event s target))
          (assert (and (not (s :temporary)) (input :code) (not parent) (not (config :inference))
            (= "inquiry" (get-in inquiry [:data :type]))
            (= (input :author) (get-in inquiry [:data :author]))) "notification target is outside this execution grant"))
        (def epoch ((first (query s "SELECT epoch FROM worlds WHERE name=?" [world])) :epoch))
        (assert epoch "configured world is unavailable")
        (def deadline (min (if (> (config :run-seconds) 0) (+ (os/clock) (config :run-seconds)) math/inf)
          (or (get-in root [:data :expires]) math/inf) (or (input :deadline) math/inf)))
        (def admitted (append s parent "task" {:type (cond (input :summary) "summary" (input :text) "inquiry" "script") :request key :input (schema/project input [:author] true)
          :world world :epoch epoch :memory_range bounds :call (get input :call (get-in caller [:data :call]))
          :author (get input :author (config :handle)) :at (get input :at (os/strftime "%Y-%m-%dT%H:%M:%SZ"))
          :expires (unless (= deadline math/inf) deadline)} (string "task:" key) (image s config)))
        (when (= "inquiry" (get-in admitted [:data :type]))
          (query s "INSERT INTO claims(task) VALUES(?)" [(admitted :id)]))
        (when (first (query s "SELECT id FROM events WHERE key=?" [(string "cancel:" key)])) (finish s (admitted :id) "cancelled" nil)) admitted))))

(defn record [s records]
  (assert (and (indexed? records) (<= (length records) ((s :config) :history-records))) "invalid context batch")
  (transact s
    (map (fn [record]
      (assert (= (tuple/slice (sorted (keys record))) [:at :author :key :text]) "invalid context fields")
      (each value (values record) (assert (and (string? value) (> (length value) 0)) "invalid context value"))
      ((append s nil "context" record (string "context:" (record :key))) :id)) records)))

(defn abort [s request reason]
  (transact s
    (unless (first (query s "SELECT id FROM events WHERE key=?" [(string "cancel:" request)]))
      (append s nil "cancel" {:request request :reason reason} (string "cancel:" request)))
    (def task (first (query s "SELECT id FROM events WHERE key=?" [(string "task:" request)])))
    (when task
      (each child (filter |(index-of ($ :kind) ["task" "operation"]) (tree s (task :id)))
        (unless (result s (child :id))
          (finish s (child :id) "cancelled" nil))))
    {:script (get task :id) :state (if (= "done" (get-in (when task (result s (task :id))) [:data :state])) "completed" "cancelled")}))

(defn rewind [s world target]
  (transact s
    (def selected (point s target world))
    (assert (= world (get-in selected [:data :world])) "publication belongs to another world")
    (world-image s world (selected :id))
    (def previous (first (query s "SELECT * FROM worlds WHERE name=?" [world])))
    (each task (query s `SELECT e.* FROM events e WHERE kind IN ('task','operation') AND json_extract(data,'$.world')=?
      AND NOT EXISTS(SELECT 1 FROM events r WHERE r.parent=e.id AND r.kind='result')` [world])
      (finish s (task :id) "cancelled" nil {:code "WorldRewound" :message "World was rewound."}))
    (def row (append s nil "rewind" {:world world :previous (previous :head) :point (selected :id) :epoch (+ 1 (previous :epoch))} nil (selected :image)))
    (query s "UPDATE worlds SET head=?,epoch=epoch+1 WHERE name=?" [(row :id) world]) (view s world)))
