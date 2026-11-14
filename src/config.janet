(import spork/json :as json)
(import spork/path :as path)
(import spork/utf8 :as utf8)

(def directory (path/abspath (path/join (path/dirname (dyn :source)) "..")))
(def bindings
  {"async" {:arity [1 1] :class "machine" :doc "(async thunk) starts a managed local task; returns a task reference."}
   "await" {:arity [1 1] :class "machine" :doc "(await reference) suspends this task until a local task or request completes; returns its value or raises its failure."}
   "sleep" {:arity [1 1] :class "local" :doc "(sleep seconds) durably waits until a recorded deadline."}
   "self" {:arity [1 1] :class "local" :doc "(self request) starts work and returns {:path p :request r}. Supply :text or :code. :path continues a path; :from forks a point; :memory selects a point's evidence or an array of point/source/summary references. :queue true orders work on busy paths or queued siblings."}
   "self/result" {:arity [1 1] :class "local" :doc "(self/result reference) returns the request receipt, or nil while pending."}
   "self/cancel" {:arity [1 1] :class "local" :doc "(self/cancel reference) cancels unfinished work and descendants; external effects are not undone."}
   "world/point" {:arity [0 0] :class "local" :doc "(world/point) returns this path's committed checkpoint."}
   "world/view" {:arity [0 0] :class "machine" :doc "(world/view) renders recorded Janet forms in order; it is not a heap export."}
   "world/rewind" {:arity [1 1] :class "local" :doc "(world/rewind point) publishes that checkpoint into this path's world. Existing work stays pinned; effects are not undone. To branch execution, use self with :from."}
   "world/remove" {:arity [1 1] :class "machine" :doc "(world/remove symbol) removes a local world binding."}
   "memory/expand" {:arity [1 1] :class "local" :doc "(memory/expand reference) returns original accessible source records without generation."}
   "memory/invalidate" {:arity [1 1] :class "local" :doc "(memory/invalidate summary) invalidates that summary and dependent representations in this path; returns true when changed."}
   "memory/summarize" {:arity [1 1] :class "managed" :doc "(memory/summarize {:point optional-point :text optional-summary}) saves or generates a summary within its subtree byte budget; it must compact its input by at least half."}
   "memory/plan" {:arity [2 3] :class "local" :private true}
   "memory/save" {:arity [2 2] :class "local" :private true}
   "memory/finish" {:arity [2 2] :class "local" :private true}
   "memory/record" {:arity [1 1] :class "local" :private true}
   "presentation/result" {:arity [1 1] :class "machine" :private true}
   "presentation/tool" {:arity [2 2] :class "local" :private true}
   "model/chat" {:arity [1 1] :class "external" :private true}
   "model/rerank" {:arity [1 1] :class "external" :private true}
   "time/now" {:arity [0 0] :class "local" :doc "(time/now) records the current Unix time."}
   "random/bytes" {:arity [1 1] :class "local" :doc "(random/bytes count) records random bytes as hexadecimal text."}
   "fs/list" {:arity [2 2] :class "external" :doc "(fs/list grant relative-path) lists a granted directory; no absolute paths, traversal, or links."}
   "fs/read" {:arity [2 2] :class "external" :doc "(fs/read grant relative-path) reads bounded UTF-8 text."}
   "fs/write" {:arity [3 3] :class "external" :doc "(fs/write grant relative-path text) writes bounded UTF-8 text."}
   "http/request" {:arity [4 4] :class "external" :doc "(http/request grant method segments body) calls a granted HTTP endpoint."}
   "process/run" {:arity [1 1] :class "external" :doc "(process/run grant) executes granted argv/env."}})

