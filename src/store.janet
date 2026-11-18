(import sqlite3 :as sql)
(import spork/json :as json)
(import spork/path :as path)
(import spork/base64 :as base64)
(import jsec/crypto :as crypto)
(import ./config)

(def layout (string (slurp (path/join (path/dirname (dyn :source)) "store.sql"))))
(defn digest [bytes] (string/join (map |(string/format "%02x" $) (string/bytes (crypto/digest :sha256 bytes)))))
(defn nonce [] (string/join (map |(string/format "%02x" $) (os/cryptorand 16))))
(defn uri [file] (string "file:" (string/replace-all "?" "%3F" (string/replace-all "#" "%23" (string/replace-all "%" "%25" file)))))
(defn query [s statement &opt parameters]
  (map (fn [row] (def r (merge row))
    (when (string? (r :data)) (put r :data (json/decode (r :data) true true))) r)
    (sql/eval (s :db) statement (or parameters []))))
(defn reload [s]
  (table/clear (s :rows))
  (def seen @{})
  (each r (query s "SELECT * FROM heads")
    (when (r :run) (put r :run (unmarshal (r :run))))
    (def h (get (s :heads) (r :id)))
    (if h (do (table/clear h) (merge-into h r)) (put (s :heads) (r :id) r))
    (put seen (r :id) true))
  (each id (keys (s :heads)) (unless (seen id) (put (s :heads) id nil))))
(defmacro transact [s & body]
  ~(if (or (not (,s :db)) (= (,s :db) (dyn :zinc/transaction))) (do ,;body)
    (do (,query ,s "BEGIN IMMEDIATE")
      (try (let [result (with-dyns [:zinc/transaction (,s :db)] ,;body)]
             (,query ,s "COMMIT") (table/clear (,s :rows)) result)
        ([err] (,query ,s "ROLLBACK") (,reload ,s) (error err))))))
(defn row [s id]
  (assert (and (int? id) (not= 0 id)) "point must be a nonzero integer")
  (def cache (when (or (not (s :db)) (= (s :db) (dyn :zinc/transaction))) (s :rows)))
  (def r (or (get cache id)
    (if (s :db) (first (query s "SELECT * FROM journal WHERE id=?" [id]))
      (when (> id 0) (def copy (merge (row (s :source) id)))
        (put copy :data (unmarshal (marshal (copy :data)))) copy))))
  (assert r "point unavailable") (when cache (put cache id r)) r)
(defn intake [s point conversation keys]
  (if point
    (query s `WITH RECURSIVE ancestry(id,previous,through) AS (
      SELECT id,previous,CASE WHEN json_extract(data,'$.coverage.conversation')=?1
        THEN json_extract(data,'$.coverage.through') END FROM journal WHERE id=?2
      UNION ALL SELECT j.id,j.previous,CASE WHEN json_extract(j.data,'$.coverage.conversation')=?1
        THEN json_extract(j.data,'$.coverage.through') END FROM journal j JOIN ancestry a ON j.id=a.previous
        WHERE a.through IS NULL OR json_array_length(?3)>0
    ), coverage AS (
      SELECT id,null key,through FROM ancestry WHERE through IS NOT NULL ORDER BY id DESC LIMIT 1
    ) SELECT * FROM coverage UNION ALL
      SELECT j.id,json_extract(j.data,'$.source.key'),null FROM ancestry a JOIN journal j USING(id)
      WHERE json_extract(j.data,'$.source.conversation')=?1
        AND json_extract(j.data,'$.source.key') IN (SELECT value FROM json_each(?3))`
      [conversation point (config/encode keys)]) []))
(defn head [s id]
  (def h (get (s :heads) id)) (assert (and (int? id) h) "path unavailable") h)
(defn world [s name]
  (get (s :heads) name))
(defn save [s h c]
  (when (s :db)
    (def bytes (when (h :run) (marshal (h :run))))
    (assert (<= (length (or bytes "")) (c :journal-bytes)) "running graph exceeds byte limit")
    (query s "UPDATE heads SET point=?,run=? WHERE id=?" [(h :point) (when bytes (buffer bytes)) (h :id)])) h)
