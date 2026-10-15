(import spork/json :as json)
(import spork/path :as path)
(import ./store)
(import ./model)
(import ./memory)
(import ./schema)

(defn- document [node]
  (cond
    (string? node) node
    (dictionary? node) (if (has-key? node :content)
                         (string (when (node :name) (string "# " (node :name) "\n\n"))
                                 (string/join (map document (node :content)) "\n\n"))
                         (or (node :text) (string (json/encode node))))
    (indexed? node) (string/join (map document node) "\n")
    ""))

(defn- model-request [s view value]
  (assert ((s :config) :inference) "model requests are not permitted in this view")
  (model/call s (schema/request (json/encode value) [:role :model :messages :tools :output :query :documents])
              (get-in (dyn :zinc/task) [:checkpoint :request])))

(defn inspect-job [s view id]
  (def row (store/task s id))
  (def owned (or (= id ((dyn :zinc/task) :id))
                 (first (store/query s `WITH RECURSIVE parents(id) AS (
      SELECT ? UNION ALL SELECT t.parent FROM tasks t JOIN parents p ON t.id=p.id WHERE t.parent IS NOT NULL)
      SELECT id FROM parents WHERE id=?` [id ((dyn :zinc/task) :id)]))))
  (unless owned (store/event s view (row "admission")))
  {:owned (not (nil? owned)) :job id :state (row "state") :kind (row "kind")
   :admission (row "admission") :outcome (row "outcome")
   :children (store/query s "SELECT id,kind,retry_policy,admission,outcome,state FROM tasks WHERE parent=? AND source=? ORDER BY id LIMIT 256" [id (s :source)])})

(defn- commit [s view paths message]
  (def config (s :config))
  (assert (config :commit) "commit is not permitted")
  (assert (and (indexed? paths) (> (length paths) 0) (string? message) (<= 1 (length message) 2048)) "commit requires paths and message")
  (each file paths
    (assert (and (string? file) (not (path/abspath? file)) (not (string/find "\\" file)) (not (string/find "\0" file))) "invalid Git path")
    (each part (string/split "/" file)
      (assert (not (index-of part ["" "." ".." ".git"])) "invalid Git path component")))
  (def child (os/spawn ["git" "-C" (path/dirname (config :file)) "--literal-pathspecs"
                        "commit" "--only" "--message" message "--" ;paths]
                       :p {:in :pipe :out :pipe :err :out}))
  (ev/close (child :in))
  (var waited false)
  (ev/with-deadline (config :seconds)
    (defer (do (unless waited (os/proc-kill child true)) (ev/close (child :out)))
      (def output @"")
      (var chunk nil)
      (while (set chunk (ev/read (child :out) 4096))
        (assert (<= (+ (length output) (length chunk)) (config :response-bytes)) "commit output byte ceiling")
        (buffer/push-string output chunk))
      (def status (os/proc-wait child))
      (set waited true)
      (assert (= 0 status) (string output))
      (string output))))

(defn definitions [config]
  (def builtins (merge memory/operations
                       {"work/inspect" {:retry-policy "retry" :description "(work/inspect job) — State, children and durable receipts." :function inspect-job}
                        "model/request" {:retry-policy "retry" :description "(model/request request) — Model response with recorded usage." :function model-request}}))
  (def selected (tabseq [name :in (config :permissions)
                         :when (or (config :inference) (not= name "model/request"))] name
                  (do (assert (builtins name) "unknown Zinc permission") (builtins name))))
  (when (config :commit)
    (put selected "commit" {:retry-policy "manual" :description "(commit paths message) — Commit selected tracked world files." :function commit}))
  (each [namespace capability] (pairs (config :capabilities))
    (def env (require (capability :module)))
    (each [name binding] (pairs env)
      (when (and (symbol? name) (not (binding :private)) (not (binding :macro))
                 (index-of (type (binding :value)) [:function :cfunction]))
        (assert (string? (binding :doc)) "capability function requires documentation")
        (def target (binding :value))
        (put selected (string namespace "/" name)
             {:retry-policy "manual" :description (binding :doc)
              :module (capability :module)
              :function (fn [s view & args] (apply target (array/concat @[] args [(get capability :config {})])))}))))
  selected)