(def defaults
  {:world "main" :worlds ["main"] :bindings ["*"] :accept ["text"] :inspect false :rewind false
   :instructions (path/join directory "zinc.md") :ephemeral false :queue true :fs {} :http {} :processes {} :modules {}
   :providers {} :thinking "default" :summary {} :web-search false :rounds 128 :parallel 4 :tasks 4096 :depth 8
   :seconds 120 :run-seconds 0 :pending 32 :http-ms 600000 :source-bytes 1048576 :image-bytes 4194304
   :response-bytes 8388608 :world-bytes 16777216 :journal-bytes 67108864 :history-records 1024
   :context-percent 50 :summary-bytes 512 :summary-max-bytes 4096 :page-bytes 4096 :memory-retrieval true :language "en"
   :terms 64 :candidates 16 :expansion-depth 1 :expansion-nodes 2048 :score 0
   :cygnet (path/join directory "build/assets/cygnet.db")
   :stopwords (path/join directory "build/assets/stopwords.json")
   :cygnet-source "aae2cdb1418c1435558584a91181e1cb94459f2506c16f2be4b00e81428deaff"})

(defn encode [value &opt seen]
  (default seen @{})
  (when (or (dictionary? value) (indexed? value))
    (assert (not (seen value)) "JSON values cannot contain cycles") (put seen value true))
  (defer (when (or (dictionary? value) (indexed? value)) (put seen value nil))
    (cond
      (dictionary? value) (string "{" (string/join (map (fn [[k v]]
        (assert (or (string? k) (keyword? k)) "JSON keys must be text")
        (string (encode (string k) seen) ":" (encode v seen)))
        (sorted (pairs value) |(< (string ($0 0)) (string ($1 0))))) ",") "}")
      (indexed? value) (string "[" (string/join (map |(encode $ seen) value) ",") "]")
      (do (when (string? value) (assert (utf8/is-valid? value) "JSON strings must be UTF-8"))
          (assert (or (nil? value) (= :null value) (string? value) (boolean? value)
        (and (number? value) (< (math/abs value) math/inf))) "value is not JSON data") (string (json/encode value))))))

(defn diagnostic [err &opt fiber]
  (def d (merge (if (and (dictionary? err) (string? (err :code)) (string? (err :message)))
    (tabseq [k :in [:code :message :detail :context] :when (has-key? err k)] k (err k))
    {:code "ExecutionFailed" :message (string err)})))
  (when (and fiber (not (d :detail)))
    (def trace @"") (with-dyns [:err trace] (debug/stacktrace fiber)) (put d :detail (string trace))) d)

(defn selected? [name selections]
  (some |(or (= $ "*") (= $ name)
    (and (string/has-suffix? "/*" $) (string/has-prefix? (string/slice $ 0 -2) name))) selections))

(defn registry [c imports]
  (def result (merge bindings)) (def native (make-env))
  (each [name documentation] (pairs imports)
    (assert (and (not (has-key? result (string name))) (not (native (symbol name)))
      (not (index-of (string name) ["input" "settings" "resources"]))) "binding collision")
    (put result (string name) {:class "external" :arity [1 1] :import true :doc documentation}))
  (each [name spec] (pairs (c :modules))
    (assert (and (not (has-key? result (string name))) (not (native (symbol name)))
      (not (index-of (string name) ["input" "settings" "resources"]))) "binding collision")
    (assert (and (string? (spec :module)) (string? (spec :export)) (string? (spec :doc))) "invalid module effect")
    (put result (string name) {:class "external" :module spec :doc (spec :doc)}))
  (tabseq [[name spec] :pairs result :when (or (spec :private) (selected? name (c :bindings)))] name spec))

