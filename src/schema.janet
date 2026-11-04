(import spork/path :as path)
(import spork/base64 :as base64)
(import spork/json :as json)

(def fields
  {:store {:type :string :absolute true}
   :world {:type :string :default "main" :visible true}
   :instructions {:type :string :absolute true}
   :identity {:type :string}
   :agent {:type :dictionary :optional true}
   :caller {:type :dictionary :optional true}
   :imports {:type :dictionary :default {}}
   :ephemeral {:type :boolean :default false}
   :inference {:type :boolean :default true}
   :janet {:type :dictionary :optional true
          :fields {:bindings {:type :array :items :string :default ["*"]}
                   :values {:type :array :items :string :default []}
                   :setup {:type :string :absolute true :optional true}
                   :imports {:type :dictionary :default {}
                             :values {:type :dictionary :fields {:module {:type :string} :export {:type :string :optional true}}}}}}
   :fs {:type :dictionary :default {} :public [:root :read :write :description]
        :values {:type :dictionary :fields {:root {:type :string :absolute true} :read {:type :boolean :default true}
                                            :write {:type :boolean :default false} :description {:type :string :optional true}}}}
   :http {:type :dictionary :default {} :public [:url :methods :description]
          :values {:type :dictionary :fields {:url {:type :string} :methods {:type :array :items :string :default ["GET"]
                                                                         :choices ["GET" "HEAD" "POST" "PUT" "PATCH" "DELETE"]}
                                              :description {:type :string :optional true}}}}
   :processes {:type :dictionary :default {} :public [:argv :description]
               :values {:type :dictionary :fields {:argv {:type :array :items :string :minimum 1}
                                                   :env {:type :dictionary :default {} :values {:type :string}}
                                                   :description {:type :string :optional true}}}}
   :providers {:type :dictionary :default {}
               :values {:type :dictionary :fields
                        {:url {:type :string}
                         :protocol {:type :string :default "chat-completions" :choices ["chat-completions" "responses"]}
                         :chat-path {:type :string :default "/v1/chat/completions"}
                         :rerank-path {:type :string :default "/v1/rerank"}
                         :token-env {:type :string :optional true}
                         :credential-command {:type :array :items :string :minimum 1 :optional true}
                         :headers {:type :dictionary :default {} :values {:type :string}}
                         :parameters {:type :dictionary :default {}}
                         :web-tools {:type :array :default []}
                         :cache-key {:type :string :optional true}
                         :catalogue {:type :dictionary :default {} :fields {:chat {:type :string :optional true} :rerank {:type :string :optional true}}}
                         :properties {:type :string :optional true}
                         :models {:type :dictionary :optional true :values {:type :dictionary :fields
                           {:name {:type :string :optional true}
                            :role {:type :string :optional true :choices ["chat" "rerank"]}
                            :context {:type :integer :minimum 2 :optional true}
                            :output {:type :integer :minimum 1 :optional true}
                            :tools {:type :boolean :optional true}
                            :parallel {:type :boolean :optional true}
                            :images {:type :boolean :optional true}
                            :control {:type :string :optional true :choices ["reasoning" "reasoning_effort"]}
                            :efforts {:type :array :items :string :optional true}
                            :reasoning-required {:type :boolean :optional true}
                            :output-field {:type :string :optional true :choices ["max_tokens" "max_completion_tokens" "max_output_tokens" "none"]}}}}}}}
   :chat {:type :string :optional true :visible true :option "chat" :autocomplete "chat" :description "Chat model"}
   :rerank {:type :string :optional true :option "rerank" :autocomplete "rerank" :description "Rerank model"}
   :thinking {:type :string :default "default" :visible true :option "thinking" :description "Reasoning effort"
              :choices ["default" "none" "minimal" "low" "medium" "high" "xhigh" "max"]}
   :web-search {:type :boolean :default false :option "web-search" :description "Permit provider-managed web search"}
   :output {:type :integer :default 0 :minimum 0 :unlimited true}
   :context-quota {:type :integer :optional true :minimum 256}
   :summary-quota {:type :integer :default 512 :minimum 128}
   :tool-quota {:type :integer :default 262144 :minimum 1}
   :task-quota {:type :integer :default 4096 :minimum 1}
   :rounds {:type :integer :default 128 :minimum 1 :option "rounds" :description "Maximum model rounds"}
   :parallel {:type :integer :default 4 :minimum 1}
   :task-depth {:type :integer :default 8 :minimum 1}
   :seconds {:type :integer :default 120 :minimum 0 :unlimited true}
   :run-seconds {:type :integer :default 0 :minimum 0 :unlimited true}
   :lease-seconds {:type :integer :default 30 :minimum 3}
   :http-ms {:type :integer :default 600000 :minimum 0 :unlimited true}
   :journal-bytes {:type :integer :default 67108864 :minimum 4096}
   :source-bytes {:type :integer :default 1048576 :minimum 1}
   :world-bytes {:type :integer :default 16777216 :minimum 1}
   :request-bytes {:type :integer :default 8388608 :minimum 4096}
   :response-bytes {:type :integer :default 8388608 :minimum 4096}
   :image-bytes {:type :integer :default 4194304 :minimum 1}
   :history-records {:type :integer :default 1024 :minimum 1}
   :memory-retrieval {:type :boolean :default true}
   :terms {:type :integer :default 64 :minimum 1}
   :candidates {:type :integer :default 16 :minimum 1}
   :depth {:type :integer :default 1 :minimum 0}
   :expansion-nodes {:type :integer :default 2048 :minimum 1}
   :language {:type :string :default "en"}
   :score {:type :number :default 0 :option "score" :description "Minimum accepted reranking relevance score"}
   :cygnet {:type :string :absolute true :optional true}
   :stopwords {:type :string :absolute true :optional true}
   :cygnet-source {:type :string :default "aae2cdb1418c1435558584a91181e1cb94459f2506c16f2be4b00e81428deaff"}})

