(import spork/json :as json)
(import spork/path :as path)
(import spork/base64 :as base64)
(import spork/utf8 :as utf8)

(def resident
  {:file {:type :string :absolute true :description "World entry source"}
   :socket {:type :string :absolute true :description "Resident Unix socket"}
   :seconds {:type :number :minimum 0.001 :description "Hard bootstrap/evaluation wall-clock deadline"}
   :forbid {:type :array :items :string :description "Forbidden Janet native capabilities"
            :choices ["all" "asm" "chroot" "compile" "env" "exit" "ffi" "ffi-define" "ffi-jit" "ffi-use"
                      "fs" "fs-read" "fs-temp" "fs-write" "hrtime" "locale" "modules" "net" "net-connect"
                      "net-listen" "sandbox" "signal" "subprocess" "threads" "unmarshal"]}})

(def relay
  {:socket {:type :string :absolute true :description "Resident Unix socket"}})

(def git
  {:repo {:type :string :absolute true :description "Granted repository"}
   :executable {:type :string :absolute true :description "Git executable"}
   :seconds {:type :number :minimum 0.001 :description "Execution deadline"}})

(defn validate [schema bytes &opt discovery]
  (def supplied (json/decode bytes true true))
  (assert (dictionary? supplied) "configuration must be an object")
  (def config @{})
  (each key (keys supplied) (assert (has-key? schema key) (string "unknown configuration field " key)))
  (each [key field] (pairs schema)
    (when (has-key? field :default) (put config key (field :default))))
  (merge-into config supplied)
  (each [key field] (pairs schema)
    (assert (or discovery (has-key? config key) (field :optional)) (string "required setting " key))
    (when (has-key? config key)
      (def value (config key))
      (assert (case (field :type)
                :string (and (string? value) (> (length value) 0) (not (string/find "\0" value)))
                :integer (int? value)
                :number (and (number? value) (< (math/abs value) math/inf))
                :boolean (boolean? value)
                :array (indexed? value)
                :dictionary (dictionary? value)
                false) (string "invalid setting " key))
      (when (field :minimum) (assert (>= value (field :minimum)) "setting below minimum"))
      (when (field :maximum) (assert (<= value (field :maximum)) "setting above maximum"))
      (when (and (field :absolute) (not discovery)) (assert (path/abspath? value) "absolute path required"))
      (when (field :fields)
        (put config key (validate (field :fields) (json/encode value) discovery)))
      (when (field :values)
        (each [name item] (pairs value)
          (validate {name (field :values)} (json/encode {name item}) discovery)))
      (if (= :array (field :type))
        (each item value
          (when (= :string (field :items))
            (assert (and (string? item) (> (length item) 0) (not (string/find "\0" item))) "invalid array item"))
          (when (field :choices) (assert (index-of item (field :choices)) "invalid setting choice")))
        (when (field :choices) (assert (index-of value (field :choices)) "invalid setting choice")))))
  config)

(defn configuration [schema bytes imports &opt discovery]
  (def config (validate schema bytes discovery))
  (each [name members] (pairs (config :imports))
    (assert (and (> (length (string name)) 0) (not (string/find "\0" (string name)))
                 (not (index-of (string name) ["self" "pa"]))
                 (indexed? members) (> (length members) 0)) "invalid Import grant")
    (each member members
      (assert (and (string? member) (> (length member) 0) (not (string/find "\0" member))) "invalid Import member")))
  (assert (<= (config :summary-quota) (config :context-quota)) "summary quota exceeds context quota")
  (unless discovery
    (each name (keys (config :imports))
      (assert (index-of (string name) imports) "Import grant unavailable"))
    (when (config :repl)
      (each [name members] [[:repl ["eval" "document"]] [:ledger ["receipt"]]]
        (each member members
          (assert (index-of member (get-in config [:imports name] [])) "resident evaluator grants required"))))
    (each [name provider] (pairs (config :providers))
      (assert (index-of name [:llama :openrouter]) "unsupported provider")
      (assert (peg/match ~(* (choice "https://" "http://") (some (if-not (set "?#@ \t\r\n") 1)) -1) (provider :url)) "invalid provider base"))
    (when (config :search)
      (each key [:cygnet :stopwords]
        (assert (and (config key) (= :file (os/stat (config key) :mode))) "semantic retrieval requires provisioned Cygnet and stopword files"))))
  config)

(defn authorize [schema current saved]
  (each key (keys saved) (assert (has-key? schema key) "unsupported saved configuration"))
  (each key [:actor :store :world]
    (assert (= (current key) (saved key)) "saved identity/location differs"))
  (assert (or (not (saved :repl)) (current :repl)) "saved evaluator revoked")
  (each key [:visibility :capabilities]
    (each value (saved key) (assert (index-of value (current key)) "saved grant revoked")))
  (each [name members] (pairs (saved :imports))
    (each member members (assert (index-of member (get-in current [:imports name] [])) "saved Import member revoked")))
  (each [name provider] (pairs (saved :providers))
    (def granted (get-in current [:providers name]))
    (assert (and granted (if (provider :identity) (= (provider :identity) (granted :identity)) (= (provider :url) (granted :url)))) "saved provider revoked"))
  (def config (merge @{} saved {:search (and (saved :search) (current :search))
                               :providers (tabseq [name :in (keys (saved :providers))]
                                                name (get-in current [:providers name]))}))
  (each [key field] (pairs schema)
    (when (= :integer (field :type))
      (put config key
           (if (and (= key :output) (= 0 (min (saved key) (current key))))
             (max (saved key) (current key))
             (min (saved key) (current key))))))
  config)

(defn request [bytes fields]
  (assert (utf8/is-valid? bytes) "invalid request bytes")
  (def value (json/decode bytes true true))
  (assert (dictionary? value) "request must be an object")
  (each key (keys value) (assert (index-of key fields) "unknown request field"))
  (each key [:parent :after :run :task :generation]
    (when (has-key? value key)
      (assert (and (int? (value key)) (<= 0 (value key) 9007199254740991)) "invalid coordinate")))
  (when (has-key? value :text)
    (assert (and (string? (value :text)) (> (length (value :text)) 0)) "invalid question"))
  (when (has-key? value :code)
    (assert (and (string? (value :code)) (> (length (value :code)) 0)) "invalid Janet source"))
  (each key [:request :capability :owner :token]
    (when (has-key? value key)
      (assert (and (string? (value key)) (<= 1 (length (value key)) 256)) "invalid request name")))
  (when (has-key? value :persist) (assert (boolean? (value :persist)) "invalid persistence flag"))
  (when (has-key? value :arguments) (assert (indexed? (value :arguments)) "arguments must be an array"))
  (when (has-key? value :memory_range)
    (def range (value :memory_range))
    (assert (dictionary? range) "invalid memory range")
    (each [key id] (pairs range)
      (assert (and (index-of key [:start :end]) (int? id) (<= 0 id 9007199254740991)) "invalid memory range"))
    (assert (or (= 0 (length range)) (and (= 2 (length range)) (<= (range :start) (range :end)) (= (= 0 (range :start)) (= 0 (range :end))))) "memory range requires inclusive start and end"))
  (when (has-key? value :images)
    (assert (and (indexed? (value :images)) (<= (length (value :images)) 4)) "invalid images")
    (each image (value :images)
      (assert (and (dictionary? image) (deep= (sorted (keys image)) (sorted [:type :data])) (index-of (image :type) ["image/png" "image/jpeg" "image/webp"]) (string? (image :data))) "invalid image")
      (def bytes (base64/decode (image :data)))
      (assert (= (base64/encode bytes) (image :data)) "noncanonical image data")))
  value)
