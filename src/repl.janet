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

(defn git [directory args &opt input environment probe]
  (def child (os/spawn ["git" "-C" directory "--literal-pathspecs" ;args] :pe
                       (merge (os/environ) (or environment {}) {:in :pipe :out :pipe :err :out})))
  (def output @"")
  (def done (ev/chan 1))
  (ev/go (fn [] (os/proc-wait child)) nil done)
  (ev/with-deadline (/ ((dyn :zinc/config) :http-ms) 1000)
    (defer (do (ev/close (child :in)) (ev/close (child :out)))
      (ev/go (fn [] (defer (ev/close (child :in)) (when input (ev/write (child :in) input)))))
      (var chunk nil)
      (while (set chunk (ev/read (child :out) 4096))
        (assert (<= (+ (length output) (length chunk)) ((dyn :zinc/config) :response-bytes)) "Git output byte ceiling")
        (buffer/push-string output chunk))
      (ev/take done)
      (assert (or probe (= 0 (child :return-code))) (string "Git " (string/join args " ") ": " output))
      (when (= 0 (child :return-code)) (string output)))))

(defn source [config &opt inherited revision]
  (if (and inherited (not revision))
    (do
      (assert (<= (os/stat (inherited :file) :size) (config :source-bytes)) "world source byte ceiling")
      (merge inherited {:code (string (slurp (inherited :file))) :file nil}))
    (let [root (string/trim (git (path/dirname (config :world)) ["rev-parse" "--show-toplevel"]))
          relative (string/join (path/parts (path/relpath root (config :world))) "/")
          base (string/trim (git root ["rev-parse" "--verify" "--end-of-options" (string (or revision "HEAD") "^{commit}")]))
          blob (string/trim (git root ["rev-parse" "--verify" "--end-of-options" (string base ":" relative)]))
          code (git root ["cat-file" "blob" blob])
          ref (git root (if revision ["rev-parse" "--symbolic-full-name" "--verify" "--end-of-options" revision] ["symbolic-ref" "-q" "HEAD"]) nil nil true)]
      (assert (<= (length code) (config :source-bytes)) "world source byte ceiling")
      {:code code :root root :path relative :blob blob :base base
       :ref (if (and ref (string/has-prefix? "refs/heads/" (string/trim ref))) (string/trim ref) "HEAD")})))