(def inputs
  {:text {:type :string} :code {:type :string} :author {:type :string} :at {:type :string}
   :request {:type :string} :memory_range {:type :dictionary} :images {:type :array} :world {:type :string}
   :parent {:type :integer :minimum 0 :option "parent" :description "History attachment event; 0 selects empty history"}
   :persist {:type :boolean :default true :option "persist" :description "Retain work; false uses a temporary RAM session"}})

(defn encode [value &opt seen]
  (default seen @{})
  (when (or (dictionary? value) (indexed? value))
    (assert (not (seen value)) "durable values cannot contain cycles")
    (put seen value true))
  (defer (when (or (dictionary? value) (indexed? value)) (put seen value nil))
    (cond
      (dictionary? value)
      (string "{" (string/join (map (fn [[key item]]
          (assert (or (string? key) (keyword? key)) "JSON keys must be text")
          (string (json/encode (string key)) ":" (encode item seen)))
        (sorted (pairs value) |(< (string ($0 0)) (string ($1 0))))) ",") "}")
      (indexed? value) (string "[" (string/join (map |(encode $ seen) value) ",") "]")
      (do (assert (or (nil? value) (= value :null) (boolean? value) (string? value)
                      (and (number? value) (< (math/abs value) math/inf))) "durable values must be JSON data")
          (string (json/encode value))))))

(defn project [value selected &opt omit]
  (tabseq [[key item] :pairs value :when (if omit (nil? (index-of key selected)) (index-of key selected))] key item))

(defn diagnostic [code err &opt fiber]
  (def value (if (and (dictionary? err) (string? (err :code)) (string? (err :message)))
    (project err [:code :message :detail :context])
    {:code code :message (if (string? err) err (string/format "%n" err))}))
  (if (or (value :detail) (nil? fiber)) value
    (do
      (def trace @"")
      (with-dyns [:err trace] (debug/stacktrace fiber))
      (merge value {:detail (string trace)}))))

