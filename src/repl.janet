(import spork/json :as json)
(import spork/path :as path)
(import ./store)

(defn- document [node]
  (cond
    (string? node) node
    (dictionary? node) (if (has-key? node :content)
                         (string (when (node :name) (string "# " (node :name) "\n\n")) (string/join (map document (node :content)) "\n\n"))
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
  (cond
    (not (config :repl)) {:code ""}
    (and inherited (not revision))
    (do
      (assert (<= (os/stat (inherited :file) :size) (config :source-bytes)) "world source byte ceiling")
      (def origin (merge inherited {:code (string (slurp (inherited :file)))}))
      (put origin :file nil) origin)
    (do
      (assert (and (config :file) (= :file (os/stat (config :file) :mode))) "world source is required")
      (def directory (path/dirname (config :file)))
      (def repository (git directory ["rev-parse" "--show-toplevel"] nil nil true))
      (def root (when repository (string/trim repository)))
      (def base (when root (git root ["rev-parse" "--verify" "--end-of-options" (string (or revision "HEAD") "^{commit}")] nil nil true)))
      (when revision (assert base "world revision unavailable"))
      (def commit (when base (string/trim base)))
      (def ref (when root (git root (if revision ["rev-parse" "--symbolic-full-name" "--verify" "--end-of-options" revision] ["symbolic-ref" "-q" "HEAD"]) nil nil true)))
      (def relative (if root (string/join (path/parts (path/relpath root (config :file))) "/") (path/basename (config :file))))
      (def tracked (and commit (not= "" (git root ["ls-tree" "-z" commit "--" relative]))))
      (when revision (assert tracked "world file is absent from the selected revision"))
      (def code (if tracked (git root ["show" (string commit ":" relative)])
                  (do (assert (<= (os/stat (config :file) :size) (config :source-bytes)) "world source byte ceiling") (string (slurp (config :file))))))
      (assert (<= (length code) (config :source-bytes)) "world source byte ceiling")
      {:code code :root (or root directory) :path relative :tracked (not (not tracked)) :base commit
       :ref (if (and ref (string/has-prefix? "refs/heads/" (string/trim ref))) (string/trim ref) (if root "HEAD" "refs/heads/main"))})))

(defn save
  "(save message options) — Save this call's world file; optional call, branch, merge and push."
  [message &opt options]
  (def [s view] (dyn :zinc/context))
  (def config (s :config))
  (assert (and (string? message) (<= 1 (length message) 2048) (or (nil? options) (dictionary? options))) "save requires a message and optional settings")
  (default options {})
  (each key (keys options) (assert (index-of key [:call :branch :merge :push]) "unknown save setting"))
  (when (has-key? options :call) (assert (and (int? (options :call)) (> (options :call) 0)) "invalid saved call"))
  (each key [:branch :merge]
    (when (has-key? options key) (assert (and (string? (options key)) (<= 1 (length (options key)) 256) (not (string/find "\0" (options key)))) "invalid save revision")))
  (when (has-key? options :push) (assert (boolean? (options :push)) "invalid push setting"))
  (def branch (store/call s (get options :call (view :branch))))
  (assert (= (branch :world) (config :world)) "saved call belongs to another world")
  (assert (= (config :file) ((json/decode (branch :config) true true) :file)) "saved world file changed")
  (def origin (json/decode (branch :origin) true true))
  (def directory (origin :root))
  (def file (branch :file))
  (assert (and file (= :file (os/stat file :mode))) "call source is unavailable")
  (assert (<= (os/stat file :size) (config :source-bytes)) "world source byte ceiling")
  (def code (string (slurp file)))
  (assert (<= (length code) (config :source-bytes)) "world source byte ceiling")
  (when (options :push) (assert (config :remote) "world push is not granted"))
  (unless (git directory ["rev-parse" "--git-dir"] nil nil true) (git directory ["init" "--initial-branch=main"]))
  (def ref (if (options :branch) (string "refs/heads/" (options :branch)) (origin :ref)))
  (assert (not= ref "HEAD") "detached HEAD requires an explicit save branch")
  (git directory ["check-ref-format" ref])
  (store/checkpoint s)
  (def base-source (if (and (origin :tracked) (origin :base)) (git directory ["show" (string (origin :base) ":" (origin :path))]) (branch :code)))
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
    (git directory ["read-tree" (or parent "--empty")] nil environment)
    (git directory ["update-index" "--add" "--cacheinfo" "100644" blob (origin :path)] nil environment)
    (var tree (string/trim (git directory ["write-tree"] nil environment)))
    (when (options :merge)
      (assert parent "merge requires a saved base")
      (def target (string/trim (git directory ["rev-parse" "--verify" "--end-of-options" (string (options :merge) "^{commit}")])))
      (each name (filter |(not= "" $) (string/split "\0" (git directory ["diff" "--name-only" "-z" parent target "--"])))
        (assert (= name (origin :path)) "merge changes files outside the world"))
      (set parent (string/trim (git directory ["commit-tree" tree "-p" parent] message)))
      (set tree (first (string/split "\n" (git directory ["merge-tree" "--write-tree" parent target]))))
      (set merged target))
    (def commit (string/trim (git directory ["commit-tree" tree ;(if parent ["-p" parent] []) ;(if merged ["-p" merged] [])] message)))
    (def intent (store/append s view "save-intent" message {:ref ref :before previous :after commit}))
    (git directory ["update-ref" "--stdin"] (string (if previous "update " "create ") ref " " commit (when previous (string " " previous)) "\n"))
    (def receipt @{:ref ref :before previous :after commit :file (origin :path) :merged merged :pushed false})
    (store/append s view "saved" message receipt (intent :id))
    (store/query s (string "UPDATE " (s :journal) ".call_payloads SET origin=? WHERE id=?") [(string (json/encode (merge origin {:ref ref :base commit :tracked true}))) (branch :id)])
    (def materialized (git directory ["show" (string commit ":" (origin :path))]))
    (when (= code (string (slurp file))) (spit file materialized :wb))
    (def head (git directory ["symbolic-ref" "-q" "HEAD"] nil nil true))
    (when (and head (= (string/trim head) ref) (= base-source (string (slurp (config :file)))))
      (spit (config :file) materialized :wb)
      (git directory ["reset" "--quiet" commit "--" (origin :path)]))
    (when (options :push)
      (git directory ["push" "--" (config :remote) (string ref ":" ref)])
      (put receipt :pushed true)
      (store/append s view "saved" "World pushed." receipt (intent :id)))
    receipt))

(defn definitions [config declared]
  (def selected @{})
  (each [grant capability] (pairs (config :capabilities))
    (def source (if (capability :module) (require (capability :module)) {(symbol grant) (declared grant)}))
    (unless (capability :module) (assert (declared grant) "unknown capability"))
    (each [name binding] (pairs source)
      (when (and (symbol? name) (not (binding :private)) (not (binding :macro)) (index-of (type (binding :value)) [:function :cfunction]))
        (assert (string? (binding :doc)) "capability function requires documentation")
        (def qualified (if (capability :module) (string grant "/" name) (string name)))
        (assert (and (not (selected qualified)) (or (not (capability :module)) (not (declared (keyword qualified))))) "capability shadows a declaration")
        (put selected qualified (merge binding {:config (capability :config)})))))
  selected)

(defn instructions [config view document-tree available]
  (string (document document-tree) "\n\n## World\n\n" (config :world)
          (when (config :instructions) (string "\n\n" (slurp (config :instructions))))
          (when (and (config :repl) (get view :tools true))
            (string "\nOne Janet environment lives for this call. Its editable source is `(world :current-file)`."
                    "\nDefinitions can be redefined; `(put world 'name nil)` removes a binding."
                    "\nEdit the one source file to preserve helpers; only `save` commits. HEAD is the current saved revision."
                    "\n`(input)` reads the inquiry; `(self/document)` reads these instructions."
                    "\n`(await (self {:text \"request\"}))` starts an independent source branch. `:persist false` keeps its journal in RAM."
                    "\nChildren inherit source, not unsaved live bindings. Performed effects are not rolled back."
                    "\n\n## Callable functions\n\n"
                    (string/join (seq [[name binding] :in (sorted (pairs available))] (string "- " (binding :doc))) "\n")
                    "\nGranted functions are already bound. Inspect uncertain receipts before repeating effects."))))

(defn- request [name args]
  (def reply (ev/thread-chan 1))
  (ev/give (dyn :zinc/requests) [name args reply])
  (def outcome (ev/take reply))
  (assert (and outcome (outcome :ok)) (get outcome :error "Execution closed"))
  (outcome :value))

(defn- evaluate [[file source input document bindings requests evaluations forbid ceiling]]
  (def env (make-env))
  (table/clear module/cache)
  (put env :current-file file) (put env :redef true)
  (put env 'stdout @{:value stderr}) (put env 'world @{:value env})
  (put env 'input @{:value (fn [] input)})
  (put env 'self @{:value (fn [value] (request "self" [value]))})
  (put env 'await @{:value (fn [handle] (request "await" [handle]))})
  (put env 'self/document @{:value (fn [] document)})
  (each binding bindings
    (def name (binding :name))
    (put env (symbol name) @{:value (fn [& args] (request name args)) :doc (binding :doc)}))
  (module/add-paths "" :source)
  (sandbox ;(map keyword forbid))
  (with-env env
    (var loaded false) (var evaluation nil)
    (while (set evaluation (ev/take evaluations))
      (def [code reply] evaluation)
      (def output @"")
      (def outcome (try
                     (with-dyns [:zinc/requests requests :out (fn [bytes]
                                                                (assert (<= (+ (length output) (length bytes)) ceiling) "execution output byte ceiling") (buffer/push-string output bytes))]
                       (unless loaded (eval-string source env) (set loaded true))
                       (def value (eval-string code env))
                       {:ok true :value (string output (if (string? value) value (string/format "%p" value)))})
                     ([err fiber]
                       (def trace @"")
                       (with-dyns [:err (fn [bytes] (buffer/push-string trace (string/slice bytes 0 (min (length bytes) (max 0 (- ceiling (length trace)))))))] (debug/stacktrace fiber))
                       {:ok false :error (string err "\n" trace)})))
      (ev/give reply outcome))))

(defn open [file source input document bindings forbid ceiling]
  (def runtime @{:requests (ev/thread-chan 1) :evaluations (ev/thread-chan 1) :finished (ev/thread-chan 1)})
  (ev/thread evaluate [file source input document bindings (runtime :requests) (runtime :evaluations) forbid ceiling] :n (runtime :finished))
  runtime)

(defn close [runtime]
  (ev/chan-close (runtime :evaluations)) (ev/chan-close (runtime :requests)))

(defn execute [runtime code handler seconds]
  (def reply (ev/thread-chan 1))
  (ev/with-deadline seconds
    (ev/give (runtime :evaluations) [code reply])
    (label done (while true
                  (def [status channel packet] (ev/select (runtime :requests) reply (runtime :finished)))
                  (assert (= status :take) "Execution closed")
                  (cond
                    (= channel reply) (do (assert (packet :ok) (packet :error)) (return done (packet :value)))
                    (= channel (runtime :finished)) (error (string "World evaluator stopped: " packet))
                    (do (def [name args response] packet)
                      (ev/give response (try {:ok true :value (handler name args)} ([err] {:ok false :error (string err)})))))))))
