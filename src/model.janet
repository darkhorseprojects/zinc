(import spork/utf8 :as utf8)
(import spork/base64 :as base64)
(import spork/json :as json)
(import ./store)
(import ./schema)
(import ./provider)

(def- tool {:type "function" :function {:name "self"
  :description "Admit a Janet script."
  :parameters {:type "object" :additionalProperties false :required ["code"]
    :properties {:code {:type "string" :minLength 1}}}}})

(defn text [message]
  (def content (message :content))
  (assert (or (nil? content) (string? content) (indexed? content)) "invalid assistant content")
  (string/join (map (fn [text] (assert (and (string? text) (utf8/is-valid? text)) "invalid assistant text") text)
    (if (indexed? content) (seq [part :in content :when (= "text" (part :type))] (part :text))
      [(if (or (nil? content) (= "" content)) (or (message :refusal) "") content)])) "\n"))

(defn estimate [messages &opt reference]
  (+ (sum (map |(if (= reference (get-in $ [:response :model])) (get-in $ [:response :reasoning-tokens] 0) 0) messages))
     (store/estimate (schema/encode (postwalk
       |(if (and (dictionary? $) (= "image_url" ($ :type))) {:type "image_url" :image_url "[provider-dependent image tokens]"} $)
       (map |(schema/project $ [:response] true) messages))))))

(defn catalogue [config role &opt provider-name]
  (assert (index-of role ["chat" "rerank"]) "unsupported model role")
  (def models @[])
  (each name (if provider-name [(keyword provider-name)] (keys (config :providers)))
    (def granted (get-in config [:providers name]))
    (assert granted "provider is not configured")
    (def path (get-in granted [:catalogue (keyword role)]))
    (def records (if path ((provider/request config {:provider (string name)} path) :data)
      (seq [[id model] :pairs (get granted :models {}) :when (= role (model :role))] {:id (string id)})))
    (assert (indexed? records) "invalid model catalogue")
    (def identities @{})
    (each record records
      (assert (and (dictionary? record) (string? (record :id)) (> (length (record :id)) 0)
                   (not (identities (record :id)))) "invalid or duplicate model ID")
      (put identities (record :id) true)
      (def configured (get-in granted [:models (keyword (record :id))]))
      (when (and (or (not (has-key? granted :models)) configured) (= role (get configured :role role)))
        (array/push models (merge record {:ref (string name ":" (record :id))
          :name (get configured :name (get record :name (record :id))) :profile (or configured {})})))))
  (sorted models |(< ($0 :ref) ($1 :ref))))

(defn profile [s reference role]
  (assert (string? reference) (string "configure a " role " model"))
  (def config (s :config))
  (def key [reference role (config :thinking) (config :web-search) (schema/encode (config :providers))])
  (or ((s :profiles) key)
    (do
      (def split (string/find ":" reference))
      (assert split "model reference must be provider:id")
      (def provider-name (string/slice reference 0 split))
      (def id (string/slice reference (+ split 1)))
      (def endpoint (get-in config [:providers (keyword provider-name)]))
      (assert (and (not= "" id) endpoint) "provider is not configured")
      (def ref {:provider provider-name :id id :reference reference})
      (def catalogued (find |(= ($ :id) id) (catalogue config (string role) provider-name)))
      (assert catalogued "exact model is unavailable")
      (def properties (endpoint :properties))
      (def record (if properties
        (provider/request config ref (string/replace-all "{model}"
          (string/join (seq [byte :in (string/bytes id)]
            (if (or (<= 48 byte 57) (<= 65 byte 90) (<= 97 byte 122) (index-of byte [45 46 95 126]))
              (string/from-bytes byte) (string/format "%%%02X" byte)))) properties)) catalogued))
      (def native-context (if properties (get-in record [:default_generation_settings :n_ctx]) (record :context_length)))
      (when properties (assert (and (int? native-context) (> native-context 1)) "invalid properties context capacity"))
      (def parameters (get record :supported_parameters []))
      (def limits (filter identity [native-context (when (= role :chat) (get-in record [:top_provider :context_length])) (get-in catalogued [:profile :context])]))
      (assert (and (> (length limits) 0) (every? (map |(and (int? $) (<= 2 $ 9007199254740991)) limits))) "invalid provider context capacity")
      (def context (min ;limits))
      (def capabilities (merge
        {:tools (if properties (and (get-in record [:chat_template_caps :supports_tools]) (get-in record [:chat_template_caps :supports_tool_calls]))
                  (not (nil? (index-of "tools" parameters))))
         :parallel (if properties (get-in record [:chat_template_caps :supports_parallel_tool_calls]) (not (nil? (index-of "parallel_tool_calls" parameters))))
         :images (if properties (get-in record [:modalities :vision]) (not (nil? (index-of "image" (get-in record [:architecture :input_modalities] [])))))
         :control (if properties (when (get-in record [:chat_template_caps :supports_reasoning_effort]) "reasoning_effort")
                    (cond (index-of "reasoning" parameters) "reasoning" (index-of "reasoning_effort" parameters) "reasoning_effort"))
         :efforts (if properties
                    (let [levels (get-in record [:chat_template_caps :reasoning_effort_levels])]
                      (when (and levels (> (length levels) 0)) levels))
                    (get-in record [:reasoning :supported_efforts]))
         :preserve-reasoning (if properties (get-in record [:chat_template_caps :supports_preserve_reasoning]) true)
         :reasoning-required (get-in record [:reasoning :mandatory])
         :output (when (= role :chat) (get-in record [:top_provider :max_completion_tokens]))
         :output-field (if (= "responses" (endpoint :protocol)) "max_output_tokens" "max_tokens")}
        (catalogued :profile)))
      (def thinking (config :thinking))
      (when (= role :chat)
        (when (= thinking "none") (assert (not (capabilities :reasoning-required)) "model requires reasoning"))
        (unless (index-of thinking ["default" "none"]) (assert (capabilities :control) "thinking effort is unsupported"))
        (when (and (capabilities :efforts) (not (index-of thinking ["default" "none"])))
          (assert (index-of thinking (capabilities :efforts)) (string reference " does not support thinking=" thinking)))
        (when (config :web-search) (assert (> (length (endpoint :web-tools)) 0) "web search is not configured")))
      (when-let [output (capabilities :output)] (assert (and (int? output) (<= 1 output context)) "invalid provider output capacity"))
      (def selected (merge ref capabilities {:context context :protocol (endpoint :protocol)
        :path (endpoint (if (= role :chat) :chat-path :rerank-path))
        :control (capabilities :control)
        :tools (array/concat @[] (if (capabilities :tools) [tool] []) (if (and (= role :chat) (config :web-search)) (endpoint :web-tools) []))}))
      (put (s :profiles) key selected) selected)))

