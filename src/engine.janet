(import ./store)
(import ./model)
(import ./memory)
(import ./schema)
(import ./vm)
(import ./effects)

(def bindings
  {"self" {:arity [1 1] :doc `(self request)
Starts an independent child inquiry (:text) or Janet script (:code). request must be an object with exactly one of :text or :code, both strings.
Optional :parent selects a historical event (0 means empty history); omitted uses the caller's current point. Optional :memory_range {:start first-id :end last-id} selects inclusive history; omitted includes all history through :parent. Optional :world selects a granted world. Descendants inherit persistence.
Returns {:script id :store store-id :request request-id :persist boolean} immediately, not completion. :script identifies either a script or an inquiry. Pass the handle to self/status, self/wait, or self/cancel.
Examples: (self {:text "Investigate source A."}); (self {:code "(+ 1 2)"}); (self {:text "Reconsider." :parent 140 :memory_range {:start 20 :end 100}}).
For concurrent children, admit them with self before waiting for any of them.`}
   "self/append" {:arity [1 1] :doc `(self/append records)
Adds source information without executing it or creating child work. records is an array of objects containing exactly :key, :author, :at, and :text, all nonempty strings. :key identifies the source record; :at is its timestamp. Returns {:events [event-id ...]}.
Example: (self/append [{:key "report:42" :author "analyst" :at "2026-11-13T01:00:00Z" :text "Three services were affected."}]).`}
   "self/queue" {:arity [1 1] :doc `(self/queue request)
Queues child work in admission order among queued siblings from this script. Returns an admission handle immediately; does not wait for completion.
request must be an object with exactly one of :text (child inquiry) or :code (Janet source), both strings. Optional :parent, :memory_range {:start first-id :end last-id}, and :world have the same meanings as self. Descendants inherit persistence.
Returns {:script id :store store-id :request request-id :persist boolean}. Use self/wait for the root outcome. Use self instead when queue ordering is unnecessary.
Examples: (self/queue {:text "Check the next source."}); (self/queue {:code "(+ 1 2)"}). A string alone, :task, and :request are not work instructions.`}
   "self/status" {:arity [1 1] :doc `(self/status handle)
Reads an authorized script or inquiry's root outcome without waiting. Accepts its admission handle or numeric :script ID. Returns :script and :state ("pending" until an outcome exists). Available outcomes include :value, :text, and optionally :error.
An inquiry's outcome is its latest completed response. A script's root return does not imply background fibers have drained or world changes have been published.
Example: (self/status child).`}
   "self/wait" {:arity [1 1] :doc `(self/wait handle)
Suspends only the calling fiber until a descendant's root outcome is available. Other fibers, scripts, and effects continue. Accepts its admission handle or numeric :script ID. An already available authorized outcome returns immediately.
Returns an outcome object, not the value directly. Check :state and :error before reading :value; child failures are returned as data. Does not wait for background fibers or world publication.
Example: (let [child (self {:code "(+ 1 2)"}) outcome (self/wait child)] (if (= "done" (outcome :state)) (outcome :value) outcome)).`}
   "self/cancel" {:arity [1 1] :doc `(self/cancel handle)
Cancels a descendant execution tree. Accepts its admission handle or numeric :script ID. Completed effects are not undone; an already dispatched external action may still finish.
Example: (self/cancel child).`}
   "world/view" {:arity [0 1] :doc "(world/view &opt point) reports a world publication and its complete defining source."}
   "world/remove" {:arity [1 1] :doc "(world/remove name) removes a local world binding; name is a symbol."}
   "memory/summarize" {:arity [0 3] :doc `(memory/summarize &opt start end text)
Summarizes accessible source events in an inclusive event-ID range. Omitted bounds select the available source range. Supplied text is the actual summary to store, not generation instructions; without text the summary model generates it. Returns {:summary summary-event-id}.
Examples: (memory/summarize 20 80); (memory/summarize 20 80 "Source A confirms X; source B disputes Y.").`}
   "memory/expand" {:arity [1 1] :doc `(memory/expand point-or-summary)
Accepts an event or summary event ID. Returns {:sources [...]} containing original accessible source records; read their :text and :data. Recursively expands summaries without generating or paraphrasing source text.
Example: (memory/expand 140).`}
   "memory/invalidate" {:arity [1 1] :doc `(memory/invalidate point-or-summary)
Accepts a summary event ID or a source event covered by a summary. Invalidates its associated summary and dependent summaries, without deleting source records. Returns {:summary summary-event-id :event invalidation-event-id}.
Example: (memory/invalidate 140).`}
   "fs/list" {:arity [2 2] :resource :fs :permission :read :doc "(fs/list resource relative-path) lists a granted directory. Both arguments are strings. Paths are grant-relative; \".\" selects the grant root. Absolute paths and traversal are rejected."}
   "fs/read" {:arity [2 2] :resource :fs :permission :read :doc "(fs/read resource relative-path) reads a granted UTF-8 file. Both arguments are strings. Paths are grant-relative; \".\" selects the grant root. Absolute paths and traversal are rejected."}
   "fs/write" {:arity [3 3] :resource :fs :permission :write :doc "(fs/write resource relative-path text) writes UTF-8 text to a granted file. All arguments are strings. Paths are grant-relative; \".\" selects the grant root. Absolute paths and traversal are rejected."}
   "http/request" {:arity [4 4] :resource :http :doc "(http/request resource method segments body) requests a granted endpoint."}
   "process/run" {:arity [1 1] :resource :processes :doc "(process/run resource) executes granted argv/env."}})

