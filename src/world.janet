(import spork/json :as json)
(import spork/path :as path)
(import ./store)

(defn process [config arguments &opt input environment]
  (assert (or (nil? input) (<= (length input) (config :request-bytes))) "process input byte ceiling")
  (def child (os/spawn arguments :pe
                       (merge (os/environ) (or environment {}) {:in :pipe :out :pipe :err :pipe})))
  (def deadline (+ (os/clock :monotonic) (/ (config :http-ms) 1000)))
  (def channel (ev/chan 2))

  (each key [:out :err]
    (ev/go (fn []
             (def output @"")
             (var failure nil)
             (try
               (do
                 (var bytes nil)
                 (while (set bytes (ev/read (child key) 4096 nil (max 0 (- deadline (os/clock :monotonic)))))
                   (assert (<= (+ (length output) (length bytes)) (config :response-bytes)) "process output byte ceiling")
                   (buffer/push-string output bytes)))
               ([err]
                 (set failure (string err))
                 (try (os/proc-kill child) ([err] nil))))
             (ev/close (child key))
             (ev/give channel {:key key :bytes (string output) :failure failure}))))

  (def timer (ev/go (fn []
                      (try (do (ev/sleep (max 0 (- deadline (os/clock :monotonic)))) (os/proc-kill child))
                        ([err] nil)))))
  (var waited false)

  (defer (do
           (unless (= :dead (fiber/status timer)) (ev/cancel timer "finished"))
           (unless waited
             (try (os/proc-kill child) ([err] nil))
             (try (os/proc-wait child) ([err] nil))))
    (when input (ev/write (child :in) input (max 0 (- deadline (os/clock :monotonic)))))
    (ev/close (child :in))
    (def a (ev/take channel))
    (def b (ev/take channel))
    (def status (os/proc-wait child))
    (set waited true)
    (assert (not (or (a :failure) (b :failure))) (or (a :failure) (b :failure)))
    {:status status
     :out (if (= :out (a :key)) (a :bytes) (b :bytes))
     :err (if (= :err (a :key)) (a :bytes) (b :bytes))}))

(defn command [config arguments]
  (def result (process config [(config :git) "-C" (config :repo) ;arguments]))
  (assert (= 0 (result :status)) (result :err))
  (string/trim (result :out)))

(defn inspect [s name]
  (assert (and (string? name) (index-of name ((s :config) :worlds))) "world not granted")
  (first (store/query s "SELECT * FROM worlds WHERE actor=? AND name=?" [(s :actor) name])))

(defn revision [s name]
  (inspect s name)
  (def config (s :config))
  (def accepted (first (store/query s "SELECT text FROM events WHERE actor=? AND kind='code-accepted' ORDER BY id DESC LIMIT 1" [(s :actor)])))
  (if accepted (accepted "text")
    (do
      (assert (= "" (command config ["status" "--porcelain" "--untracked-files=all"]))
              "commit the installed agent before starting revision-pinned work")
      (command config ["rev-parse" "HEAD"]))))

(defn materialize [s revision]
  (assert (peg/match ~(* (repeat 40 (set "0123456789abcdef")) -1) revision) "invalid agent revision")
  (def config (s :config))
  (def directory (path/join (config :state) "revisions"))
  (os/mkdir directory)
  (def root (path/join directory revision))
  (unless (os/stat root)
    (command config ["worktree" "add" "--detach" root revision]))
  (assert (= revision (command (merge config {:repo root}) ["rev-parse" "HEAD"])) "agent revision mismatch")
  (assert (= "" (command (merge config {:repo root}) ["status" "--porcelain" "--untracked-files=all"]))
          "pinned agent files changed")
  root)

(defn activate [s view value]
  (assert (and (dyn :zinc/user) (index-of "activate" ((s :config) :code-actions))) "user-triggered code activation required")
  (def prior (first (store/query s "SELECT data FROM events WHERE actor=? AND task=? AND kind='code-accepted'"
                                 [(s :actor) ((dyn :zinc/task) :id)])))
  (if prior (json/decode (prior "data") true true)
    (let [previous (revision s (view :world)) root (materialize s (value :revision))]
      (def check (pa/spawn "worker" (string (json/encode {:root root})) "" :member "validate-package" :imports []))
      (assert ((json/decode (pa/await check) true true) :accepted) "agent package validation failed")
      (store/transact s
                      (store/checkpoint s ((dyn :zinc/task) :checkpoint))
                      (assert (= previous (revision s (view :world))) "active code changed during validation")
                      (def result {:revision (value :revision) :previous previous})
                      (store/append s view "code-accepted" (value :revision) result nil ((dyn :zinc/task) :id))
                      result))))

