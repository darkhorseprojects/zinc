(import spork/path :as path)
(import spork/base64 :as base64)
(import spork/json :as json)

(defn encode [value]
  (cond
    (dictionary? value)
    (string "{" (string/join (map (fn [[key item]] (string (json/encode (string key)) ":" (encode item)))
                                 (sorted (pairs value) |(< (string ($0 0)) (string ($1 0))))) ",") "}")
    (indexed? value) (string "[" (string/join (map encode value) ",") "]")
    (string (json/encode value))))

(defn project [value fields &opt omit]
  (tabseq [[key item] :pairs value :when (if omit (nil? (index-of key fields)) (index-of key fields))] key item))

(defn validate [schema supplied &opt discovery]
  (assert (dictionary? supplied) "configuration must be an object")
  (def config @{})
  (each key (keys supplied) (assert (has-key? schema key) (string "unknown configuration field " key)))
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
      (when (field :maximum) (assert (<= (if (indexed? value) (length value) value) (field :maximum)) "setting above maximum"))
      (when (and (field :absolute) (not discovery)) (assert (path/abspath? value) "absolute path required"))
      (when (field :fields) (put config key (validate (field :fields) value discovery)))
      (when (field :values)
        (put config key (tabseq [[name item] :in (pairs value)] name ((validate {name (field :values)} {name item} discovery) name))))
      (each item (if (= :array (field :type)) value [value])
        (when (and (= :array (field :type)) (= :string (field :items)))
          (assert (and (string? item) (> (length item) 0) (not (string/find "\0" item))) "invalid array item"))
        (when (field :choices) (assert (index-of item (field :choices)) "invalid setting choice")))))
  config)

(defn select [names selections]
  (sorted (distinct (catseq [selection :in selections]
                      (def matches (filter |(or (= selection "*") (= selection $)
                                                (and (string/has-suffix? "/*" selection)
                                                     (string/has-prefix? (string/slice selection 0 (- (length selection) 1)) $))) names))
                      (assert (> (length matches) 0) (string "unknown selection: " selection))
                      matches))))

