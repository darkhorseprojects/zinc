(import spork/json :as json)
(import spork/path :as path)
(import ./store)
(import ./schema)

(defn- document [node]
  (cond
    (string? node) node
    (dictionary? node) (if (has-key? node :content)
                         (string (when (node :name) (string (string/repeat "#" (node :level)) " " (node :name) "\n\n")) (string/join (map document (node :content)) "\n\n"))
                         (or (node :text) (string (json/encode node))))
    (indexed? node) (string/join (map document node) "\n") ""))

(defn source [config &opt inherited revision]
  (if (and inherited (not revision))
    (let [code (or (inherited :code) (store/git (inherited :root) ["cat-file" "blob" (inherited :blob)]))]
      (assert (<= (length code) (config :source-bytes)) "world source byte ceiling")
      (merge inherited {:code code :blob (if (inherited :code) (string/trim (store/git (inherited :root) ["hash-object" "-w" "--stdin"] code)) (inherited :blob))}))
    (let [root (string/trim (store/git (path/dirname (config :world)) ["rev-parse" "--show-toplevel"]))
          relative (string/join (path/parts (path/relpath root (config :world))) "/")
          base (string/trim (store/git root ["rev-parse" "--verify" "--end-of-options" (string (or revision "HEAD") "^{commit}")]))
          blob (string/trim (store/git root ["rev-parse" "--verify" "--end-of-options" (string base ":" relative)]))
          code (store/git root ["cat-file" "blob" blob])
          ref (store/git root (if revision ["rev-parse" "--symbolic-full-name" "--verify" "--end-of-options" revision] ["symbolic-ref" "-q" "HEAD"]) nil nil true)]
      (assert (<= (length code) (config :source-bytes)) "world source byte ceiling")
      {:code code :root root :path relative :blob blob :base base
       :ref (if (and ref (string/has-prefix? "refs/heads/" (string/trim ref))) (string/trim ref) "HEAD")})))

(defn world [s value]
  (def config (s :config))
  (def action (value :action))
  (assert (index-of action ["view" "save" "discard" "switch"]) "unknown world action")
  (store/transact s
    (def origin (json/decode (((store/query s "SELECT origin FROM main.world WHERE id=1") 0) :origin) true true))
    (def selected (if (value :point)
                     (do (assert (and (= action "view") (int? (value :point)) (> (value :point) 0)) "view point must be an event ID")
                       ((json/decode ((store/event s {:first 1 :last 9007199254740991} (value :point)) :data) true true) :world-source)) origin))
    (assert (selected :base) "event has no world source")
    (def clean (string/trim (store/git (selected :root) ["rev-parse" "--verify" "--end-of-options" (string (selected :base) ":" (selected :path))])))
    (unless (= action "view")
      (assert (config :repl) "world editing is not permitted")
      (assert (not (first (store/query s "SELECT id FROM main.live_calls WHERE kind<>'summarize' AND id<>coalesce(?,0) LIMIT 1" [(get (dyn :zinc/call) :id)]))) "world is busy; abort or wait for current work"))
    (case action
      "view" (merge selected {:source (store/git (selected :root) ["cat-file" "blob" (selected :blob)]) :dirty (not= clean (selected :blob))})
      (do
        (var updated (merge origin {:blob clean}))
        (case action
          "switch" (do (assert (= clean (origin :blob)) "save or discard changes before switching")
                       (assert (and (string? (value :commit)) (> (length (value :commit)) 0) (not (string/find "\0" (value :commit)))) "commit required")
                       (set updated (merge (source config nil (value :commit)) {:code nil :ref "HEAD"}))
                       (store/git (updated :root) ["update-ref" (string "refs/zinc/world/" (updated :base)) (updated :base)]))
          "save" (do
                   (def message (value :message))
                   (assert (and (string? message) (<= 1 (length (string/trim message)) 2048)) "commit message required")
                   (when (dyn :zinc/call) (store/checkpoint s) (store/publish s true))
                   (def draft (json/decode (((store/query s "SELECT origin FROM main.world WHERE id=1") 0) :origin) true true))
                   (def ref (if (= "HEAD" (draft :ref))
                              (string "refs/heads/world/" (string/slice (draft :base) 0 7) "-" (string/join (map |(string/format "%02x" $) (os/cryptorand 6))))
                              (draft :ref)))
                   (def index (string (config :store) ".index"))
                   (def environment {"GIT_INDEX_FILE" index})
                   (defer (when (os/stat index) (os/rm index))
                     (store/git (draft :root) ["read-tree" (draft :base)] nil environment)
                     (store/git (draft :root) ["update-index" "--add" "--cacheinfo" "100644" (draft :blob) (draft :path)] nil environment)
                     (def tree (string/trim (store/git (draft :root) ["write-tree"] nil environment)))
                     (def commit (string/trim (store/git (draft :root) ["commit-tree" tree "-p" (draft :base)] message)))
                     (def before (unless (= "HEAD" (draft :ref)) (draft :base)))
                     (def intent (store/append s {} "save-intent" message {:ref ref :before before :after commit}))
                     (store/git (draft :root) ["update-ref" "--stdin"] (string (if before "update " "create ") ref " " commit (when before (string " " before)) "\n"))
                     (def head (store/git (draft :root) ["symbolic-ref" "-q" "HEAD"] nil nil true))
                     (when (and head (= ref (string/trim head)) (= (string (slurp (config :world))) (store/git (draft :root) ["show" (string (draft :base) ":" (draft :path))])))
                       (spit (config :world) (store/git (draft :root) ["cat-file" "blob" (draft :blob)]) :wb)
                       (store/git (draft :root) ["reset" "--quiet" commit "--" (draft :path)]))
                     (set updated (merge draft {:ref ref :base commit}))
                     (store/query s "UPDATE main.world SET origin=? WHERE id=1" [(string (json/encode updated))])
                     (store/append s {} "saved" message updated (intent :id)))))
        (store/query s "UPDATE main.world SET origin=? WHERE id=1" [(string (json/encode updated))])
        (when-let [current (dyn :zinc/call)]
          (store/query s (string "UPDATE " (s :journal) ".call_payloads SET origin=? WHERE id=?") [(string (json/encode updated)) (current :id)]))
        updated))))