(defn validate [schema supplied &opt discovery]
  (assert (dictionary? supplied) "configuration must be an object")
  (def config @{})
  (each key (keys supplied) (assert (has-key? schema key) (string "unknown setting " key)))
  (each [key field] (pairs schema) (when (has-key? field :default) (put config key (field :default))))
  (merge-into config supplied)
  (each [key field] (pairs schema)
    (assert (or discovery (has-key? config key) (field :optional)) (string "required setting " key))
    (when (has-key? config key)
      (def value (config key))
      (assert (case (field :type)
                :string (and (string? value) (> (length value) 0) (not (string/find "\0" value)))
                :integer (int? value) :number (and (number? value) (< (math/abs value) math/inf))
                :boolean (boolean? value) :array (indexed? value) :dictionary (dictionary? value) false)
              (string "invalid setting " key))
      (when (field :minimum) (assert (>= (if (indexed? value) (length value) value) (field :minimum)) "setting below minimum"))
      (when (field :maximum) (assert (<= value (field :maximum)) "setting above maximum"))
      (when (and (field :absolute) (not discovery)) (assert (path/abspath? value) "absolute path required"))
      (when (field :fields) (put config key (validate (field :fields) value discovery)))
      (when (field :values) (put config key (tabseq [[name item] :pairs value] name ((validate {name (field :values)} {name item} discovery) name))))
      (each item (if (= :array (field :type)) value [value])
        (when (= :string (field :items)) (assert (and (string? item) (> (length item) 0) (not (string/find "\0" item))) "invalid array item"))
        (when (field :choices) (assert (index-of item (field :choices)) "invalid setting choice")))))
  config)

(defn select [names selections]
  (sorted (distinct (catseq [selection :in selections]
    (def matches (filter |(or (= selection "*") (= selection $)
      (and (string/has-suffix? "/*" selection) (string/has-prefix? (string/slice selection 0 -2) $))) names))
    (assert (> (length matches) 0) (string "unknown selection: " selection)) matches))))

