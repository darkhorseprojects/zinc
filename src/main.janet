(import pa)
(import spork/path :as path)
(import ./schema)
(import ./store)
(import ./janet)
(import ./engine)
(import ./model)
(import ./memory)

(defn main [executable & args]
  (assert (= 0 (length args)) "Zinc accepts a live Portable Agents connection on stdin")
  (unless (index-of (os/which) [:windows :mingw]) (os/sigaction :pipe (fn [])))
  (def limit (scan-number (os/getenv "PA_FRAME_BYTES")))
  (assert (and (int? limit) (<= 1 limit 0x7fffffff)) "PA_FRAME_BYTES is required")
  (def incoming (ev/thread-chan 1)) (def outgoing (ev/thread-chan 32))
  (def finished (ev/chan 32))
  (def stores @{}) (def calls @{}) (def latest @{}) (var configuration nil)
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
                (pa/write stdout {:version 1 :type "error" :id (message :id) :error (schema/diagnostic "ResponseRejected" err fiber)} limit)
                (error err))))))
      ([err fiber] (eprint (schema/encode (schema/diagnostic "ProtocolError" err fiber))) (os/exit 1 true)))) [outgoing limit] :n)
  (ev/give outgoing {:version 1 :type "ready"})
  (try
    (while true
      (def [_ channel packet] (ev/select incoming finished))
      (when (= channel finished)
        (def [status fiber id] packet)
        (when id (put calls id nil))
        (unless (= :ok status) (error (schema/diagnostic "HostFailed" (fiber/last-value fiber) fiber))))
      (when (= channel incoming)
        (unless (= "call" (get packet :type)) (error packet))
        (assert (not (calls (packet :id))) "duplicate outstanding call identity")
        (put calls (packet :id) (ev/go (fiber/new (fn [call]
          (try
            (do
              (def method (call :method))
              (def params (schema/request (call :params) [:input :config :imports]))
              (def input (get params :input {}))
              (def owner (find |(= ($ :identity) (or (input :store) (when (input :operation) (first (string/split "/" (input :operation)))))) (values stores)))
              (def supplied-config (or (params :config) (get owner :config) configuration {}))
              (def config (schema/configuration (merge supplied-config {:imports (get params :imports (get supplied-config :imports {}))}) (= method "describe")))
              (when (config :agent) (put (config :agent) :imports (config :imports)))
              (unless (= method "describe") (set configuration config))
              (assert (and (dictionary? input) (<= (length (schema/encode input)) (config :request-bytes))) "invalid or oversized input")
              (when-let [fields (get {"init" [] "resume" [:after] "instructions" [] "models" [:role] "work" [:lane]
                "status" [:request :store :script :persist] "wait" [:request :store :script :persist]
                "cancel" [:request :store :script :persist :reason] "authorize" [:request :store :script :persist :operation :inspect]
                "world" [:action :point :world] "views" [:event :mode] "render" [:event]
                "memory/summarize" [:start :end :text :persist :store :session]
                "memory/expand" [:point :persist :store :session] "memory/invalidate" [:point :persist :store :session]
                "resolve" [:event :outcome] "diagnostics" [:request]} method)] (schema/request input fields))
              (def value (case method
                "describe" (engine/describe config)
                "instructions" (janet/instructions config (janet/definitions config engine/bindings))
                "models" (map |{:ref ($ :ref) :name ($ :name)} (model/catalogue config (get input :role "chat")))
                (do
                  (when (= method "init")
                    (assert (= (config :identity) (os/realpath (config :identity))) "canonical instance directory required")
                    (def relative (path/relpath (config :identity) (config :store)))
                    (assert (and (not (path/abspath? relative)) (not= ".." (first (path/parts relative)))) "store must belong to instance")
                    (assert (not (os/lstat (config :store))) "init requires a fresh database")
                    (var directory (config :identity))
                    (each part (filter next (path/parts (path/dirname relative)))
                      (unless (= part ".")
                        (set directory (path/join directory part)) (os/mkdir directory)
                        (assert (= directory (os/realpath directory)) "state directories cannot contain links"))))
                  (def supplied (or (input :store) (when (input :operation)
                    (first (string/split "/" (input :operation))))))
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
                  (store/configure s)
                  (case (cond (index-of method ["self" "queue"]) "invoke"
                    (index-of method ["status" "wait" "cancel" "authorize"]) "lookup" method)
                    "init" {:store (s :identity) :world (config :world)}
                    "resume" (do
                      (def after (get (get input :after {}) (keyword (s :identity)) 0))
                      (assert (and (int? after) (>= after 0)) "invalid observation cursor")
                      (put s :cursor (max after (get s :cursor (get s :floor 0))))
                      (engine/start s outgoing) {:store (s :identity)})
                    "append" (do
                      (schema/request input [:records :persist :store :session])
                      (def records (filter (fn [record]
                        (not (find |(first (store/query $ "SELECT id FROM events WHERE key=?" [(string "task:" (record :key))])) (values stores)))) (input :records)))
                      {:events (store/record s records) :store (s :identity)})
                    "invoke"
                    (do
                      (schema/request input (keys schema/inputs))
                      (assert (and (input :author) (input :at)) "authenticated author and occurrence time required")
                      (each profile (filter identity [config (config :agent)]) (janet/definitions profile engine/bindings))
                      (def lane (get input :lane (schema/encode [(input :author) (config :world)])))
                      (def request (merge input {:lane lane :queued (= method "queue")}))
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
                        (when (and (input :code) (not (s :temporary)))
                          (when-let [target (find |(and (= "inquiry" (get-in $ [:data :type])) (store/progress s ($ :id))) (store/work s lane))]
                            (put request :notify (target :id)))))
                      (assert (= (not (s :temporary)) (not= false (get input :persist true))) "request persistence differs from its store")
                      (when previous (put request :notify (get-in previous [:data :input :notify])))
                      (def task (store/start s request config))
                      (engine/start s outgoing)
                      (store/handle s task))
                    "work" (seq [owner :in (values stores) task :in (store/work owner (input :lane))]
                      (merge (store/handle owner task) {:state (if (store/progress owner (task :id)) "active" "queued")
                        :replace (get-in task [:data :input :replace]) :code (= "script" (get-in task [:data :type]))}))
                    "lookup"
                    (do
                      (def id (if (input :operation) (scan-number (last (string/split "/" (input :operation))))
                        (or (input :script) (get (first (store/query s "SELECT id FROM events WHERE key=?" [(string "task:" (input :request))])) :id))))
                      (assert (and id (> id (get s :floor 0))) "execution unavailable in this session")
                      (def task (store/event s id))
                      (def root (store/root s id))
                      (case method
                        "authorize"
                        (do
                          (when (input :operation) (store/check s id))
                          (unless (input :inspect)
                            (assert (not (= "cancelled" (get-in (store/result s (root :id)) [:data :state]))) "request authority revoked"))
                          (def origin (get-in root [:data :input :connector]))
                          (assert (and origin (or (nil? (origin :expires)) (= :null (origin :expires)) (> (origin :expires) (* 1000 (os/clock))))) "request authority expired")
                          (merge origin (store/handle s root) {:at (get-in root [:data :at])}))
                        "cancel" (store/abort s (get-in task [:data :request]) (get input :reason "cancelled by caller"))
                        (do
                          (when (= method "wait")
                            (while (not (store/outcome s id)) (ev/sleep store/interval)))
                          (merge (store/handle s task) (get (store/outcome s id) :data {:state "pending"})))))
                    "world"
                    (let [name (get input :world (config :world))]
                      (assert (has-key? (config :worlds) (keyword name)) "world is not granted")
                      (case (get input :action "view")
                        "view" (store/view s name (input :point))
                        "rewind" (do (assert (and (not (config :inference)) (config :janet)) "rewind requires direct execution")
                          (store/rewind s name (input :point)))
                        (error "unknown world action")))
                    "views" (memory/report s (input :event) (get input :mode "memory"))
                    "render" (memory/report s (input :event) "render")
                    "memory/expand" (memory/expand s nil (input :point))
                    "memory/invalidate" (memory/invalidate s nil (input :point))
                    "memory/summarize"
                    (do
                      (var summary nil)
                      (while (not summary)
                        (set summary (try (memory/summarize s nil (input :start) (input :end) (input :text))
                          ([err] (if (= "Yield" (get err :code)) (do (engine/start s outgoing) (ev/sleep store/interval) nil) (error err))))))
                      summary)
                    "resolve" (do (assert (and (not (config :inference)) (config :janet)) "resolution requires direct execution")
                      {:event ((store/resolve s (store/event s (input :event)) (input :outcome)) :id)})
                    "diagnostics"
                    (let [task (first (store/query s "SELECT id FROM events WHERE key=?" [(string "task:" (input :request))]))]
                      (seq [row :in (if task (store/tree s (task :id)) []) :when (get-in row [:data :error])]
                        {:source "zinc" :id (row :id) :kind (row :kind)
                         :created_at (os/strftime "%Y-%m-%dT%H:%M:%SZ" (math/floor (row :created))) :data (get-in row [:data :error])}))
                    (error (string "unknown method " method))))))
              (ev/give outgoing {:version 1 :type "result" :id (call :id) :value (if (nil? value) :null value)}))
            ([err fiber]
              (unless (= err :host-exited)
                (ev/give outgoing {:version 1 :type "error" :id (call :id) :error (schema/diagnostic "ProgramError" err fiber)})))))
          :t @{:task-id (packet :id)}) packet finished))))
    ([err fiber] (eprint (schema/encode (schema/diagnostic "HostFailed" err fiber))) (os/exit 1 true))))
