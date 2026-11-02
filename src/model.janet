(import spork/utf8 :as utf8)
(import spork/json :as json)
(import spork/base64 :as base64)
(import ./store)
(import ./schema)
(import ./provider)

(def- tool
  {:type "function"
   :function {:name "run_janet"
              :description "Evaluate Janet source. All calls in one response run concurrently in the shared world. Their fibers settle before one atomic image/result publication. Use self for independent forked worlds."
              :parameters {:type "object"
                           :additionalProperties false
                           :required ["code"]
                           :properties {:code {:type "string"}}}}})

(defn text [message]
  (def content (message :content))
  (assert (or (nil? content) (string? content) (indexed? content)) "invalid assistant content")
  (string/join (map (fn [text] (assert (and (string? text) (utf8/is-valid? text)) "invalid assistant text") text)
                   (if (indexed? content) (seq [part :in content :when (= "text" (part :type))] (part :text))
                     [(if (or (nil? content) (= "" content)) (or (message :refusal) "") content)])) "\n"))

(defn estimate [messages &opt reference]
  (+ (sum (map |(if (= reference (get-in $ [:response :model])) (get-in $ [:response :reasoning-tokens] 0) 0) messages))
     (store/estimate (schema/encode (map (fn [original]
                                         (def message (schema/project original [:response] true))
                                         (if (indexed? (message :content))
                                           (merge message {:content (map |(if (= "image_url" ($ :type))
                                                                            {:type "image_url" :image_url "[image tokens are provider-dependent]"} $) (message :content))})
                                           message)) messages)))))

(defn catalogue [config role &opt provider]
  (assert (index-of role ["chat" "rerank"]) "unsupported model role")
  (def models @[])
  (each name (if provider [(keyword provider)] (keys (config :providers)))
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
      (when (and (or (not (has-key? granted :models)) configured)
                 (= role (get configured :role role)))
        (array/push models (merge record {:ref (string name ":" (record :id))
                                          :name (get configured :name (get record :name (record :id)))
                                          :profile (or configured {})})))))
  (sorted models |(< ($0 :ref) ($1 :ref))))

