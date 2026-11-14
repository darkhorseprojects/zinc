(import sqlite3 :as sql)
(import spork/json :as json)
(import spork/path :as path)
(import spork/base64 :as base64)
(import jsec/crypto :as crypto)
(import ./config)

(def layout (string (slurp (path/join (path/dirname (dyn :source)) "store.sql"))))
(defn digest [bytes] (string/join (map |(string/format "%02x" $) (string/bytes (crypto/digest :sha256 bytes)))))
(defn nonce [] (string/join (map |(string/format "%02x" $) (os/cryptorand 24))))
(defn uri [file] (string "file:" (string/replace-all "?" "%3F" (string/replace-all "#" "%23" (string/replace-all "%" "%25" file)))))
(defn query [s statement &opt parameters]
  (map |(if (string? ($ :data)) (merge $ {:data (json/decode ($ :data) true true)}) $)
    (sql/eval (s :db) statement (or parameters []))))
(defmacro transact [s & body]
  ~(if (= (,s :db) (dyn :zinc/transaction)) (do ,;body)
    (do (,query ,s "BEGIN IMMEDIATE")
      (try (let [result (with-dyns [:zinc/transaction (,s :db)] ,;body)] (,query ,s "COMMIT") result)
        ([err fiber] (,query ,s "ROLLBACK") (error (,config/diagnostic err fiber)))))))
(defn row [s key &opt kind]
  (def r (first (query s "SELECT * FROM journal WHERE key=?" [key])))
  (assert (and r (or (nil? kind) (= kind (r :kind)))) "reference unavailable or wrong kind") r)
(defn load [s key &opt kind] ((row s key kind) :data))
(defn append [s kind data &opt key image]
  (def bytes (config/encode data))
  (assert (<= (+ (length bytes) (length (or image ""))) (get-in s [:config :journal-bytes])) "journal record exceeds byte limit")
  (default key (string (s :identity) "/" kind "/" (digest (string kind "\0" bytes (or image "")))))
  (if-let [old (first (query s "SELECT * FROM journal WHERE key=?" [key]))]
    (do (assert (and (= kind (old :kind)) (= bytes (config/encode (old :data)))
      (= (string (or image "")) (string (or (old :image) "")))) "record key reused with different data") (old :key))
    ((first (query s "INSERT INTO journal(key,kind,data,image) VALUES(?,?,?,?) RETURNING key"
      [key kind bytes (when image (buffer image))])) :key)))
(defn head [s kind name]
  (first (query s (case kind
    "point" "SELECT * FROM journal WHERE kind='point' AND json_extract(data,'$.path')=? ORDER BY sequence DESC LIMIT 1"
    "SELECT * FROM journal WHERE kind='world' AND json_extract(data,'$.world')=? ORDER BY sequence DESC LIMIT 1") [name])))
(defn point [s ref] (or (head s "point" ref) (row s ref "point")))
(defn image [s ref]
  (var r (row s ref))
  (while (and (not (r :image)) (= "point" (r :kind)))
    (set r (row s (or (get-in r [:data :seed]) (get-in r [:data :world])))))
  (r :image))
(defn receipt [s ref]
  (get (first (query s "SELECT data FROM journal WHERE key=?" [(string "receipt:" ref)])) :data))
(defn unfinished [s &opt kind]
  (query s `SELECT j.* FROM journal j WHERE j.kind IN ('input','effect') AND (? IS NULL OR j.kind=?)
    AND NOT EXISTS(SELECT 1 FROM journal r WHERE r.key='receipt:'||j.key) ORDER BY j.sequence` [kind kind]))
(defn accessible? [s ref author]
  (def p ((point s ref) :data))
  (or (= author (get-in s [:config :handle])) (= author (p :author))
    (when-let [owner (p :owner)] (accessible? s (get-in (row s owner "input") [:data :path]) author))))
(defn require-access [s ref author]
  (assert (accessible? s ref author) {:code "NotAuthorized" :message "Path belongs to another author."}))
(defn checkpoint [s p image &opt expected]
  (when expected (assert (= expected (get (head s "point" (p :path)) :key))
    {:code "ReferenceChanged" :message "Path advanced during computation."}))
  (append s "point" (merge p {:previous expected})
    (string (s :identity) "/point/" (nonce)) image))