(defn- ready? [s execution]
  (def state (store/progress s (execution :id)))
  (def wait (get-in state [:data :wait]))
  (cond
    (nil? wait) true
    (wait :tasks) (every? (map |(store/outcome s $) (wait :tasks)))
    (wait :changes) (store/turn s (execution :id))
    (error "unsupported stored wait condition")))

(defn- infer [s inquiry available]
  (def config (s :config))
  (def scope-id (inquiry :id))
  (def admission (store/turn s scope-id))
  (def pending (when admission (store/result s (admission :id))))
  (if pending
    (store/transact s
      (store/check s (inquiry :id))
      (def response (pending :data))
      (var admitted false)
      (each tool (get response :tools [])
        (def receipt (try
          (do
            (when (tool :error) (error (tool :error)))
            (def child (store/start s (merge (schema/project tool [:code])
              {:request (string "tool:" (pending :id) ":" (tool :id)) :call (tool :id)}) config (pending :id)))
            (set admitted true) {:script (child :id) :status "accepted"})
          ([err fiber] {:status "rejected" :error (schema/diagnostic "AdmissionRejected" err fiber)})))
        (store/append s (pending :id) "receipt"
          {:tool (tool :id) :error (receipt :error)
           :message {:role "tool" :tool_call_id (tool :id) :content (schema/encode receipt)}}
          (string "receipt:" (pending :id) ":" (tool :id))))
      (store/append s (pending :id) "turn" {} (string "turn:" (pending :id)))
      (case (response :status)
        "continue" (store/advance s {})
        "tools" (unless admitted (store/advance s {}))
        nil))
    (label turn (do
      (when-let [unknown admission]
        (if (first (store/query s "SELECT id FROM events WHERE parent=? AND kind='dispatch'" [(unknown :id)]))
          (return turn (store/append s (unknown :id) "result"
            {:type "model" :state "done" :role "chat" :turn true :status "continue" :tools [] :text ""
             :message {:role "assistant" :content "[Inference was interrupted before its response was committed. No tool calls from that response were admitted. Continue from committed execution evidence.]"}}
            (string "result:" (unknown :id))))
          (return turn (model/complete s unknown))))
      (def rounds (((store/query s "SELECT count(*) n FROM events WHERE parent=? AND kind='model' AND json_extract(data,'$.turn')=1" [(inquiry :id)]) 0) :n))
      (assert (< rounds (config :rounds)) "model round limit exhausted")
      (def selected (model/profile s (config :chat) :chat))
      (def tools (filter |(or (config :janet) (not= "function" ($ :type))) (selected :tools)))
      (def system {:role "system" :content (vm/instructions config available)})
      (def budget @[(config :image-bytes)])
      (def input {:role "user" :content (model/images (get-in inquiry [:data :input])
        (string "Author: " (get-in inquiry [:data :author]) " · Occurred: " (get-in inquiry [:data :at]) "\n\n" (get-in inquiry [:data :input :text])) budget)})
      (def state {:role "user" :content (string "## World source\n\n" ((store/view s (get-in inquiry [:data :world])) :text))})
      (def window (min (get config :context-quota math/inf) (selected :context)))
      (def capacity (math/floor (/ (* window (config :context-percent)) 100)))
      (def scope (store/transact s
        (store/advance s {:wait {:changes true}})
        (store/tree s scope-id)))
      (def changes (tabseq [row :in (store/changes s scope-id 0)
        :unless (= "summary" (row :task-type))] (row :id) true))
      (def replay (seq [row :in scope :let [data (row :data)
        message (cond
          (and (index-of (row :kind) ["result" "receipt"])
            (= (inquiry :id) (row :task))
            (or (= "receipt" (row :kind)) (and (= "model" (data :type)) (data :turn))))
          (or (data :message) (when (data :error) {:role "user" :content (memory/render s row)}))
          (changes (row :id)) {:role "user" :content (string "Committed execution event:\n"
            (memory/render s row) (row :operation))})]
        :when message] [row message]))
      (sort-by |(let [row ($ 0)] [(if (= "receipt" (row :kind)) (row :parent) (row :id)) (row :id)]) replay)
      (def previous (last (filter |(and (= "model" ($ :kind)) (= (inquiry :id) ($ :parent)) (get-in $ [:data :turn])) scope)))
      (var closed (get-in previous [:data :views :closed] 0))
      (when (>= (+ (model/estimate (array/concat @[system input state] (map |($ 1) (filter |(> (($ 0) :id) closed) replay))) (selected :reference))
        (store/estimate (schema/encode tools)) 768) capacity)
        (def pending (filter |(and (not= (inquiry :id) ($ :id)) (not= "summary" (get-in $ [:data :type]))
          (not (store/outcome s ($ :id)))) (store/pending s scope-id)))
        (each row scope
          (when (and (= "model" (row :kind)) (= (inquiry :id) (row :parent)) (get-in row [:data :turn])
            (not (find |(< ($ :id) (row :id)) pending))) (set closed (row :id))))
        (unless (store/busy? s scope-id) (set closed ((last scope) :id))))
      (def exchanges (map |($ 1) (filter |(> (($ 0) :id) closed) replay)))
      (def room (- capacity (model/estimate (array/concat @[system input state] exchanges) (selected :reference))
        (store/estimate (schema/encode tools)) 512))
      (assert (> room 256)
        {:code "InquiryContextExhausted" :message "Instructions, inquiry, world and live exchanges leave insufficient context."
         :context {:model (selected :reference) :capacity capacity :remaining room}})
      (def context (memory/context s inquiry room (map |($ 0) (filter |(<= (($ 0) :id) closed) replay))))
      (def messages @[system])
      (def views @{:closed closed
        :records (distinct (catseq [row :in (context :nodes)] (if (row :segments) (map |($ 0) (row :segments)) [(row :id)])))
        :eligible (context :eligible) :retrieved (map |($ :id) (context :evidence))
        :candidates (context :candidates) :cutoff (config :score)})
      (each [key title rows] [[:chronological "Chronological memory" (context :nodes)] [:semantic "Retrieved excerpts" (context :evidence)]]
        (when (> (length rows) 0)
          (put views key (length messages))
          (def images @[])
          (each row rows (each source (if (row :segments) (map |(store/event s $) (distinct (map |($ 0) (row :segments)))) [row])
            (array/concat images (get-in source [:data :input :images] []))))
          (array/push messages {:role "user" :content (model/images {:images images} (string "## " title "\n\n" (string/join (map |(memory/render s $) rows))) budget)})))
      (put views :world (length messages)) (array/push messages state)
      (put views :inquiry (length messages)) (array/push messages input)
      (put views :after (if (> (length scope) 0) ((last scope) :id) (inquiry :id)))
      (array/concat messages exchanges)
      (assert (< (+ (model/estimate messages (selected :reference)) (store/estimate (schema/encode tools))) capacity) "inquiry exchanges exhaust context")
      (model/call s {:turn true :messages messages :tools tools :views views} (string "turn:" rounds) selected)))))