(defn source [s view file]
  (assert (and (string? file)
               (index-of file (string/split "\n" (command (s :config) ["ls-tree" "-r" "--name-only" (view :revision)]))))
          "source path outside pinned agent")
  (def text (command (s :config) ["show" (string (view :revision) ":" file)]))
  (assert (<= (length text) ((s :config) :source-bytes)) "source byte ceiling")
  text)

(defn definition [s name revision]
  (def accepted (inspect s name))
  (def rules (get-in (s :spec) [:worlds (if accepted (accepted "definition") name)]))
  (assert rules "world definition unavailable")
  rules)

(defn document [node]
  (cond
    (string? node) node
    (dictionary? node) (string (when (node :name) (string (node :name) "\n"))
                               (string/join (map document (get node :content [])) "\n\n"))
    (indexed? node) (string/join (map document node) "\n")
    ""))

(defn operations [s view]
  (def rules (definition s (view :world) (view :revision)))
  (def selected (table ;(kvs (s :operations))))
  (each [name operation] (pairs (rules :operations))
    (when (and (index-of name (rules :requested)) (index-of name ((s :config) :capabilities)))
      (assert (not (has-key? selected name)) "world operation shadows an agent member")
      (put selected name operation)))
  (unless (and (rules :agent-merge) (index-of "merge" ((s :config) :world-actions)))
    (put selected "world/merge" nil))
  (unless (index-of "fork" ((s :config) :world-actions)) (put selected "world/fork" nil))
  selected)

(defn image [s view]
  (def event (first (store/query s "SELECT data FROM events WHERE id=? AND actor=? AND kind='world-image'"
                                 [(view :image) (s :actor)])))
  (assert event "world snapshot unavailable")
  (def snapshot (json/decode (event "data") true true))
  (assert (= (view :world) (snapshot :origin)) "snapshot belongs to another world")
  snapshot)

(defn initial-image [s name revision]
  (def accepted (inspect s name))
  (if accepted
    (merge (image s {:world name :image (accepted "head")}) {:base (accepted "head")})
    {:origin name :base 0 :bindings [] :state {}}))

(defn- validate [s view snapshot]
  (def validation (pa/spawn "worker"
                            (string (json/encode {:bindings (snapshot :bindings) :members (keys (operations s view))})) ""
                            :member "validate-image" :imports []))
  (assert ((json/decode (pa/await validation) true true) :accepted) "world validation rejected")
  snapshot)

(defn change [s view kind name value &opt expected]
  (def prior (first (store/query s "SELECT id,data FROM events WHERE actor=? AND task=? AND kind='world-image'"
                                 [(s :actor) ((dyn :zinc/task) :id)])))
  (if prior
    (let [snapshot (json/decode (prior "data") true true)]
      {:image (prior "id") :origin (snapshot :origin) :base (snapshot :base)})
    (do
      (def current (store/branch s (view :branch)))
      (def snapshot (image s (merge view {:image (current "image")})))
      (case kind
        "binding"
        (do
          (assert (and (string? name)
                       (peg/match ~(* (some (choice (range "az" "AZ" "09") (set "_-/"))) -1) name)
                       (dictionary? value) (string? (value :source)) (string? (value :description))
                       (<= 1 (length (value :source)) ((s :config) :source-bytes)))
                  "invalid world definition")
          (def binding (merge value {:name name :event (dyn :zinc/effect)}))
          (put snapshot :bindings
               (if (find |(= ($ :name) name) (snapshot :bindings))
                 (map |(if (= ($ :name) name) binding $) (snapshot :bindings))
                 (array/concat @[] (snapshot :bindings) [binding]))))
        "state"
        (do
          (assert (and (string? name) (<= 1 (length name) 256)) "invalid state key")
          (def state (table ;(kvs (snapshot :state))))
          (def generation (get-in state [(keyword name) :generation] 0))
          (unless (nil? expected) (assert (and (int? expected) (= generation expected)) "state generation conflict"))
          (put state (keyword name) {:value value :generation (+ generation 1)})
          (put snapshot :state state))
        (error "unknown world change"))
      (assert (<= (length (json/encode snapshot)) ((s :config) :response-bytes)) "world snapshot byte ceiling")
      (when (= kind "binding") (validate s view snapshot))
      (store/transact s
                      (store/checkpoint s ((dyn :zinc/task) :checkpoint))
                      (assert (= (current "image") ((store/branch s (view :branch)) "image")) "working world changed")
                      (def event (store/append s view "world-image" "Working environment changed." snapshot (current "image") ((dyn :zinc/task) :id)))
                      (store/query s "UPDATE branches SET image=? WHERE id=?" [(event "id") (view :branch)])
                      {:image (event "id") :origin (snapshot :origin) :base (snapshot :base)}))))

