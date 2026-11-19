(import ./policy)
(import ./agent)
(import ./memory)

(def bindings
  {"input" {:arity [0 0] :class "machine" :doc "(input) returns the current inquiry input."}
   "settings" {:arity [0 0] :class "machine" :doc "(settings) returns exposed model and execution settings."}
   "resources" {:arity [0 0] :class "machine" :doc "(resources) returns granted filesystem, HTTP and process resource names."}
   "ev/go" {:arity [1 1] :class "machine" :doc "(ev/go thunk) starts a managed task; returns a task reference."}
   "ev/gather" {:class "macro" :doc "(ev/gather expression ...) concurrently evaluates expressions and returns their results."}
   "await" {:arity [1 1] :class "machine" :doc "(await reference) suspends this task until a local task or request completes; returns its value or raises its failure."}
   "ev/sleep" {:arity [1 1] :class "machine" :doc "(ev/sleep seconds) suspends until a saved deadline."}
   "self" {:arity [1 1] :class "local" :doc "(self request) returns {:path p :request r}. Supply :text or :code; :path continues, :from forks an exact point, :memory selects an exact point's evidence. :queue true orders busy paths or queued siblings."}
   "self/result" {:arity [1 1] :class "local" :doc "(self/result reference) returns the request receipt, or nil while pending."}
   "self/cancel" {:arity [1 1] :class "local" :doc "(self/cancel reference) cancels unfinished work and descendants; external effects are not undone."}
   "world/point" {:arity [0 0] :class "local" :doc "(world/point) returns this path's latest actual event."}
   "world/view" {:arity [0 1] :class "machine" :doc "(world/view &opt point) renders current bindings or an exact historical point as Janet source."}
   "world/rewind" {:arity [1 1] :class "local" :doc "(world/rewind point) publishes that point's binding image into this path's world. Existing work stays pinned; effects are not undone. To branch execution, use self with :from."}
   "world/remove" {:arity [1 1] :class "machine" :doc "(world/remove symbol) removes a local world binding."}
   "memory/expand" {:arity [1 1] :class "local" :doc "(memory/expand reference) returns original accessible source records without generation."}
   "memory/invalidate" {:arity [1 1] :class "local" :doc "(memory/invalidate node-reference) clears a summary and affected ancestor caches."}
   "memory/summarize" {:arity [1 1] :class "managed" :doc "(memory/summarize {:point exact-point :node optional-[event-slot] :text optional-summary}) installs a space-saving representation of that exact subtree."}
   "time/now" {:arity [0 0] :class "local" :doc "(time/now) records the current Unix time."}
   "random/bytes" {:arity [1 1] :class "local" :doc "(random/bytes count) records random bytes as hexadecimal text."}
   "fs/list" {:arity [2 2] :class "external" :doc "(fs/list grant relative-path) lists a granted directory; no absolute paths, traversal, or links."}
   "fs/read" {:arity [2 2] :class "external" :doc "(fs/read grant relative-path) reads bounded UTF-8 text."}
   "fs/write" {:arity [3 3] :class "external" :doc "(fs/write grant relative-path text) writes bounded UTF-8 text."}
   "http/request" {:arity [4 4] :class "external" :doc "(http/request grant method segments body) calls a granted HTTP endpoint."}
   "process/run" {:arity [1 1] :class "external" :doc "(process/run grant) executes granted argv/env."}})

(def core '[+ - * / % mod = not= < > <= >= band bor bxor bnot blshift brshift brushift
  not nil? true? false? boolean? number? int? string? symbol? keyword? tuple? array? table? struct? dictionary? indexed? function? buffer?
  type length get get-in put put-in has-key? first last keys values pairs next in range slice tuple array table struct buffer string symbol keyword
  scan-number scan-int number int assert error print printf eprint eprintf pp describe pretty format
  defn defn- defmacro defmacro- as-macro def var fn do if if-not when when-not unless cond case match let with defer try catch
  each for forever while repeat loop break continue label return and or default set setdyn += -= *= /= ++ --
  map mapcat filter reduce fold find find-index index-of some every? all any? empty? sorted reverse distinct concat sum product min max
  apply partial comp complement identity juxt constantly take drop seq tabseq catseq collect generate coro yield-to
  quote quasiquote unquote splice comment doc gensym assert-type assert-arity])