(defn open [c &opt initialize]
  (def memory (c :ephemeral))
  (unless memory
    (assert (= (c :directory) (os/realpath (c :directory))) "canonical instance directory required")
    (def relative (path/relpath (c :directory) (c :store)))
    (assert (and (not (path/abspath? relative)) (not= ".." (first (path/parts relative)))) "store must belong to instance")
    (if initialize
      (do (assert (not (os/lstat (c :store))) "initialization requires a fresh store")
        (var directory (c :directory))
        (each part (path/parts (path/dirname relative))
          (unless (index-of part ["" "."]) (set directory (path/join directory part)) (os/mkdir directory)
            (assert (= directory (os/realpath directory)) "state directories cannot contain links"))))
      (assert (os/stat (c :store)) "initialize the store first")))
  (def lock (unless memory (sql/open (string (c :store) ".lock"))))
  (when lock (try (sql/eval lock "PRAGMA busy_timeout=0; BEGIN EXCLUSIVE;")
    ([err] (sql/close lock) (error {:code "StoreBusy" :message "Store already has an execution host."}))))
  (def s @{:db (sql/open (if memory ":memory:" (c :store))) :config c :lock lock :identity ""})
  (try
    (do
      (query s "PRAGMA foreign_keys=ON; PRAGMA trusted_schema=OFF; PRAGMA busy_timeout=5000;")
      (unless (or memory initialize)
        (assert (first (query s "SELECT name FROM sqlite_schema WHERE name='journal'")) "legacy store requires an explicit fresh-history cutover"))
      (unless memory (query s "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;"))
      (when (or memory initialize)
        (transact s (query s layout) (put s :identity (nonce))
          (append s "identity" {:id (s :identity) :handle (c :handle)} "identity")))
      (def identity (load s "identity" "identity"))
      (assert (= (identity :handle) (c :handle)) "store belongs to another agent")
      (assert (not (first (query s "SELECT key FROM journal WHERE kind='policy' AND json_extract(data,'$.runtime') IS NOT ? LIMIT 1" [(c :runtime)])))
        {:code "RuntimeChanged" :message "Store requires its original runtime; archive incompatible history before fresh initialization."})
      (put s :identity (identity :id))
      (query s "CREATE INDEX IF NOT EXISTS journal_output ON journal(json_extract(data,'$.output.id'),sequence) WHERE kind='output'")
      (each world (c :worlds) (unless (head s "world" world)
        (append s "world" {:world world} (string (s :identity) "/world/" (nonce))))) s)
    ([err] (sql/close (s :db)) (when lock (sql/close lock)) (error err))))
(defn close [s] (sql/close (s :db)) (when (s :lock) (sql/close (s :lock))))