(defn parse [supplied handle profile runtime]
  (def allowed (array/concat @[:store :directory :chat :rerank :context-quota :output] (keys defaults)))
  (each k (keys supplied) (assert (index-of k allowed) (string "unknown setting " k)))
  (def c (json/decode (encode (merge defaults supplied)) true true))
  (each k [:store :directory :instructions :cygnet :stopwords]
    (assert (and (string? (c k)) (path/abspath? (c k))) (string "absolute path required: " k)))
  (each [k v] (pairs defaults)
    (when (or (boolean? v) (number? v))
      (assert (= (type v) (type (c k))) (string "invalid setting " k))
      (when (number? v) (assert (and (< (math/abs (c k)) math/inf) (or (= k :score) (>= (c k) 0))) "invalid numeric setting"))))
  (each k [:parallel :tasks :depth :pending :response-bytes :world-bytes :journal-bytes :history-records :page-bytes :summary-bytes :summary-max-bytes]
    (assert (and (int? (c k)) (> (c k) 0)) (string "positive integer required: " k)))
  (assert (and (<= 1 (c :context-percent) 100) (index-of (c :world) (c :worlds))) "invalid context/world selection")
  (each kind (c :accept) (assert (index-of kind ["text" "code"]) "invalid input kind"))
  (each k [:worlds :bindings :accept] (assert (and (indexed? (c k)) (every? (map string? (c k)))) "expected an array of strings"))
  (each k [:fs :http :processes :modules :providers :summary] (assert (dictionary? (c k)) "expected a configuration object"))
  (each [name provider] (pairs (c :providers))
    (assert (and (string? (provider :url)) (index-of (get provider :protocol "chat-completions") ["chat-completions" "responses"])
      (not (and (provider :token-env) (provider :credential-command)))) "invalid provider")
    (when (provider :credential-command) (assert (path/abspath? ((provider :credential-command) 0)) "credential executable must be absolute"))
    (each key (keys (get provider :parameters {}))
      (assert (not (index-of key [:model :messages :input :instructions :tools :tool_choice :stream :stream_options :store :include
        :max_tokens :max_completion_tokens :max_output_tokens :parallel_tool_calls :reasoning :reasoning_effort :prompt_cache_key])) "managed provider parameter")))
  (each [name resource] (pairs (c :fs)) (assert (path/abspath? (resource :root)) "filesystem grant root must be absolute"))
  (each [name endpoint] (pairs (c :http)) (assert (and (string? (endpoint :url)) (string/has-suffix? "/" (endpoint :url))) "HTTP grant base must end in /")
    (assert (indexed? (endpoint :methods)) "HTTP grant needs explicit methods"))
  (merge c {:handle handle :profile profile :runtime runtime}))

(defn authorize [current saved]
  (each k [:store :directory :handle :profile :runtime :instructions :instructions-text :ephemeral]
    (assert (= (current k) (saved k)) {:code "AuthorityChanged" :message (string "saved " k " changed")}))
  (each k [:fs :http :processes :modules :providers]
    (each [name spec] (pairs (saved k))
      (assert (= (encode spec) (encode (get-in current [k name])))
        {:code "AuthorityChanged" :message (string "resource changed or revoked: " k "/" name)})))
  (each name (saved :worlds) (assert (index-of name (current :worlds)) "world grant revoked"))
  (merge saved {:bindings (filter |(selected? $ (current :bindings)) (saved :granted))
    :granted (filter |(selected? $ (current :bindings)) (saved :granted))
    :inspect (and (saved :inspect) (current :inspect)) :rewind (and (saved :rewind) (current :rewind))
    :memory-retrieval (and (saved :memory-retrieval) (current :memory-retrieval))
    :score (max (saved :score) (current :score))}
    (tabseq [k :in [:parallel :tasks :depth :pending :response-bytes :world-bytes :journal-bytes :history-records :summary-bytes :summary-max-bytes]]
      k (min (saved k) (current k)))))

(def parameters
  [{:name "chat" :type "string" :description "Chat model" :autocomplete "models"}
   {:name "thinking" :type "string" :description "Reasoning effort" :choices ["default" "none" "minimal" "low" "medium" "high" "xhigh" "max"]}
   {:name "rounds" :type "integer" :description "Maximum model rounds" :minimum 1}
   {:name "queue" :type "boolean" :description "Queue behind earlier work"}
   {:name "path" :type "integer" :minimum 1 :description "Continue this path"}
   {:name "from" :type "integer" :minimum 1 :description "Fork this immutable point"}
   {:name "memory" :type "integer" :minimum 1 :description "Use this point's memory"}])

(def commands
  [{:name "world-point" :description "Show the selected checkpoint" :parameters []}
   {:name "world-view" :description "Render recorded Janet source" :parameters []}
   {:name "world-inspect" :description "Read an exact execution record" :parameters [{:name "reference" :type "integer" :minimum 1 :description "Record reference"}]}
   {:name "memory-expand" :description "Read original evidence" :parameters [{:name "reference" :type "integer" :minimum 1 :description "Point, source, or summary reference"}]}
   {:name "models" :description "List available models" :parameters [{:name "role" :type "string" :description "Model role" :choices ["chat" "rerank"]}]}])
