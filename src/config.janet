(import spork/json :as json)
(import spork/path :as path)

(def resident
  {:file {:type :string :absolute true :description "World entry source"}
   :socket {:type :string :absolute true :description "Resident Unix socket"}
   :forbid {:type :array :items :string :description "Forbidden Janet native capabilities"
            :choices ["all" "asm" "chroot" "compile" "env" "exit" "ffi" "ffi-define" "ffi-jit" "ffi-use"
                      "fs" "fs-read" "fs-temp" "fs-write" "hrtime" "locale" "modules" "net" "net-connect"
                      "net-listen" "sandbox" "signal" "subprocess" "threads" "unmarshal"]}})

(def relay
  {:socket {:type :string :absolute true :description "Resident Unix socket"}})

(def git
  {:repo {:type :string :absolute true :description "Granted repository"}
   :executable {:type :string :absolute true :description "Git executable"}
   :seconds {:type :number :minimum 0.001 :description "Execution deadline"}
   :response-bytes {:type :integer :minimum 1 :maximum 16777216 :description "Output byte ceiling"}})

(defn validate [schema bytes &opt discovery]
  (assert (<= (length bytes) 65536) "private configuration byte ceiling")
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