(defn- invoke [s effect available]
  (def name (get-in effect [:data :name]))
  (def args (get-in effect [:data :arguments]))
  (def binding (available name))
  (assert (and binding (not (binding :local)))
    {:code "BindingNotGranted" :message (string "Host binding is not granted: " name)})
  (when-let [[minimum maximum] (binding :arity)]
    (assert (<= minimum (length args) maximum)
      {:code "InvalidHostArguments"
       :message (string name " expects " (if (= minimum maximum) minimum (string minimum ".." maximum))
         " arguments; received " (length args) ".")
       :context {:effect (effect :id) :binding name :expected [minimum maximum]
         :received (length args) :signature (binding :doc)}}))
  (def local? (or (= name "self") (string/has-prefix? "world/" name)
    (string/has-prefix? "self/" name) (string/has-prefix? "memory/" name)))
  (defn execute []
    (store/check s (effect :id))
    (def script (store/task s (effect :id)))
    (def world (get-in effect [:data :world]))
    (case (if (= name "self/queue") "self" name)
      "world/view" (apply store/view s world args)
      "memory/summarize" (apply memory/summarize s script args)
      "memory/expand" (apply memory/expand s script args)
      "memory/invalidate" (apply memory/invalidate s script args)
      "self/append"
      (let [ids (store/record s (first args))]
        (each id ids (store/append s (script :id) "notice" {:source id}))
        {:events ids})
      "self"
      (let [_ (assert (and (dictionary? (first args))
                (not= (nil? (get (first args) :text)) (nil? (get (first args) :code))))
                "supply an object with exactly one of :text or :code; e.g. {:text \"Investigate source A.\"}")
            input (merge (schema/request (first args) [:text :code :parent :memory_range :world])
              {:request (effect :key) :queued (= name "self/queue")
               :lane (when (= name "self/queue") (string "script:" (script :id)))})
            config (if (input :text) (get (s :config) :agent (s :config)) (s :config))
            child (store/start s input config (effect :id))]
        (store/handle s child))
      (if (index-of name ["self/status" "self/wait" "self/cancel"])
        (let [handle (first args) id (if (dictionary? handle) (handle :script) handle)]
          (when (dictionary? handle) (assert (= (handle :store) (s :identity)) "execution belongs to another store"))
          (assert (= "task" ((store/event s id) :kind)) "choose a script or inquiry")
          (assert (= ((store/root s id) :id) ((store/root s (effect :id)) :id)) "execution is outside this inquiry")
          (when (and (not= name "self/status") (not (and (= name "self/wait") (store/outcome s id))))
            (assert (and (not= id (script :id)) (find |(= id ($ :id)) (store/tree s (script :id)))) "choose a descendant"))
          (case name
            "self/cancel" (store/abort s (get-in (store/event s id) [:data :request]) "cancelled by caller")
            "self/status" (merge (get (store/outcome s id) :data {:state "pending"}) {:script id})
            (or (get (store/outcome s id) :data)
              (error {:code "Yield" :message "Waiting for a descendant." :context {:wait {:tasks [id]}}}))))
        (cond
          (binding :import)
          (let [reply (ev/thread-chan 1)]
            (defer (ev/chan-close reply)
              (ev/give (s :connection) {:method name :params (first args) :reply reply})
              (def outcome (ev/take reply))
              (when (outcome :error) (error (outcome :error)))
              (outcome :value)))
          (index-of name ["fs/list" "fs/read" "fs/write" "http/request" "process/run"])
          (effects/invoke (s :config) name args)
          (apply (binding :value) args)))))
  (if local?
    (try (store/finish s (effect :id) "done" (execute))
      ([err fiber]
        (when (index-of (get err :code) ["Yield" "TaskClosed" "TaskReplaced" "DeadlineExceeded"]) (error err))
        (store/finish s (effect :id) "failed" nil (schema/diagnostic "OperationFailed" err fiber))))
    (let [prior (first (store/query s "SELECT * FROM events WHERE parent=? AND kind='attempt' ORDER BY id DESC LIMIT 1" [(effect :id)]))]
      (if (and prior (first (store/query s "SELECT id FROM events WHERE parent=? AND kind='dispatch'" [(prior :id)])))
        (store/finish s (effect :id) "failed" nil
          {:code "EffectOutcomeUnknown" :message "The effect was dispatched without a committed response; it may have completed."
           :context {:outcome "unknown" :effect (effect :id) :attempt (prior :id) :name name :arguments args}})
        (let [attempt (or prior (store/append s (effect :id) "attempt" {} (string "attempt:" (effect :id))))]
          (store/append s (attempt :id) "dispatch" {})
          (try (store/finish s (effect :id) "done" (execute))
            ([err fiber]
              (when (index-of (get err :code) ["TaskClosed" "TaskReplaced" "DeadlineExceeded"]) (error err))
              (def failure (schema/diagnostic "OperationFailed" err fiber))
              (store/finish s (effect :id) "failed" nil
                (merge failure {:context (merge (get failure :context {})
                  {:outcome (get-in failure [:context :outcome] "unknown")
                   :effect (effect :id) :attempt (attempt :id) :name name :arguments args})})))))))))