(defn create [s &opt name point]
  (def id (or name (if (s :db) ((first (query s "SELECT coalesce(max(id),0)+1 id FROM heads WHERE typeof(id)='integer'")) :id)
    (do (put s :next-head (- (s :next-head) 1)) (s :next-head)))))
  (when (s :db) (query s (if name "INSERT INTO heads(id,point) VALUES(?,?)"
    "INSERT INTO heads(id,point) VALUES(CAST(? AS INTEGER),?)") [id point]))
  (def h @{:id id :point point}) (put (s :heads) id h) h)
(defn replace [s r c]
  (def bytes (config/encode (r :data)))
  (assert (<= (+ (length bytes) (length (or (r :image) ""))) (c :journal-bytes)) "event byte limit")
  (when (s :db) (query s "UPDATE journal SET data=?,image=? WHERE id=?" [bytes (when (r :image) (buffer (r :image))) (r :id)]))
  (put (s :rows) (r :id) r) r)
(defn append [s h data c &opt image]
  (def bytes (config/encode data))
  (assert (<= (+ (length bytes) (length (or image ""))) (c :journal-bytes)) "event byte limit")
  (def id (if (s :db) ((first (query s "INSERT INTO journal(previous,data,image) VALUES(?,?,?) RETURNING id"
    [(h :point) bytes (when image (buffer image))])) :id)
    (do (put s :next-row (- (s :next-row) 1)) (s :next-row))))
  (def r @{:id id :previous (h :point) :data (merge data) :image image})
  (put (s :rows) id r) (put h :point id) r)
(defn text [r]
  (if (has-key? (r :data) :text) (get-in r [:data :text])
    (if (has-key? (r :data) :outcome) (config/encode (get-in r [:data :outcome])) "")))
(defn image [s point]
  (when point (def r (row s point)) (if (r :image) (r :image)
    (when-let [ref (get-in r [:data :bindings])] (image s ref)))))
(defn access [s point c]
  (when point (assert (index-of (get-in (row s point) [:data :world]) (c :worlds))
    {:code "NotAuthorized" :message "World is not granted."})) point)
(defn permit [s h c]
  (if (h :point) (access s (h :point) c)
    (assert (index-of (or (get-in h [:run :world]) (get-in h [:run :active :policy :world])
      (get-in (first (get-in h [:run :queue])) [:policy :world]) (c :world)) (c :worlds)) "world is not granted")) h)
(defn nearest [s point requested c]
  (when requested (assert (and (int? requested) (not= 0 requested)) "point must be a nonzero integer"))
  (var p point)
  (while (and p requested (if (> requested 0) (or (< p 0) (> p requested)) (and (< p 0) (< p requested))))
    (set p ((row s p) :previous)))
  (assert (and p (or (not requested) (> requested 0) (< p 0))) "no earlier point in the selected ancestry") (access s p c))
(defn result [s work]
  (def token (if (dictionary? work) (work :request) work))
  (def r (if (s :db) (first (query s "SELECT * FROM journal WHERE json_extract(data,'$.request')=? AND json_extract(data,'$.terminal')=1 ORDER BY id DESC LIMIT 1" [token]))
    (find |(and (= token (get-in $ [:data :request])) (get-in $ [:data :terminal])) (values (s :rows)))))
  (when r (when (dictionary? work) (assert (= (work :path) (get-in r [:data :path])) "work reference does not match path"))
    (merge (get-in r [:data :outcome])
      (if (= "response" (get-in r [:data :presentation :type])) {:value (get-in r [:data :text])} {}) {:point (r :id)})))
(defn pending [s]
  (catseq [h :in (values (s :heads)) :when (h :run)]
    (array/concat @[] (if-let [a (get-in h [:run :active])] [a] []) (get-in h [:run :queue] []))))