(defn configuration [supplied &opt discovery]
  (def config (validate fields supplied discovery))
  (when (config :context-quota) (assert (<= (config :summary-quota) (config :context-quota)) "summary quota exceeds context quota"))
  (when (config :agent)
    (assert (not (get-in config [:agent :agent])) "nested execution profiles are not supported")
    (put config :agent (configuration (config :agent) discovery))
    (each key [:store :identity] (assert (= (config key) (get-in config [:agent key])) "agent profile changes instance identity")))
  (when-let [janet (config :janet)]
    (put janet :values (select (seq [[key field] :pairs fields :when (field :visible)] (string key)) (janet :values)))
    (each name (keys (janet :imports))
      (assert (and (peg/match ~(* (some (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")) -1) (string name))
                   (not (index-of name [:core :self :task :fs :http :process :memory :world :zinc]))) "invalid module namespace")))
  (each field [:fs :http :processes]
    (each name (keys (config field))
      (assert (peg/match ~(* (some (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")) -1) (string name)) "invalid resource name")))
  (each [name command] (pairs (config :processes))
    (unless discovery (assert (path/abspath? ((command :argv) 0)) "process executable must be absolute"))
    (each key (keys (command :env)) (assert (not (string/find "=" (string key))) "invalid environment name")))
  (each [name endpoint] (pairs (config :http))
    (assert (and (peg/match ~(* (choice "https://" "http://") (some (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]"))
                               "/" (any (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-~./")) -1) (endpoint :url))
                 (string/has-suffix? "/" (endpoint :url))
                 (not (find |(index-of $ ["." ".."]) (string/split "/" (endpoint :url))))) "invalid HTTP base"))
  (each [name provider] (pairs (config :providers))
    (assert (peg/match ~(* (some (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")) -1) (string name)) "invalid provider name")
    (assert (peg/match ~(* (choice "https://" "http://") (some (if-not (set "?#@ \t\r\n") 1)) -1) (provider :url)) "invalid provider base")
    (assert (not (and (provider :token-env) (provider :credential-command))) "choose one credential source")
    (when (provider :credential-command) (assert (path/abspath? ((provider :credential-command) 0)) "credential executable must be absolute"))
    (each [name value] (pairs (provider :headers))
      (assert (and (peg/match ~(* (some (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")) -1) (string name))
                   (not (string/find "\r" value)) (not (string/find "\n" value))) "invalid provider header"))
    (each suffix (array/concat @[(provider :chat-path) (provider :rerank-path)] (values (provider :catalogue))
                              (if (provider :properties) [(provider :properties)] []))
      (assert (and (string/has-prefix? "/" suffix) (not (string/has-prefix? "//" suffix))
                   (not (string/find "#" suffix)) (not (string/find "\r" suffix)) (not (string/find "\n" suffix))) "invalid provider path"))
    (each key (keys (provider :parameters))
      (assert (not (index-of key [:model :messages :input :instructions :tools :stream :stream_options :store :include
        :max_tokens :max_completion_tokens :max_output_tokens :parallel_tool_calls :reasoning :reasoning_effort :prompt_cache_key])) "managed provider parameter"))
    (each tool (provider :web-tools) (assert (dictionary? tool) "invalid provider web tool"))
    (each [id model] (pairs (get provider :models {}))
      (assert (and (> (length (string id)) 0) (not (string/find "\0" (string id)))) "invalid model ID")
      (unless (get-in provider [:catalogue (keyword (get model :role "chat"))]) (assert (model :role) "static model needs a role"))))
  config)

(defn authorize [current saved]
  (each key [:store :identity :instructions :ephemeral]
    (assert (= (current key) (saved key)) "saved identity/location changed"))
  (each key [:inference :web-search] (assert (or (not (saved key)) (current key)) "saved permission revoked"))
  (assert (or (not (saved :janet)) (current :janet)) "Janet execution revoked")
  (assert (= (get-in saved [:janet :setup]) (get-in current [:janet :setup])) "saved setup changed")
  (each key [:bindings :values]
    (each name (get-in saved [:janet key] [])
      (assert (find |(or (= $ "*") (= $ name)
        (and (string/has-suffix? "/*" $) (string/has-prefix? (string/slice $ 0 -2) name)))
        (get-in current [:janet key])) "saved selection revoked")))
  (each [name spec] (pairs (saved :imports))
    (def granted (get-in current [:imports name]))
    (assert (and granted (= (encode (spec :command)) (encode (granted :command)))
                         (= (encode (spec :exports)) (encode (granted :exports))))
            {:code "AuthorityChanged" :message "saved capability changed" :context {:capability (string name)}}))
  (each field [:fs :http :processes :providers]
    (each [name grant] (pairs (saved field))
      (assert (= (encode grant) (encode (get-in current [field name])))
              {:code "AuthorityChanged" :message "saved resource changed or revoked"
               :context {:field (string field) :resource (string name)}})))
  (each [name module] (pairs (get-in saved [:janet :imports]))
    (assert (= (encode module) (encode (get-in current [:janet :imports name])))
            {:code "AuthorityChanged" :message "saved import changed or revoked" :context {:module (string name)}}))
  (when (saved :agent) (assert (current :agent) "agent profile revoked"))
  (merge saved {:memory-retrieval (and (saved :memory-retrieval) (current :memory-retrieval))
                :score (max (saved :score) (current :score))
                :imports (tabseq [name :in (keys (saved :imports))] name (get-in current [:imports name]))
                :agent (when (saved :agent) (authorize (current :agent) (saved :agent)))}
    (tabseq [[key field] :pairs fields :when (= :integer (field :type)) :when (or (saved key) (current key))]
    key (if (and (field :unlimited) (= 0 (min (get saved key math/inf) (get current key math/inf))))
          (max (saved key) (current key)) (min (get saved key math/inf) (get current key math/inf))))))

(defn request [value selected]
  (assert (dictionary? value) "request must be an object")
  (each key (keys value) (assert (index-of key selected) (string "unknown request field " key)))
  (each key [:text :code :request :author :at :world]
    (when (has-key? value key) (assert (and (string? (value key)) (> (length (value key)) 0) (not (string/find "\0" (value key)))) "invalid request text")))
  (each key [:persist] (when (has-key? value key) (assert (boolean? (value key)) "invalid request flag")))
  (when (value :images)
    (assert (and (indexed? (value :images)) (<= (length (value :images)) 4)) "invalid images")
    (each image (value :images)
      (assert (and (= (tuple/slice (sorted (keys image))) [:data :type]) (index-of (image :type) ["image/png" "image/jpeg" "image/webp"])
                   (string? (image :data))) "invalid image")
      (base64/decode (image :data))))
  value)