(defn instructions [config view document-tree]
  (def available (definitions config))
  (string (document document-tree) "\n\n## World\n\n" (config :world)
          (when (config :instructions) (string "\n\n" (slurp (config :instructions))))
          (when (and (config :repl) (get view :tools true))
            (string "\nSource: `" (config :file) "`\nExecution deadline: " (config :seconds) " seconds."
                    "\n\n## Janet\n\n`world` is this branch's environment. Files persist independently of definitions."
                    "\n`(input)` reads the inquiry. `(self/document)` reads these instructions."
                    "\n`(all-bindings world true)` lists local bindings."
                    "\n`(await (self {:text \"request\"}))` starts an independent agent branch under agent permissions."
                    "\nSearch by asking self a question; its semantic window retrieves within the allowed history."
                    "\n`(memory/expand id)` expands a known event ID into scoped original records or summary children."
                    "\n\n## Callable functions\n\n"
                    (string/join (seq [name :in (view :permissions) :when (available name)]
                                   (string "- " ((available name) :description))) "\n")
                    "\n\nProvided library namespaces can also be imported with `(import @namespace)`."
                    "\nCheck receipts before repeating an operation with an uncertain outcome."))))


(defn- request [name args]
  (def reply (ev/thread-chan 1))
  (ev/give (dyn :zinc/requests) [name args reply])
  (def outcome (ev/take reply))
  (assert (and outcome (outcome :ok)) (get outcome :error "Execution closed"))
  (outcome :value))

(defn- evaluate [[file source code input document bindings requests forbid ceiling]]
  (def env (make-env))
  (table/clear module/cache)
  (put env :current-file file)
  (put env :redef true)
  (put env 'stdout @{:value stderr})
  (put env 'world @{:value env})
  (put env 'input @{:value (fn [] input) :doc "(input) — Current inquiry."})
  (put env 'self @{:value (fn [value] (request "self" [value])) :doc "(self request) — Spawn an agent branch; await its handle."})
  (put env 'await @{:value (fn [handle] (request "await" [handle])) :doc "(await handle) — Read a descendant result."})
  (put env 'self/document @{:value (fn [] document) :doc "(self/document) — Current instructions and callable interfaces."})
  (each binding bindings
    (def name (binding :name))
    (def metadata @{:value (fn [& args] (request name args)) :doc (binding :doc)})
    (put env (symbol name) metadata)
    (when (binding :module)
      (def split (string/find "/" name))
      (def namespace (string/slice name 0 split))
      (def module (or (module/cache (binding :module)) (make-env)))
      (put module (symbol (string/slice name (+ split 1))) metadata)
      (put module/cache (binding :module) module)
      (put env (keyword namespace) (binding :module))))
  (module/add-paths "" :source)
  (sandbox ;(map keyword forbid))
  (with-env env
    (def output @"")
    (with-dyns [:zinc/requests requests
                :out (fn [bytes]
                       (assert (<= (+ (length output) (length bytes)) ceiling) "execution output byte ceiling")
                       (buffer/push-string output bytes))]
      (eval-string source env)
      (let [result (eval-string code env)]
        (string output (if (string? result) result (string/format "%p" result)))))))

(defn execute [file source code input document bindings handler seconds forbid ceiling]
  (def requests (ev/thread-chan 1))
  (def finished (ev/thread-chan 1))
  (ev/thread evaluate [file source code input document bindings requests forbid ceiling] :n finished)
  (var result nil)
  (ev/with-deadline seconds
    (defer (do (ev/chan-close requests) (ev/chan-close finished))
      (while true
        (def [status channel packet] (ev/select requests finished))
        (assert (= status :take) "Execution closed")
        (if (= channel finished)
          (do
            (assert (= :ok (packet 0)) (string (packet 1)))
            (set result (packet 1))
            (break))
          (do
            (def [name args reply] packet)
            (def outcome (try {:ok true :value (handler name args)} ([err] {:ok false :error (string err)})))
            (ev/give reply outcome))))
      result)))