(defn save
  "Commit world source to Git, not live state. options: :call, :branch, :merge, :push. After merging, continue in a new child."
  [message &opt options]
  (def [s view] (dyn :zinc/context))
  (def config (s :config))
  (assert (and (string? message) (> (length (string/trim message)) 0) (<= (length message) 2048) (or (nil? options) (dictionary? options))) "save requires a message and optional settings")
  (default options {})
  (each key (keys options) (assert (index-of key [:call :branch :merge :push]) "unknown save setting"))
  (when (has-key? options :call) (assert (and (int? (options :call)) (> (options :call) 0)) "invalid saved call"))
  (each key [:branch :merge]
    (when (has-key? options key) (assert (and (string? (options key)) (<= 1 (length (options key)) 256) (not (string/find "\0" (options key)))) "invalid save revision")))
  (when (has-key? options :push) (assert (boolean? (options :push)) "invalid push setting"))
  (def branch (store/call s (get options :call (view :branch))))
  (def origin (json/decode (branch :origin) true true))
  (def directory (origin :root))
  (def file (branch :file))
  (assert (and file (= :file (os/stat file :mode))) "call source is unavailable")
  (assert (<= (os/stat file :size) (config :source-bytes)) "world source byte ceiling")
  (def code (string (slurp file)))
  (assert (<= (length code) (config :source-bytes)) "world source byte ceiling")
  (when (options :push) (assert (config :remote) "world push is not granted"))
  (def ref (if (options :branch) (string "refs/heads/" (options :branch)) (origin :ref)))
  (assert (not= ref "HEAD") "detached HEAD requires an explicit save branch")
  (git directory ["check-ref-format" ref])
  (store/checkpoint s)
  (def base-source (git directory ["show" (string (origin :base) ":" (origin :path))]))
  (def current (git directory ["rev-parse" "--verify" "--end-of-options" ref] nil nil true))
  (def previous (when current (string/trim current)))
  (def active (git directory ["symbolic-ref" "-q" "HEAD"] nil nil true))
  (assert (or (options :branch) (and (nil? previous) (not= ref (when active (string/trim active)))) (= previous (origin :base))) "world HEAD changed; save on an explicit branch")
  (var parent (or previous (origin :base)))
  (var merged nil)
  (def index (string file ".index"))
  (def environment {"GIT_INDEX_FILE" index})
  (defer (when (os/stat index) (os/rm index))
    (def blob (string/trim (git directory ["hash-object" "-w" "--stdin"] code)))
    (git directory ["read-tree" parent] nil environment)
    (git directory ["update-index" "--add" "--cacheinfo" "100644" blob (origin :path)] nil environment)
    (var tree (string/trim (git directory ["write-tree"] nil environment)))
    (when (options :merge)
      (def target (string/trim (git directory ["rev-parse" "--verify" "--end-of-options" (string (options :merge) "^{commit}")])))
      (each name (filter |(not= "" $) (string/split "\0" (git directory ["diff" "--name-only" "-z" parent target "--"])))
        (assert (= name (origin :path)) "merge changes files outside the world"))
      (set parent (string/trim (git directory ["commit-tree" tree "-p" parent] message)))
      (set tree (first (string/split "\n" (git directory ["merge-tree" "--write-tree" parent target]))))
      (set merged target))
    (def commit (string/trim (git directory ["commit-tree" tree "-p" parent ;(if merged ["-p" merged] [])] message)))
    (def intent (store/append s view "save-intent" message {:ref ref :before previous :after commit}))
    (git directory ["update-ref" "--stdin"] (string (if previous "update " "create ") ref " " commit (when previous (string " " previous)) "\n"))
    (def published (string/trim (git directory ["rev-parse" "--verify" "--end-of-options" (string commit ":" (origin :path))])))
    (def receipt @{:ref ref :before previous :after commit :path (origin :path) :blob published :merged merged :pushed false})
    (store/append s view "saved" message receipt (intent :id))
    (def materialized (git directory ["cat-file" "blob" published]))
    (when (= code (string (slurp file))) (spit file materialized :wb))
    (store/query s (string "UPDATE " (s :journal) ".call_payloads SET origin=? WHERE id=?")
                 [(string (json/encode (merge origin {:ref ref :base commit :blob (string/trim (git directory ["hash-object" "-w" "--stdin"] (string (slurp file))))}))) (branch :id)])
    (def head (git directory ["symbolic-ref" "-q" "HEAD"] nil nil true))
    (when (and head (= (string/trim head) ref) (= base-source (string (slurp (config :world)))))
      (spit (config :world) materialized :wb)
      (git directory ["reset" "--quiet" commit "--" (origin :path)]))
    (when (options :push)
      (git directory ["push" "--" (config :remote) (string ref ":" ref)])
      (put receipt :pushed true)
      (store/append s view "saved" "World pushed." receipt (intent :id)))
    receipt))

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
          "\n\n## World file\n\n" (json/encode (config :world))
          (when (and (config :repl) available)
            (string "\n\n## Janet\n\nTop-level single-name `def`, `defn` and `defmacro` add or replace this call's source declarations; a definition evaluating to nil removes its declaration. Other forms execute without updating source.\nCalls run source initializers when their environments load; use `let` for temporary values and effects.\n`(input)`: admitted input map. `(self/document)`: these instructions. `(settings)`: exposed settings. `(resources)`: callable resource grants."
                    (string/join (seq [[title value] :in [["Settings" (public :settings)] ["Resources" (public :resources)]] :when (> (length value) 0)]
                                   (string "\n\n## " title "\n\n" (json/encode value "  " "\n"))))
                    (when (> (length available) 0)
                      (string "\n\n## Bindings\n\n" (string/join (get-in config [:repl :bindings]) ", ")
                              "\n\n" (string/join (seq [[_ binding] :in (sorted (pairs available)) :unless (binding :local)] (binding :doc)) "\n\n")))))))

(defn- request [name args]
  (def reply (ev/thread-chan 1))
  (ev/give (dyn :zinc/requests) [name args reply])
  (def outcome (ev/take reply))
  (assert (and outcome (outcome :ok)) (get outcome :error "Execution closed"))
  (outcome :value))