(defn propose [s view]
  (def current (store/branch s (view :branch)))
  (def snapshot (image s (merge view {:image (current "image")})))
  {:image (current "image") :origin (snapshot :origin) :base (snapshot :base)})

(defn merge-image [s view value]
  (assert (index-of "merge" ((s :config) :world-actions)) "world acceptance not granted")
  (def record (first (store/query s "SELECT data FROM events WHERE id=? AND actor=? AND kind='world-image'"
                                  [(value :image) (s :actor)])))
  (assert record "proposal snapshot unavailable")
  (def snapshot (json/decode (record "data") true true))
  (def name (snapshot :origin))
  (def rules (definition s name (view :revision)))
  (unless (dyn :zinc/user)
    (assert (and (= name (view :world)) (rules :agent-merge)) "user-triggered acceptance required")
    (store/event s view (value :image)))
  (def prior (first (store/query s "SELECT data FROM events WHERE actor=? AND task=? AND kind='world-accepted'"
                                 [(s :actor) ((dyn :zinc/task) :id)])))
  (if prior (json/decode (prior "data") true true)
    (do
      (validate s view snapshot)
      (store/transact s
                      (store/checkpoint s ((dyn :zinc/task) :checkpoint))
                      (def accepted (inspect s name))
                      (assert (= (snapshot :base) (if accepted (accepted "head") 0)) "world changed since proposal")
                      (store/query s
                                   `INSERT INTO worlds(actor,name,definition,head) VALUES(?,?,?,?)
           ON CONFLICT(actor,name) DO UPDATE SET head=excluded.head`
                                   [(s :actor) name (if accepted (accepted "definition") name) (value :image)])
                      (def result {:world name :image (value :image) :previous (snapshot :base)})
                      (store/append s view "world-accepted" "World accepted." result (value :image) ((dyn :zinc/task) :id))
                      result))))

(defn fork [s view name]
  (assert (index-of "fork" ((s :config) :world-actions)) "world fork not granted")
  (assert (and (string? name) (peg/match ~(* (some (choice (range "az" "09") (set "-_"))) -1) name)
               (index-of name ((s :config) :worlds))) "fork target not granted")
  (def prior (first (store/query s "SELECT data FROM events WHERE actor=? AND task=? AND kind='world-fork'"
                                 [(s :actor) ((dyn :zinc/task) :id)])))
  (if prior (json/decode (prior "data") true true)
    (do
      (def current (store/branch s (view :branch)))
      (def source (image s (merge view {:image (current "image")})))
      (def snapshot (merge source {:origin name :base 0}))
      (validate s view snapshot)
      (store/transact s
                      (store/checkpoint s ((dyn :zinc/task) :checkpoint))
                      (assert (not (inspect s name)) "fork target exists")
                      (def accepted (inspect s (view :world)))
                      (def event (store/append s view "world-image" "World forked." snapshot (current "image")))
                      (store/query s "INSERT INTO worlds(actor,name,definition,parent,base,head) VALUES(?,?,?,?,?,?)"
                                   [(s :actor) name (if accepted (accepted "definition") (view :world)) (view :world)
                                    (when (> (source :base) 0) (source :base)) (event "id")])
                      (def result {:world name :image (event "id") :parent (view :world)})
                      (store/append s view "world-fork" "Independent world accepted." result (event "id") ((dyn :zinc/task) :id))
                      result))))

(defn restore [s view value]
  (assert (and (dyn :zinc/user) (index-of "restore" ((s :config) :world-actions))) "user-triggered restore required")
  (def name (get value :world (view :world)))
  (def accepted (inspect s name))
  (assert accepted "world has no accepted state")
  (def last (first (store/query s "SELECT data FROM events WHERE actor=? AND kind='world-accepted' AND json_extract(data,'$.world')=? ORDER BY id DESC LIMIT 1"
                                [(s :actor) name])))
  (def id (get value :image (when last ((json/decode (last "data") true true) :previous))))
  (assert (and (int? id) (>= id 0)) "restore requires a previous snapshot")
  (when (> id 0)
    (assert (first (store/query s "SELECT id FROM events WHERE actor=? AND kind='world-accepted' AND json_extract(data,'$.world')=? AND json_extract(data,'$.image')=?"
                                [(s :actor) name id])) "snapshot was not accepted for this world"))
  (def snapshot (merge (if (= id 0) {:origin name :bindings [] :state {}} (image s {:world name :image id}))
                       {:base (accepted "head")}))
  (def event (store/transact s
                             (store/checkpoint s ((dyn :zinc/task) :checkpoint))
                             (store/append s view "world-image" "Previous world state proposed." snapshot (accepted "head"))))
  (merge-image s view {:image (event "id")}))