(defn profile [s reference role]
  (assert (string? reference) (string "configure a " role " model"))
  (def config (s :config))
  (def key [(config :providers) reference role (config :thinking) (config :web-search)])
  (or ((s :profiles) key)
      (do
        (def split (string/find ":" reference))
        (assert split "model reference must be provider:id")
        (def provider (string/slice reference 0 split))
        (def id (string/slice reference (+ split 1)))
        (def endpoint (get-in config [:providers (keyword provider)]))
        (assert (and (not= "" id) endpoint) "provider is not configured")
        (def ref {:provider provider :id id :reference reference})
        (def catalogued (find |(= ($ :id) id) (catalogue config (string role) provider)))
        (assert catalogued "exact model is unavailable")
        (def properties (endpoint :properties))
        (def record (if properties (provider/request config ref (string/replace-all "{model}" ((module/value (require "jurl/native") 'escape) id) properties)) catalogued))
        (def parameters (get record :supported_parameters []))
        (def native-context (if properties (get-in record [:default_generation_settings :n_ctx]) (record :context_length)))
        (when properties (assert (and (int? native-context) (> native-context 1)) "invalid properties context capacity"))
        (def limits (filter identity [native-context (when (= role :chat) (get-in record [:top_provider :context_length]))
                                      (get-in catalogued [:profile :context])]))
        (assert (and (> (length limits) 0) (every? (map |(and (int? $) (<= 2 $ 9007199254740991)) limits))) "invalid provider context capacity")
        (def context (min ;limits))
        (def capabilities
          (merge {:tools (if properties (and (get-in record [:chat_template_caps :supports_tools]) (get-in record [:chat_template_caps :supports_tool_calls]))
                             (not (nil? (index-of "tools" parameters))))
                  :parallel (if properties (get-in record [:chat_template_caps :supports_parallel_tool_calls])
                                (not (nil? (index-of "parallel_tool_calls" parameters))))
                  :images (if properties (get-in record [:modalities :vision])
                              (not (nil? (index-of "image" (get-in record [:architecture :input_modalities] [])))))
                  :control (if properties (when (get-in record [:chat_template_caps :supports_reasoning_effort]) "reasoning_effort")
                               (cond (index-of "reasoning" parameters) "reasoning" (index-of "reasoning_effort" parameters) "reasoning_effort"))
                  :efforts (get-in record [:reasoning :supported_efforts])
                  :reasoning-required (get-in record [:reasoning :mandatory])
                  :output (when (= role :chat) (get-in record [:top_provider :max_completion_tokens]))
                  :output-field (if (= "responses" (endpoint :protocol)) "max_output_tokens" "max_tokens")}
                 (catalogued :profile)))
        (def thinking (config :thinking))
        (when (= role :chat)
          (when (= thinking "none") (assert (not (capabilities :reasoning-required)) "model requires reasoning"))
          (unless (index-of thinking ["default" "none"])
            (assert (capabilities :control) "thinking effort is unsupported"))
          (when (and (capabilities :efforts) (not= thinking "default")
                     (or (not= thinking "none") (= "responses" (endpoint :protocol))))
            (assert (index-of thinking (capabilities :efforts)) (string reference " does not support thinking=" thinking)))
          (when (config :web-search) (assert (> (length (endpoint :web-tools)) 0) "web search is not configured")))
        (def output (capabilities :output))
        (when output (assert (and (int? output) (<= 1 output context)) "invalid provider output capacity"))
        (def selected (merge ref capabilities {:context context :protocol (endpoint :protocol)
                                              :path (endpoint (if (= role :chat) :chat-path :rerank-path))
                                              :control (when (capabilities :control) (keyword (capabilities :control)))
                                              :tools (array/concat @[] (if (capabilities :tools) [tool] [])
                                                       (if (and (= role :chat) (config :web-search)) (endpoint :web-tools) []))}))
        (put (s :profiles) key selected) selected)))

(defn account [s request selected raw]
  (default raw {})
  (assert (dictionary? raw) "invalid usage report")
  (each field [:prompt_tokens :completion_tokens :total_tokens]
    (when (has-key? raw field) (assert (and (int? (raw field)) (>= (raw field) 0)) "invalid reported usage")))
  (store/query s "INSERT INTO main.usage(request,provider,model,raw) VALUES(?,?,?,?)"
               [request (selected :provider) (selected :id) (string (json/encode raw))]))

(defn call [s input &opt pending selected]
  (def config (s :config))
  (def role (get input :role "chat"))
  (assert (index-of role ["chat" "rerank"]) "unknown model role")
  (def input (merge {:model (config (if (= "rerank" role) :rerank :chat))} input))
  (def event
    (or (when pending (first (store/query s "SELECT id,data,text FROM events WHERE parent=? AND kind='model-outcome'" [pending])))
        (do
          (assert (nil? pending) "inference outcome is uncertain; refusing to resubmit an admitted request")
          (default selected (profile s (input :model) (keyword role)))
          (assert (= (selected :reference) (input :model)) "profile does not match admitted model")
          (var size 0) (var maximum 0)
          (if (= role "rerank")
            (do
              (assert (> (length (input :query)) 0) "rerank query must remain nonempty")
              (each passage (input :documents)
                (def cost (store/estimate (string (input :query) passage)))
                (assert (< cost (selected :context)) "original rerank query/passage exceeds capacity")
                (+= size cost)))
            (do
              (each message (input :messages)
                (each part (if (indexed? (message :content)) (message :content) [])
                  (when (= "image_url" (part :type)) (assert (selected :images) "model does not support image input"))))
              (set size (+ (estimate (input :messages) (selected :reference)) (if (input :tools) (store/estimate (json/encode (input :tools))) 0)))
              (assert (<= size (get config :context-quota math/inf)) "model input exceeds context quota")
              (def caps (map (fn [cap] (assert (and (int? cap) (>= cap 0)) "invalid output limit") (if (= cap 0) math/inf cap)) [(config :output) (get input :output 0)]))
              (set maximum (min (or (selected :output) (selected :context)) ;caps (- (selected :context) size)))
              (assert (> maximum 0) "approximate context capacity exhausted")
              (each definition (get input :tools [])
                (assert (index-of definition (selected :tools)) "model does not support tool"))))
          (def wire (provider/encode config selected input maximum))
          (def endpoint (selected :path))
          (def current (dyn :zinc/call))
          (def admission (store/transact s
                                         (store/checkpoint s)
                                         (store/charge s 1 0)
                                         (def event (store/append s (current :scope) "model-admission" (selected :reference)
                                                                  {:input (schema/project input [:messages :tools :query :documents :views] true)
                                                                   :request {:method "POST" :url (string (get-in config [:providers (keyword (selected :provider)) :url]) endpoint) :body wire}
                                                                   :views (input :views) :context (selected :context) :estimate size :output maximum} nil (current :id)))
                                         (store/checkpoint s (merge (current :checkpoint) {:request (event :id)})) (event :id)))
          (def raw (provider/request config selected endpoint wire))
          (def result
            (try
              (do
                (def value (if (= role "rerank") raw (provider/decode selected raw)))
                (account s admission selected (value :usage))
                (merge
                  (if (= role "rerank")
                    (do
                      (assert (indexed? (value :results)) "invalid rerank results")
                      (def seen @{})
                      (each ranked (value :results)
                        (assert (and (int? (ranked :index)) (<= 0 (ranked :index) (- (length (input :documents)) 1))
                                     (not (seen (ranked :index))) (number? (ranked :relevance_score))
                                     (< (math/abs (ranked :relevance_score)) math/inf)) "invalid rerank result")
                        (put seen (ranked :index) true))
                      (assert (= (length seen) (length (input :documents))) "incomplete rerank results")
                      {:results (sort (value :results) (fn [a b]
                                                         (if (= (a :relevance_score) (b :relevance_score)) (< (a :index) (b :index)) (> (a :relevance_score) (b :relevance_score))))) :status "complete"})
                    (do
                      (def finish (value :finish-reason))
                      (assert (not= "error" finish) "provider generation failed")
                      (def message (value :message))
                      (assert (and (dictionary? message) (= "assistant" (message :role))) "invalid assistant message")
                      (def content (message :content))
                      (text message)
                      (def calls (or (message :tool_calls) []))
                      (assert (indexed? calls) "invalid tool calls")
                      (def identities @{})
                      (def tools (map (fn [call]
                                        (assert (and (dictionary? call) (string? (call :id)) (> (length (call :id)) 0) (not (identities (call :id)))) "invalid or duplicate tool identity")
                                        (put identities (call :id) true)
                                        (try (do
                                               (assert (index-of finish ["stop" "tool_calls"]) "Interrupted tool call; not executed.")
                                               (assert (and (= "function" (call :type)) (= "run_janet" (get-in call [:function :name]))
                                                            (input :tools) (index-of tool (input :tools))) "unknown or unavailable tool")
                                               (def arguments (schema/request (json/decode (get-in call [:function :arguments]) true true) [:code]))
                                               (assert (arguments :code) "missing Janet tool source")
                                               {:id (call :id) :code (arguments :code)})
                                          ([err] {:id (call :id) :error {:code "InvalidToolCall" :message (string err)}}))) calls))
                      (def tail (if (string? content) {:type "text" :text content} (when (indexed? content) (last content))))
                      (assert (indexed? (or (message :reasoning_details) [])) "invalid reasoning details")
                      {:message message :finish-reason finish :tools tools
                       :reasoning-visible (not= "none" (config :thinking))
                       :status (cond (> (length calls) 0) "tools"
                                 (and (string? (message :refusal)) (> (length (string/trim (message :refusal))) 0)) "refused"
                                 (= "content_filter" finish) "blocked"
                                 (and (= "stop" finish) (= "text" (get tail :type)) (> (length (string/trim (tail :text))) 0)) "complete" "continue")}))
                  {:role role :turn (get input :turn false)
                   :visible (and (= role "chat") (not (input :turn)) (not= "summarize" (current :kind)))}))
              ([err] (error {:code "InvalidModelResponse" :message (string err) :detail (string (json/encode raw)) :context {:request admission}}))))
          (store/transact s
                          (assert (first (store/query s "SELECT id FROM main.call_controls WHERE id=? AND owner=? AND state IN ('running','waiting','uncertain','cancelled')"
                                                      [(current :id) (current :owner)])) "model completion fenced")
                          (store/append s (current :scope) "model-outcome" (if (= role "chat") (text (result :message)) "") result admission (current :id))))))
  (merge (json/decode (event :data) true true) {:event (event :id) :text (event :text)}))

(defn render [row]
  (def message (if (row :public_message) (json/decode (row :public_message) true true) {}))
  (def reasoning (or (message :reasoning_content) (message :reasoning)
                     (string/join (seq [part :in (get message :reasoning_details []) :when (and (dictionary? part) (string? (part :text)))] (part :text)) "\n")))
  (def content (message :content))
  (def text (if (row :public_message) (text message) (row :text)))
  (def content (when (and (not= "model-admission" (row :kind)) (indexed? content)) (filter |(not= "text" ($ :type)) content)))
  (def parts (filter identity [(when (> (length reasoning) 0) (string "> " (string/replace-all "\n" "\n> " reasoning)))
                               (when (> (length (string/trim text)) 0) text)
                               (when (and content (> (length content) 0)) (string "Non-text content:\n\n```json\n" (json/encode content) "\n```"))]))
  (if (> (length parts) 0) (string/join parts "\n\n")
    (if (> (length (get message :tool_calls [])) 0) "" "[empty model response]")))

(defn images [s events text budget]
  (def parts @[{:type "text" :text text}])
  (each row (store/query s `SELECT event,position,mime,length(bytes) size,
    CASE WHEN sum(length(bytes)) OVER (ORDER BY event DESC,position)<=? THEN bytes END bytes
    FROM images WHERE event IN (SELECT value FROM json_each(?)) ORDER BY event DESC,position` [(budget 0) (string (json/encode events))])
    (array/push parts {:type "text" :text (string "Image from #" (row :event) " · attachment " (+ 1 (row :position))
                                               (unless (row :bytes) " · omitted: prompt image byte budget"))})
    (when (row :bytes)
      (put budget 0 (- (budget 0) (row :size)))
      (array/push parts {:type "image_url" :image_url {:url (string "data:" (row :mime) ";base64," (base64/encode (string (row :bytes))))}})))
  parts)