(defn- execute [[config profiles execution file signals connection]]
  (def s (store/open config nil file))
  (defer (store/close s)
    (put s :signals signals)
    (put s :connection connection)
    (with-dyns [:zinc/task execution :zinc/call s]
      (def owner (fiber/root)) (def finished (ev/chan 1))
      (def checker (ev/go (fn []
        (try (while true (store/check s (execution :id)) (ev/sleep store/interval))
          ([err] (unless (= err :finished) (ev/cancel owner err))))) nil finished))
      (defer (do
        (when (fiber/can-resume? checker) (ev/cancel checker :finished))
        (ev/take finished) (ev/chan-close finished))
        (try
          (do
            (store/check s (execution :id))
            (def saved (store/restore s (execution :image)))
            (when (saved :deployment) (assert (= (saved :deployment) (config :deployment)) "deployment authority changed"))
            (def current (profiles (keyword (saved :profile))))
            (assert current "execution profile revoked")
            (def granted (if (saved :agent)
              (merge current {:agent (profiles (keyword (get-in saved [:agent :profile])))}) current))
            (put s :config (schema/authorize granted saved))
            (def available (unless (= "summary" (get-in execution [:data :type])) (vm/definitions (s :config) bindings)))
            (if (= "operation" (execution :kind)) (invoke s execution available)
              (case (get-in execution [:data :type])
                "inquiry" (infer s execution available)
                "summary" (store/finish s (execution :id) "done" (memory/complete-summary s execution))
                "script"
                (if (get-in (store/progress s (execution :id)) [:data :started])
                  (store/finish s (execution :id) "failed" (get-in (store/outcome s (execution :id)) [:data :value])
                    {:code "ContinuationLost" :message "The VM was interrupted; committed effects may have completed. Locals and waits were not retained."
                     :context {:outcome "unknown" :script (execution :id) :progress (get (store/progress s (execution :id)) :data)}})
                  (do
                    (store/advance s {:started true :form 0})
                    (def outcome (vm/run s execution available))
                    (store/finish s (execution :id) (outcome :state) (outcome :value) (outcome :error))))
                (error "unsupported execution type"))))
          ([err fiber]
            (unless (store/result s (execution :id))
              (cond
                (= "Yield" (get err :code)) (store/advance s {:wait (get-in err [:context :wait])})
                (and (= "inquiry" (get-in execution [:data :type]))
                  (get-in (store/result s (get (store/turn s (execution :id)) :id)) [:data :error])) nil
                (and (= "inquiry" (get-in execution [:data :type])) (= "unknown" (get-in err [:context :outcome]))) (store/advance s {})
                (not (index-of (get err :code) ["TaskClosed" "TaskReplaced"]))
                (store/finish s (execution :id) "failed" nil (schema/diagnostic "ExecutionFailed" err fiber))))))))))