(defn authorize [s current saved]
  (each key [:actor :store :repo :state]
    (assert (= (current key) (saved key)) "saved identity/location differs"))
  (each key [:roots :actions :search]
    (each [name value] (pairs (saved key))
      (assert (deep= value (get-in current [key name])) "saved host grant revoked")))
  (each key [:worlds :world-actions :code-actions :capabilities :visibility :allowed-models]
    (each value (saved key) (assert (index-of value (current key)) "saved grant revoked")))
  (each reference [(saved :chat) (saved :rerank)]
    (assert (or (index-of reference [(current :chat) (current :rerank)]) (index-of reference (current :allowed-models))) "saved model revoked"))
  (each [name provider] (pairs (saved :providers))
    (def granted (get-in current [:providers name]))
    (assert (and granted (if (provider :identity) (= (provider :identity) (granted :identity)) (= (provider :url) (granted :url)))) "saved provider authority revoked"))
  (each [key field] (pairs ((s :spec) :schema))
    (when (= :integer (field :type))
      (assert (if (index-of key [:budget :output])
                (or (= 0 (current key)) (and (> (saved key) 0) (<= (saved key) (current key))))
                (<= (saved key) (current key))) "saved limit exceeds current authority")))
  (merge saved {:providers (tabseq [[name provider] :in (pairs (saved :providers))] name (get-in current [:providers name]))}))

(defn instructions [s view &opt snapshot]
  (def catalog (operations s view))
  (def members (if (has-key? view :capabilities)
                 (tabseq [[name member] :in (pairs catalog) :when (index-of name (view :capabilities))] name member)
                 catalog))
  (default snapshot (image s view))
  (string (document ((s :spec) :document)) "\n\n"
          (document ((definition s (view :world) (view :revision)) :document))
          "\n\n(self request) spawns this agent in the inherited world. (await handle) reads its committed result."
          "\n(self/document) returns these instructions. Do not redefine self, input or await."
          "\n(self/work/map member argument-lists) maps safe members in bounded parallel batches."
          "\n(self/work/reduce member values initial) folds a safe member with a receipt per step."
          "\n" (string/join (map |(string "self/" ($ 0) ": " (($ 1) :description)) (sorted (pairs members))) "\n")
          "\n" (string/join (map |(string ($ :name) ": " ($ :description)) (snapshot :bindings)) "\n")
          "\nNamed roots: " (json/encode (keys ((s :config) :roots)))
          "\nHTTP actions: " (json/encode (keys ((s :config) :actions)))
          "\nImports: " (json/encode (view :imports))))

(def members
  {"source/inspect"
   {:policy "safe" :description "(self/source/inspect path) reads bounded source from this job's pinned revision."
    :function source}
   "source/definition"
   {:policy "safe" :description "(self/source/definition name) returns a learned binding's Janet source."
    :function (fn [s view name]
                (def binding (find |(= ($ :name) name) ((image s view) :bindings)))
                (assert binding "binding unavailable")
                (binding :source))}
   "world/inspect"
   {:policy "safe" :description "(self/world/inspect) returns the working image's origin, bindings and state generations."
    :function (fn [s view]
                (def snapshot (image s view))
                {:origin (snapshot :origin) :base (snapshot :base)
                 :bindings (map |{:name ($ :name) :description ($ :description)} (snapshot :bindings))
                 :state (map |[($ 0) (($ 1) :generation)] (pairs (snapshot :state)))})}
   "world/define"
   {:policy "safe" :description "(self/world/define name source description) persists a Janet definition in the working environment."
    :function (fn [s view name source description] (change s view "binding" name {:source source :description description}))}
   "world/state"
   {:policy "safe" :description "(self/world/state key) reads a managed state value and generation."
    :function (fn [s view key] (get-in (image s view) [:state (keyword key)]))}
   "world/put"
   {:policy "safe" :transactional true :description "(self/world/put key value generation) atomically updates managed state."
    :function (fn [s view key value generation] (change s view "state" key value generation))}
   "world/propose"
   {:policy "safe" :description "(self/world/propose) returns an immutable working image for acceptance into its origin."
    :function propose}
   "world/fork"
   {:policy "safe" :description "(self/world/fork name) snapshots an independently evolving world with explicit origin metadata."
    :function fork}
   "world/merge"
   {:policy "safe" :description "(self/world/merge proposal) validates and merges into the origin; only agent-merge worlds expose this."
    :function merge-image}})