(defn admit [s input policy author context &opt owner from]
  (assert (and (dictionary? input) (not= (nil? (input :text)) (nil? (input :code)))) "supply exactly one of text or code")
  (each k [:text :code] (when (has-key? input k)
    (assert (and (string? (input k)) (> (length (input k)) 0) (<= (length (input k)) (policy :source-bytes))) "invalid source")))
  (each k (keys input) (assert (index-of k [:text :code :path :from :memory :queue :request :records :at :images]) (string "unknown input field " k)))
  (assert (<= (length (get input :records [])) (policy :history-records)) "source batch limit")
  (assert (and (<= (length (get input :images [])) 4)
    (<= (sum (map |(length (base64/decode ($ :data))) (get input :images []))) (policy :image-bytes))) "image limit")
  (each image (get input :images []) (assert (index-of (image :type) ["image/png" "image/jpeg" "image/webp"]) "invalid image type"))
  (assert (not (and (input :path) (input :from))) "path and from are mutually exclusive")
  (when (has-key? input :queue) (assert (boolean? (input :queue)) "queue must be boolean"))
  (def id (string (s :identity) "/request/" (digest (get input :request (nonce)))))
  (def args {:payload input :policy (append s "policy" policy) :author author :context context :owner owner})
  (if-let [old (first (query s "SELECT * FROM journal WHERE key=?" [id]))]
    (do (assert (= (config/encode args) (config/encode (tabseq [[k v] :pairs (old :data) :unless (index-of k [:path :deadline])] k v))) "request identity reused with different work")
      {:path (get-in old [:data :path]) :request id})
    (do
      (assert (< (length (unfinished s "input")) (policy :pending)) "pending request limit")
      (def path (or (input :path) (string (s :identity) "/path/" (nonce))))
      (if (input :path)
        (do (require-access s path author)
          (assert (index-of (get-in (point s path) [:data :world-name]) (policy :worlds)) "path world is not granted")
          (assert (or (input :queue) (not (find |(= path (get-in $ [:data :path])) (unfinished s "input"))))
            {:code "PathBusy" :message "Path is busy; use queue true."}))
        (do
          (var depth 0) (var ancestor owner)
          (while ancestor (++ depth) (assert (< depth (policy :depth)) "recursion depth limit")
            (set ancestor (get-in (row s ancestor "input") [:data :owner])))
          (def base (when-let [ref (or (input :from) from)] (point s ref)))
          (when base (require-access s (base :key) author))
          (def world (get-in base [:data :world-name] (policy :world)))
          (assert (index-of world (policy :worlds)) "world is not granted")
          (checkpoint s {:path path :author author :owner owner :world-name world
            :world (if base (get-in base [:data :world]) ((head s "world" world) :key))
            :seed (when base (base :key))
            :view (or (input :memory) (get-in base [:data :view]) (append s "view" {:roots [] :invalid []}))} nil)))
      (append s "input" (merge args {:path path :deadline (when (> (policy :run-seconds) 0) (+ (os/clock) (policy :run-seconds)))}) id)
      {:path path :request id})))

(defn blocked-by [s request]
  (def d (request :data))
  (map |($ :key) (filter (fn [old]
    (def o (old :data))
    (and (< (old :sequence) (request :sequence))
      (or (= (o :path) (d :path))
        (and (d :owner) (get-in d [:payload :queue]) (get-in o [:payload :queue]) (= (o :owner) (d :owner))))))
    (unfinished s "input"))))
(defn depends? [s from target &opt seen]
  (default seen @{})
  (cond (= from target) true (seen from) false
    (do (put seen from true)
      (def r (row s from))
      (when (and (= "input" (r :kind)) (not (receipt s from)))
        (def p ((head s "point" (get-in r [:data :path])) :data))
        (some |(depends? s $ target seen)
          (array/concat (blocked-by s r) (if (= from (p :active)) (p :waits) [])))))))
(defn emit [s request output &opt state]
  (def a (load s request "input"))
  (def key (string (s :identity) "/output/" (nonce)))
  (def id (get output :id key))
  (def previous (first (query s
    "SELECT data FROM journal WHERE kind='output' AND json_extract(data,'$.output.id')=? ORDER BY sequence DESC LIMIT 1" [id])))
  (def old (get-in previous [:data :output]))
  (when old
    (assert (= request (get-in previous [:data :work :request])) "output belongs to another request")
    (assert (not (old :done)) "output is already complete")
    (unless (= "metadata" (output :type))
      (unless (= "metadata" (old :type))
        (each k [:type :format :language :reply] (assert (= (old k) (output k)) "output format changed")))))
  (when (= "metadata" (output :type))
    (assert (and old (not= "metadata" (old :type))) "metadata requires an open message"))
  (def value {:context (a :context) :work {:path (a :path) :request request} :state state
    :retain (not ((load s (a :policy) "policy") :ephemeral))
    :output (merge output {:id id :revision (+ 1 (get old :revision -1))})})
  (assert (< (length (config/encode {:type "event" :value (merge value {:stream (s :identity) :cursor key})})) (s :frame-limit))
    {:code "OutputLimit" :message "Committed output would exceed PA_FRAME_BYTES."})
  (append s "output" value key) id)