(defn admission [s work]
  (def token (work :request))
  (or (find |(and (= token ($ :request)) (= (work :path) ($ :path))) (pending s))
    (let [r (if (s :db)
      (first (query s "SELECT data FROM journal WHERE json_extract(data,'$.request')=? ORDER BY id LIMIT 1" [token]))
      (find |(and (= token (get-in $ [:data :request])) (get-in $ [:data :signature])) (values (s :rows))))
          d (get r :data)]
      (when (= (work :path) (get d :path)) (merge d {:policy {:scope (get d :scope)}})))))
(defn reaches? [s from target]
  (def pending (pending s)) (def seen @{})
  (def visit (fn visit [id]
    (or (= id target) (unless (seen id)
      (put seen id true) (def run ((head s id) :run)) (def a (get run :active)) (def queued (first (get run :queue [])))
      (or (some |(and ($ :path) (visit ($ :path))) (get run :waits []))
        (some |(and a (= (a :request) ($ :owner)) (visit ($ :path))) pending)
        (and queued (queued :owner) (get-in queued [:input :queue])
          (some |(and (= (queued :owner) ($ :owner)) (get-in $ [:input :queue]) (< ($ :order) (queued :order))
            (visit ($ :path))) pending)))))))
  (visit from))
(defn close [s]
  (each key [:db :lock :search] (when (s key) (sql/close (s key))))
  (when (get-in s [:source :read-only]) (close (s :source))))
(defn open [c &opt initialize source read-only]
  (def s @{:heads @{} :rows @{} :source source :next-head 0 :next-row 0
    :read-only read-only :identity (nonce)})
  (try (do
  (unless (c :temporary)
    (assert (= (c :directory) (os/realpath (c :directory))) "canonical instance directory required")
    (def relative (path/relpath (c :directory) (c :store)))
    (assert (and (not (path/abspath? relative)) (not= ".." (first (path/parts relative)))) "store must belong to instance")
    (if initialize
      (do (assert (not (os/lstat (c :store))) "initialization requires a fresh store")
        (var directory (c :directory))
        (each part (path/parts (path/dirname relative)) (unless (index-of part ["" "."])
          (set directory (path/join directory part)) (os/mkdir directory)
          (assert (= directory (os/realpath directory)) "state directories cannot contain links"))))
      (assert (os/stat (c :store)) "initialize the store first"))
    (unless read-only
      (def lock (sql/open (string (c :store) ".lock")))
      (try (sql/eval lock "PRAGMA busy_timeout=0; BEGIN EXCLUSIVE;")
        ([err] (sql/close lock) (error {:code "StoreBusy" :message "Store already has an execution host."})))
      (put s :lock lock))
    (put s :db (sql/open (if read-only (string (uri (c :store)) "?mode=ro") (c :store))))
    (query s "PRAGMA foreign_keys=ON; PRAGMA trusted_schema=OFF;")
    (unless read-only (query s "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;"))
    (when initialize
      (query s layout)
      (query s "INSERT INTO journal(data) VALUES(?)" [(config/encode {:kind "identity" :handle (c :handle) :stream (s :identity)})]))
    (assert (and (= ["id" "previous" "data" "image"] (tuple/slice (map |($ :name) (query s "PRAGMA table_info(journal)"))))
      (= ["id" "point" "run"] (tuple/slice (map |($ :name) (query s "PRAGMA table_info(heads)")))))
      {:code "FreshStateRequired" :message "Incompatible store layout; a separate fresh-state cutover must be authorized."})
    (def identity (get (first (query s "SELECT data FROM journal WHERE id=1")) :data))
    (assert (and (= "identity" (get identity :kind)) (= (c :handle) (identity :handle)) (string? (identity :stream)))
      "store identity mismatch; a fresh-history cutover must be explicitly initialized")
    (put s :identity (identity :stream))
    (reload s)
    (unless read-only (each a (pending s)
      (assert (= (c :runtime) (get-in a [:policy :runtime])) {:code "RuntimeChanged" :message "Unfinished execution requires its original runtime."}))))
  (unless read-only (each name (c :worlds) (unless (world s name)
    (create s name (when (and source (world source name)) ((world source name) :point)))))) s)
    ([err] (close s) (error err))))