(defn configuration [schema supplied &opt discovery]
  (def config (validate schema supplied discovery))
  (when (config :context-quota)
    (assert (<= (config :summary-quota) (config :context-quota)) "summary quota exceeds context quota"))
  (when (config :agent)
    (assert (not (get-in config [:agent :agent])) "nested execution profiles are not supported")
    (put config :agent (configuration schema (config :agent) discovery))
    (each key [:store :world]
      (assert (= (config key) (get-in config [:agent key])) "agent view changes world identity/location")))
  (when-let [janet (config :janet)]
    (put janet :values (select (seq [[key field] :in (pairs schema) :when (field :visible)] (string key)) (janet :values)))
    (each name (keys (janet :imports))
      (assert (and (peg/match ~(* (some (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")) -1) (string name))
                   (not (index-of name [:core :self :pa :fs :http :process :memory :world :zinc]))) "invalid module namespace")))
  (each field [:fs :http :processes]
    (each name (keys (config field))
      (assert (peg/match ~(* (some (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")) -1) (string name)) "invalid resource name")))
  (each [name command] (pairs (config :processes))
    (unless discovery (assert (path/abspath? ((command :argv) 0)) "process executable must be absolute"))
    (each key (keys (command :env)) (assert (not (string/find "=" (string key))) "invalid environment name")))
  (each [name endpoint] (pairs (config :http))
    (def url (endpoint :url))
    (assert (and (peg/match ~(* (choice "https://" "http://")
                                (some (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]"))
                                "/" (any (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-~./")) -1) url)
                 (string/has-suffix? "/" url)
                 (not (find |(index-of $ ["." ".."]) (string/split "/" url)))) "invalid HTTP base"))
  (each [name provider] (pairs (config :providers))
    (assert (peg/match ~(* (some (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")) -1) (string name)) "invalid provider name")
    (assert (peg/match ~(* (choice "https://" "http://") (some (if-not (set "?#@ \t\r\n") 1)) -1) (provider :url)) "invalid provider base")
    (assert (not (and (provider :token-env) (provider :credential-command))) "choose one provider credential source")
    (when (provider :credential-command)
      (assert (path/abspath? ((provider :credential-command) 0)) "credential executable must be absolute"))
    (each [name value] (pairs (provider :headers))
      (assert (and (peg/match ~(* (some (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")) -1) (string name))
                   (not (string/find "\r" value)) (not (string/find "\n" value))) "invalid provider header"))
    (each suffix (array/concat @[(provider :chat-path) (provider :rerank-path)] (values (provider :catalogue))
                              (if (provider :properties) [(provider :properties)] []))
      (assert (and (string/has-prefix? "/" suffix) (not (string/has-prefix? "//" suffix))
                   (not (string/find "#" suffix)) (not (string/find "\r" suffix)) (not (string/find "\n" suffix))) "invalid provider path"))
    (each key (keys (provider :parameters))
      (assert (not (index-of key [:model :messages :input :instructions :tools :stream :stream_options :store :include
                                  :max_tokens :max_completion_tokens :max_output_tokens :parallel_tool_calls :reasoning :reasoning_effort :prompt_cache_key]))
              "provider parameters replace managed request fields"))
    (each tool (provider :web-tools) (assert (dictionary? tool) "invalid provider web tool"))
    (each [id model] (pairs (get provider :models {}))
      (assert (and (> (length (string id)) 0) (not (string/find "\0" (string id)))) "invalid model ID")
      (unless (get-in provider [:catalogue (keyword (get model :role "chat"))])
        (assert (model :role) "static model requires a role"))))
  config)

(defn authorize [schema current saved]
  (each key (keys saved) (assert (has-key? schema key) "unsupported saved configuration"))
  (each key [:store :world :instructions :identity :ephemeral]
    (assert (= (current key) (saved key)) "saved identity/location differs"))
  (each key [:inference :web-search]
    (assert (or (not (saved key)) (current key)) (string "saved permission revoked: " key)))
  (assert (or (not (saved :janet)) (current :janet)) "saved Janet execution revoked")
  (assert (= (get-in saved [:janet :setup]) (get-in current [:janet :setup])) "saved Janet setup changed")
  (each key [:bindings :values]
    (each name (get-in saved [:janet key] [])
      (assert (index-of name (get-in current [:janet key])) "saved Janet selection revoked")))
  (each field [:fs :http :processes]
    (each [name grant] (pairs (saved field))
      (assert (deep= grant (get-in current [field name])) "saved resource changed or revoked")))
  (each [name module] (pairs (get-in saved [:janet :imports] {}))
    (assert (deep= module (get-in current [:janet :imports name])) "saved import changed or revoked"))
  (when (saved :agent) (assert (current :agent) "agent execution view revoked"))
  (each [name provider] (pairs (saved :providers))
    (def granted (get-in current [:providers name]))
    (assert (and granted (deep= provider granted)) "saved provider changed or revoked"))
  (def config (merge saved {:memory-retrieval (and (saved :memory-retrieval) (current :memory-retrieval))
                            :score (max (saved :score) (current :score))
                            :agent (when (saved :agent) (authorize schema (current :agent) (saved :agent)))
                            :providers (tabseq [name :in (keys (saved :providers))] name (get-in current [:providers name]))}))
  (each [key field] (pairs schema)
    (when (and (= :integer (field :type)) (or (saved key) (current key)))
      (put config key
           (if (and (field :unlimited) (= 0 (min (get saved key math/inf) (get current key math/inf))))
             (max (saved key) (current key))
             (min (get saved key math/inf) (get current key math/inf))))))
  config)

(defn data [value]
  (postwalk |(if (dictionary? $) (tabseq [[key item] :in (pairs $)] key item) $) value))

(defn request [value fields]
  (assert (dictionary? value) "request must be an object")
  (each key (keys value) (assert (index-of key fields) "unknown request field"))
  (each key [:text :code]
    (when (has-key? value key) (assert (and (string? (value key)) (> (length (value key)) 0)) "invalid inquiry")))
  (each key [:request :author :at :owner :revision]
    (when (has-key? value key)
      (assert (and (string? (value key)) (<= 1 (length (value key)) 256) (not (string/find "\0" (value key)))) "invalid request name")))
  (each key [:persist :queue]
    (when (has-key? value key) (assert (boolean? (value key)) (string "invalid " key " flag"))))
  (when (has-key? value :images)
    (assert (and (indexed? (value :images)) (<= (length (value :images)) 4)) "invalid images")
    (put value :images (map (fn [image]
                              (assert (and (dictionary? image) (deep= (sorted (keys image)) (sorted [:type :data]))
                                           (index-of (image :type) ["image/png" "image/jpeg" "image/webp"]) (string? (image :data))) "invalid image")
                              {:type (image :type) :bytes (buffer (base64/decode (image :data)))}) (value :images))))
  value)
