(import ./schema)
(import ./store)
(import ./effects)

(defn definitions [config supplied]
  (if-not (config :janet) {}
    (let [base (make-env)
          available (tabseq [name :in (all-bindings base) :unless (get (base name) :private)
            :unless (index-of name ['make-env 'env-lookup 'root-env 'debugger-env 'stdin 'stdout 'stderr
              'make-image 'make-image-dict 'load-image 'load-image-dict 'eval 'eval-string 'run-context 'compile
              'curenv 'with-env 'setdyn 'with-dyns 'defdyn 'all-dynamics 'native 'require 'import 'import* 'use])
            :unless (string/has-prefix? "*module" (string name))
            :when (or (not (string/find "/" (string name)))
              (index-of name ['/ '/= 'os/clock 'os/date 'os/time 'os/cryptorand])
              (some |(string/has-prefix? $ (string name))
                ["array/" "buffer/" "tuple/" "table/" "struct/" "string/" "math/" "peg/" "parser/" "ev/" "fiber/"]))]
            (cond (= name '*) "core/multiply"
              (index-of name ['/ '/=]) (string "core/" name)
              (string/find "/" (string name)) (string name)
              (string "core/" name))
            (if (index-of name ['os/clock 'os/date 'os/time 'os/cryptorand]) (base name) {:local name}))
          imports (get config :imports {})]
      (merge-into available supplied)
      (each [namespace spec] (pairs imports)
        (each [name documentation] (pairs (spec :exports))
          (def qualified (if (= (string name) (spec :entry)) (string namespace) (string namespace "/" name)))
          (assert (not (available qualified)) "duplicate import binding")
          (put available qualified {:doc documentation :value (fn [& args]
            (effects/call spec (string name) args (dyn :zinc/operation) (config :response-bytes)))})))
      (each [namespace module] (pairs (get-in config [:janet :imports]))
        (each [name binding] (pairs (with-env base (require (module :module))))
          (when (and (symbol? name) (not (binding :private)) (not (binding :macro))
                     (index-of (type (binding :value)) [:function :cfunction])
                     (or (nil? (module :export)) (= (string name) (module :export))))
            (def qualified (if (module :export) (string namespace) (string namespace "/" name)))
            (assert (and (not (available qualified)) (string? (binding :doc))) "invalid or undocumented host binding")
            (put available qualified (merge binding
              {:doc (string/replace-all (string "(" name) (string "(" qualified) (binding :doc))})))))
      (def selected (schema/select (keys available) (get-in config [:janet :bindings])))
      (put (config :janet) :bindings selected)
      (tabseq [name :in selected] name (available name)))))

(defn public [config bindings]
  {:settings (schema/project config (map keyword (get-in config [:janet :values] [])))
   :resources (tabseq [[key field] :pairs schema/fields :when (field :public)
     :let [grants (tabseq [[name grant] :pairs (config key)
       :let [functions (sorted (seq [[name binding] :pairs bindings :when (= key (binding :resource))
         :when (or (not (binding :permission)) (grant (binding :permission)))] name))]
       :when (> (length functions) 0)] name (merge (schema/project grant (field :public)) {:functions functions}))]
     :when (> (length grants) 0)] key grants)})

(defn instructions [config bindings]
  (string (slurp (config :instructions))
    (when (config :janet)
      (string "\n\n## Settings and resources\n\n" (schema/encode (public config bindings))
        "\n\nHost arguments and results must be JSON data. Use :null for explicit null."
        "\n\nHost bindings: " (string/join (seq [[name binding] :in (sorted (pairs bindings)) :unless (binding :local)] name) ", ")
        ". Use (doc name) for arguments and behavior."))))

(defn- evaluate [[code id input instructions public bindings setup snapshot events stop limit world-limit seconds]]
  (try (do
  (def native (make-env))
  (def base @{:redef true 'doc (native 'doc)})
  (var env nil) (var succeeded false)
  (var output-size 0)
  (def output @[])
  (defn flush-output []
    (while (> (length output) 0)
      (def packet (first output)) (array/remove output 0)
      (unless (= "" (string/trim (packet :text))) (ev/give events packet))) nil)
  (each port [:out :err]
    (put base port (fn [text]
      (+= output-size (length text))
      (assert (<= output-size limit) "script output byte ceiling")
      (when (> (length text) 0)
        (if (= (string port) (get (last output) :port))
          (put (last output) :text (string ((last output) :text) text))
          (array/push output @{:kind :output :port (string port) :text (string text)}))
        (ev/go flush-output nil)))))
  (def call (fn [name & args]
    (assert (bindings name) {:code "BindingNotGranted" :message (string "Host binding is not granted: " name)})
    (if (= name "world/remove")
      (do (assert (and (= 1 (length args)) (symbol? (first args))) "binding name must be a symbol")
        (put env (first args) nil))
      (do
        (schema/encode args)
        (flush-output)
        (def reply (ev/thread-chan 1))
        (defer (ev/chan-close reply)
          (ev/give events {:kind :call :name name :args args :reply reply})
          (def outcome (ev/take reply))
          (when (outcome :error) (error (outcome :error)))
          (outcome :value))))))
  (each [name binding] (pairs bindings)
    (put base (or (binding :local) (symbol name))
      (if (binding :local)
        (if (= 'print (binding :local))
          @{:doc "Prints text or JSON data." :value (fn [& values]
            (apply (module/value native 'print)
              (map |(if (string? $) $ (schema/encode (schema/transport $))) values)))}
          (native (binding :local)))
        @{:doc (binding :doc) :value (partial call name)})))
  (each [name documentation value]
    [['input "(input) returns script input." (fn [] input)]
     ['self/document "(self/document) returns execution instructions." (fn [] instructions)]
     ['settings "(settings) returns exposed settings." (fn [] (public :settings))]
     ['resources "(resources) returns exposed resource grants." (fn [] (public :resources))]]
    (put base name @{:doc documentation :value value}))
  (def options (if setup ((module/value (require setup) 'configure) base) {}))
  (each key (keys options) (assert (= key :expander) "setup supports only :expander"))
  (put base *module-paths* []) (put base *module-cache* @{})
  (def reverse (merge make-image-dict {base 'zinc/base call 'zinc/call}))
  (def forward (merge load-image-dict {'zinc/base base 'zinc/call call}))
  (each [name binding] (pairs base)
    (when (symbol? name)
      (def key (symbol "zinc/binding/" name))
      (put reverse binding key) (put forward key binding)
      (when (index-of name ['input 'self/document 'settings 'resources 'print])
        (def key (symbol "zinc/value/" name))
        (put reverse (binding :value) key) (put forward key (binding :value)))))
  (set env (if (snapshot 5) (unmarshal (snapshot 5) forward) (make-env base)))
  (assert (and (table? env) (= base (table/getproto env))) "invalid world environment")
  (def sources (tabseq [binding :in (snapshot 4)] (symbol (binding :name)) binding))
  (def known (tabseq [name :in (all-bindings env true)] name (env name)))
  (def baseline (marshal env reverse))
  (math/seedrandom (os/cryptorand 32))
  (sandbox :fs :net :subprocess :ffi :modules :env :asm :unmarshal :exit :locale :signal :chroot :sandbox)
  (def owner (fiber/root))
  (when (> seconds 0) (ev/deadline seconds owner owner true))
  (def stopped (ev/chan 1))
  (def watcher (ev/go (fn []
    (ev/take stop)
    (each fiber (ev/all-tasks) (unless (= fiber (fiber/root)) (ev/cancel fiber :execution-ended)))) nil stopped))
  (defer (do
    (each fiber (ev/all-tasks)
      (unless (or (= fiber owner) (= fiber watcher)) (ev/cancel fiber :execution-ended)))
    (when (fiber/can-resume? watcher) (ev/cancel watcher :finished))
    (ev/take stopped) (ev/chan-close stopped))
    (def root (ev/go (fiber/new (fn []
      (var form-index nil)
      (def outcome (try
        (do
          (def forms (try (parse-all code)
            ([err fiber] (error (schema/diagnostic "ParseFailed" err fiber)))))
          (var value nil)
          (each [index form] (pairs forms)
            (set form-index index)
            (def thunk (compile (if (options :expander) ((options :expander) form) form) env))
            (when (dictionary? thunk)
              (error {:code "CompileFailed" :message (thunk :error)
                      :context (schema/project thunk [:line :column])}))
            (set value (thunk))
            (each name (all-bindings env true)
              (def binding (env name))
              (when (not= binding (known name))
                (put sources name {:source (string/format "%j" form) :script id :form index}))
              (put known name binding))
            (flush-output)
            (ev/give events {:kind :progress :form (+ index 1)}))
          (def projected (schema/transport value))
          (def encoded (schema/encode projected))
          (def text (if (string? value) value encoded))
          (assert (<= (length encoded) limit) "script result byte ceiling")
          (set succeeded true)
          {:state "done" :value projected :text text})
        ([err fiber]
          (def failure (schema/diagnostic "ExecutionFailed" err fiber))
          {:state "failed"
           :error (merge failure {:context (merge (get failure :context {})
             {:script id :form form-index})})
           :text (failure :message)})))
      (flush-output)
      (ev/go (fn [] (ev/give events (merge outcome {:kind :return})) nil)) nil) :t env) nil events))
    (while (or (fiber/can-resume? root)
      (some |(and (not= $ owner) (not= $ watcher)) (ev/all-tasks)))
      (ev/sleep store/interval))
    (when succeeded
      (def encoded (marshal env reverse))
      (unless (= (string baseline) (string encoded))
        (def metadata (seq [name :in (sorted (all-bindings env true))]
          (merge (sources name) {:name (string name) :type (string (type (module/value env name true)))})))
        (def bytes (marshal [1 janet/version janet/build janet/config-bits metadata encoded] @{}))
        (assert (<= (length bytes) world-limit) "world byte ceiling")
        (def reply (ev/thread-chan 1))
        (defer (ev/chan-close reply)
          (ev/give events {:kind :publish :bytes bytes :reply reply
            :aliases (seq [key :in (keys forward) :when (string/has-prefix? "zinc/" (string key))] key)})
          (def outcome (ev/take reply))
          (when (outcome :error) (error (outcome :error))))))))
    ([err fiber] (ev/give events {:kind :failure :error (schema/diagnostic "ExecutorFailed" err fiber)}) nil)))

(defn run [s script bindings]
  (def config (s :config))
  (def events (ev/thread-chan (config :task-quota)))
  (def stop (ev/thread-chan 1)) (def finished (ev/chan 1))
  (def waiting @{})
  (var joined false) (var sequence 0) (var failure nil)
  (def seconds (min (if (= 0 (config :seconds)) math/inf (config :seconds))
    (- (or (get-in script [:data :expires]) math/inf) (os/clock))))
  (def [publication snapshot] (store/transact s
    (store/world-image s (get-in script [:data :world]))))
  (def revision (publication :id))
  (def arguments [(get-in script [:data :input :code]) (script :id) (get-in script [:data :input])
    (instructions config bindings) (public config bindings)
    (tabseq [[name binding] :pairs bindings] name (schema/project binding [:local :doc]))
    (get-in config [:janet :setup]) snapshot events stop (config :response-bytes) (config :world-bytes)
    (if (= seconds math/inf) 0 (max 0.001 seconds))])
  (ev/go (fn [] (with-env @{} (ev/thread evaluate arguments (keyword "") events))) nil finished)
  (defer (do
    (unless joined
      (ev/give stop true)
      (while (not joined)
        (def [_ channel packet] (ev/select events finished))
        (if (= channel finished) (set joined true)
          (when (and (dictionary? packet) (packet :reply)) (ev/chan-close (packet :reply))))))
    (each [fiber done] (pairs waiting)
      (when (fiber/can-resume? fiber) (ev/cancel fiber :execution-ended))
      (ev/take done))
    (each channel [events stop finished] (ev/chan-close channel)))
    (while (not joined)
      (def [_ channel packet] (ev/select events finished))
      (cond
        (= channel finished)
        (do (set joined true)
          (assert (= :ok (packet 0))
            (schema/diagnostic "ExecutorFailed" (fiber/last-value (packet 1)) (packet 1))))
        (tuple? packet)
        (when (or (not= :ok (packet 0)) (not (nil? (packet 1))))
          (when (not= :ok (packet 0)) (set failure (schema/diagnostic "FiberFailed" (packet 1))))
          (store/append s (script :id) (if (= :ok (packet 0)) "fiber" "diagnostic")
            (if (= :ok (packet 0)) (let [value (schema/transport (packet 1))]
              {:value value :text (if (string? value) value (schema/encode value))})
              {:error failure :text (failure :message)})))
        (= :call (packet :kind))
        (do
          (++ sequence)
          (def admission (store/append s (script :id) "operation"
            (merge (schema/project (script :data) [:world :epoch :expires :memory_range :call])
              {:name (packet :name) :arguments (packet :args)})
            (string "operation:" (script :id) ":" sequence) (script :image)))
          (def done (ev/chan 1))
          (def waiter (ev/go (fn [[id reply]]
            (var outcome nil)
            (while (not (set outcome (store/result s id))) (ev/sleep store/interval))
            (ev/give reply (outcome :data))) [(admission :id) (packet :reply)] done))
          (put waiting waiter done))
        (= :failure (packet :kind))
        (do (set failure (packet :error))
          (store/append s (script :id) "diagnostic" {:error failure :text (failure :message)}))
        (= :publish (packet :kind))
        (ev/give (packet :reply) (try
          (do
            (when failure (error failure))
            {:value (store/publish s (packet :bytes) revision (packet :aliases))})
          ([err fiber] {:error (schema/diagnostic "PublicationFailed" err fiber)})))
        (= :progress (packet :kind))
        (store/advance s {:started true :form (packet :form)})
        (= :return (packet :kind))
        (store/append s (script :id) "return" (schema/project packet [:kind] true) (string "return:" (script :id)))
        (= :output (packet :kind))
        (store/append s (script :id) "output" (schema/project packet [:kind] true))))
    (def returned (store/outcome s (script :id)))
    (assert (or returned failure) "VM exited without a root outcome")
    (if failure (merge (get returned :data {}) {:state "failed" :error failure :text (failure :message)}) (returned :data))))
