(import ./config)
(import ./agent)
(import ./memory)
(import ./store)

(def image-modules [[(require "./agent") 'agent] [(require "./memory") 'memory] [(require "./config") 'config]])

(defn step [[image starting input c bindings receipts ticket request]]
  (try
    (do
      (def native (make-env))
      (def forbidden '[stdin stdout stderr make-env env-lookup root-env debugger-env make-image make-image-dict
        load-image load-image-dict marshal unmarshal eval eval-string run-context compile curenv with-env setdyn
        with-dyns defdyn all-dynamics dyn native require import import* use yield signal resume cancel propagate
        getline repl debugger debugger-on-status cli-main dofile slurp spit asm disasm
        os/clock os/time os/cryptorand math/random math/seedrandom])
      (def base (tabseq [name :in (all-bindings native) :unless (or (get (native name) :private)
        (index-of name forbidden) (string/has-prefix? "*module" (string name)))
        :when (or (not (string/find "/" (string name)))
          (some |(string/has-prefix? $ (string name)) ["array/" "buffer/" "tuple/" "table/" "struct/" "string/" "math/" "peg/" "parser/"]))]
        name (native name)))
      (put base :redef true)
      (var env nil) (var sources nil)
      (def output @"")
      (each port [:out :err]
        (put base port (fn [text]
          (assert (<= (+ (length output) (length text)) (c :response-bytes)) "script output limit")
          (buffer/push-string output text))))
      (def invoke (fn [name args]
        (assert (bindings name) {:code "BindingNotGranted" :message (string "Binding is not granted: " name)})
        (when-let [[minimum maximum] (get-in bindings [name :arity])]
          (assert (<= minimum (length args) maximum) {:code "InvalidArguments" :message (string "Wrong argument count for " name)}))
        (def r (yield {:binding name :arguments args}))
        (if (= "ok" (r :status)) (r :value) (error (or (r :error) {:code "Cancelled" :message "Work cancelled."})))))
      (def evaluate (fn [code]
        (var result nil)
        (each form (parse-all code)
          (def before (tabseq [name :in (all-bindings env true)] name (env name)))
          (def thunk (compile form env))
          (when (dictionary? thunk) (error {:code "CompileFailed" :message (thunk :error)}))
          (set result (thunk))
          (each name (all-bindings env true)
            (when (not= (before name) (env name)) (put sources name (string/format "%j" form))))) result))
      (each [name spec] (pairs bindings) (unless (spec :private)
        (put base (symbol name) @{:doc (spec :doc) :value
          (if (= name "memory/summarize") (partial memory/summarize invoke)
            (fn [& args] (invoke name args)))})))
      (put base 'input @{:doc "(input) returns the current request input." :value (fn [] input)})
      (put base 'settings @{:doc "(settings) returns public model settings." :value
        (fn [] (tabseq [k :in [:chat :rerank :thinking :rounds :context-percent]] k (c k)))})
      (put base 'resources @{:doc "(resources) lists granted resource names." :value
        (fn [] (tabseq [k :in [:fs :http :processes]] k (keys (c k))))})
      (def reverse (merge make-image-dict {base 'zinc/base invoke 'zinc/invoke evaluate 'zinc/evaluate}))
      (def forward (merge load-image-dict {'zinc/base base 'zinc/invoke invoke 'zinc/evaluate evaluate}))
      (each [module namespace] image-modules
        (each [name binding] (pairs module) (when (and (symbol? name) (binding :value))
          (def alias (symbol "zinc/" namespace "/" name))
          (put reverse (binding :value) alias) (put forward alias (binding :value)))))
      (each [name binding] (pairs base) (when (symbol? name)
        (def alias (symbol "zinc/binding/" name)) (put reverse binding alias) (put forward alias binding)
        (when (binding :value)
          (def value-alias (symbol "zinc/value/" name))
          (put reverse (binding :value) value-alias) (put forward value-alias (binding :value)))))
      (def machine (if image (unmarshal image forward) @{:env (make-env base) :sources @{}}))
      (set env (machine :env)) (set sources (machine :sources))
      (assert (= base (table/getproto env)) "invalid checkpoint environment")
      (when starting
        (put machine :baseline (store/digest (marshal @{:env env :sources sources} reverse)))
        (put machine :tasks @[@{:fiber (fiber/new (fn []
          (if (input :code) (evaluate (input :code))
            (agent/run input invoke evaluate memory/context (c :rounds)))) :a env)}])
        (put machine :cursor 0))
      (sandbox :fs :net :subprocess :ffi :modules :env :asm :unmarshal :exit :locale :signal :threads :sandbox)
      (when (> (c :seconds) 0) (ev/deadline (c :seconds) (fiber/root) (fiber/root) true))
      (def tasks (machine :tasks))
      (var chosen nil)
      (for offset 0 (length tasks)
        (def i (mod (+ (machine :cursor) offset) (length tasks))) (def task (tasks i))
        (unless (task :outcome)
          (def wait (task :wait))
          (def response (cond
            (nil? wait) (get task :inbox {:status "ok"})
            (dictionary? wait) (do
              (assert (= request (wait :scope)) "task belongs to another request")
              (def target (get tasks (wait :task))) (assert target "unknown local task")
              (when (target :outcome) (put target :observed true) (target :outcome)))
            (receipts wait)))
          (when response (set chosen [i task response]) (break))))
      (var operation nil)
      (when chosen
        (def [i task response] chosen)
        (put machine :cursor (mod (+ i 1) (length tasks)))
        (put task :wait nil) (put task :inbox nil)
        (def fiber (task :fiber))
        (def value (resume fiber (if (= :new (fiber/status fiber)) nil response)))
        (case (fiber/status fiber)
          :dead (put task :outcome {:status "ok" :value value})
          :error (put task :outcome {:status "error" :error (config/diagnostic value fiber)})
          :pending
          (do
            (assert (and (dictionary? value) (bindings (value :binding))) "unsupported task suspension")
            (def args (value :arguments))
            (case (value :binding)
              "async" (do
                (assert (and (= 1 (length args)) (function? (first args))) "async expects a Janet function")
                (assert (< (length tasks) (c :tasks)) "task limit")
                (def id (length tasks))
                (array/push tasks @{:fiber (fiber/new (first args) :a env)})
                (put task :inbox {:status "ok" :value {:scope request :task id}}))
              "await" (do
                (assert (= 1 (length args)) "await expects one reference")
                (def ref (first args))
                (assert (or (string? ref) (and (dictionary? ref) (or (has-key? ref :task) (string? (ref :request))))) "await expects a task or request reference")
                (put task :wait (if (and (dictionary? ref) (has-key? ref :task)) ref
                  (if (dictionary? ref) (ref :request) ref)))
                (assert (not= (task :wait) request) "cannot await this request")
                (var next (task :wait)) (def seen @{})
                (while (dictionary? next)
                  (def id (next :task))
                  (assert (and (= request (next :scope)) (int? id) (<= 0 id (- (length tasks) 1))) "invalid task reference")
                  (assert (and (not= id i) (not (seen id))) {:code "WaitCycle" :message "Local task await would create a cycle."})
                  (put seen id true) (set next (get-in tasks [id :wait]))))
              "world/remove" (do
                (assert (and (= 1 (length args)) (symbol? (first args))) "world/remove expects a symbol")
                (put env (first args) nil) (put sources (first args) nil)
                (put task :inbox {:status "ok" :value true}))
              (do (config/encode args) (put task :wait ticket)
                (set operation {:binding (value :binding) :arguments args}))))
          (error "unsupported fiber state")))
      (def waits @[]) (var ready false)
      (each task tasks (unless (task :outcome)
        (def wait (task :wait))
        (cond (nil? wait) (set ready true)
          (dictionary? wait) (when (get-in tasks [(wait :task) :outcome]) (set ready true))
          (receipts wait) (set ready true)
          (array/push waits wait))))
      (def settled (when (every? (map |($ :outcome) tasks))
        (or (get (find |(and (not ($ :observed)) (= "error" (get-in $ [:outcome :status]))) tasks) :outcome)
          ((tasks 0) :outcome))))
      (when settled (config/encode settled))
      (def bytes (marshal machine reverse))
      (assert (<= (length bytes) (c :world-bytes)) "checkpoint image limit")
      (def world-image (when settled (marshal @{:env env :sources sources} reverse)))
      {:image bytes :world-image world-image :changed (and settled (not= (machine :baseline) (store/digest world-image)))
       :definitions (map |{:name (string ($ 0)) :source ($ 1)} (sorted (pairs sources)))
       :ready ready :waits (distinct waits) :operation operation :output (string output) :settled settled})
    ([err fiber] {:failure (config/diagnostic err fiber)})))