(defn- evaluate [[source input document public bindings requests evaluations limits config]]
  (def base (make-env))
  (def env (make-env @{}))
  (each [name binding] (pairs bindings)
    (if-let [local (binding :local)] (put env local (base local))
      (put env (symbol name) @{:value (fn [& args] (request name args)) :doc (binding :doc)})))
  (def options (if (config :setup) ((module/value (require (config :setup)) 'configure) env) {}))
  (each key (keys options) (assert (index-of key [:parser :read :expander :on-compile-warning]) "unsupported REPL option"))
  (table/clear module/cache)
  (put env :redef true)
  (put env :zinc/requests requests)
  (put env 'stdout @{:value stderr})
  (put env 'input @{:value (fn [] input)})
  (put env 'self/document @{:value (fn [] document)})
  (put env 'settings @{:value (fn [] (schema/data (public :settings)))})
  (put env 'resources @{:value (fn [] (schema/data (public :resources)))})
  (sandbox :fs :net :subprocess :ffi :modules :threads :env :asm
           :unmarshal :exit :locale :signal :chroot :sandbox)
  (with-env env
    (var forms nil)
    (var loaded-source source) (var evaluation nil)
    (while (set evaluation (ev/take evaluations))
      (def [code reply] evaluation)
      (def output @"")
      (def outcome (try
                     (do
                       (put env :out (fn [bytes]
                                       (assert (<= (+ (length output) (length bytes)) (limits :output)) "execution output byte ceiling")
                                       (buffer/push-string output bytes)))
                       (unless forms
                         (def parsed (parse-all source))
                         (each form parsed
                           (assert (and (tuple? form) (= :parens (tuple/type form)) (index-of (first form) ['def 'defn 'defmacro]) (symbol? (get form 1))) "world source requires named declarations")
                           (eval form env))
                         (set forms parsed))
                       (var value nil) (var supplied false)
                       (run-context
                         (merge options
                                {:env env
                                 :chunks (fn [buf _] (unless supplied (buffer/push-string buf code) (set supplied true)))
                                 :on-status (fn [f result] (if (= :dead (fiber/status f)) result (error result)))
                                 :on-compile-error (fn [err &] (error err))
                                 :on-parse-error (fn [parser &] (error (parser/error parser)))
                                 :evaluator
                                 (fn [thunk form &]
                                   (def declaration (and (tuple? form) (= :parens (tuple/type form)) (index-of (first form) ['def 'defn 'defmacro])))
                                   (when declaration (assert (symbol? (get form 1)) "persistent definitions require one name"))
                                   (set value (thunk))
                                   (when declaration
                                     (def index (find-index |(= (form 1) ($ 1)) forms))
                                     (def next (filter |(not= (form 1) ($ 1)) forms))
                                     (unless (nil? value) (array/insert next (or index (length next)) form))
                                     (def updated (string/join (map |(string/format "%n" $) next) "\n"))
                                     (assert (<= (length updated) (limits :source)) "world source byte ceiling")
                                     (request "world/source" [loaded-source updated])
                                     (set loaded-source updated) (set forms next)
                                     (when (nil? value) (put env (form 1) nil))))}))
                       {:ok true :value (string output (if (string? value) value (string/format "%n" value)))})
                     ([err fiber]
                       (def failure (schema/failure "EvaluationFailed" err fiber))
                       {:ok false :error (merge failure {:context {:output (string output) :cause (failure :context)}})})))
      (ev/give reply outcome))))

(defn open [source input document public bindings limits config]
  (def runtime @{:requests (ev/thread-chan 1) :evaluations (ev/thread-chan 1) :finished (ev/thread-chan 1)})
  (ev/thread evaluate [source input document public bindings (runtime :requests) (runtime :evaluations) limits config] :n (runtime :finished))
  runtime)

(defn close [runtime]
  (ev/chan-close (runtime :evaluations)) (ev/chan-close (runtime :requests)))

(defn execute [runtime code handler seconds]
  (def reply (ev/thread-chan 1))
  (def pending @[])
  (defer (each [task done] pending
           (when (fiber/can-resume? task) (ev/cancel task "evaluation ended"))
           (ev/take done))
    (ev/with-deadline seconds
      (ev/give (runtime :evaluations) [code reply])
      (label done (while true
                    (def [status channel packet] (ev/select (runtime :requests) reply (runtime :finished)))
                    (assert (= status :take) "Execution closed")
                    (cond
                      (= channel reply) (do (assert (packet :ok) (packet :error)) (return done (packet :value)))
                      (= channel (runtime :finished)) (error (string "World evaluator stopped: " packet))
                      (do (def [name args response] packet)
                        (def finished (ev/chan))
                        (array/push pending [(ev/go (fn []
                                                      (defer (ev/chan-close finished)
                                                        (ev/give response (try {:ok true :value (handler name args)} ([err] {:ok false :error err})))))) finished]))))))))
