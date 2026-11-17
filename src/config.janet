(import pa)
(import spork/json :as json)
(import spork/path :as path)
(import spork/utf8 :as utf8)

(def directory (path/abspath (path/join (path/dirname (dyn :source)) "..")))
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

(def defaults
  {:world "main" :worlds ["main"] :input "text" :operation "submit" :conversation "default" :initialize false :inspect false :rewind false
   :vm {:user {:bindings ["*"] :imports {} :fs {} :http {} :processes {} :modules {}}
        :agent {:bindings ["*"] :imports {} :fs {} :http {} :processes {} :modules {}}}
   :instructions (path/join directory "zinc.md") :temporary false :queue true :publish ["reasoning" "response" "tool-call" "tool-result"] :arguments {}
   :providers {} :chat {:thinking "default"} :rerank {} :summary {:thinking "default" :bytes 512 :max-bytes 4096} :web-search false :rounds 128 :parallel 4 :tasks 4096 :depth 8
   :seconds 120 :run-seconds 0 :pending 32 :http-ms 600000 :source-bytes 1048576 :image-bytes 4194304
   :response-bytes 8388608 :world-bytes 16777216 :journal-bytes 67108864 :history-records 1024
   :context-percent 50 :page-bytes 4096 :memory-retrieval true :language "en"
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

(def diagnostic pa/diagnostic)

(defn selected? [name selections]
  (some |(or (= $ "*") (= $ name)
    (and (string/has-suffix? "/*" $) (string/has-prefix? (string/slice $ 0 -1) name))) selections))

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
  (tabseq [[name spec] :pairs result :when (selected? name (settings :bindings))] name spec))
(defn expose [c role]
  (def registry (get-in c [:registry role]))
  {:settings (tabseq [k :in [:chat :rerank :summary :rounds :context-percent :score :queue :temporary]] k (c k))
   :resources (tabseq [k :in [:fs :http :processes]] k (map string (keys (get-in c [:vm role k]))))
   :bindings (sorted (keys registry))
   :documentation (string/join (seq [[name spec] :in (sorted (pairs registry)) :when (spec :doc)] (spec :doc)) "\n")})

(defn parse [supplied handle runtime]
  (def allowed (array/concat @[:store :directory :context-quota :output :request :path :from :memory :work] (keys defaults)))
  (each k (keys supplied) (assert (index-of k allowed) (string "unknown setting " k)))
  (def c (json/decode (encode (merge defaults supplied)) true true))
  (each role [:chat :rerank :summary] (put c role (merge (defaults role) (c role))))
  (each k [:store :directory :instructions :cygnet :stopwords]
    (assert (and (string? (c k)) (path/abspath? (c k))) (string "absolute path required: " k)))
  (each [k v] (pairs defaults)
    (when (or (boolean? v) (number? v))
      (assert (= (type v) (type (c k))) (string "invalid setting " k))
      (when (number? v) (assert (and (< (math/abs (c k)) math/inf) (or (= k :score) (>= (c k) 0))) "invalid numeric setting"))))
  (each k [:parallel :tasks :depth :pending :response-bytes :world-bytes :journal-bytes :history-records :page-bytes]
    (assert (and (int? (c k)) (> (c k) 0)) (string "positive integer required: " k)))
  (assert (and (<= 1 (c :context-percent) 100) (index-of (c :world) (c :worlds))) "invalid context/world selection")
  (assert (index-of (c :input) ["text" "code" "json"]) "invalid input encoding")
  (each k [:worlds :publish] (assert (and (indexed? (c k)) (every? (map string? (c k)))) "expected an array of strings"))
  (each k [:vm :providers :chat :rerank :summary :arguments] (assert (dictionary? (c k)) "expected a configuration object"))
  (each role (keys (c :vm)) (assert (index-of role [:user :agent]) "unknown VM role"))
  (each role [:user :agent]
    (def settings (merge (get-in defaults [:vm role]) (get-in c [:vm role] {})))
    (put-in c [:vm role] settings)
    (each k (keys settings) (assert (index-of k [:bindings :imports :fs :http :processes :modules]) "unknown VM setting"))
    (assert (and (indexed? (settings :bindings)) (every? (map string? (settings :bindings)))) "invalid VM bindings")
    (each k [:imports :fs :http :processes :modules] (assert (dictionary? (settings k)) "invalid VM resources"))
    (each [name value] (pairs (settings :imports))
      (assert (not= name :output) "output is private caller plumbing")
      (assert (case name :discord (or (= true value) (= false value) (dictionary? value))
        :exa (boolean? value) :tinyfish (boolean? value)
        (and (dictionary? value) (string? (value :policy)) (string? (value :documentation)))) "invalid import declaration"))
    (each resource (values (settings :fs)) (assert (path/abspath? (resource :root)) "filesystem grant root must be absolute"))
    (each endpoint (values (settings :http))
      (assert (and (string? (endpoint :url)) (string/has-suffix? "/" (endpoint :url)) (indexed? (endpoint :methods))) "invalid HTTP grant")))
  (each [name provider] (pairs (c :providers))
    (assert (and (string? (provider :url)) (index-of (get provider :protocol "chat-completions") ["chat-completions" "responses"])
      (not (and (provider :token-env) (provider :credential-command)))) "invalid provider")
    (when (provider :credential-command) (assert (path/abspath? ((provider :credential-command) 0)) "credential executable must be absolute"))
    (each key (keys (get provider :parameters {}))
      (assert (not (index-of key [:model :messages :input :instructions :tools :tool_choice :stream :stream_options :store :include
        :max_tokens :max_completion_tokens :max_output_tokens :parallel_tool_calls :reasoning :reasoning_effort :prompt_cache_key])) "managed provider parameter")))
  (each role [:chat :rerank :summary]
    (each key (keys (c role)) (assert (index-of key (case role :summary [:model :thinking :bytes :max-bytes] :rerank [:model] [:model :thinking])) "unknown model setting")))
  (each key [:bytes :max-bytes] (assert (and (int? (get-in c [:summary key])) (> (get-in c [:summary key]) 0)) "invalid summary quota"))
  (assert (<= (get-in c [:summary :bytes]) (get-in c [:summary :max-bytes])) "invalid summary quota range")
  (merge c {:handle handle :runtime runtime}))

(def options
  {"chat.model" {:type "string" :description "Chat model"}
   "chat.thinking" {:type "string" :description "Chat reasoning effort"}
   "rerank.model" {:type "string" :description "Rerank model"}
   "summary.model" {:type "string" :description "Summary model"}
   "summary.thinking" {:type "string" :description "Summary reasoning effort"}
   "rounds" {:type "integer" :minimum 1 :description "Maximum model rounds"}
   "context-percent" {:type "integer" :minimum 1 :maximum 100 :description "Shared memory allowance"}
   "path" {:type "integer" :description "Continue an exact path"}
   "from" {:type "integer" :description "Fork an exact event"}
   "memory" {:type "integer" :description "Select exact memory"}
   "queue" {:type "boolean" :description "Queue on a busy path"}
   "temporary" {:type "boolean" :description "Use RAM only"}})
(def commands
  [{:name "agent" :description "Invoke or change personal settings"}
   {:name "reset" :description "Discard personal settings"}
   {:name "models" :description "List available models" :options [{:name "role" :type "string" :description "chat or rerank"}]}
   {:name "world-point" :description "Show the selected event"}
   {:name "world-view" :description "Render world source" :reference true}
   {:name "world-inspect" :description "Inspect evidence" :reference true}
   {:name "render" :description "Inspect the assembled model prompt" :reference true}
   {:name "memory-expand" :description "Read original evidence" :reference true :node true}
   {:name "memory-summarize" :description "Install a subtree summary" :reference true :node true
    :options [{:name "text" :type "string" :description "Optional replacement summary"}]}
   {:name "memory-invalidate" :description "Invalidate a subtree summary" :reference true :node true}])
(defn discover [c]
  {:schema options :commands commands :imports
    (reduce (fn [result role]
      (each [name spec] (pairs (get-in c [:vm role :imports])) (when spec
        (when (and (has-key? result name) (not= true (result name)) (not= true spec))
          (assert (= (encode (result name)) (encode spec)) "conflicting import declarations"))
        (unless (and (= true spec) (dictionary? (result name))) (put result name spec)))) result) @{} [:user :agent])})

(defn authorize [current saved]
  (each k [:store :directory :handle :runtime :instructions]
    (assert (= (current k) (saved k)) {:code "AuthorityChanged" :message (string "saved " k " changed")}))
  (each [name spec] (pairs (saved :providers))
    (assert (= (encode spec) (encode (get-in current [:providers name]))) "provider changed or revoked"))
  (def vm (merge (saved :vm)))
  (each role [:user :agent]
    (each k [:imports :fs :http :processes :modules]
      (each [name spec] (pairs (get-in saved [:vm role k]))
        (assert (= (encode spec) (encode (get-in current [:vm role k name]))) "VM resource changed or revoked")))
    (put vm role (merge (get-in saved [:vm role])
      {:bindings (filter |(selected? $ (get-in current [:vm role :bindings])) (keys (get-in saved [:registry role])))})))
  (each name (saved :worlds) (assert (index-of name (current :worlds)) "world grant revoked"))
  (merge saved {:vm vm :registry (tabseq [role :in [:user :agent]] role
      (tabseq [[name spec] :pairs (get-in saved [:registry role]) :when (selected? name (get-in vm [role :bindings]))] name spec))
    :inspect (and (saved :inspect) (current :inspect)) :rewind (and (saved :rewind) (current :rewind))
    :memory-retrieval (and (saved :memory-retrieval) (current :memory-retrieval))
    :score (max (saved :score) (current :score))}
    (tabseq [k :in [:parallel :tasks :depth :pending :response-bytes :world-bytes :journal-bytes :history-records]]
      k (min (saved k) (current k)))))
