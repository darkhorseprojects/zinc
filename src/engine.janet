(import spork/json :as json)
(import spork/path :as path)
(import spork/utf8 :as utf8)
(import portable-agents/protocol :as wire)
(import ./store)
(import ./model)
(import ./memory)
(import ./schema)
(import ./repl)
(import ./http)

(defn make [spec]
  (defn message [event]
    (when (event :branch)
      (def data (json/decode (event :data) true true))
      (def origin (data :world-source))
      (def durable (= 0 (event :branch_temporary)))
      (def coordinate (if durable "#" "local "))
      (def body (case (event :kind)
                  "user" ""
                  "response" (model/render event)
                  "completed" (if (event :public_message) (model/render event) (event :text))
                  "model-outcome" (when (and (= "chat" (data :role)) (data :visible)) (model/render event))
                  "interruption" (when (= "uncertain" (data :state)) (event :text))
                  "saved" (string "Saved " (data :ref) " @ " (string/slice (data :after) 0 7) (when (data :pushed) " · pushed") "\n" (event :text))
                  "summary" (string "summary " coordinate (event :id) " · " (data :count)
                                    " records · source range " coordinate (data :first) "–" (data :last))
                  (when (and (not= false (data :display)) (index-of (event :kind) ["code-admission" "tool-result" "tool-ambiguity" "error"]))
                    (if-let [failure (data :error)]
                      (string/trim (string (get-in failure [:context :output] "") "\n" (failure :code) ": " (failure :message))) (event :text)))))
      (when body
        {:type (if (= "user" (event :kind)) "start" "display") :body body :kind (event :kind) :root (nil? (event :branch_parent))
         :caller (or (event :branch_parent) :null) :prompt (if (data :turn) (event :parent) :null)
         :related (if (and (not (data :turn)) (index-of (event :kind) ["tool-result" "tool-ambiguity" "completed"])) (or (event :parent) :null) :null)
         :status (or (data :status) (case (event :kind) "code-admission" "admitted" "error" "failed" "tool-ambiguity" "uncertain" (if (= false (data :ok)) "failed" "complete")))
         :language (case (event :kind) "code-admission" "janet" "tool-result" "text" nil)
         :run (event :run) :branch (event :branch) :execution (string (event :request) "/" (event :branch))
         :persist durable :event (if durable (event :id) :null)
         :sequence (event :id) :author (event :author) :at (event :at)
         :world {:path (origin :path) :blob (or (data :blob) (origin :blob)) :ref (or (data :ref) (origin :ref))
                 :revision (or (data :after) (origin :base))}})))

  (defn result [s id]
    (def call (store/call s id))
    (def final (first (store/query s "SELECT * FROM memory_records WHERE branch=? AND kind='completed'" [id])))
    (assert final "call has no completion")
    (merge (tabseq [[key value] :in (pairs (message final)) :unless (index-of key [:body :language])] key value) {:type "result" :final true :text (final :text)
                                                                                                                  :message (when (final :public_message) (json/decode (final :public_message) true true))
                                                                                                                  :start (if (= 0 (call :temporary)) (call :admission) :null)
                                                                                                                  :parent (or (call :entry) 0) :memory_range {:start (call :first) :end (call :last)}
                                                                                                                  :tool_usage (store/tool-used s (call :run)) :context_unit "token-estimate"
                                                                                                                  :usage (first (store/query s `SELECT coalesce(sum(u.total),0) reported_total,count(*) FILTER(WHERE u.total IS NULL) unreported
        FROM memory_records e LEFT JOIN usage u ON u.request=e.id WHERE e.run=? AND e.kind='model-admission'`
                                                                                                                                             [(call :run)]))}))

  (defn worker [entry input config]
    (def limits (dyn :pa/limits))
    (def process (os/spawn [(dyn :pa/executable) "run" (string (limits "frameBytes")) (string (limits "admissionSeconds"))]
                           :d {:in :pipe :out :pipe :err stderr}))
    (def exited (ev/chan 1))
    (ev/go (fn [] (os/proc-wait process)) nil exited)
    (try
      (do
        (defer (ev/close (process :in))
          (wire/send (process :in) (wire/request {"version" wire/version "program" (merge (dyn :pa/program) {"entry" entry})
                                                  "input" (wire/base64 (string (json/encode input)))
                                                  "config" (wire/base64 (string (json/encode config)))})))
        (def reader (wire/reader (process :out) true))
        (ev/with-deadline (limits "admissionSeconds") (wire/output reader true))
        [process reader exited])
      ([err] (ev/close (process :out)) (error err))))

  (defn launch [s id &opt here]
    (when-let [row (store/claim s id)]
      (try
        (cond here ((dyn :zinc/execute) s row)
          (or (s :temporary) (and (= "summarize" (row :kind)) (not (dyn :zinc/background))))
          (ev/go (fn [] ((dyn :zinc/execute) s row)))
          (let [[process] (worker "task" {:task id :owner (row :owner)} (dyn :zinc/config))]
            (ev/close (process :out))))
        ([err] (store/append s (store/view s (if (= "summarize" (row :kind)) (row :parent) id))
                             "launch-uncertain" "Call acceptance could not be confirmed." {:error err} nil id))))
    id)

  (defn wait [s id &opt here]
    (def current (dyn :zinc/call))
    (when current
      (when (= 0 (get current :waiters 0)) (store/park s true))
      (put current :waiters (+ 1 (get current :waiters 0))))
    (defer (when current
             (put current :waiters (- (current :waiters) 1))
             (when (and (= 0 (current :waiters)) (= "waiting" (get (first (store/query s "SELECT state FROM main.call_controls WHERE id=?" [(current :id)])) :state)))
               (store/park s false)))
      (if (string? id)
        (let [child ((current :children) id)]
          (assert child "temporary self is not owned by this call")
          (def [worker done] child)
          (ev/take done)
          (unless (= :dead (fiber/status worker)) (error (fiber/last-value worker)))
          (def [ok value] (fiber/last-value worker))
          (if ok value (error value)))
        (label done (while true
                      (store/recover s)
                      (when current (store/checkpoint s))
                      (def row (first (store/query s "SELECT state,kind FROM main.call_controls WHERE id=?" [id])))
                      (assert row "call unavailable")
                      (case (row :state)
                        "done" (return done (if (= "text" (row :kind)) (result s id)
                                              ((json/decode ((first (store/query s "SELECT data FROM events WHERE call=? AND kind='call-result' ORDER BY id DESC LIMIT 1" [id])) :data) true true) :value)))
                        "failed" (error ((json/decode ((first (store/query s "SELECT data FROM events WHERE call=? AND kind='call-result' ORDER BY id DESC LIMIT 1" [id])) :data) true true) :error))
                        "uncertain" (error (string "Call #" id ": uncertain effects; inspect receipts, do not replay."))
                        "cancelled" (error "call cancelled")
                        "queued" (launch s id here))
                      (ev/sleep 0.1))))))

  (defn start-child [s view value &opt snapshot]
    (def value (schema/request (postwalk |(if (dictionary? $) (tabseq [[k v] :in (pairs $)] (keyword k) v) $) value)
                               [:text :code :parent :memory_range :persist :revision]))
    (assert (not= (nil? (value :text)) (nil? (value :code))) "self requires text or code")
    (def config (if (value :text) (or ((s :config) :agent) (s :config)) (s :config)))
    (assert (if (value :text) (config :inference) (config :repl)) "child execution is not permitted")
    (def parent (store/call s (view :branch)))
    (put value :author (string "self:" (parent :request) "/" (parent :id)))
    (put value :at (((store/query s "SELECT strftime('%Y-%m-%dT%H:%M:%fZ','now') at") 0) :at))
    (put value :persist (get value :persist (= 0 (parent :temporary))))
    (when (= 1 (parent :temporary)) (assert (not (value :persist)) "temporary calls cannot create durable descendants"))
    (def origin (merge (or snapshot (repl/source config (when (parent :file) (merge (json/decode (parent :origin) true true) {:file (parent :file)})) (value :revision)))
                       {:ref (string "refs/heads/self/" (string/join (map |(string/format "%02x" $) (os/cryptorand 12))))}))
    (if (value :persist)
      (do
        (repl/git (origin :root) ["update-ref" "--stdin"] (string "create " (origin :ref) " " (origin :base) "\n"))
        (def call (store/start s value config (merge view {:event (dyn :zinc/effect) :agent (or (view :agent) (not= config (s :config)))}) origin))
        {:job (call :id) :branch (call :id)})
      (do
        (each id [(get value :parent 0) (get-in value [:memory_range :start] 0) (get-in value [:memory_range :end] 0)]
          (when (> id 0) (store/event s view id)))
        (assert (< (view :depth) (config :task-depth)) "agent recursion ceiling exhausted")
        (def request (string/join (map |(string/format "%02x" $) (os/cryptorand 24))))
        (def entry (get value :parent (view :last)))
        (def [process reader exited]
          (worker "self" (merge value {:request request :parent entry
                                       :memory_range (get value :memory_range {:start (if (= 0 entry) 0 (view :first)) :end entry})})
                  (merge config {:snapshot (merge (store/snapshot s view) {:origin origin})})))
        (def done (ev/chan))
        (def collector (ev/spawn
                         (defer (ev/chan-close done)
                           (try
                             (defer (ev/close (process :out))
                               (def output (json/decode (wire/output reader) true true))
                               (ev/take exited)
                               (assert (= 0 (process :return-code)) "ProcessFailure")
                               [true (if (value :code) (output :text) output)])
                             ([err] [false err])))))
        (put ((dyn :zinc/call) :children) request [collector done])
        {:temporary request})))

  (defn run-code [s view bindings code]
    (def config (s :config))
    (assert (config :repl) "Janet execution is not permitted")
    (assert (<= (length code) (config :source-bytes)) "tool source byte ceiling")
    (store/checkpoint s)
    (def current (dyn :zinc/call))
    (unless (current :runtime)
      (os/cd (path/dirname (config :world)))
      (assert (<= (os/stat (current :file) :size) (config :source-bytes)) "world source byte ceiling")
      (def public (repl/public config (spec :schema)))
      (put current :runtime (repl/open (string (slurp (current :file))) (current :input)
                                       (repl/instructions config (spec :document) bindings public) public
                                       (tabseq [[name binding] :in (pairs bindings)] name (if (binding :local) binding {:doc (binding :doc)}))
                                       {:source (config :source-bytes) :output (config :response-bytes)} (config :repl))))
    (repl/execute (current :runtime) code
                  (fn [name args]
                    (store/checkpoint s)
                    (def binding (bindings name))
                    (assert (or (= name "world/source") (and binding (not (binding :local)))) "function revoked")
                    (when (get binding :intrinsic) (assert (= 1 (length args)) "invalid intrinsic arity"))
                    (def args (schema/data args))
                    (case name
                      "world/source"
                      (do (assert (and (= 2 (length args)) (every? (map string? args)) (<= (length (args 1)) (config :source-bytes))) "invalid world source update")
                        (assert (= (args 0) (string (slurp (current :file)))) "world source changed; continue in a new self after merging")
                        (def blob (string/trim (repl/git (path/dirname (config :world)) ["hash-object" "-w" "--stdin"] (args 1))))
                        (spit (current :file) (args 1) :wb)
                        (store/query s (string "UPDATE " (s :journal) ".call_payloads SET origin=json_set(origin,'$.blob',?) WHERE id=?") [blob (current :id)]) nil)
                      (let [admission (store/transact s (store/charge s 1 0)
                                                      (store/append s view "call-admission" name {:arguments args} nil ((dyn :zinc/call) :id)))]
                        (def value
                          (cond
                            (= name "self")
                            (let [handle (with-dyns [:zinc/effect (admission :id)] (start-child s (merge view (store/view s (view :branch))) (first args)))]
                              (when (handle :job) (launch s (handle :job)))
                              (wait s (or (handle :temporary) (handle :job))))
                            (index-of name ["fs/list" "fs/read" "fs/write"])
                            (do
                              (assert (= (length args) (if (= name "fs/write") 3 2)) "invalid filesystem arity")
                              (def [root relative text] args)
                              (def grant (get-in config [:fs (keyword root)]))
                              (assert (and grant (grant (if (= name "fs/write") :write :read))) "filesystem operation is not granted")
                              (assert (and (string? relative) (> (length relative) 0) (not (string/find "\0" relative))
                                           (not (string/find "\\" relative)) (not (string/find ":" relative)) (not (path/abspath? relative))) "invalid relative path")
                              (var target (os/realpath (grant :root)))
                              (each part (array/concat @[""] (if (= relative ".") [] (string/split "/" relative)))
                                (unless (= part "")
                                  (assert (not (index-of part ["." ".."])) "invalid path component")
                                  (when (index-of (os/which) [:windows :mingw])
                                    (assert (and (not (index-of (last part) [32 46]))
                                                 (not (peg/match ~(* (choice "CON" "PRN" "AUX" "NUL" (* (choice "COM" "LPT") (range "19"))) -1)
                                                                 (string/ascii-upper (first (string/split "." part)))))) "invalid Windows path component"))
                                  (set target (path/join target part)))
                                (assert (if (index-of (os/which) [:windows :mingw])
                                          (let [attributes (ffi/call (ffi/lookup (ffi/native "kernel32.dll") "GetFileAttributesA") (ffi/signature :default :uint32 :string) target)]
                                            (or (= attributes 0xffffffff) (= 0 (band attributes 0x400))))
                                          (not= :link (os/lstat target :mode))) "filesystem links are not permitted"))
                              (case name
                                "fs/list" (do (assert (= :directory (os/stat target :mode)) "directory required")
                                            (def names (os/dir target))
                                            (assert (and (<= (length names) (config :history-records)) (<= (sum (map length names)) (config :response-bytes))) "directory result exceeds limit")
                                            (sorted names))
                                "fs/read" (do (assert (= :file (os/stat target :mode)) "regular file required")
                                            (with [file (file/open target :rbn)]
                                              (def bytes (or (file/read file (+ 1 (config :response-bytes))) ""))
                                              (assert (and (<= (length bytes) (config :response-bytes)) (utf8/is-valid? bytes)) "file exceeds limit or is not UTF-8")
                                              (string bytes)))
                                (do (assert (and (string? text) (utf8/is-valid? text) (<= (length text) (config :response-bytes))) "invalid file contents")
                                  (assert (or (nil? (os/stat target)) (= :file (os/stat target :mode))) "regular file required")
                                  (spit target text :wb) nil)))
                            (= name "http/request")
                            (do
                              (assert (= 4 (length args)) "invalid HTTP arity")
                              (def [root method segments body] args)
                              (def grant (get-in config [:http (keyword root)]))
                              (assert (and grant (index-of method (grant :methods))) "HTTP operation is not granted")
                              (assert (and (indexed? segments) (every? (map |(and (string? $) (not (index-of $ ["." ".."]))
                                                                                  (peg/match ~(* (some (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-~.")) -1) $)) segments))) "invalid HTTP path")
                              (assert (or (nil? body) (string? body)) "HTTP body must be text or nil")
                              (http/request config grant method (string/join segments "/") body))
                            (= name "process/run")
                            (do
                              (assert (= 1 (length args)) "invalid process arity")
                              (def command (get-in config [:processes (keyword (first args))]))
                              (assert command "process is not granted")
                              (def child (os/spawn (command :argv) :e (merge (tabseq [[k v] :in (pairs (command :env))] (string k) v) {:in :pipe :out :pipe :err :out})))
                              (def exited (ev/chan 1))
                              (ev/go (fn [] (os/proc-wait child)) nil exited)
                              (def owner (fiber/current))
                              (def watcher (ev/go (fn [] (try (while true (store/checkpoint s) (ev/sleep 0.1))
                                                           ([err] (unless (= err :finished) (ev/cancel owner err)))))))
                              (defer (do (ev/cancel watcher :finished)
                                       (when (nil? (child :return-code)) (try (os/proc-kill child) ([err] nil)) (ev/take exited))
                                       (ev/close (child :out)))
                                (ev/close (child :in))
                                (def output @"") (var chunk nil)
                                (while (set chunk (ev/read (child :out) 4096))
                                  (assert (<= (+ (length output) (length chunk)) (config :response-bytes)) "process output exceeds limit")
                                  (buffer/push-string output chunk))
                                (ev/take exited)
                                (assert (utf8/is-valid? output) "process output is not UTF-8")
                                {:exit (child :return-code) :output (string output)}))
                            (schema/data
                              (with-dyns [:zinc/context [s view] :capability/config (binding :config)
                                          :capability/presentation (filter identity (map message (memory/events s (view :run) 0 (admission :id))))]
                                (apply (binding :value) args)))))
                        (store/transact s (store/checkpoint s)
                                        (store/append s view "operation-outcome" name {:value value} (admission :id) ((dyn :zinc/call) :id)))
                        value)))
                  (min (config :seconds) (max 0.001 (- (view :expires) (os/clock))))))

  (defn infer [s call bindings]
    (def id (call :id))
    (def config (s :config))
    (def inherited (store/view s id false))
    (def selected (model/profile s (config :chat) :chat))
    (def tools (filter |(or (config :repl) (not= "function" ($ :type))) (selected :tools)))
    (def system (repl/instructions config (spec :document) (when (find |(= "function" ($ :type)) tools) bindings) (repl/public config (spec :schema))))
    (def user (first (store/query s "SELECT * FROM memory_records WHERE task=? AND kind='user'" [id])))
    (def inquiry {:role "user" :content (model/images s (user :id) (memory/render user))})
    (def tool-size (if (> (length tools) 0) (store/estimate (json/encode tools)) 0))
    (def capacity (min (get config :context-quota math/inf) (- (selected :context) 256)))
    (var space 0)
    (def progress ((dyn :zinc/call) :checkpoint))
    (def pool (or (progress :semantic)
                  (let [pending (when (progress :request) (first (store/query s "SELECT id FROM events WHERE id=? AND json_extract(data,'$.input.role')='rerank'" [(progress :request)])))
                        rows (memory/semantic-window s inherited (user :text) (when pending (pending :id)))]
                    (store/checkpoint s {:semantic rows}) rows)))
    (while (not (first (store/query s "SELECT id FROM memory_records WHERE branch=? AND kind='completed'" [id])))
      (def responses (store/query s "SELECT id FROM memory_records WHERE task=? AND kind='response' ORDER BY id" [id]))
      (each tool (store/query s "SELECT * FROM unresolved_tools WHERE branch=?" [id])
        (store/append s (store/view s id) "tool-ambiguity" "Interrupted evaluation; effects may have happened. Inspect before repeating."
                      {:tool-id (tool :tool_id) :response (tool :response) :ok false :uncertain true} (tool :response) id))
      (assert (< (length responses) (config :rounds)) "model round limit exhausted")
      (def view (store/view s id))
      (def world (when (config :repl) {:role "user" :content (string "## World source\n\n" (slurp (call :file)))}))
      (set space (- capacity (model/estimate (filter identity [{:role "system" :content system} world inquiry])) tool-size 256))
      (assert (> space 256) "question, world source and instructions exhaust context")
      (var context (memory/context s inherited space pool))
      (def messages @[]) (def views @{})
      (while true
        (array/clear messages) (array/push messages {:role "system" :content system})
        (when world (array/push messages world))
        (table/clear views) (put views :through (context :through))
        (each [key title rows] [[:chronological "Chronological memory" (context :nodes)] [:semantic "Retrieved excerpts" (context :evidence)]]
          (def text (string/join (map |($ :rendered) rows)))
          (put views key @{:message (when (> (length text) 0) (length messages))
                           :records (seq [row :in rows] (tabseq [field :in [:id :label :first :last :children :offset :next :total :score] :when (has-key? row field)] field (row field)))})
          (when (> (length text) 0) (array/push messages {:role "user" :content (string "## " title "\n\n" text)})))
        (put (views :semantic) :cutoff (config :score))
        (put (views :semantic) :candidates (seq [row :in pool] {:id (row :id) :score (row :score) :rerank (row :rerank)}))
        (array/push messages inquiry)
        (each record (store/query s "SELECT conversation_message,json_extract(data,'$.status') status FROM conversation_records WHERE branch=? AND id>? ORDER BY id" [id (context :through)])
          (array/push messages (json/decode (record :conversation_message) true true))
          (when (= "continue" (record :status))
            (array/push messages {:role "system" :content "Continue the inquiry."})))
        (when (<= (+ (model/estimate messages) tool-size) capacity) (break))
        (assert (< (context :through) (view :last)) "context metadata cannot fit")
        (set context (memory/context s (merge view {:exclude [(user :id)]}) space pool)))
      (def pending (get-in (dyn :zinc/call) [:checkpoint :request]))
      (def response (model/call s {:turn true :model (config :chat) :messages messages :views views :tools (when (> (length tools) 0) tools)}
                                (when (and pending (not (first (store/query s "SELECT id FROM events WHERE parent=? AND kind='model-outcome'" [pending])))) pending) selected))
      (def parallel (> (length (response :tools)) 1))
      (def fork (store/view s id))
      (def origin (when parallel (repl/source config (merge (json/decode ((store/call s id) :origin) true true) {:file (call :file)}))))
      (def work (seq [tool :in (response :tools)]
                  (def admission (store/transact s (store/checkpoint s) (store/charge s 1 (if (or parallel (tool :error)) 0 (store/estimate (tool :code))))
                                                 (store/append s view (if (or parallel (tool :error)) "call-admission" "code-admission") (cond (tool :error) "run_janet" parallel "self" (tool :code))
                                                               {:tool-id (tool :id) :response (response :event)} nil id)))
                  [tool admission (if (tool :error) tool (when parallel (try (with-dyns [:zinc/effect (admission :id)] (start-child s fork {:code (tool :code)} origin)) ([err fiber] {:error (schema/failure "ToolFailed" err fiber)}))))]))
      (each [_ _ handle] work (when-let [job (get handle :job)] (launch s job)))
      (each [tool admission handle] work
        (def outcome (try
                       {:ok true :text (if (get handle :error) (error (get handle :error)) (if parallel
                                                                                             (wait s (or (handle :temporary) (handle :job)))
                                                                                             (run-code s view bindings (tool :code))))}
                       ([err fiber]
                         (when (= err "deadline expired") (error err))
                         (def failure (schema/failure "ToolFailed" err fiber))
                         {:ok false :text (failure :message) :error failure})))
        (store/charge s 0 (store/estimate (json/encode outcome)))
        (store/transact s (store/checkpoint s)
                        (store/append s view "tool-result" (if (outcome :ok) (outcome :text) (string (json/encode outcome)))
                                      (merge outcome {:tool-id (tool :id) :response (response :event) :child (get handle :branch) :display (or (not parallel) (has-key? handle :error))}) (admission :id) id))
        (unless (outcome :ok)
          (eprint (json/encode (merge (outcome :error) {:context (merge (or (get-in outcome [:error :context]) {}) {:tool-call {:branch id :tool (tool :id) :event (admission :id)}})}))))))
    (unless (s :temporary)
      (try (with-dyns [:zinc/background true] (memory/context s (store/view s id) space pool true))
        ([err] (store/append s (store/view s id) "launch-uncertain" "Background compaction preparation failed." {:error (string err)}))))
    {:completion ((first (store/query s "SELECT id FROM memory_records WHERE branch=? AND kind='completed'" [id])) :id)})

  (defn execute [store row]
    (def config (if (and (= 1 (row :agent)) ((store :config) :agent)) ((store :config) :agent) (store :config)))
    (def s (merge store {:config config :budget-root (or (row :root) (row :id))}))
    (def id (row :id))
    (def view (store/view s (if (= "summarize" (row :kind)) (row :parent) id)))
    (def stop (ev/thread-chan 1))
    (def finished (ev/thread-chan 1))
    (ev/thread store/heartbeat [(config :store) (config :lease-seconds) id (row :owner) stop] :n finished)
    (defer (do (ev/give stop true) (ev/take finished))
      (with-dyns [:zinc/call (merge row {:scope view :children @{} :input (json/decode (row :input) true true)
                                         :checkpoint (json/decode (row :checkpoint) true true)}) :zinc/effect (row :admission)]
        (store/transact s
                        (store/checkpoint s)
                        (store/append s view "call-attempt" (if (= "code" (row :kind)) (get-in (dyn :zinc/call) [:input :code]) "execution entered") {:attempt (row :attempt)} nil id))
        (def [value failure]
          (try
            (let [input ((dyn :zinc/call) :input)
                  bindings (if (not= "summarize" (row :kind)) (repl/definitions config (spec :schema)) {})
                  value (case (row :kind) "text" (infer s row bindings)
                          "code" (run-code s view bindings (input :code)) "summarize" (memory/summarize s row input))]
              (when (= "code" (row :kind)) (store/charge s 0 (store/estimate (json/encode value))))
              [value nil])
            ([err fiber]
              (def tokens (keep |(when ($ :token-env) (os/getenv ($ :token-env))) (values (config :providers))))
              [nil {:error (postwalk (fn [value]
                                       (if (string? value) (reduce (fn [text token] (string/replace-all token "[redacted]" text)) value tokens) value))
                                     (schema/failure "ExecutionFailed" err fiber))}])))
        (when-let [runtime ((dyn :zinc/call) :runtime)] (repl/close runtime))
        (when (first (store/query s "SELECT id FROM main.live_calls WHERE id=? AND owner=?" [id (row :owner)]))
          (each request (keys ((dyn :zinc/call) :children))
            (try (wait s request) ([err] (eprint (json/encode (if (dictionary? err) err {:code "ChildFailed" :message (string err)})))))))
        (store/finish s row value failure)
        (each pending (store/query s "SELECT c.id FROM main.call_controls c JOIN call_payloads p ON p.id=c.id WHERE p.run=? AND c.state='queued' AND c.expires>? ORDER BY c.id LIMIT ?"
                                   [(row :run) (os/clock) (config :parallel)]) (launch s (pending :id))))))

  (defn drain [s run after]
    (var sequence after)
    (while true
      (def records (memory/events s run sequence))
      (each event records
        (when-let [frame (message event)] (print (json/encode frame)))
        (set sequence (event :id)))
      (when (< (length records) 256) (break)))
    sequence)

  (defn run [s value operation]
    (def existing (first (store/query s "SELECT * FROM calls WHERE id=? OR request_key=?" [(or (value :task) (value :run)) (value :request)])))
    (when (index-of operation ["task" "resume"]) (assert existing "call unavailable"))
    (when existing
      (assert (= 0 (existing :temporary)) "temporary execution cannot be reattached")
      (assert (= 0 (existing :cancelled)) "saved call unavailable")
      (put s :config (schema/authorize (spec :schema) (s :config) (json/decode (existing :config) true true)))
      (put s :budget-root (or (existing :root) (existing :id)))
      (store/query s "UPDATE main.call_controls SET expires=min(expires,(SELECT created FROM events WHERE call=call_controls.id AND kind='user')+?) WHERE id=?"
                   [((s :config) :run-seconds) (existing :run)]))
    (with-dyns [:zinc/wait wait :zinc/spawn launch :zinc/execute execute :zinc/config (s :config)]
      (store/recover s)
      (if (= operation "task")
        (do (assert (= (value :owner) (existing :owner)) "call ownership changed") (execute s existing) {:task (value :task)})
        (do
          (unless (= operation "resume")
            (assert (and (value :author) (value :at) (not= (nil? (value :text)) (nil? (value :code)))) "self requires text or code, authenticated author and occurrence time")
            (assert (if (value :text) ((s :config) :inference) ((s :config) :repl)) "execution is not permitted in this view")
            (unless (value :request) (put value :request (string/join (map |(string/format "%02x" $) (os/cryptorand 24))))))
          (def call (if (= operation "resume") existing (store/start s value (s :config) nil
                                                                     (unless existing (or (get-in (s :config) [:snapshot :origin]) (repl/source (s :config) nil (value :revision)))))))
          (def id (call :id))
          (var sequence (drain s (call :run) (get value :after 0)))
          (when (= operation "resume")
            (assert (and (= "text" (call :kind)) (> (call :expires) (os/clock))) "call requires reconciliation or its deadline expired")
            (store/query s "UPDATE main.call_controls SET state='queued',retries=1,owner=NULL,lease_expires=NULL WHERE id=? AND state IN ('failed','uncertain')" [id]))
          (def emitter (ev/go (fn [] (try (while true (set sequence (drain s (call :run) sequence)) (ev/sleep 0.1))
                                       ([err] (eprint (json/encode {:code "ObservationFailed" :message (string err)})))))))
          (defer (do (ev/cancel emitter "observer detached") (drain s (call :run) sequence))
            (var failure nil)
            (try (wait s id true) ([err] (set failure err)))
            (while true
              (store/recover s)
              (def children (store/query s "SELECT c.id,c.state,p.run FROM main.call_controls c LEFT JOIN call_payloads p ON p.id=c.id WHERE c.root=? AND c.kind<>'summarize' AND c.state IN ('queued','running','waiting') ORDER BY c.id" [(or (call :root) id)]))
              (when (= 0 (length children)) (break))
              (each child children (when (and (= "queued" (child :state)) (= (call :run) (child :run))) (launch s (child :id))))
              (ev/sleep 0.1))
            (if failure (error failure) (result s id)))))))

  (defn describe [config]
    {:contract "inquiry-v1" :profile {:field "agent" :inference "inference"}
     :parameters (catseq [[target fields] :in [[:config (spec :schema)] [:input (spec :input)]]]
                   (seq [[key field] :in (sorted (pairs fields)) :when (field :option)]
                     (def parameter (merge (tabseq [[k v] :in (pairs field) :unless (index-of k [:optional :option :repl])] k v)
                                           {:name (field :option) :path (string target "." key) :type (string (field :type)) :default (get config key (get field :default "automatic"))}))
                     (when (and (= target :config) (= :integer (field :type)) (> (config key) 0)) (put parameter :maximum (config key))) parameter))})

  (tabseq [[operation fields] :in [["self" (keys (spec :input))] ["task" [:task :owner]] ["resume" [:run :request :after]]
                                   ["describe" []] ["instructions" []] ["models" [:role]] ["views" [:event]] ["render" [:event]] ["events" [:run :after]] ["record" [:records]] ["pending" [:request]] ["abort" [:run :request :reason]] ["invalidate" [:event]]]]
    operation (fn [bytes opaque]
                (def config (schema/configuration (spec :schema) (json/decode opaque true true) (= operation "describe")))
                (when (index-of operation ["self" "task" "resume" "instructions"])
                  (each profile (filter identity [config (config :agent)]) (repl/definitions profile (spec :schema))))
                (assert (and (utf8/is-valid? bytes) (<= (length bytes) (config :request-bytes))) "request must be bounded UTF-8")
                (when (index-of operation ["describe" "instructions"]) (assert (= "" bytes) "operation takes empty input"))
                (def value (if (and (= "" bytes) (index-of operation ["describe" "instructions" "pending"])) {} (schema/request (json/decode bytes true true) fields)))
                (def s (unless (index-of operation ["describe" "instructions" "models"]) (store/open config (and (= operation "self") (= false (get value :persist true))))))
                (defer (when s (store/close s))
                  (with-dyns [:zinc/config config]
                    (def output (cond
                                  (= operation "describe") (describe config)
                                  (= operation "instructions") (repl/instructions config (spec :document) (repl/definitions config (spec :schema)) (repl/public config (spec :schema)))
                                  (= operation "models") (map |{:ref ($ :ref) :name ($ :name)} (model/catalogue config (get value :role "chat")))
                                  (= operation "record") {:events (store/record s (value :records))}
                                  (index-of operation ["views" "render"])
                                  (do
                                    (assert (and (int? (value :event)) (> (value :event) 0)) "choose a model-admission event")
                                    (def row (store/event s {:first 1 :last 9007199254740991} (value :event)))
                                    (assert (= "model-admission" (row :kind)) "point must identify a model-admission event")
                                    (def data (json/decode (row :data) true true))
                                    (assert (get-in data [:request :body]) "exact request was not recorded")
                                    (def call (store/call s (row :task)))
                                    (def report {:event (row :id) :run (row :run) :branch (row :branch) :author (row :author) :at (row :at)
                                                 :world (data :world-source) :memory_range {:start (call :first) :end (call :last)}})
                                    (if (= operation "render") (merge report {:request (data :request)})
                                      (let [body (json/decode (get-in data [:request :body]) true true) windows (data :views)]
                                        (assert windows "this request has no chronological or semantic windows")
                                        (each key [:chronological :semantic]
                                          (put (windows key) :text (if-let [index (get-in windows [key :message])] (get-in body [:messages index :content]) "")))
                                        (merge report {:views windows}))))
                                  (= operation "invalidate") {:event ((memory/invalidate s (value :event)) :id)}
                                  (= operation "abort") (store/abort s value)
                                  (= operation "events") (let [records (memory/events s (value :run) (get value :after 0))]
                                                           {:events (filter identity (map message records)) :after (get (last records) :id (get value :after 0)) :more (= 256 (length records))})
                                  (= operation "pending") (do (store/recover s)
                                                            (store/query s `SELECT c.id run,c.request,c.id branch,c.id job,c.state,CASE WHEN c.kind='text' THEN 'agent' ELSE c.kind END kind,c.attempt,
                (SELECT id FROM events WHERE call=c.id AND kind IN ('user','summary-input')) admission,
                (SELECT id FROM events WHERE call=c.id AND kind='call-result' ORDER BY id DESC LIMIT 1) outcome,
                CASE WHEN c.temporary OR c.kind='code' THEN 'manual' ELSE 'retry' END retry_policy,c.expires run_expires,c.lease_expires,c.temporary
                FROM main.call_controls c WHERE c.request IS NOT NULL AND (? IS NULL OR c.request=?)
                AND (? IS NOT NULL OR c.state IN ('queued','running','waiting','failed','uncertain','cancelled')) ORDER BY c.id`
                                                                         [(value :request) (value :request) (value :request)]))
                                  (run s value operation)))
                    (if (= operation "instructions") output (string (json/encode output))))))))