(defn close-output [s request outcome &opt prefix state]
  (var status outcome)
  (when (and status (nil? prefix))
    (def previous (get (first (query s `SELECT r.data FROM journal e LEFT JOIN journal r ON r.key='receipt:'||e.key
      WHERE e.kind='effect' AND json_extract(e.data,'$.owner')=? AND json_extract(e.data,'$.binding')='model/chat'
      AND json_extract(e.data,'$.arguments[0].round') IS NOT NULL ORDER BY e.sequence DESC LIMIT 1` [request])) :data))
    (when (and (= "ok" (get previous :status)) (index-of (get-in previous [:value :stop]) ["tools" "continue" "answer" "refused"]))
      (set status nil)))
  (var messages (filter (fn [r]
    (def o (get-in r [:data :output]))
    (and (not (o :done)) (or (nil? prefix) (= prefix (o :id)) (string/has-prefix? (string prefix "/") (o :id)))))
    (query s `SELECT data FROM (
      SELECT data,sequence,row_number() OVER (PARTITION BY json_extract(data,'$.output.id') ORDER BY sequence DESC) n
      FROM journal WHERE kind='output' AND json_extract(data,'$.work.request')=?
      AND json_extract(data,'$.output.type')!='metadata') WHERE n=1 ORDER BY sequence` [request])))
  (when (and status (empty? messages))
    (def id (emit s request {:type "response" :format "markdown" :text "" :done false}))
    (set messages [{:data {:output {:id id :type "response" :format "markdown" :text ""}}}]))
  (when (and status (not (empty? messages)))
    (def a (row s request "input"))
    (def start (first (query s "SELECT sequence FROM journal WHERE kind='point' AND json_extract(data,'$.active')=? ORDER BY sequence LIMIT 1" [request])))
    (def origin (when prefix (get (first (query s `SELECT sequence FROM journal WHERE kind='effect'
      AND json_extract(data,'$.owner')=? AND (?=key OR substr(?,1,length(key)+1)=key||'/')
      ORDER BY sequence DESC LIMIT 1` [request prefix prefix])) :sequence)))
    (def round (get (first (query s `SELECT json_extract(data,'$.arguments[0].round') round FROM journal
      WHERE kind='effect' AND json_extract(data,'$.owner')=? AND json_extract(data,'$.binding')='model/chat'
      AND json_extract(data,'$.arguments[0].round') IS NOT NULL AND (? IS NULL OR sequence<=?)
      ORDER BY sequence DESC LIMIT 1` [request origin origin])) :round 1))
    (def end (head s "point" (get-in a [:data :path])))
    (emit s request {:id (get-in (last messages) [:data :output :id]) :type "metadata"
      :text (string "#" (get start :sequence (a :sequence)) " (↻" round ") → #" (end :sequence) " · "
        (if (= status "error") "failed" status))}))
  (each r messages
    (emit s request (merge (get-in r [:data :output]) {:text "" :done true}) state)))
(defn finish [s ref value]
  (or (receipt s ref)
    (do
      (append s "receipt" (merge value {:call ref}) (string "receipt:" ref))
      (def r (row s ref)) (def owner (get-in r [:data :owner]))
      (when (and (= "effect" (r :kind)) (not (receipt s owner))
        (first (query s "SELECT key FROM journal WHERE kind='output' AND json_extract(data,'$.output.id')=? LIMIT 1" [(string ref "/call")])))
        (emit s owner {:id (string ref "/result") :type "tool-result" :format "json" :text (config/encode value) :done false})
        (close-output s owner (value :status) (string ref "/result")))
      value)))
(defn cancel [s id]
  (def rows (query s "SELECT * FROM journal WHERE kind IN ('input','effect') ORDER BY sequence")) (def owned @{id true})
  (each row rows (when (owned (get-in row [:data :owner])) (put owned (row :key) true)))
  (def selected (filter |(and (owned ($ :key)) (not (receipt s ($ :key)))) rows))
  (def result {:status "cancelled" :error {:code "Cancelled" :message "Work cancelled; dispatched actions are not undone."}})
  (each kind ["effect" "input"]
    (each r selected (when (= kind (r :kind))
      (finish s (r :key) result)
      (when (= kind "input")
        (emit s (r :key) {:type "response" :format "json" :text (config/encode result) :done false})
        (close-output s (r :key) "cancelled")))))
  (> (length selected) 0))