(defn save
  "(save message) commits the current world's draft. Rewound worlds fork automatically."
  [message]
  (def [s] (dyn :zinc/context))
  (assert (and (= 0 ((dyn :zinc/call) :temporary)) (nil? ((dyn :zinc/call) :parent))) "only the durable current world can be saved")
  (world s {:action "save" :message message}))

(defn definitions [config fields]
  (if-not (config :repl) {}
    (do
      (def base (make-env))
      (def available (tabseq [name :in (all-bindings base) :unless (get (base name) :private)]
                       (cond (= name '*) "core/multiply" (string/find "/" (string name)) (string name) (string "core/" name)) {:local name}))
      (each [key field] (pairs fields)
        (each [name binding] (pairs (get-in field [:repl :functions] {}))
          (put available name binding)))
      (each [namespace module] (pairs (get-in config [:repl :modules]))
        (each [name binding] (pairs (require (module :module)))
          (when (and (symbol? name) (not (binding :private)) (not (binding :macro)) (index-of (type (binding :value)) [:function :cfunction]))
            (def qualified (string namespace "/" name))
            (assert (and (not (available qualified)) (not= qualified "world/source")) "host function shadows a binding")
            (assert (string? (binding :doc)) "host function requires documentation")
            (put available qualified (merge binding {:config (module :config)})))))
      (def selected (schema/select (keys available) (get-in config [:repl :bindings])))
      (put (config :repl) :bindings selected)
      (tabseq [name :in selected] name (available name)))))

(defn public [config fields]
  {:settings (tabseq [name :in (get-in config [:repl :values] [])]
               (keyword name) (config (keyword name)))
   :resources
   (tabseq [[key field] :in (pairs fields) :let [access (get field :repl {})] :when (and (config :repl) (access :public))
            :let [grants (tabseq [[name grant] :in (pairs (config key))
                                  :let [functions (sorted (seq [[function binding] :in (pairs (access :functions))
                                                                :when (and (index-of function (get-in config [:repl :bindings]))
                                                                           (or (not (binding :permission)) (grant (binding :permission))))] function))]
                                  :when (> (length functions) 0)]
                           name (merge (tabseq [field :in (access :public) :when (has-key? grant field)] field (grant field))
                                       {:functions functions}))]
            :when (> (length grants) 0)] key grants)})

(defn instructions [config document-tree available public]
  (string (document document-tree)
          (when (config :instructions) (string "\n\n## World instructions\n\n" (slurp (config :instructions))))
          (when (and (config :repl) available)
            (string "\n\n## Janet\n\nTop-level single-name `def`, `defn` and `defmacro` persist declarations; redefining replaces them and nil is an ordinary value. Failed evaluations restore the last saved commit, not partial changes. External effects are not undone.\nSource initializers run on load; use `(let [name value] ...)` for temporary values and effects.\n`(input)`: admitted input map. `(self/document)`: these instructions. `(settings)`: exposed settings. `(resources)`: callable resource grants."
                    (string/join (seq [[title value] :in [["Settings" (public :settings)] ["Resources" (public :resources)]] :when (> (length value) 0)]
                                   (string "\n\n## " title "\n\n" (json/encode value "  " "\n"))))
                    (when (> (length available) 0)
                      (string "\n\n## Bindings\n\n" (string/join (seq [[name binding] :in (sorted (pairs available)) :unless (and (binding :local) (> (length (string (binding :local))) 2) (string/has-prefix? "*" (string (binding :local))) (string/has-suffix? "*" (string (binding :local))))] (string (or (binding :local) name))) ", ")
                              "\n\n" (string/join (seq [[_ binding] :in (sorted (pairs available)) :unless (binding :local)] (binding :doc)) "\n\n")))))))

(defn- request [name args]
  (def reply (ev/thread-chan 1))
  (ev/give (dyn :zinc/requests) [name args reply])
  (def outcome (ev/take reply))
  (assert (and outcome (outcome :ok)) (get outcome :error "Execution closed"))
  (outcome :value))

(defn- evaluate [[source input document public bindings requests code limits config]]
  (def base (make-env))
  (def env (make-env @{}))
  (each [name binding] (pairs bindings)
    (if-let [local (binding :local)] (put env local (base local))
      (put env (symbol name) @{:value (fn [& args] (request name args)) :doc (binding :doc)})))
  (def options (if (config :setup) ((module/value (require (config :setup)) 'configure) env) {}))
  (each key (keys options) (assert (index-of key [:parser :read :expander]) "unsupported evaluator option"))
  (table/clear module/cache)
  (put env :redef true)
  (put env :zinc/requests requests)
  (put env 'stdout @{:value stderr})
  (put env 'input @{:value (fn [] input)})
  (put env 'self/document @{:value (fn [] document)})
  (put env 'settings @{:value (fn [] (schema/data (public :settings)))})
  (put env 'resources @{:value (fn [] (schema/data (public :resources)))})
  (with [file (file/temp)]
    (file/write file code) (file/seek file :set 0)
    (sandbox :fs :net :subprocess :ffi :modules :threads :env :asm
             :unmarshal :exit :locale :signal :chroot :sandbox)
    (def output @"")
    (put env :out (fn [bytes]
                    (assert (<= (+ (length output) (length bytes)) (limits :output)) "execution output byte ceiling")
                    (buffer/push-string output bytes)))
    (put env :err (env :out))
    (with-env env
      (try
        (do
          (var forms (parse-all source))
          (each form forms
            (assert (and (tuple? form) (= :parens (tuple/type form)) (index-of (first form) ['def 'defn 'defmacro]) (symbol? (get form 1))) "world source requires named declarations")
            (eval form env))
          (var value nil) (var loaded-source source)
          (dofile file :env env :source :world :parser (options :parser) :read (options :read) :expander (options :expander)
            :evaluator (fn [thunk form &]
                         (def declaration (and (tuple? form) (= :parens (tuple/type form)) (index-of (first form) ['def 'defn 'defmacro])))
                         (when declaration (assert (symbol? (get form 1)) "persistent definitions require one name"))
                         (set value (thunk))
                         (when declaration
                           (def index (find-index |(= (form 1) ($ 1)) forms))
                           (set forms (filter |(not= (form 1) ($ 1)) forms))
                           (array/insert forms (or index (length forms)) form)
                           (def updated (string/join (map |(string/format "%n" $) forms) "\n"))
                           (assert (<= (length updated) (limits :source)) "world source byte ceiling")
                           (request "world/source" [loaded-source updated])
                           (set loaded-source updated))))
          {:ok true :value (string output (if (string? value) value (string/format "%n" value)))})
        ([err fiber]
          (def failure (schema/failure "EvaluationFailed" err fiber))
          {:ok false :error (merge failure {:context {:output (string output) :cause (failure :context)}})})))))

(defn execute [source input document public bindings code limits config handler seconds]
  (def requests (ev/thread-chan 1))
  (def finished (ev/thread-chan 1))
  (def pending @[])
  (defer (do (ev/chan-close requests)
           (each [task done] pending
             (when (fiber/can-resume? task) (ev/cancel task "evaluation ended"))
             (ev/take done)))
    (ev/with-deadline seconds
      (ev/thread evaluate [source input document public bindings requests code limits config] :n finished)
      (label done (while true
        (def [status channel packet] (ev/select requests finished))
        (assert (= status :take) "Execution closed")
        (if (= channel finished)
          (do (assert (= :ok (packet 0)) (string "World evaluator stopped: " (packet 1)))
            (def outcome (packet 1))
            (assert (outcome :ok) (outcome :error))
            (return done (outcome :value)))
          (do (def [name args response] packet)
            (def joined (ev/chan))
            (array/push pending [(ev/go (fn [] (defer (ev/chan-close joined)
                                                (ev/give response (try {:ok true :value (handler name args)} ([err] {:ok false :error err})))))) joined]))))))))
