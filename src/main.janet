(import spork/path :as path)
(import ./schema)
(import ./io)
(import ./store)
(import ./runtime)
(import ./engine)
(import ./model)
(import ./memory)

(defn main [executable & args]
  (assert (= 0 (length args)) "Zinc accepts one version-1 call on stdin")
  (unless (index-of (os/which) [:windows :mingw]) (os/sigaction :pipe (fn [])))
  (def limit (scan-number (os/getenv "PA_FRAME_BYTES")))
  (assert (and (int? limit) (<= 1 limit 0x7fffffff)) "PA_FRAME_BYTES is required")
  (var execution nil) (var method nil) (var admitted false) (var observer true)
  (try
    (do
      (def call (io/read-call stdin limit))
      (set method (call :method))
      (def params (schema/request (call :params) [:input :config :imports :after :store]))
      (def config (schema/configuration (merge (get params :config {}) {:imports (get params :imports {})}) (= method "describe")))
      (when (config :agent) (put (config :agent) :imports (config :imports)))
      (def input (get params :input {}))
      (assert (dictionary? input) "input must be an object")
      (assert (<= (length (schema/encode input)) (config :request-bytes)) "input exceeds request byte limit")
      (io/send stdout {:version 1 :type "ready"} limit)
      (def value
        (case method
          "describe" (engine/describe config)
          "instructions" (runtime/instructions config (runtime/definitions config engine/bindings))
          "models" (map |{:ref ($ :ref) :name ($ :name)} (model/catalogue config (get input :role "chat")))
          (do
            (when (= method "init")
              (assert (= (config :identity) (os/realpath (config :identity))) "canonical instance directory required")
              (def relative (path/relpath (config :identity) (config :store)))
              (assert (and (not (path/abspath? relative)) (not= ".." (first (path/parts relative)))) "store must belong to the instance")
              (assert (not (os/lstat (config :store))) "init requires a fresh database")
              (var directory (config :identity))
              (each part (filter next (path/parts (path/dirname relative)))
                (unless (= part ".")
                  (set directory (path/join directory part)) (os/mkdir directory)
                  (assert (= directory (os/realpath directory)) "state directories cannot contain links"))))
            (def readonly (or (index-of method ["diagnostics" "views" "render" "status"])
              (and (= method "world") (= "view" (get input :action "view")))))
            (def s (store/open config (or readonly (and (= method "self") (= false (get input :persist true))))))
            (defer (store/close s)
              (case method
                "init" (do (store/configure s) {:store (s :identity) :world (config :world)})
                "self"
                (do
                  (schema/request input (keys schema/inputs))
                  (def attach (not (or (input :text) (input :code))))
                  (when (config :ephemeral) (assert (= false (get input :persist true)) "ephemeral profiles require persist:false"))
                  (each profile (filter identity [config (config :agent)]) (runtime/definitions profile engine/bindings))
                  (def local (if (= false (get input :persist true)) (store/temporary config) s))
                  (defer (unless (= local s) (store/close local))
                    (store/configure local)
                    (when (or attach (params :store)) (assert (= (params :store) (local :identity)) "execution store identity changed"))
                    (def task (if attach
                      (do (schema/request input [:request])
                        (or (first (store/query local "SELECT * FROM events WHERE key=?" [(string "task:" (input :request))])) (error "task unavailable")))
                      (do (assert (and (input :author) (input :at)) "authenticated author and occurrence time required")
                        (store/start local input config))))
                    (set admitted true)
                    (def after (get params :after 0))
                    (assert (and (int? after) (>= after 0)) "invalid observation cursor")
                    (def updates (ev/thread-chan 1))
                    (defer (ev/chan-close updates)
                      (def done (ev/thread-chan 1)) (def completed (ev/chan 1))
                      (ev/thread (fn [[config id file updates]]
                        (try (engine/run config id file updates)
                          ([err fiber] (error (schema/diagnostic "ExecutorFailed" err fiber)))))
                        [config (task :id) (local :file) updates] :n done)
                      (def owner (fiber/root))
                      (ev/go (fn []
                        (def packet (ev/take done)) (ev/chan-close done) (ev/give completed packet)
                        (unless (= :ok (packet 0)) (ev/cancel owner (packet 1)))))
                      (set execution completed)
                      (def emit (fn [frame] (when observer
                        (try (io/send stdout {:version 1 :type "event" :value frame} limit) ([err] (set observer false))))))
                      (emit {:type "admission" :script (task :id) :store (local :identity) :request (get-in task [:data :request]) :persist (not (local :temporary))})
                      (def reader (store/open config true (local :file)))
                      (def outcome (defer (store/close reader) (engine/observe reader task after emit updates true)))
                      (def [status failure] (ev/take completed))
                      (ev/chan-close completed) (set execution nil) (assert (= status :ok) failure) outcome)))
                "status"
                (do
                  (schema/request input [:request :store]) (assert (= (input :store) (s :identity)) "status store identity changed")
                  (def task (first (store/query s "SELECT id FROM events WHERE key=?" [(string "task:" (input :request))])))
                  (assert task "execution unavailable")
                  (merge {:script (task :id) :store (s :identity)} (get (store/outcome s (task :id)) :data {:state "pending"})))
                "abort" (do (schema/request input [:request :reason]) (store/abort s (input :request) (input :reason)))
                "record" (do (schema/request input [:records]) {:events (store/record s (input :records))})
                "world"
                (do
                  (schema/request input [:action :point :world])
                  (def name (get input :world (config :world)))
                  (assert (has-key? (config :worlds) (keyword name)) "world is not granted")
                  (case (get input :action "view")
                    "view" (store/view s name (input :point))
                    "rewind" (do (assert (and (not (config :inference)) (config :janet)) "rewind requires direct-execution authority")
                      (store/rewind s name (input :point)))
                    (error "unknown world action")))
                "views" (do (schema/request input [:event :mode]) (memory/report s (input :event) (get input :mode "memory")))
                "render" (do (schema/request input [:event]) (memory/report s (input :event) "render"))
                "invalidate" (do (schema/request input [:event]) (assert (= "summary" ((store/event s (input :event)) :kind)) "choose a summary")
                  {:event ((store/append s (input :event) "invalidate" {}) :id)})
                "resolve"
                (do
                  (schema/request input [:event :outcome])
                  (assert (and (not (config :inference)) (config :janet)) "resolution requires direct-execution authority")
                  {:event ((store/resolve s (store/event s (input :event)) (input :outcome)) :id)})
                "diagnostics"
                (do
                  (schema/request input [:request])
                  (def task (first (store/query s "SELECT id FROM events WHERE key=?" [(string "task:" (input :request))])))
                  (seq [row :in (if task (store/tree s (task :id)) []) :when (get-in row [:data :error])]
                    {:source "zinc" :id (row :id) :kind (row :kind) :created_at (os/strftime "%Y-%m-%dT%H:%M:%SZ" (math/floor (row :created))) :data (get-in row [:data :error])}))
                (error (string "unknown method " method)))))))
      (when observer (io/send stdout {:version 1 :type "result" :value value} limit)))
    ([err fiber]
      (eprint (schema/encode (schema/diagnostic "ProgramError" err fiber)))
      (when execution (ev/take execution) (ev/chan-close execution))
      (when observer
        (def failure (schema/diagnostic "ProgramError" err fiber))
        (io/send stdout {:version 1 :type "error" :error
          (if (and (= method "self") (not admitted)) (merge failure {:code "AdmissionRejected"}) failure)} limit))
      (os/exit 1))))
