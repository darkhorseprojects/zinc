(import spork/json :as json)
(import spork/path :as path)
(import portable-agents/markdown :as markdown)
(import ./store)
(import ./schema)
(def- design (module/value (markdown/load (path/join (path/dirname (dyn :source)) "../design.md") []) 'document))

(defn- document [node]
  (cond
    (string? node) node
    (dictionary? node) (if (has-key? node :content)
                         (string (when (node :name) (string (string/repeat "#" (node :level)) " " (node :name) "\n\n")) (string/join (map document (node :content)) "\n\n"))
                         (or (node :text) (string (json/encode node))))
    (indexed? node) (string/join (map document node) "\n") ""))

(defn image [config &opt inherited revision]
  (def origin (if (and inherited (not revision)) inherited
    (let [root (string/trim (store/git (path/dirname (config :world)) ["rev-parse" "--show-toplevel"]))
          relative (string/join (path/parts (path/relpath root (config :world))) "/")
          base (string/trim (store/git root ["rev-parse" "--verify" "--end-of-options" (string (or revision "HEAD") "^{commit}")]))
          blob (string/trim (store/git root ["rev-parse" "--verify" "--end-of-options" (string base ":" relative)]))
          ref (store/git root (if revision ["rev-parse" "--symbolic-full-name" "--verify" "--end-of-options" revision] ["symbolic-ref" "-q" "HEAD"]) nil nil true)]
      {:root root :path relative :blob blob :base base
       :ref (if (and ref (string/has-prefix? "refs/heads/" (string/trim ref))) (string/trim ref) "HEAD")})))
  (if (origin :bindings) origin
    (let [bytes (store/git (origin :root) ["cat-file" "blob" (origin :blob)])
          metadata (do (assert (<= (length bytes) (config :world-bytes)) "world image byte ceiling") (unmarshal bytes @{}))]
      (assert (and (tuple? metadata) (= 6 (length metadata)) (= 1 (metadata 0)) (indexed? (metadata 4))) "incompatible world image")
      (merge origin {:bindings (metadata 4)}))))

(defn- evaluate [[bytes input document public bindings requests code limits config seconds]]
  (when (> seconds 0) (ev/deadline seconds nil nil true))
  (math/seedrandom (os/cryptorand 32))
  (def native (make-env))
  (def output @"")
  (def emit (fn [bytes]
              (assert (<= (+ (length output) (length bytes)) (limits :output)) "execution output byte ceiling")
              (buffer/push-string output bytes)))
  (def base @{:out emit :err emit})
  (def reverse (merge make-image-dict {emit 'zinc/output}))
  (def forward (merge load-image-dict {'zinc/output emit}))
  (var env nil)
  (defn snapshot []
    (def bindings (seq [name :in (take 128 (all-bindings env true)) :when (<= (length (string name)) 128)]
                       {:name (string name) :type (string (type (module/value env name true)))}))
    (def image (marshal [1 janet/version janet/build janet/config-bits bindings (marshal env reverse)] @{}))
    (assert (<= (length image) (limits :world)) "world image byte ceiling")
    {:image image :bindings bindings})
  (defn request [name args]
    (def reply (ev/thread-chan 1))
    (ev/give requests [name args (when (index-of name ["self" "save" "world/save" "world/view"]) (snapshot)) reply])
    (def outcome (ev/take reply))
    (assert (and outcome (outcome :ok)) (get outcome :error "Execution closed"))
    (outcome :value))
  (each [name binding] (pairs bindings)
    (put base (or (binding :local) (symbol name))
         (if-let [local (binding :local)] (native local)
           @{:value (fn [& args] (request name args)) :doc (binding :doc)})))
  (each [name value] [['input (fn [] input)] ['self/document (fn [] document)]
                     ['settings (fn [] (schema/data (public :settings)))] ['resources (fn [] (schema/data (public :resources)))]]
    (put base name @{:value value}))
  (when (bindings "world/remove")
    (put base 'world/remove @{:doc "(world/remove name) deletes a local world binding; nil remains an ordinary value."
                             :value (fn [name] (assert (symbol? name) "binding name must be a symbol") (put env name nil))}))
  (each name ["world/discard" "world/switch"]
    (when (bindings name)
      (put base (symbol name) @{:doc ((bindings name) :doc) :value (fn [& args] (return :zinc/replace (request name args)))})))
  (put reverse base 'zinc/base) (put forward 'zinc/base base)
  (loop [[name binding] :pairs base :when (symbol? name)]
    (unless (bindings (string name))
      (put reverse binding (symbol "zinc/binding/" name)) (put forward (symbol "zinc/binding/" name) binding))
    (when (and (binding :value) (not (get (bindings (string name)) :local)))
      (def key (symbol "zinc/host/" name))
      (put reverse (binding :value) key) (put forward key (binding :value))))
  (when bytes (assert (<= (length bytes) (limits :world)) "world image byte ceiling"))
  (def loaded (when bytes (unmarshal bytes @{})))
  (when loaded (assert (and (tuple? loaded) (= 6 (length loaded)) (= 1 (loaded 0)) (= janet/version (loaded 1)) (= janet/build (loaded 2)) (= janet/config-bits (loaded 3))) "incompatible world image; provision a matching runtime"))
  (set env (if loaded (unmarshal (loaded 5) forward) (make-env base)))
  (assert (and (table? env) (= base (table/getproto env))) "invalid world environment")
  (def options (if (config :setup) ((module/value (require (config :setup)) 'configure) env) {}))
  (each key (keys options) (assert (index-of key [:parser :read :expander]) "unsupported evaluator option"))
  (def documentation @{'document @{:value design}})
  (table/clear module/cache)
  (put module/cache "zinc/design" documentation)
  (put env :redef true)
  (with [file (file/temp)]
    (file/write file code) (file/seek file :set 0)
    (sandbox :fs :net :subprocess :ffi :modules :threads :env :asm :unmarshal :exit :locale :signal :chroot :sandbox)
    (with-env env
        (try
          (let [replacement (prompt :zinc/replace
                              (var value nil)
                              (dofile file :env env :source :world :parser (options :parser) :read (options :read) :expander (options :expander)
                                :evaluator (fn [thunk &] (set value (thunk))))
                              (def text (string output (if (string? value) value (string/format "%n" value))))
                              (assert (<= (length text) (limits :output)) "execution result byte ceiling")
                              (merge {:ok true :value text} (snapshot)))]
            (if (replacement :ok) replacement {:ok true :value (string output) :replacement replacement}))
          ([err fiber]
            (def failure (schema/failure "EvaluationFailed" err fiber))
            {:ok false :error (merge failure {:context {:output (string output) :cause (failure :context)}})})))))

(defn execute [bytes input document public bindings code limits config handler seconds]
  (def requests (ev/thread-chan 1))
  (def finished (ev/thread-chan 1))
  (def pending @[])
  (defer (do (ev/chan-close requests)
           (each [task done] pending
             (when (fiber/can-resume? task) (ev/cancel task "evaluation ended"))
             (ev/take done)))
    (ev/thread evaluate [bytes input document public bindings requests code limits config seconds] :n finished)
    (label done (while true
      (def [status channel packet] (ev/select requests finished))
      (assert (= status :take) "Execution closed")
      (if (= channel finished)
        (do (assert (= :ok (packet 0)) (string "World evaluator stopped: " (packet 1)))
          (def outcome (packet 1))
          (assert (outcome :ok) (outcome :error))
          (return done outcome))
        (do (def [name args snapshot response] packet)
          (def joined (ev/chan))
          (array/push pending [(ev/go (fn [] (defer (ev/chan-close joined)
                                              (ev/give response (try {:ok true :value (handler name args snapshot)} ([err] {:ok false :error err})))))) joined])))))))

(defn world [s value]
  (def config (s :config))
  (def current (dyn :zinc/call))
  (def action (value :action))
  (assert (index-of action ["view" "save" "discard" "switch"]) "unknown world action")
  (def origin (if current (or (when (index-of action ["view" "save"]) (current :candidate)) (json/decode ((store/call s (current :id)) :origin) true true))
                 (json/decode (((store/query s "SELECT origin FROM main.world WHERE id=1") 0) :origin) true true)))
  (def selected (if (value :point)
                   (do (assert (= action "view") "only view accepts a historical point")
                     ((json/decode ((store/event s (or (get current :scope) {:first 1 :last 9007199254740991}) (value :point)) :data) true true) :world)) origin))
  (assert (selected :base) "event has no world image")
  (def clean (string/trim (store/git (selected :root) ["rev-parse" "--verify" "--end-of-options" (string (selected :base) ":" (selected :path))])))
  (if (= action "view") (merge (image config selected) {:dirty (not= clean (selected :blob))})
    (do
      (assert (config :repl) "world editing is not permitted")
      (assert current "world edits require an executing root")
      (assert (and (= 0 (current :temporary)) (nil? (current :parent)) (nil? (get-in current [:input :revision]))) "only the durable instance root can replace or save the world")
      (assert (not (first (store/query s "SELECT id FROM main.live_calls WHERE parent IS NULL AND temporary=0 AND id<>coalesce(?,0) LIMIT 1" [(get current :id)]))) "world is busy")
      (def updated
        (case action
          "discard" (merge (image config nil (origin :base)) {:ref (origin :ref)})
          "switch" (do (assert (= clean (origin :blob)) "save or discard changes before switching")
                       (assert (and (string? (value :commit)) (> (length (value :commit)) 0)) "commit required")
                       (merge (image config nil (value :commit)) {:ref "HEAD"}))
          "save" (do
                   (def message (value :message))
                   (assert (and (string? message) (<= 1 (length (string/trim message)) 2048)) "commit message required")
                   (def ref (if (= "HEAD" (origin :ref)) (string "refs/heads/world/" (origin :base) "-" (string/join (map |(string/format "%02x" $) (os/cryptorand 6)))) (origin :ref)))
                   (def index (string (config :store) ".index"))
                   (def environment {"GIT_INDEX_FILE" index})
                   (defer (when (os/stat index) (os/rm index))
                     (store/git (origin :root) ["read-tree" (origin :base)] nil environment)
                     (store/git (origin :root) ["update-index" "--add" "--cacheinfo" "100644" (origin :blob) (origin :path)] nil environment)
                     (def tree (string/trim (store/git (origin :root) ["write-tree"] nil environment)))
                     (def commit (string/trim (store/git (origin :root) ["commit-tree" tree "-p" (origin :base)] message)))
                     (def before (unless (= "HEAD" (origin :ref)) (origin :base)))
                     (def next (merge origin {:ref ref :base commit}))
                     (def intent (store/append s (current :scope) "save-intent" message {:ref ref :before before :after commit :origin ((store/call s (current :id)) :origin) :next next :call (current :id)}))
                     (store/checkpoint s)
                     (store/git (origin :root) ["update-ref" "--stdin"] (string (if before "update " "create ") ref " " commit (when before (string " " before)) "\n"))
                     (store/transact s
                       (store/publish s next)
                       (store/append s (current :scope) "saved" message next (intent :id)))
                     (spit (config :world) (store/git (origin :root) ["cat-file" "blob" (origin :blob)]) :wb)
                     next))))
      (when (= action "save") (put current :candidate updated))
      updated)))

(defn definitions [config fields]
  (if-not (config :repl) {}
    (do
      (def base (make-env))
      (def available (tabseq [name :in (all-bindings base) :unless (get (base name) :private)]
                       (cond (= name '*) "core/multiply" (string/find "/" (string name)) (string name) (string "core/" name)) {:local name}))
      (each [key field] (pairs fields)
        (each [name binding] (pairs (get-in field [:repl :functions] {})) (put available name binding)))
      (each [namespace module] (pairs (get-in config [:repl :modules]))
        (each [name binding] (pairs (require (module :module)))
          (when (and (symbol? name) (not (binding :private)) (not (binding :macro)) (index-of (type (binding :value)) [:function :cfunction])
                     (or (nil? (module :export)) (= (string name) (module :export))))
            (def qualified (if (module :export) (string namespace) (string namespace "/" name)))
            (assert (not (available qualified)) "host function shadows a binding")
            (assert (string? (binding :doc)) "host function requires documentation")
            (put available qualified (merge binding {:config (module :config)})))))
      (def selected (schema/select (keys available) (get-in config [:repl :bindings])))
      (put (config :repl) :bindings selected)
      (tabseq [name :in selected] name (available name)))))

(defn public [config fields]
  {:settings (tabseq [name :in (get-in config [:repl :values] [])] (keyword name) (config (keyword name)))
   :resources (tabseq [[key field] :in (pairs fields) :let [access (get field :repl {})] :when (and (config :repl) (access :public))
                       :let [grants (tabseq [[name grant] :in (pairs (config key))
                                             :let [functions (sorted (seq [[function binding] :in (pairs (access :functions))
                                                                           :when (and (index-of function (get-in config [:repl :bindings]))
                                                                                      (or (not (binding :permission)) (grant (binding :permission))))] function))]
                                             :when (> (length functions) 0)]
                                      name (merge (tabseq [field :in (access :public) :when (has-key? grant field)] field (grant field)) {:functions functions}))]
                       :when (> (length grants) 0)] key grants)})

(defn instructions [config document-tree available public]
  (string (document document-tree)
          (when (config :instructions) (string "\n\n## World instructions\n\n" (slurp (config :instructions))))
          (when (and (config :repl) available)
            (string "\n\n## Janet\n\nSuccessful bindings, mutations and closures persist as a native image. Initializers never replay. Errors leave the previous image intact; external effects are not undone. Parallel children fork without merging. Use `(doc name)`, `(doc \"string/\")`, and `(doc-of string/join)` for native documentation. `(import zinc/design :as design)` exposes `design/document`.\n`(input)`, `(self/document)`, `(settings)` and `(resources)` expose invocation data."
                    (string/join (seq [[title value] :in [["Settings" (public :settings)] ["Resources" (public :resources)]] :when (> (length value) 0)]
                                   (string "\n\n## " title "\n\n" (json/encode value "  " "\n"))))
                    "\n\n## Host bindings\n\n" (string/join (seq [[_ binding] :in (sorted (pairs available)) :unless (binding :local)] (binding :doc)) "\n\n")))))