(defn admit [s supplied c author &opt owner seed]
  (assert (dictionary? supplied) "input must be an object")
  (def input (merge supplied {:queue (get supplied :queue (c :queue))}))
  (assert (not= (nil? (input :text)) (nil? (input :code))) "supply exactly one of text or code")
  (each k [:text :code] (when (input k)
    (assert (and (string? (input k)) (<= (length (input k)) (c :source-bytes))
      (or (> (length (input k)) 0) (and (= k :text) (not (empty? (get input :images [])))))) "invalid source")))
  (each k (keys input) (assert (index-of k [:text :code :path :from :memory :queue :request :at :images :source]) (string "unknown input field " k)))
  (assert (not (and (input :path) (input :from))) "path and from are mutually exclusive")
  (assert (boolean? (get input :queue (c :queue))) "queue must be boolean")
  (assert (and (<= (length (get input :images [])) 4)
    (<= (sum (map |(length (base64/decode ($ :data))) (get input :images []))) (c :image-bytes))) "image limit")
  (each image (get input :images []) (assert (index-of (image :type) ["image/png" "image/jpeg" "image/webp"]) "invalid image type"))
  (def token (get input :request (nonce)))
  (assert (and (string? token) (<= 1 (length token) 256)) "request must be a nonempty string of at most 256 bytes")
  (def signature (digest (config/encode [input author (string (c :role))
    (tabseq [[k v] :pairs c :unless (index-of k [:registry :role])] k v)])))
  (def active (pending s))
  (def old (or (find |(= token ($ :request)) active)
    (if (s :db) (get (first (query s "SELECT data FROM journal WHERE json_extract(data,'$.request')=? ORDER BY id LIMIT 1" [token])) :data)
      (get (find |(= token (get-in $ [:data :request])) (values (s :rows))) :data))))
  (if old (do (assert (= signature (old :signature)) "request reused with different work") {:path (old :path) :request token})
    (do
      (assert (< (length active) (c :pending)) "pending request limit")
      (def base (or (input :from) (when (and (input :path) (s :source) (> (input :path) 0)) ((head (s :source) (input :path)) :point))))
      (access s base c) (when (input :memory) (access s (input :memory) c))
      (def target (when (and (input :path) (not base)) (head s (input :path))))
      (when target (permit s target c))
      (when (and owner target (target :run))
        (assert (not (reaches? s (target :id) (owner :path))) "recursive admission would form a wait cycle"))
      (def point (or base (get target :point)))
      (def selected (when point (row s point)))
      (assert (index-of (get seed :world (get-in selected [:data :world] (c :world))) (c :worlds)) "path world is not granted")
      (assert (or (input :queue) (not (get target :run))) {:code "PathBusy" :message "Path is busy; use queue true."})
      (def depth (if owner (+ 1 (owner :depth)) 0)) (assert (< depth (c :depth)) "recursion depth limit")
      (def id (if target (target :id) (if (s :db)
        ((first (query s "SELECT coalesce(max(id),0)+1 id FROM heads WHERE typeof(id)='integer'")) :id) (- (s :next-head) 1))))
      (def a @{:request token :path id :input input :policy c :author author :signature signature
        :owner (when owner (owner :request)) :depth depth :seed seed :order (+ 1 (reduce max 0 (map |($ :order) active)))
        :deadline (when (> (c :run-seconds) 0) (+ (os/clock) (c :run-seconds)))})
      (def run (get target :run))
      (def queue (array/concat @[] (get run :queue []) [a]))
      (def next (merge (or run {}) {:queue queue}))
      (def bytes (marshal next))
      (assert (<= (length bytes) (c :journal-bytes)) "running graph exceeds byte limit")
      (when (s :db)
        (if target (query s "UPDATE heads SET run=? WHERE id=?" [(buffer bytes) id])
          (query s "INSERT INTO heads(id,point,run) VALUES(CAST(? AS INTEGER),?,?)" [id point (buffer bytes)])))
      (if target (if run (put run :queue queue) (put target :run next))
        (do (unless (s :db) (put s :next-head id))
          (put (s :heads) id @{:id id :point point :run next})))
      {:path id :request token})))