(defn- presentation [s row owner root]
  (when (and owner (not= "summary" (get-in owner [:data :type]))
    (not (and (= "result" (row :kind)) (= "task" (row :parent-kind)) (nil? (row :publication)))))
    (def data (row :data))
    (def source (when (and (= "task" (row :kind)) (= "script" (data :type))) (get-in data [:input :code])))
    (def effect (and (= "result" (row :kind)) (= "operation" (row :parent-kind))))
    (def terminal (and (= "result" (row :kind)) (= (owner :id) (row :parent))))
    (def body (cond
      (and (= "result" (row :kind)) (= "model" (data :type)) (= "chat" (data :role)) (not (data :error))) (model/render data)
      source source
      (data :error) (schema/encode {:error (data :error)})
      effect (data :text)
      (or terminal (index-of (row :kind) ["return" "fiber"]))
      (when (and (not= "inquiry" (get-in owner [:data :type])) (not= :null (data :value))) (data :text))
      (index-of (row :kind) ["output" "artifact"]) (data :text)))
    (when (and body (not= "" (string/trim body)))
      (def inquiry (row :inquiry))
      (def model (when inquiry (first (store/query s `WITH RECURSIVE ancestors AS (
        SELECT * FROM events WHERE id=? UNION ALL SELECT e.* FROM events e JOIN ancestors a ON e.id=a.parent
      ) SELECT * FROM ancestors WHERE kind='model' AND parent=? AND json_extract(data,'$.turn')=1 ORDER BY id DESC LIMIT 1`
        [(row :id) inquiry]))))
      (def round (when model (((store/query s "SELECT count(*) n FROM events WHERE parent=? AND kind='model' AND json_extract(data,'$.turn')=1 AND id<=?"
        [inquiry (model :id)]) 0) :n)))
      {:root (root :id) :store (s :identity)
       :agent (get-in s [:config :handle]) :request (get-in root [:data :request])
       :inquiry (or inquiry :null) :loop (or round :null)
       :reply (or (cond source (when (owner :parent)
           (def parent (store/event s (owner :parent)))
           (if (= "model" (get-in parent [:data :type])) (parent :id) (get (store/task s (parent :id)) :id)))
         (= "script" (get-in owner [:data :type])) (owner :id)
         (owner :parent) (get (store/task s (owner :parent)) :id)) :null)
       :status (if source "accepted" (get data :status (get data :state "done")))
       :language (cond (data :error) "json" source "clojure"
         (and (or effect terminal (index-of (row :kind) ["return" "fiber"])) (not (string? (data :value)))) "json"
         (or effect terminal (index-of (row :kind) ["return" "output" "fiber" "artifact"])) "text" :null)
       :persist (not (s :temporary)) :sequence (row :id)
       :body body :diagnostic (data :error)})))

