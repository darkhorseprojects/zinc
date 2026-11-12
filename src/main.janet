(import pa)
(import spork/path :as path)
(import ./schema)
(import ./store)
(import ./vm)
(import ./engine)
(import ./model)
(import ./memory)

(defn main []
  (unless (index-of (os/which) [:windows :mingw])
    (os/umask 8r077)
    (os/sigaction :pipe (fn [])))
  (def limit (scan-number (os/getenv "PA_FRAME_BYTES")))
  (assert (and (int? limit) (<= 1 limit 0x7fffffff)) "PA_FRAME_BYTES is required")
  (def handle (os/getenv "PA_HANDLE"))
  (assert (and handle (> (length handle) 0)) "PA_HANDLE is required")
  (def incoming (ev/thread-chan 1)) (def outgoing (ev/thread-chan 32))
  (def connection (ev/thread-chan 32)) (def publications (ev/chan 32))
  (def finished (ev/chan 32))
  (def stores @{}) (def calls @{}) (def pending @{}) (def latest @{}) (var sequence 0)
  (ev/thread (fn [[incoming limit]]
    (try
      (do (def pending @"") (var call nil)
        (while (set call (pa/read stdin pending limit)) (ev/give incoming call))
        (os/exit 0 true))
      ([err fiber] (eprint (schema/encode (schema/diagnostic "ProtocolError" err fiber))) (os/exit 1 true)))) [incoming limit] :n)
  (ev/thread (fn [[outgoing limit]]
    (try
      (do (var message nil)
        (while (set message (ev/take outgoing))
          (try (pa/write stdout message limit)
            ([err fiber]
              (if (= "result" (message :type))
                (pa/write stdout {:type "error" :id (message :id) :error (schema/diagnostic "ResponseRejected" err fiber)} limit)
                (error err))))))
      ([err fiber] (eprint (schema/encode (schema/diagnostic "ProtocolError" err fiber))) (os/exit 1 true)))) [outgoing limit] :n)
  (ev/give outgoing {:type "ready" :handle handle})
  (try
    (while true
      (def [_ channel packet] (ev/select incoming finished connection publications))
      (when (= channel publications) (ev/give outgoing {:type "event" :value packet}))
      (when (= channel connection)
        (def id (string (++ sequence)))
        (put pending id (packet :reply))
        (ev/give outgoing {:type "call" :id id :caller handle :method (packet :method) :params (packet :params)}))
      (when (and (= channel incoming) (index-of (packet :type) ["result" "error"]))
        (def reply (pending (packet :id)))
        (assert reply "unexpected response identity")
        (put pending (packet :id) nil)
        (try (ev/give reply (schema/project packet [:value :error])) ([err] nil)))
      (when (= channel finished)
        (def [status fiber id] packet)
        (when id (put calls id nil))
        (unless (= :ok status) (error (schema/diagnostic "HostFailed" (fiber/last-value fiber) fiber))))
      (when (and (= channel incoming) (not (index-of (packet :type) ["result" "error"])))
        (assert (= "call" (packet :type)) "unexpected protocol message")
        (assert (not (calls (packet :id))) "duplicate outstanding call identity")
        (put calls (packet :id) (ev/go (fiber/new (fn [call]
          (try
            (do
              (assert (string/has-prefix? "owner/" (call :method)) "owner binding required")
              (def method (string/slice (call :method) 6))
              (assert (index-of method ["describe" "instructions" "models" "init" "resume" "append" "self" "queue"
                "work" "status" "wait" "cancel" "authorize" "world" "views" "render" "memory/expand"
                "memory/invalidate" "memory/summarize" "resolve" "diagnostics"]) "unknown owner binding")
              (def params (call :params))
              (assert (dictionary? params) "owner arguments must be an object")
              (def input (schema/project params [:config :profiles] true))
              (def config (schema/configuration (params :config) (= method "describe")))
              (assert (= handle (config :handle)) "configuration changes author handle")
              (put config :imports (get call :imports {}))
              (when (config :agent) (put (config :agent) :imports (config :imports)))
              (assert (<= (length (schema/encode input)) (config :request-bytes)) "oversized input")
              (def value (case method
                "describe" (do (schema/request input []) (schema/describe config))
                "instructions" (do (schema/request input []) (vm/instructions config (vm/definitions config engine/bindings)))
                "models" (do (schema/request input [:role])
                  (map |{:ref ($ :ref) :name ($ :name)} (model/catalogue config (get input :role "chat"))))
                (do
                  (assert (dictionary? (params :profiles)) "current profiles are required")
                  (def profiles (tabseq [[name supplied] :pairs (params :profiles)] name
                    (do
                      (def profile (schema/configuration supplied))
                      (assert (= (string name) (profile :profile)) "profile name differs from its definition")
                      (each key [:store :directory :handle]
                        (assert (= (config key) (profile key)) "profile changes instance identity"))
                      (put profile :imports (config :imports))
                      profile)))
                  (assert (profiles (keyword (config :profile))) "selected profile is not configured")
                  (when (= method "init")
                    (schema/request input [])
                    (assert (= (config :directory) (os/realpath (config :directory))) "canonical instance directory required")
                    (def relative (path/relpath (config :directory) (config :store)))
                    (assert (and (not (path/abspath? relative)) (not= ".." (first (path/parts relative)))) "store must belong to instance")
                    (assert (not (os/lstat (config :store))) "init requires a fresh database")
                    (var directory (config :directory))
                    (each part (filter next (path/parts (path/dirname relative)))
                      (unless (= part ".")
                        (set directory (path/join directory part)) (os/mkdir directory)
                        (assert (= directory (os/realpath directory)) "state directories cannot contain links"))))
                  (def supplied (input :store))
                  (var s (when supplied (find |(= supplied ($ :identity)) (values stores))))
                  (when (and (nil? s) (input :request))
                    (set s (find |(first (store/query $ "SELECT id FROM events WHERE key=? AND id>?" [(string "task:" (input :request)) (get $ :floor 0)])) (values stores))))
                  (when (and supplied (nil? s) (= false (get input :persist true))) (error "temporary session is unavailable"))
                  (unless s
                    (if (= false (get input :persist true))
                      (do
                        (set s (when (input :session) (stores (input :session))))
                        (unless s (set s (store/temporary config)) (put stores (get input :session (s :identity)) s)))
                      (do
                        (unless (stores (config :store))
                          (unless (= method "init") (assert (os/stat (config :store)) "initialize the store first"))
                          (put stores (config :store) (store/open config)))
                        (set s (stores (config :store))))))
                  (when supplied (assert (= supplied (s :identity)) "execution store is unavailable"))
                  (put s :config config)
                  (put s :profiles profiles)
                  (put s :connection connection)
                  (store/configure s)
                  (case (cond (index-of method ["self" "queue"]) "invoke"
                    (index-of method ["status" "wait" "cancel" "authorize"]) "lookup" method)
                    "init" {:store (s :identity) :world (config :world)}
                    "resume" (do
                      (schema/request input [:after])
                      (def after (get (get input :after {}) (keyword (s :identity)) 0))
                      (assert (and (int? after) (>= after 0)) "invalid observation cursor")
                      (put s :cursor (max after (get s :cursor (get s :floor 0))))
                      (engine/start s publications) {:store (s :identity)})
                    "append" (do
                      (schema/request input [:records :persist :store :session])
                      (def records (filter (fn [record]
                        (not (find |(first (store/query $ "SELECT id FROM events WHERE key=?" [(string "task:" (record :key))])) (values stores)))) (input :records)))
                      {:events (store/record s records) :store (s :identity)})
                    "invoke"
                    (do
                      (schema/request input (keys schema/inputs))
                      (each profile (filter identity [config (config :agent)]) (vm/definitions profile engine/bindings))
                      (def lane (get input :lane (schema/encode [(call :caller) (config :world)])))
                      (def request (merge input {:author (call :caller)
                        :at (get input :at (os/strftime "%Y-%m-%dT%H:%M:%SZ")) :lane lane :queued (= method "queue")}))
                      (def previous (first (store/query s "SELECT * FROM events WHERE key=? AND id>?" [(string "task:" (input :request)) (get s :floor 0)])))
                      (unless previous
                        (assert (< (sum (map |(length (store/work $)) (values stores))) (config :pending-requests)) "queue capacity exceeded")
                        (def message (get-in input [:connector :context :message]))
                        (def newest (or (latest lane)
                          (first (store/query s `SELECT json_extract(data,'$.input.connector.context.message') message FROM events
                            WHERE kind='task' AND json_extract(data,'$.input.lane')=? AND json_extract(data,'$.input.replace')=1
                            ORDER BY length(json_extract(data,'$.input.connector.context.message')) DESC,
                            json_extract(data,'$.input.connector.context.message') DESC LIMIT 1` [lane]))))
                        (when (and (input :replace) message)
                          (when (get newest :message)
                            (assert (>= [(length message) message] [(length (newest :message)) (newest :message)]) "a newer inquiry already replaced this message"))
                          (put latest lane {:message message})
                          (each owner (values stores)
                            (each old (store/work owner lane)
                              (when (and (= "inquiry" (get-in old [:data :type]))
                                (or (get-in old [:data :input :replace]) (store/progress owner (old :id))))
                                (store/abort owner (get-in old [:data :request]) "replaced by newer inquiry")))))
                        (when (and (input :code) (not (config :inference)) (not (s :temporary)))
                          (when-let [target (find |(and (= "inquiry" (get-in $ [:data :type])) (store/progress s ($ :id))) (store/work s lane))]
                            (put request :notify (target :id)))))
                      (assert (= (not (s :temporary)) (not= false (get input :persist true))) "request persistence differs from its store")
                      (when previous (put request :notify (get-in previous [:data :input :notify])))
                      (def task (store/start s request config))
                      (engine/start s publications)
                      (store/handle s task))
                    "work" (do (schema/request input [:lane])
                      (seq [owner :in (values stores) task :in (store/work owner (input :lane))]
                        (merge (store/handle owner task) {:state (if (store/progress owner (task :id)) "active" "queued")
                          :replace (get-in task [:data :input :replace]) :code (= "script" (get-in task [:data :type]))})))
                    "lookup"
                    (do
                      (schema/request input (array/concat @[:request :store :script :persist]
                        (case method "cancel" [:reason] "authorize" [:inspect] [])))
                      (when (has-key? input :persist)
                        (assert (= (not (s :temporary)) (input :persist)) "work persistence differs from its store"))
                      (def id (or (input :script)
                        (get (first (store/query s "SELECT id FROM events WHERE key=?" [(string "task:" (input :request))])) :id)))
                      (assert (and id (> id (get s :floor 0))) "execution unavailable in this session")
                      (def task (store/event s id))
                      (assert (= "task" (task :kind)) "choose a script or inquiry")
                      (def root (store/root s id))
                      (case method
                        "authorize"
                        (if (input :inspect)
                          {:author (get-in root [:data :author])}
                          (do
                            (def origin (get-in root [:data :input :connector]))
                            (assert (not (= "cancelled" (get-in (store/result s (root :id)) [:data :state]))) "request authority revoked")
                            (assert (and origin (or (nil? (origin :expires)) (= :null (origin :expires)) (> (origin :expires) (* 1000 (os/clock))))) "request authority expired")
                            (merge origin (store/handle s root))))
                        "cancel" (store/abort s (get-in task [:data :request]) (get input :reason "cancelled by caller"))
                        (do
                          (when (= method "wait")
                            (while (not (store/outcome s id)) (ev/sleep store/interval)))
                          (merge (store/handle s task) (get (store/outcome s id) :data {:state "pending"})))))
                    "world"
                    (let [name (get input :world (config :world))]
                      (schema/request input [:action :point :world])
                      (assert (has-key? (config :worlds) (keyword name)) "world is not granted")
                      (case (get input :action "view")
                        "view" (store/view s name (input :point))
                        "rewind" (do (assert (and (not (config :inference)) (config :janet)) "rewind requires direct execution")
                          (store/rewind s name (input :point)))
                        (error "unknown world action")))
                    "views" (do (schema/request input [:event :mode]) (memory/report s (input :event) (get input :mode "memory")))
                    "render" (do (schema/request input [:event]) (memory/report s (input :event) "render"))
                    "memory/expand" (do (schema/request input [:point :persist :store :session]) (memory/expand s nil (input :point)))
                    "memory/invalidate" (do (schema/request input [:point :persist :store :session]) (memory/invalidate s nil (input :point)))
                    "memory/summarize"
                    (do
                      (schema/request input [:start :end :text :persist :store :session])
                      (var summary nil)
                      (while (not summary)
                        (set summary (try (memory/summarize s nil (input :start) (input :end) (input :text))
                          ([err] (if (= "Yield" (get err :code)) (do (engine/start s publications) (ev/sleep store/interval) nil) (error err))))))
                      summary)
                    "resolve" (do (schema/request input [:event :outcome]) (assert (and (not (config :inference)) (config :janet)) "resolution requires direct execution")
                      {:event ((store/resolve s (store/event s (input :event)) (input :outcome)) :id)})
                    "diagnostics"
                    (let [task (first (store/query s "SELECT id FROM events WHERE key=?" [(string "task:" (input :request))]))]
                      (schema/request input [:request])
                      (seq [row :in (if task (store/tree s (task :id)) []) :when (get-in row [:data :error])]
                        {:source "zinc" :id (row :id) :kind (row :kind)
                         :created_at (os/strftime "%Y-%m-%dT%H:%M:%SZ" (math/floor (row :created))) :data (get-in row [:data :error])}))
                    (error (string "unknown method " method))))))
              (ev/give outgoing {:type "result" :id (call :id) :value (if (nil? value) :null value)}))
            ([err fiber]
              (unless (= err :host-exited)
                (ev/give outgoing {:type "error" :id (call :id) :error (schema/diagnostic "ProgramError" err fiber)})))))
          :t @{:task-id (packet :id)}) packet finished))))
    ([err fiber] (eprint (schema/encode (schema/diagnostic "HostFailed" err fiber))) (os/exit 1 true))))