(defn call [s inquiry key &opt profiled]
  (def task (dyn :zinc/task))
  (def config (s :config))
  (def role (get inquiry :role "chat"))
  (assert (index-of role ["chat" "rerank"]) "unknown model role")
  (def identity (string "model:" (task :id) ":" key))
  (def prior (first (store/query s "SELECT * FROM events WHERE key=?" [identity])))
  (def recorded (when prior (store/result s (prior :id))))
  (def saved (when prior (store/restore s (prior :image))))
  (def input (if saved (saved :input) inquiry))
  (var selected (if saved (saved :selected) profiled))
  (if recorded
    (do (when (get-in recorded [:data :error]) (error (get-in recorded [:data :error])))
        (merge (recorded :data) {:event (recorded :id)}))
    (do
      (when (and prior (first (store/query s "SELECT id FROM events WHERE parent=? AND kind='dispatch'" [(prior :id)])))
        (error {:code "Blocked" :message "Dispatched inference has no committed outcome; reconcile before repeating." :context {:operation (prior :id)}}))
      (default selected (profile s (get input :model (config (if (= role "rerank") :rerank :chat))) (keyword role)))
      (def size (if (= role "rerank") (store/estimate (schema/encode input))
        (+ (estimate (input :messages) (selected :reference)) (store/estimate (schema/encode (input :tools))))))
      (when (= role "rerank")
        (assert (> (length (input :query)) 0) "empty rerank query")
        (each passage (input :documents) (assert (< (store/estimate (string (input :query) passage)) (selected :context)) "rerank passage exceeds capacity")))
      (when (= role "chat")
        (each message (input :messages)
          (each part (if (indexed? (message :content)) (message :content) [])
            (when (= "image_url" (part :type)) (assert (selected :images) "model does not support images"))))
        (each definition (get input :tools []) (assert (index-of definition (selected :tools)) "model does not support tool")))
      (def window (min (selected :context) (get config :context-quota math/inf)))
      (def capacity (math/floor (/ (* window (config :context-percent)) 100)))
      (def maximum (if (= role "rerank") 0
        (min (or (selected :output) window) (- window size 256)
          (if (= 0 (config :output)) math/inf (config :output)) (get input :output math/inf))))
      (unless (= role "rerank")
        (assert (and (> maximum 0) (<= size capacity)) "model input ceiling exhausted"))
      (def wire (if prior (get-in prior [:data :request :body]) (provider/encode config selected input maximum)))
      (def admission (store/transact s (or prior (store/append s (task :id) "model"
        {:input (schema/project input [:messages :tools :query :documents :views] true) :views (input :views)
         :request {:method "POST" :url (string (get-in config [:providers (keyword (selected :provider)) :url]) (selected :path)) :body wire}
         :estimate size :context window :capacity capacity :output maximum :turn (get input :turn false) :role role} identity
        (store/image s {:input input :selected selected :key key})))))
      (store/append s (admission :id) "dispatch" {})
      (def raw (try (provider/request config selected (selected :path) wire)
        ([err fiber]
          (def failure (schema/diagnostic "ProviderFailed" err fiber))
          (def failure (merge failure {:context (merge (get failure :context {}) {:operation (admission :id)})}))
          (when (= "failed" (get-in failure [:context :outcome]))
            (store/append s (admission :id) "result" {:type "model" :state "failed" :role role :turn (get input :turn false) :error failure}
              (string "result:" (admission :id))))
          (error failure))))
      (def outcome (try
        (do
          (def value (if (= role "rerank") raw (provider/decode selected raw)))
          (when-let [usage (value :usage)]
            (assert (dictionary? usage) "invalid usage report")
            (each key [:prompt_tokens :completion_tokens :total_tokens]
              (when (has-key? usage key) (assert (and (int? (usage key)) (>= (usage key) 0)) "invalid usage counter"))))
          (def result (if (= role "rerank")
            (do
              (assert (indexed? (value :results)) "invalid rerank results")
              (def seen @{})
              (each ranked (value :results)
                (assert (and (int? (ranked :index)) (<= 0 (ranked :index) (- (length (input :documents)) 1))
                  (not (seen (ranked :index))) (number? (ranked :relevance_score))
                  (< (math/abs (ranked :relevance_score)) math/inf)) "invalid rerank result")
                (put seen (ranked :index) true))
              (assert (= (length seen) (length (input :documents))) "incomplete rerank results")
              {:results (sorted (value :results) |(> ($0 :relevance_score) ($1 :relevance_score))) :status "complete" :text ""})
            (let [message (value :message) status (value :status)
                  calls (if (index-of status ["tools" "complete"]) (get message :tool_calls []) [])]
              (assert (and (dictionary? message) (= "assistant" (message :role)) (indexed? calls)) "invalid assistant response")
              (def seen @{})
              (def work (map (fn [call]
                (assert (and (string? (call :id)) (> (length (call :id)) 0) (not (seen (call :id)))) "invalid tool identity")
                (put seen (call :id) true)
                (try
                  (do
                    (assert (and (= "function" (call :type))
                      (= "self" (get-in call [:function :name])) (index-of tool (input :tools))) "unavailable tool")
                    (def arguments (schema/request (json/decode (get-in call [:function :arguments]) true true) [:code]))
                    (assert (arguments :code) "missing Janet source")
                    (merge {:id (call :id)} arguments))
                  ([err fiber] {:id (call :id) :error (schema/diagnostic "InvalidToolCall" err fiber)}))) calls))
              {:message message :tools work :text (text message)
               :finish-reason (value :finish-reason) :status status})))
          (merge result {:type "model" :state "done" :role role :turn (get input :turn false) :usage (value :usage) :raw raw
            :reasoning-visible (not= "none" (config :thinking))}))
        ([err fiber]
          (def failure (schema/diagnostic "InvalidModelResponse" err fiber))
          {:type "model" :state "failed" :role role :turn (get input :turn false) :raw raw
           :error (merge failure {:context (merge (get failure :context {})
             {:operation (admission :id) :provider (selected :provider) :model (selected :id)
              :protocol (selected :protocol) :response-id (raw :id)})})})))
      (def result
        (or (store/result s (admission :id)) (store/append s (admission :id) "result" outcome (string "result:" (admission :id)))))
      (when (get-in result [:data :error]) (error (get-in result [:data :error])))
      (merge (result :data) {:event (result :id)}))))

(defn render [data]
  (def message (or (data :message) {}))
  (def reasoning (when (data :reasoning-visible) (or (message :reasoning_content) (message :reasoning)
    (string/join (seq [part :in (get message :reasoning_details []) :when (string? (part :text))] (part :text)) "\n"))))
  (def content (if (indexed? (message :content)) (filter |(not= "text" ($ :type)) (message :content)) []))
  (string (when (and reasoning (> (length reasoning) 0)) (string "> " (string/replace-all "\n" "\n> " reasoning) "\n\n"))
    (get data :text "") (when (> (length content) 0) (string "\n\nNon-text content: " (schema/encode content)))))

(defn images [input text budget]
  (def parts @[{:type "text" :text text}])
  (each image (get input :images [])
    (def size (length (base64/decode (image :data))))
    (if (> size (budget 0)) (array/push parts {:type "text" :text "[image omitted: prompt byte budget]"})
      (do (put budget 0 (- (budget 0) size))
        (array/push parts {:type "image_url" :image_url {:url (string "data:" (image :type) ";base64," (image :data))}}))))
  parts)