(defn run [s publications]
  (def active @{}) (def finished (ev/chan 1))
  (def wake (ev/thread-chan 1)) (def ticked (ev/chan 1))
  (put s :signals [wake])
  (def ticker (ev/go (fn [] (while true (ev/sleep store/interval) (unless (ev/full wake) (ev/give wake true)))) nil ticked))
  (defer (do
    (ev/cancel ticker :finished) (ev/take ticked)
    (each channel [ticked finished wake] (ev/chan-close channel)))
  (while true
      (def pending (store/pending s))
      (each execution pending
        (def id (execution :id))
        (when-let [deadline (get-in execution [:data :expires])]
          (when (and (<= deadline (os/clock)) (not (store/result s id)))
            (store/finish s id "failed" nil {:code "DeadlineExceeded" :message "Execution deadline expired."})))
        (def kind (if (= "operation" (execution :kind)) "effect" (get-in execution [:data :type])))
        (def profile (keyword ((store/restore s (execution :image)) :profile)))
        (def category [profile kind])
        (def current ((s :profiles) profile))
        (def lane (get-in execution [:data :input :lane]))
        (def queued (get-in execution [:data :input :queued]))
        (when (and (not (active id)) (not (store/result s id)) (ready? s execution)
          (or (= kind "script") (nil? current) (< (length (filter |(= category $) (values active))) (current :parallel)))
          (or (not queued) (not (find |(and (< ($ :id) id)
            (= "task" ($ :kind)) (= lane (get-in $ [:data :input :lane]))
            (not (store/outcome s ($ :id)))) pending))))
          (store/query s "INSERT OR IGNORE INTO claims(task) VALUES(?)" [id])
          (put active id category)
          (ev/go (fiber/new (fn [arguments]
            (def done (ev/thread-chan 1))
            (defer (ev/chan-close done)
              (with-env @{} (ev/thread execute arguments (keyword "") done))
              (def packet (ev/take done))
              (assert (= :ok (packet 0)) (packet 1)))) :t @{:task-id id})
            [(s :config) (s :profiles) execution (s :file) (s :signals) (s :connection)] finished)))
      (def rows (store/tree s nil (get s :cursor (get s :floor 0))))
      (def owners (store/owners s rows))
      (each row rows
        (def root (store/root s (row :id)))
        (when-let [frame (presentation s row (owners (row :task)) root)]
          (ev/give publications {:frame frame :origin (get-in root [:data :input :connector])}))
        (put s :cursor (row :id)))
      (when (and (= 0 (length active)) (= 0 (length (store/pending s))))
        (put s :running nil) (put s :signals []) (break))
      (def [_ channel packet] (ev/select finished wake))
      (when (= channel finished)
        (def [status fiber id] packet)
        (put active id nil)
        (assert (= :ok status) (schema/diagnostic "ExecutorFailed" (fiber/last-value fiber) fiber))))))

(defn start [s publications]
  (unless (s :running)
    (put s :running true)
    (ev/go (fn [] (try (run s publications)
      ([err fiber] (eprint (schema/encode (schema/diagnostic "ExecutorFailed" err fiber))) (os/exit 1 true)))))))
