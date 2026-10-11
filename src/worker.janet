(assert (dyn :library) "worker requires the installed Janet dependency tree")
(module/add-syspath (dyn :library))

(import spork/json :as json)
(import spork/base64 :as base64)

(defn- install [env binding]
  (def parser (parser/new))
  (parser/consume parser (binding :source))
  (parser/consume parser "\n")
  (assert (and (= :root (parser/status parser)) (parser/has-more parser)) "incomplete world definition")
  (def form (parser/produce parser))
  (assert (not (parser/has-more parser)) "world definitions require one expression")
  (def pending @[[form true]])
  (while (> (length pending) 0)
    (def [node initializing] (array/pop pending))
    (cond
      (tuple? node)
      (do
        (def call (= :parens (tuple/type node)))
        (def head (first node))
        (when call
          (assert (not (index-of head ['comptime 'mac 'defmacro 'defmacro-])) "definitions cannot execute at compile time")
          (when initializing
            (assert (index-of head ['fn 'quote]) "definition initializers must be literals or functions")))
        (unless (and call (= 'quote head))
          (each item node (array/push pending [item (and initializing (not (and call (= 'fn head))))]))))
      (array? node) (each item node (array/push pending [item initializing]))
      (dictionary? node) (each item (values node) (array/push pending [item initializing]))))
  (def name (symbol (binding :name)))
  (assert (or (not (has-key? env name)) ((env name) :learned)) "definition shadows a reserved binding")
  (put env name @{:value (eval form env) :doc (binding :description) :learned true}))

(defn- receipt [value operation & fields]
  (def result (json/decode
                ((pa/import "ledger")
                  (string (json/encode (merge {:task (value :task) :token (value :token)
                                               :owner (value :owner) :generation (value :generation)
                                               :operation operation} (struct ;fields))))
                  :member "receipt") true true))
  (assert (result :ok) (result :error))
  (result :value))

(defn- environment [value]
  (def env (make-env))
  (var position 0)
  (var active false)
  (defn spawn [name & arguments]
    (assert active "world reconstruction cannot perform effects")
    (receipt value name :position (++ position) :arguments arguments))
  (defn await [handle]
    (assert active "world reconstruction cannot await work")
    (def result (receipt value "await" :arguments [handle]))
    (if (handle :bytes) (base64/decode (result :data)) result))

  (put env 'self @{:value (partial spawn "spawn") :doc "Spawn this scoped agent recursively."})
  (put env 'await @{:value await})
  (put env 'input @{:value (value :input)})
  (put env 'self/document @{:value (fn [] (value :document))})
  (each name (value :members)
    (put env (symbol "self/" name) @{:value (partial spawn name)}))

  (put env 'self/world/define
       @{:value (fn [name source description]
                  (assert active "world reconstruction cannot change definitions")
                  (set active false)
                  (defer (set active true)
                    (install env {:name name :source source :description description}))
                  (spawn "world/define" name source description))})
  (put env 'self/work/map
       @{:value (fn [name inputs]
                  (assert (and (index-of name (value :safe)) (indexed? inputs)) "map requires safe owned members")
                  (def handles (map (fn [arguments]
                                      (assert (indexed? arguments) "map arguments must be arrays")
                                      (apply spawn name arguments)) inputs))
                  (map await handles))})
  (put env 'self/work/reduce
       @{:value (fn [name values initial]
                  (assert (and (index-of name (value :safe)) (indexed? values)) "reduce requires a safe owned member")
                  (reduce (fn [result item] (await (spawn name result item))) initial values))})

  (each name (get value :imports [])
    (assert (not (has-key? env (symbol name))) "Import shadows a reserved binding")
    (put env (symbol name)
         @{:value (fn [bytes &named member]
                    (assert (bytes? bytes) "Imports take bytes")
                    (spawn "import" {:name name :member (or member "call")
                                     :data (base64/encode (string bytes))}))}))
  (each binding (value :bindings) (install env binding))
  (set active true)
  env)

(defn execute [bytes opaque]
  (def config (json/decode opaque true true))
  (assert (= true (config :jailed)) "invoker must provide a confined worker")
  (def value (json/decode bytes true true))
  (assert (and (string? (value :code)) (<= 1 (length (value :code)) (config :source-bytes))) "worker source byte ceiling")
  (receipt value "renew")
  (sandbox :fs :net :subprocess :ffi :modules :threads :env
           :asm :unmarshal :exit :locale :signal :chroot :sandbox)
  (def results (ev/chan 1))
  (def vm (ev/go (fn []
                   (ev/give results (try
                                      (let [result (eval-string (value :code) (environment value))]
                                        (assert (not (nil? result)) "Janet source returned no value")
                                        (assert (<= (length (json/encode result)) (config :response-bytes)) "worker result byte ceiling")
                                        {:value result})
                                      ([err] {:error (string err)}))))))
  (def heartbeat (ev/go (fn []
                          (try (while true
                                 (ev/sleep (/ (value :lease-seconds) 3))
                                 (receipt value "renew"))
                            ([err] (unless (= :dead (fiber/status vm)) (ev/cancel vm err)))))))
  (def outcome (ev/take results))
  (unless (= :dead (fiber/status heartbeat)) (ev/cancel heartbeat "finished"))
  (receipt value "complete" :value (outcome :value) :error (outcome :error))
  (string (json/encode outcome)))

(defn validate-image [bytes opaque]
  (assert (= true ((json/decode opaque true true) :jailed)) "validation requires a confined worker")
  (def value (json/decode bytes true true))
  (sandbox :fs :net :subprocess :ffi :modules :threads :env
           :asm :unmarshal :exit :locale :signal :chroot :sandbox)
  (environment value)
  (string (json/encode {:accepted true})))

(defn validate-package [bytes opaque]
  (assert (= true ((json/decode opaque true true) :jailed)) "validation requires a confined worker")
  (def value (json/decode bytes true true))
  (def program (require (string (value :root) "/zinc.md")))
  (each name ['call 'worker 'receipt 'resume 'describe 'document 'models 'events 'acknowledge 'pending 'abort 'supervise 'invoke 'merge-world 'restore-world 'reload]
    (assert (function? (module/value program name)) "required agent entry is missing"))
  (string (json/encode {:accepted true})))
