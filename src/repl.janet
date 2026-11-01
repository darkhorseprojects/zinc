(import spork/json :as json)
(import spork/path :as path)
(import portable-agents/markdown :as markdown)
(import portable-agents/protocol :as wire)
(import ./store)
(import ./schema)
(def- design (module/value (markdown/load (path/join (path/dirname (dyn :source)) "../design.md") []) 'document))

(defn image [config &opt inherited revision]
  (def origin (if (and inherited (not revision)) inherited
    (let [root (string/trim (store/git (path/dirname (config :world)) ["rev-parse" "--show-toplevel"]))
          relative (string/join (path/parts (path/relpath root (config :world))) "/")
          base (string/trim (store/git root ["rev-parse" "--verify" "--end-of-options" (string (or revision "HEAD") "^{commit}")]))
          blob (string/trim (store/git root ["rev-parse" "--verify" "--end-of-options" (string base ":" relative)]))
          ref (store/git root (if revision ["rev-parse" "--symbolic-full-name" "--verify" "--end-of-options" revision] ["symbolic-ref" "-q" "HEAD"]) nil nil true)]
      {:root root :path relative :blob blob :base base
       :ref (if (and ref (string/has-prefix? "refs/heads/" (string/trim ref))) (string/trim ref) "HEAD")})))
  origin)

(defn- evaluate [[bytes input document public bindings commands events limits config]]
  (math/seedrandom (os/cryptorand 32))
  (def native (make-env))
  (def output @"")
  (def emit (fn [bytes]
              (assert (<= (+ (length output) (length bytes)) (limits :output)) "execution output byte ceiling")
              (buffer/push-string output bytes)))
  (def base @{:out emit :err emit})
  (def reverse (merge make-image-dict {emit 'zinc/output}))
  (def forward (merge load-image-dict {'zinc/output emit}))
  (var env nil) (var primary nil)
  (def sources @{})
  (def known @{})
  (var form nil)
  (defn capture []
    (each name (all-bindings env true)
      (def binding (env name))
      (when (and form (not= binding (known name))) (put sources name (string/format "%j" form)))
      (put known name binding)))
  (defn snapshot []
    (capture)
    (def bindings (seq [name :in (sorted (all-bindings env true))]
                       {:name (string name) :type (string (type (module/value env name true))) :source (sources name)}))
    (def image (marshal [1 janet/version janet/build janet/config-bits bindings (marshal env reverse)] @{}))
    (assert (<= (length image) (limits :world)) "world image byte ceiling")
    {:image image})
  (defn request [name args]
    (def reply (ev/thread-chan 1))
    (ev/give events [:call name args (when (index-of name ["self" "save" "world/save" "world/view"]) (snapshot)) reply])
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
      (put base (symbol name) @{:doc ((bindings name) :doc) :value (fn [& args]
                               (assert (= (fiber/root) primary) "world replacement requires the foreground evaluation")
                               (return :zinc/replace (request name args)))})))
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
  (when loaded (each binding (loaded 4) (put sources (symbol (binding :name)) (binding :source))))
  (def options (if (config :setup) ((module/value (require (config :setup)) 'configure) env) {}))
  (each key (keys options) (assert (index-of key [:parser :read :expander]) "unsupported evaluator option"))
  (def documentation @{'document @{:value design}})
  (table/clear module/cache)
  (put module/cache "zinc/design" documentation)
  (put base *module-cache* module/cache)
  (put base *module-paths* [[(fn [name] (when (= name "zinc/design") name)) :preload]])
  (put env :redef true)
  (merge-into known env)
  (def driver (fiber/root))
  (def supervised (ev/chan 1))
  (var closing false) (var cancelled false)
  (sandbox :fs :net :subprocess :ffi :modules :threads :env :asm :unmarshal :exit :locale :signal :chroot :sandbox)
  (defer (do (each task (ev/all-tasks) (unless (= task driver) (ev/cancel task :evaluation-ended)))
             (ev/chan-close supervised))
    (label settled (while true
      (when (and closing (= 1 (length (ev/all-tasks))) (= 0 (ev/count supervised)))
        (return settled (if cancelled {:ok true} (merge {:ok true :value (string output)} (snapshot)))))
      (def [status channel packet] (if cancelled [:take supervised (ev/take supervised)] (ev/select commands supervised)))
      (if (= channel commands)
        (let [[code seconds] packet]
          (if (or (= status :close) (nil? code))
            (do (set closing true) (set cancelled (or (= status :close) seconds))
              (when cancelled (each task (ev/all-tasks) (unless (= task driver) (ev/cancel task :evaluation-ended)))))
            (do
              (set primary (ev/go (fn []
                (def outcome (with-env env
                  (try
                    (let [replacement (prompt :zinc/replace
                      (var value nil) (var chunk code)
                      (put env :exit nil)
                      (when (options :parser) (:flush (options :parser)))
                      (run-context (merge options
                        {:env env :source :world
                         :chunks (fn [buffer &] (when chunk (buffer/push-string buffer chunk) (set chunk nil)))
                         :on-status (fn [fiber value] (unless (= :dead (fiber/status fiber)) (propagate value fiber)))
                         :on-parse-error (fn [parser source] (error (string source ":" (string/join (map string (:where parser)) ":") ": parse error: " (:error parser))))
                         :on-compile-error (fn [message fiber source line column] (error (string source ":" line ":" column ": compile error: " message)))
                         :evaluator (fn [thunk source &] (set form source) (set value (thunk)) (capture))}))
                      (def text (string output (if (string? value) value (string/format "%n" value))))
                      (assert (<= (length text) (limits :output)) "execution result byte ceiling")
                      (merge {:ok true :value text} (snapshot)))]
                      (if (replacement :ok) replacement {:ok true :value (string output) :replacement replacement}))
                    ([err fiber]
                      (def failure (wire/diagnostic "EvaluationFailed" err fiber))
                      {:ok false :error (merge failure {:context {:output (string output) :cause (failure :context)}})}))))
                (buffer/clear output)
                (ev/give supervised [:evaluated outcome seconds])) nil supervised))
              (when (> seconds 0) (ev/deadline seconds driver primary true)))))
        (case (packet 0)
          :evaluated (do
            (when (> (packet 2) 0)
              (each task (ev/all-tasks) (unless (= task driver) (ev/deadline (packet 2) driver task true))))
            (ev/give events [:result (packet 1)]))
          :error (unless (= :evaluation-ended (fiber/last-value (packet 1)))
                   (error (wire/diagnostic "BackgroundFailed" (fiber/last-value (packet 1)) (packet 1))))))))))

(defn open [bytes input document public bindings limits config handler]
  (def commands (ev/thread-chan 1))
  (def events (ev/thread-chan 1))
  (def runtime @{:commands commands :reply (ev/chan 1) :done (ev/chan 1)})
  (def pending @{})
  (ev/thread evaluate [bytes input document public bindings commands events limits config] :n events)
  (ev/go (fn []
    (defer (do (ev/chan-close commands) (ev/chan-close events)
               (each [task done] (pairs (merge pending))
                 (when (fiber/can-resume? task) (ev/cancel task :evaluation-ended))
                 (ev/take done)))
      (try
        (while true
          (def packet (ev/take events))
          (case (packet 0)
            :call (do
              (def [_ name args snapshot response] packet)
              (def joined (ev/chan))
              (def task (ev/go (fn []
                (def task (fiber/root))
                (defer (do (put pending task nil) (ev/chan-close joined))
                  (ev/give response (try {:ok true :value (handler name args snapshot)} ([err] {:ok false :error err})))))))
              (put pending task joined))
            :result (ev/give (runtime :reply) (packet 1))
            :ok (do (ev/give (runtime :reply) (packet 1)) (break))
            :error (error (packet 1))))
        ([err] (put runtime :failure err) (ev/give (runtime :reply) {:ok false :error err}))))) nil (runtime :done))
  runtime)

(defn execute [runtime code seconds]
  (when (runtime :failure) (error (runtime :failure)))
  (ev/give (runtime :commands) [code seconds])
  (def outcome (ev/take (runtime :reply)))
  (assert (outcome :ok) (outcome :error))
  outcome)

(defn close [runtime &opt cancel]
  (defer (do (ev/chan-close (runtime :commands))
             (def [status fiber] (ev/take (runtime :done)))
             (unless (= :ok status) (propagate (fiber/last-value fiber) fiber)))
    (when (runtime :failure) (error (runtime :failure)))
    (ev/give (runtime :commands) [nil cancel])
    (def outcome (ev/take (runtime :reply)))
    (assert (outcome :ok) (outcome :error))
    outcome))

(defn world [s value &opt status-only]
  (def config (s :config))
  (def current (dyn :zinc/call))
  (def action (value :action))
  (assert (index-of action ["view" "save" "discard" "switch"]) "unknown world action")
  (def origin (if current (or (when (index-of action ["view" "save"]) (current :candidate)) (store/origin s (current :id)))
                 (store/origin s)))
  (def selected (if (value :point)
                   (do (assert (= action "view") "only view accepts a historical point")
                     ((json/decode ((store/event s (or (get current :scope) {:first 1 :last 9007199254740991}) (value :point)) :data) true true) :world)) origin))
  (assert (selected :base) "event has no world image")
  (def clean (string/trim (store/git (selected :root) ["rev-parse" "--verify" "--end-of-options" (string (selected :base) ":" (selected :path))])))
  (if (= action "view")
    (let [bytes (store/git (selected :root) ["cat-file" "blob" (selected :blob)])
          metadata (do (assert (<= (length bytes) (config :world-bytes)) "world image byte ceiling") (unmarshal bytes @{}))]
      (assert (and (tuple? metadata) (= 6 (length metadata)) (= 1 (metadata 0)) (indexed? (metadata 4))) "incompatible world image")
      (merge selected {:bindings (metadata 4) :dirty (not= clean (selected :blob))
                       :summary (string "World · " (selected :ref) " @ " (string/slice (selected :base) 0 7)
                                        (when (not= clean (selected :blob)) " · unsaved changes"))
                       :text (if status-only "" (string/join (distinct (seq [binding :in (metadata 4)]
                         (assert (string? (binding :source)) (string "source was not recorded for " (binding :name)))
                         (binding :source))) "\n\n"))}))
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

(defn definitions [config supplied]
  (if-not (config :repl) {}
    (do
      (def base (make-env))
      (def available (tabseq [name :in (all-bindings base) :unless (get (base name) :private)]
                       (cond (= name '*) "core/multiply" (string/find "/" (string name)) (string name) (string "core/" name)) {:local name}))
      (merge-into available supplied)
      (each [namespace module] (pairs (get-in config [:repl :imports]))
        (each [name binding] (pairs (require (module :module)))
          (when (and (symbol? name) (not (binding :private)) (not (binding :macro)) (index-of (type (binding :value)) [:function :cfunction])
                     (or (nil? (module :export)) (= (string name) (module :export))))
            (def qualified (if (module :export) (string namespace) (string namespace "/" name)))
            (assert (not (available qualified)) "host function shadows a binding")
            (assert (string? (binding :doc)) "host function requires documentation")
            (put available qualified binding))))
      (def selected (schema/select (keys available) (get-in config [:repl :bindings])))
      (put (config :repl) :bindings selected)
      (tabseq [name :in selected] name (available name)))))

(defn public [config fields bindings]
  {:settings (schema/project config (map keyword (get-in config [:repl :values] [])))
   :resources (tabseq [[key field] :pairs fields :when (and (config :repl) (field :public))
                       :let [grants (tabseq [[name grant] :pairs (config key)
                                             :let [functions (sorted (seq [[function binding] :pairs bindings
                                                                           :when (= key (binding :resource))
                                                                           :when (or (not (binding :permission)) (grant (binding :permission)))] function))]
                                             :when (> (length functions) 0)]
                                      name (merge (schema/project grant (field :public)) {:functions functions}))]
                       :when (> (length grants) 0)] key grants)})

(defn instructions [config document-tree available public]
  (string (markdown/render document-tree)
          (when (config :instructions) (string "\n\n## World instructions\n\n" (slurp (config :instructions))))
          (when (and (config :repl) available)
            (string "\n\n## Janet\n\nSuccessful bindings, mutations and closures persist as a native image. Initializers never replay. Native ev/ fibers continue across tool rounds and settle before call completion; they are not persisted. Errors cancel the runtime and leave the previous image intact; external effects are not undone. Parallel children fork without merging. Use `(doc name)`, `(doc \"string/\")`, and `(doc-of string/join)` for native documentation. `(import zinc/design :as design)` exposes `design/document`.\n`(input)`, `(self/document)`, `(settings)` and `(resources)` expose invocation data."
                    (string/join (seq [[title value] :in [["Settings" (public :settings)] ["Resources" (public :resources)]] :when (> (length value) 0)]
                                   (string "\n\n## " title "\n\n" (schema/encode value))))
                    "\n\n## Host bindings\n\n" (string/join (seq [[_ binding] :in (sorted (pairs available)) :unless (binding :local)] (binding :doc)) "\n\n")))))
