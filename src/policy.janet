(import pa)
(import spork/json :as json)
(import spork/path :as path)
(import spork/utf8 :as utf8)

(def directory (path/abspath (path/join (path/dirname (dyn :source)) "..")))
(def defaults
  {:world "main" :worlds ["main"] :input "text" :operation "submit" :conversation "default" :initialize false :inspect false :rewind false :profile false
   :vm {:user {:bindings ["*"] :imports {} :fs {} :http {} :processes {} :modules {}}
        :agent {:bindings ["*"] :imports {} :fs {} :http {} :processes {} :modules {}}}
   :instructions (path/join directory "zinc.md") :temporary false :queue false :publish ["reasoning" "response" "tool-call" "tool-result" "diagnostic"] :arguments {}
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

(def model-field {:type "string" :minLength 1 :description "Provider:model reference"})
(def thinking {:type "string" :minLength 1 :description "Reasoning effort"})
(def role {:type "object" :properties {:model model-field :thinking thinking}})
(def schema {:type "object" :properties
  {:chat role :summary role :rerank {:type "object" :properties {:model model-field}}
   :rounds {:type "integer" :minimum 1 :description "Maximum model rounds"}
   :context-percent {:type "integer" :minimum 1 :maximum 100 :description "Shared memory allowance"}
   :path {:type "integer" :description "Continue an exact path"} :from {:type "integer" :description "Fork an exact event"}
   :memory {:type "integer" :description "Select exact memory"} :queue {:type "boolean" :description "Queue on a busy path"}
   :temporary {:type "boolean" :description "Use RAM only"}}})
(defn validate [field value]
  (assert (case (field :type)
    "object" (and (dictionary? value) (do (each [k child] (pairs (field :properties)) (when (has-key? value k) (validate child (value k)))) true))
    "string" (and (string? value) (>= (length value) (get field :minLength 0)))
    "integer" (and (int? value) (<= (get field :minimum (- math/inf)) value (get field :maximum math/inf)))
    "boolean" (boolean? value)) (string "invalid " (field :description))))
(defn parse [supplied handle runtime]
  (def allowed (array/concat @[:store :directory :context-quota :output :request :path :from :memory :work :scope] (keys defaults)))
  (each k (keys supplied) (assert (index-of k allowed) (string "unknown setting " k)))
  (def c (json/decode (encode (merge defaults supplied)) true true))
  (each role [:chat :rerank :summary] (put c role (merge (defaults role) (c role))))
  (validate schema c)
  (assert (not (and (c :path) (c :from))) "path and from are mutually exclusive")
  (each k [:store :directory :instructions :cygnet :stopwords]
    (assert (and (string? (c k)) (path/abspath? (c k))) (string "absolute path required: " k)))
  (each [k v] (pairs defaults)
    (when (and (not (has-key? (schema :properties) k)) (or (boolean? v) (number? v)))
      (assert (= (type v) (type (c k))) (string "invalid setting " k))
      (when (number? v) (assert (and (< (math/abs (c k)) math/inf) (or (= k :score) (>= (c k) 0))) "invalid numeric setting"))))
  (each k [:parallel :tasks :depth :pending :response-bytes :world-bytes :journal-bytes :history-records :page-bytes]
    (assert (and (int? (c k)) (> (c k) 0)) (string "positive integer required: " k)))
  (assert (index-of (c :world) (c :worlds)) "invalid context/world selection")
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
    (each [name grant] (pairs (settings :imports))
      (assert (and (not= :output name) (boolean? grant)) "expected a boolean import grant"))
    (each resource (values (settings :fs)) (assert (path/abspath? (resource :root)) "filesystem grant root must be absolute"))
    (each endpoint (values (settings :http))
      (assert (and (string? (endpoint :url)) (string/has-suffix? "/" (endpoint :url)) (indexed? (endpoint :methods))) "invalid HTTP grant")))
  (each [name provider] (pairs (c :providers))
    (when (= :chatgpt name)
      (assert (= "https://api.openai.com" (get provider :url "https://api.openai.com")) "invalid ChatGPT origin")
      (put provider :url "https://api.openai.com") (put provider :protocol "responses"))
    (assert (and (string? (provider :url)) (dictionary? (provider :models))
      (every? (map |(index-of $ [:url :protocol :credential-command :token-env :headers :models :parameters :cache-key :web-tools]) (keys provider)))
      (not (and (provider :token-env) (provider :credential-command)))) "invalid provider")
    (each spec (values (provider :models)) (assert (dictionary? spec) "expected model properties"))
    (when (provider :credential-command) (assert (path/abspath? ((provider :credential-command) 0)) "credential executable must be absolute"))
    (each key (keys (get provider :parameters {}))
      (assert (not (index-of key [:model :messages :input :instructions :tools :tool_choice :stream :stream_options :store :include
        :max_tokens :max_completion_tokens :max_output_tokens :parallel_tool_calls :reasoning :reasoning_effort :prompt_cache_key])) "managed provider parameter")))
  (each role [:chat :rerank :summary]
    (each key (keys (c role)) (assert (index-of key (case role :summary [:model :thinking :bytes :max-bytes] :rerank [:model] [:model :thinking])) "unknown model setting")))
  (each key [:bytes :max-bytes] (assert (and (int? (get-in c [:summary key])) (> (get-in c [:summary key]) 0)) "invalid summary quota"))
  (assert (<= (get-in c [:summary :bytes]) (get-in c [:summary :max-bytes])) "invalid summary quota range")
  (merge c {:handle handle :runtime runtime}))

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