(defmacro gather [& forms] ~(map await [,;(map |~(ev/go (fn [] ,$)) forms)]))
(defn registry [c role imports]
  (def settings (get-in c [:vm role]))
  (def native (make-env))
  (def result (tabseq [name :in (all-bindings native) :unless (or (get (native name) :private) (index-of name '[math/random math/seedrandom]))
    :when (or (index-of name core) (some |(string/has-prefix? $ (string name)) ["array/" "buffer/" "tuple/" "table/" "struct/" "string/" "math/" "peg/" "parser/"]))]
    (string name) {:class "native" :native name}))
  (merge-into result bindings)
  (each [name binding] (pairs imports) (when (and (not= name 'output)
    (get (settings :imports) (keyword (first (string/split "/" (string name))))))
    (assert (and (symbol? name) (not (has-key? result (string name))) (not (native name))) "binding collision")
    (put result (string name) {:class "external" :arity [1 1] :import true :doc (binding :doc)})))
  (each [name spec] (pairs (settings :modules))
    (assert (and (not (has-key? result (string name))) (not (native (symbol name)))
      (not (index-of (string name) ["input" "settings" "resources"]))) "binding collision")
    (assert (and (string? (spec :module)) (string? (spec :export)) (string? (spec :doc))) "invalid module effect")
    (put result (string name) {:class "external" :module spec :doc (spec :doc)}))
  (tabseq [[name spec] :pairs result :when (policy/selected? name (settings :bindings))] name spec))
(defn expose [c role]
  (def registry (get-in c [:registry role]))
  {:settings (tabseq [k :in [:chat :rerank :summary :rounds :context-percent :score :queue :temporary]] k (c k))
   :resources (tabseq [k :in [:fs :http :processes]] k (map string (keys (get-in c [:vm role k]))))
   :bindings (sorted (keys registry))
   :documentation (string/join (seq [[name spec] :in (sorted (pairs registry)) :when (spec :doc)] (spec :doc)) "\n")})

(def modules [[(require "./agent") 'agent] [(require "./memory") 'memory] [(require "./policy") 'policy]])
(defn render [env]
  (string/join (distinct (seq [name :in (all-bindings env true)]
    (assert (get (env name) :zinc/source) (string "definition source unavailable for " name)))) "\n\n"))

(defn source-forms [code]
  (def parser (parser/new)) (def forms @[]) (def lines @[0])
  (for i 0 (+ 1 (length code))
    (if (= i (length code)) (parser/eof parser) (parser/byte parser (code i)))
    (when (= :error (parser/status parser)) (error (parser/error parser)))
    (while (parser/has-more parser)
      (def wrapped (parser/produce parser true)) (def [line column] (tuple/sourcemap wrapped))
      (array/push forms [(wrapped 0) (string/slice code (+ (lines (- line 1)) column -1) (min (+ i 1) (length code)))]))
    (when (= 10 (get code i)) (array/push lines (+ i 1)))) forms)
(defn step [p]
  (try (do
    (def c (p :config)) (def input (p :input)) (def request (p :request))
    (def bindings (merge (get-in c [:registry :user]) (get-in c [:registry :agent])))
    (var role :agent) (var current nil) (var machine nil)
    (def base @{:redef true}) (def native (make-env)) (var env nil)
    (each port [:out :err] (put base port (fn [text]
      (def output (or (current :output) @""))
      (assert (<= (+ (length output) (length text)) (c :response-bytes)) "script output limit")
      (buffer/push-string output text) (put current :output output))))
    (def invoke (fn [name args]
      (when (string? name)
        (assert (get-in c [:registry role name]) {:code "BindingNotGranted" :message (string "Binding not granted: " name)})
        (when-let [[minimum maximum] (get-in c [:registry role name :arity])]
          (assert (<= minimum (length args) maximum) "wrong argument count")))
      (def r (yield {:binding name :arguments args :role role}))
      (if (= "ok" (r :status)) (if (= :null (r :value)) nil (r :value)) (error (r :error)))))
    (def evaluate (fn [code]
      (var value nil)
      (each [form source] (source-forms code)
        (def before (tabseq [name :in (all-bindings env true)] name (env name)))
        (def thunk (compile form env))
        (when (dictionary? thunk) (error {:code "CompileFailed" :message (thunk :error)}))
        (each name (all-bindings env true) (unless (= (before name) (env name))
          (put (env name) :zinc/source source)))
        (set value (thunk))) value))
    (each [name spec] (pairs bindings)
      (put base (symbol name) (case (spec :class)
        "native" (native (spec :native))
        "macro" @{:macro true :value gather :doc (spec :doc)}
        @{:doc (spec :doc) :value (fn [& args]
          (if (= name "memory/summarize")
            (do (assert (get-in c [:registry role name]) "binding not granted") (agent/manual invoke (first args)))
            (invoke name args)))})))
    (def installed (merge base))
    (def reverse (merge make-image-dict {base 'zinc/base invoke 'zinc/invoke evaluate 'zinc/evaluate}))
    (def forward (merge load-image-dict {'zinc/base base 'zinc/invoke invoke 'zinc/evaluate evaluate}))
    (each [module namespace] modules (each [name binding] (pairs module)
      (when (and (symbol? name) (binding :value))
        (def alias (symbol "zinc/" namespace "/" name))
        (put reverse (binding :value) alias) (put forward alias (binding :value)))))
    (each [name binding] (pairs base) (when (symbol? name)
      (def alias (symbol "zinc/binding/" name)) (put reverse binding alias) (put forward alias binding)
      (when (binding :value) (def key (symbol "zinc/value/" name))
        (put reverse (binding :value) key) (put forward key (binding :value)))))
    (set machine (if (p :image) (unmarshal (p :image) forward) @{:env (make-env base)}))
    (assert (not (has-key? machine :definitions)) {:code "IncompatibleWorld" :message "This world image predates binding source metadata."})
    (set env (machine :env))
    (assert (= base (table/getproto env)) "invalid machine environment")
    (when (p :view) (break {:view (render env)}))
    (def before (marshal @{:env env} reverse))
    (unless (machine :tasks)
      (put machine :tasks @[@{:fiber (fiber/new (fn []
        (case (c :operation)
          "memory-summarize" (agent/manual invoke (c :arguments))
          "render" (agent/assemble invoke input [])
          (if (input :code) (evaluate (input :code)) (agent/run input invoke (c :rounds))))) :a env)
        :role (if (input :code) (c :role) :agent)}])
      (put machine :cursor 0) (put machine :admitted @{}) (put machine :updates @[]) (put machine :revision 0))
    (def tasks (machine :tasks)) (def completed @[])
    (each item (get p :items [])
      (def call (item :call)) (def key [(item :model) (call :id)])
      (unless (get (machine :admitted) key)
        (def id (length tasks))
        (put (machine :admitted) key (if (call :error) {:status "rejected" :error (call :error)} {:status "accepted" :task id}))
        (unless (call :error)
          (assert (< (length tasks) (c :tasks)) "task limit")
          (array/push tasks @{:fiber (fiber/new (fn [] (evaluate (call :code))) :a env)
            :role :agent :script (item :output)}))))
    (each update (get p :updates []) (array/push (machine :updates) update) (++ (machine :revision)))
    (when-let [[index response] (p :reply)] (put (tasks index) :wait nil) (put (tasks index) :inbox response))
    (sandbox :fs :net :subprocess :ffi :modules :env :asm :unmarshal :exit :locale :signal :threads :sandbox)
    (when (> (c :seconds) 0) (ev/deadline (c :seconds) (fiber/root) (fiber/root) true))
    (var operation nil) (var host-task nil)
    (while (not operation)
      (var chosen nil)
      (for offset 0 (length tasks)
        (def i (mod (+ (machine :cursor) offset) (length tasks))) (def task (tasks i))
        (unless (task :outcome)
          (def wait (task :wait))
          (def response (cond (nil? wait) (get task :inbox {:status "ok"})
            (has-key? wait :task) (let [target (get tasks (wait :task))]
              (assert (= request (wait :scope)) "task belongs to another inquiry")
              (when (target :outcome) (put target :observed true) (target :outcome)))
            (has-key? wait :call) (get-in (p :calls) [(wait :call) :result])
            (has-key? wait :request) (get (p :results) (wait :request))
            (has-key? wait :changes) (when (> (machine :revision) (wait :changes)) {:status "ok"})
            (has-key? wait :timer) (when (<= (wait :timer) (p :now)) {:status "ok"})))
          (when response (set chosen [i task response]) (break))))
      (unless chosen (break))
      (def [i task response] chosen) (put machine :cursor (mod (+ i 1) (length tasks)))
      (put task :wait nil) (put task :inbox nil) (set current task) (set role (task :role))
      (each [name binding] (pairs installed) (when (symbol? name)
        (put base name (when (get-in c [:registry role (string name)]) binding))))
      (def fiber (task :fiber)) (def value (resume fiber (unless (= :new (fiber/status fiber)) response)))
      (case (fiber/status fiber)
        :dead (put task :outcome (try
          (do (assert (<= (length (policy/encode value)) (c :response-bytes)) "script result limit")
            {:status "ok" :value (if (nil? value) :null value)})
          ([err fiber] {:status "error" :error (policy/diagnostic err fiber)})))
        :error (put task :outcome {:status "error" :error (policy/diagnostic value fiber)})
        :pending (do
          (def name (value :binding)) (def args (value :arguments))
          (case name
            "input" (put task :inbox {:status "ok" :value input})
            "settings" (put task :inbox {:status "ok" :value ((expose c role) :settings)})
            "resources" (put task :inbox {:status "ok" :value ((expose c role) :resources)})
            :updates (do (put task :inbox {:status "ok" :value (array/slice (machine :updates))}) (array/clear (machine :updates)))
            :admission (put task :inbox {:status "ok" :value (get (machine :admitted) args)})
            :pending (put task :inbox {:status "ok" :value (or (not (empty? (machine :updates))) (p :children)
              (some |(and (not= $ task) (not ($ :outcome))) tasks))})
            :listen (if (or (not (empty? (machine :updates))) (and (not (p :children)) (not (some |(and (not= $ task) (not ($ :outcome))) tasks))))
              (put task :inbox {:status "ok"}) (put task :wait {:changes (machine :revision)}))
            "ev/go" (do (assert (function? (first args)) "ev/go expects a function")
              (assert (< (length tasks) (c :tasks)) "task limit")
              (def id (length tasks)) (array/push tasks @{:fiber (fiber/new (first args) :a env) :role role})
              (put task :inbox {:status "ok" :value {:scope request :task id}}))
            "ev/sleep" (do (assert (and (number? (first args)) (<= 0 (first args) 31536000)) "invalid sleep duration")
              (put task :wait {:timer (+ (p :now) (first args))}))
            "await" (let [ref (first args)]
              (if (and (dictionary? ref) (has-key? ref :task))
                (do (put task :wait ref) (var at ref) (def seen @{})
                  (while (and at (has-key? at :task))
                    (def id (at :task)) (assert (and (= request (at :scope)) (int? id) (<= 0 id (- (length tasks) 1))
                      (not= id i) (not (seen id))) {:code "WaitCycle" :message "Invalid or cyclic task wait."})
                    (put seen id true) (set at (get-in tasks [id :wait]))))
                (do (assert (and (dictionary? ref) (string? (ref :request)) (int? (ref :path))) "invalid work reference")
                  (set operation {:binding :await :arguments [ref]}) (set host-task i) (put task :wait ref))))
            "world/view" (if (first args)
              (do (set operation value) (set host-task i) (put task :wait {:host true}))
              (put task :inbox {:status "ok" :value (render env)}))
            "world/remove" (do (assert (symbol? (first args)) "world/remove expects a symbol")
              (put env (first args) nil) (put task :inbox {:status "ok" :value true}))
            (do (policy/encode args) (set operation value) (set host-task i)
              (put task :wait (if (or (index-of name [:chat :rerank]) (= "external" (get-in c [:registry role name :class])))
                {:call (length (p :calls))} {:host true})))) )
        (error "unsupported fiber suspension"))
      (when (task :outcome)
        (put task :fiber nil)
        (when (task :output) (put task :outcome (merge (task :outcome) {:output (string (task :output))})))
        (when (and (not= i 0) (or (task :script) (task :output)))
          (array/push completed {:task i :script (task :script) :outcome (task :outcome)}))))
    (def settled (when (and (not (p :children)) (every? (map |($ :outcome) tasks)))
      (or (get (find |(and (not ($ :observed)) (not ($ :script)) (= "error" (get-in $ [:outcome :status]))) tasks) :outcome)
        ((tasks 0) :outcome))))
    (def image (marshal machine reverse))
    (assert (<= (length image) (c :world-bytes)) "machine image limit")
    (def projected (marshal @{:env env} reverse))
    {:image image :changed (not= (string before) (string projected))
     :bindings projected :completed completed
     :operation operation :role (when host-task ((tasks host-task) :role)) :task host-task :settled settled
     :waits (seq [task :in tasks :unless (task :outcome) :when (task :wait)] (task :wait))})
    ([err fiber] {:failure (policy/diagnostic err fiber)})))

(defn view [image c]
  (def packet (step {:view true :image image :config c}))
  (when (packet :failure) (error (packet :failure))) (packet :view))
