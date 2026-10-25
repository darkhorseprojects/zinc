(import spork/utf8 :as utf8)
(import spork/json :as json)
(import spork/base64 :as base64)
(import ./store)
(import ./http)

(def- tool
  {:type "function" :function
   {:name "run_janet" :description "Evaluate Janet source. One tool call uses the current call's environment; multiple tool calls in one response each use a separate child copied from the same source and history. Child source changes do not merge into the caller."
    :parameters {:type "object" :additionalProperties false :required ["code"]
                 :properties {:code {:type "string"}}}}})

(defn estimate [messages]
  (store/estimate (json/encode (map (fn [message]
                                      (if (indexed? (message :content))
                                        (merge message {:content (map |(if (= "image_url" ($ :type))
                                                                         {:type "image_url" :image_url "[image bytes accounted separately]"} $) (message :content))})
                                        message)) messages))))

(defn request [config reference method path &opt body preserve-nulls]
  (def provider (get-in config [:providers (keyword (reference :provider))]))
  (when (and (= "POST" method) (has-key? provider :models))
    (assert (index-of ((json/decode body true true) :model) (provider :models)) "model is not granted"))
  (def response (http/request config provider method path body))
  (assert (<= 200 (response :status) 299) (string "model HTTP " (response :status) ": " (response :body)))
  (def value (json/decode (response :body) true (not preserve-nulls)))
  (assert (dictionary? value) "model response must be an object")
  (when-let [failure (or (value :error) (get-in value [:choices 0 :error]))]
    (error (string "provider error: " (json/encode failure))))
  value)

(defn catalogue [config role &opt provider]
  (assert (index-of role ["chat" "rerank"]) "unsupported model role")
  (def models @[])
  (each name (if provider [(keyword provider)] (keys (config :providers)))
    (def response (request config {:provider (string name)} "GET"
                           (if (= :openrouter name) (string "/v1/models?output_modalities=" (if (= role "chat") "text" "rerank")) "/v1/models") nil provider))
    (assert (and (dictionary? response) (indexed? (response :data))) "invalid model catalogue")
    (def identities @{})
    (def granted (get-in config [:providers name]))
    (each record (response :data)
      (assert (and (dictionary? record) (string? (record :id)) (> (length (record :id)) 0)
                   (not (identities (record :id)))) "invalid or duplicate model ID")
      (put identities (record :id) true)
      (when (or (not (has-key? granted :models)) (index-of (record :id) (granted :models)))
        (array/push models (merge record {:ref (string name ":" (record :id)) :name (get record :name (record :id))})))))
  (sorted models |(< ($0 :ref) ($1 :ref))))

(defn profile [s reference role]
  (def config (s :config))
  (def key [(config :providers) reference role (config :thinking) (config :web-search)])
  (or ((s :profiles) key)
      (do
        (def split (string/find ":" reference))
        (assert split "model reference must be provider:id")
        (def provider (string/slice reference 0 split))
        (def id (string/slice reference (+ split 1)))
        (assert (and (not= "" id) (index-of provider ["llama" "openrouter"])) "unsupported model reference")
        (def ref {:provider provider :id id :reference reference})
        (def catalogued (find |(= ($ :id) id) (catalogue config (string role) provider)))
        (assert catalogued "exact model is unavailable")
        (def record (if (= provider "llama")
                      (request config ref "GET" (string "/props?model=" ((module/value (require "jurl/native") 'escape) id))) catalogued))
        (def context (if (= provider "llama") (get-in record [:default_generation_settings :n_ctx])
                       (if (= role :chat)
                         (do
                           (assert (and (int? (record :context_length)) (int? (get-in record [:top_provider :context_length]))
                                        (> (get-in record [:top_provider :context_length]) 1)) "invalid provider context capacity")
                           (min (record :context_length) (get-in record [:top_provider :context_length])))
                         (record :context_length))))
        (assert (and (int? context) (<= 2 context 9007199254740991)) "invalid provider context capacity")
        (def parameters (get record :supported_parameters []))
        (def reasoning (record :reasoning))
        (def thinking (config :thinking))
        (when (and (= role :chat) (= provider "openrouter"))
          (when (= thinking "none")
            (assert (not= true (get reasoning :mandatory)) "model requires reasoning"))
          (when (and (not (index-of thinking ["default" "none"]))
                     (indexed? (get reasoning :supported_efforts)))
            (assert (index-of thinking (reasoning :supported_efforts))
                    (string reference " does not support thinking=" thinking))))
        (def control (if (= provider "llama")
                       (when (get-in record [:chat_template_caps :supports_reasoning_effort]) :reasoning_effort)
                       (cond (index-of "reasoning" parameters) :reasoning (index-of "reasoning_effort" parameters) :reasoning_effort)))
        (when (and (= role :chat) (not (index-of (config :thinking) ["default" "none"])))
          (assert control "thinking effort is unsupported"))
        (def advertised (when (= provider "openrouter") (get-in record [:top_provider :max_completion_tokens])))
        (def output (unless (= :null advertised) advertised))
        (when output (assert (and (int? output) (<= 1 output context)) "invalid provider output capacity"))
        (when (and (= role :chat) (config :web-search)) (assert (= provider "openrouter") "web search is unsupported by this provider"))
        (def selected (merge ref {:context context :output output :control control
                                  :tools (array/concat @[]
                                           (if (if (= provider "llama")
                                                 (and (get-in record [:chat_template_caps :supports_tools]) (get-in record [:chat_template_caps :supports_tool_calls]))
                                                 (index-of "tools" parameters)) [tool] [])
                                           (if (and (= role :chat) (config :web-search)) [{:type "openrouter:web_search"}] []))
                                  :parallel (if (= provider "llama") (get-in record [:chat_template_caps :supports_parallel_tool_calls])
                                              (not (nil? (index-of "parallel_tool_calls" parameters))))
                                  :images (if (= provider "llama") (get-in record [:modalities :vision])
                                            (not (nil? (index-of "image" (get-in record [:architecture :input_modalities] [])))))}))
        (put (s :profiles) key selected) selected)))

(defn account [s request selected raw]
  (default raw {})
  (assert (dictionary? raw) "invalid usage report")
  (each field [:prompt_tokens :completion_tokens :total_tokens]
    (when (has-key? raw field) (assert (and (int? (raw field)) (>= (raw field) 0)) "invalid reported usage")))
  (store/query s (string "INSERT INTO " (s :journal) ".usage(request,provider,model,input,output,total,reasoning,cached,raw) VALUES(?,?,?,?,?,?,?,?,?)")
               [request (selected :provider) (selected :id) (raw :prompt_tokens) (raw :completion_tokens) (raw :total_tokens)
                (get-in raw [:completion_tokens_details :reasoning_tokens]) (get-in raw [:prompt_tokens_details :cached_tokens])
                (string (json/encode raw))]))

(defn call [s input &opt pending selected]
  (def config (s :config))
  (def role (get input :role "chat"))
  (assert (index-of role ["chat" "rerank"]) "unknown model role")
  (def input (merge {:model (config (if (= "rerank" role) :rerank :chat))} input))
  (def cached (when pending (first (store/query s
                                                "SELECT e.id,e.data,m.text FROM events e JOIN memory_records m USING(id) WHERE e.source=? AND e.parent=? AND e.kind='model-outcome'" [(s :source) pending]))))
  (if cached (merge (json/decode (cached :data) true true) {:event (cached :id) :text (cached :text)})
    (do
      (default selected (profile s (input :model) (keyword role)))
      (assert (= (selected :reference) (input :model)) "profile does not match admitted model")
      (def [body size maximum] (if (= role "rerank")
                                 (do
                                   (assert (> (length (input :query)) 0) "rerank query must remain nonempty")
                                   (each passage (input :documents)
                                     (assert (< (store/estimate (string (input :query) passage)) (selected :context)) "original rerank query/passage exceeds capacity"))
                                   [{:model (selected :id) :query (input :query) :documents (input :documents) :top_n (length (input :documents))}
                                    (sum (map |(store/estimate (string (input :query) $)) (input :documents))) 0])
                                 (do
                                   (each message (input :messages)
                                     (each part (if (indexed? (message :content)) (message :content) [])
                                       (when (= "image_url" (part :type)) (assert (selected :images) "model does not support image input"))))
                                   (def size (+ (estimate (input :messages)) (if (input :tools) (store/estimate (json/encode (input :tools))) 0)))
                                   (when (config :context-quota)
                                     (assert (<= size (config :context-quota)) "model input exceeds context quota"))
                                   (def requested (get input :output (config :output)))
                                   (assert (and (int? requested) (>= requested 0)) "invalid requested output limit")
                                   (def cap
                                     (cond
                                       (= requested 0) (config :output)
                                       (= (config :output) 0) requested
                                       (min requested (config :output))))
                                   (def maximum
                                     (min (or (selected :output) (selected :context))
                                          (if (= 0 cap) (selected :context) cap)
                                          (- (selected :context) size)))
                                   (assert (> maximum 0) "approximate context capacity exhausted")
                                   (def body @{:model (selected :id) :messages (input :messages) :max_tokens maximum :stream false})
                                   (when (input :tools)
                                     (each definition (input :tools) (assert (index-of definition (selected :tools)) "model does not support tool"))
                                     (put body :tools (input :tools))
                                     (when (selected :parallel) (put body :parallel_tool_calls true)))
                                   (unless (= "default" (config :thinking))
                                     (case (selected :control)
                                       :reasoning (put body :reasoning (if (= "none" (config :thinking)) {:enabled false} {:effort (config :thinking)}))
                                       :reasoning_effort (put body :reasoning_effort (config :thinking))))
                                   (when (= "openrouter" (selected :provider)) (put body :provider {:require_parameters true :allow_fallbacks false}))
                                   [body size maximum])))
      (def wire (string (json/encode body)))
      (def endpoint (if (= role "rerank") "/v1/rerank" "/v1/chat/completions"))
      (def current (dyn :zinc/call))
      (def admission (store/transact s
                                     (store/checkpoint s)
                                     (store/charge s 1 0)
                                     (def event (store/append s (current :scope) "model-admission" (selected :reference)
                                                              {:input (tabseq [[key value] :in (pairs input) :unless (index-of key [:messages :tools :query :documents :views])] key value)
                                                               :request {:method "POST" :url (string (get-in config [:providers (keyword (selected :provider)) :url]) endpoint) :body wire}
                                                               :views (input :views) :estimate size :output maximum} nil (current :id)))
                                     (store/checkpoint s (merge (current :checkpoint) {:request (event :id)})) (event :id)))
      (def value (request config selected "POST" endpoint wire))
      (def result (try (do (account s admission selected (value :usage)) (merge
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
                                                                               (assert (and (indexed? (value :choices)) (= 1 (length (value :choices)))) "expected one complete assistant message")
                                                                               (def choice ((value :choices) 0))
                                                                               (assert (not= "error" (choice :finish_reason)) "provider generation failed")
                                                                               (def message (choice :message))
                                                                               (assert (and (dictionary? message) (= "assistant" (message :role))) "invalid assistant message")
                                                                               (def content (message :content))
                                                                               (def text (cond (nil? content) (or (message :refusal) "") (string? content) content
                                                                                           (indexed? content) (string/join (seq [part :in content :when (= "text" (part :type))] (part :text)) "\n")
                                                                                           (error "invalid assistant content")))
                                                                               (assert (and (string? text) (utf8/is-valid? text)) "invalid assistant text")
                                                                               (def calls (or (message :tool_calls) []))
                                                                               (assert (and (indexed? calls) (<= (length calls) (config :tool-calls))) "invalid tool calls")
                                                                               (def identities @{})
                                                                               (def tools (map (fn [call]
                                                                                                 (assert (and (dictionary? call) (string? (call :id)) (> (length (call :id)) 0) (not (identities (call :id)))) "invalid or duplicate tool identity")
                                                                                                 (put identities (call :id) true)
                                                                                                 (try (do
                                                                                                        (assert (index-of (choice :finish_reason) ["stop" "tool_calls"]) "Interrupted tool call; not executed.")
                                                                                                        (assert (and (= "function" (call :type)) (= "run_janet" (get-in call [:function :name]))
                                                                                                                     (input :tools) (index-of tool (input :tools))) "unknown or unavailable tool")
                                                                                                        (def arguments (json/decode (get-in call [:function :arguments]) true true))
                                                                                                        (assert (and (dictionary? arguments) (= [:code] (tuple/slice (sort (keys arguments))))
                                                                                                                     (string? (arguments :code)) (> (length (arguments :code)) 0)) "invalid Janet tool source")
                                                                                                        {:id (call :id) :code (arguments :code)})
                                                                                                   ([err] {:id (call :id) :error {:code "InvalidToolCall" :message (string err)}}))) calls))
                                                                               (def tail (if (string? content) {:type "text" :text content} (when (indexed? content) (last content))))
                                                                               (assert (indexed? (or (message :reasoning_details) [])) "invalid reasoning details")
                                                                               {:text text :message message :finish-reason (choice :finish_reason) :tools tools
                                                                                :reasoning-visible (not= "none" (config :thinking))
                                                                                :status (cond (> (length calls) 0) "tools"
                                                                                          (and (= "stop" (choice :finish_reason)) (= "text" (get tail :type)) (> (length (string/trim (tail :text))) 0)) "complete" "continue")}))
                                                                           {:usage (value :usage) :model selected :request admission :role role :turn (get input :turn false)
                                                                            :visible (and (= role "chat") (not (input :turn)) (not= "summarize" (current :kind)))
                                                                            :provider-metadata (tabseq [[key item] :in (pairs value) :unless (index-of key [:usage :choices :results])] key item)
                                                                            :choice-metadata (when (= role "chat") (tabseq [[key item] :in (pairs ((value :choices) 0)) :unless (index-of key [:message :finish_reason])] key item))}))
                    ([err] (error {:code "InvalidModelResponse" :message (string err) :detail (string (json/encode value)) :context {:request admission}}))))
      (def event (store/transact s
                                 (assert (first (store/query s "SELECT id FROM main.call_controls WHERE id=? AND source=? AND owner=? AND state IN ('running','waiting','uncertain','cancelled')"
                                                             [(current :id) (s :source) (current :owner)])) "model completion fenced")
                                 (store/append s (current :scope) "model-outcome" "Model outcome committed." (tabseq [[key value] :in (pairs result) :unless (= key :text)] key value) admission (current :id))))
      (merge result {:event (event :id)}))))

(defn render [row]
  (def message (if (row :public_message) (json/decode (row :public_message) true true) {}))
  (def reasoning (string/join (distinct (filter |(and (string? $) (> (length (string/trim $)) 0))
                                              (array/concat @[(message :reasoning_content) (message :reasoning)]
                                                            (seq [part :in (get message :reasoning_details []) :when (dictionary? part)] (part :text))))) "\n"))
  (def content (when (indexed? (message :content)) (filter |(not= "text" ($ :type)) (message :content))))
  (def parts (filter identity [(when (> (length reasoning) 0) (string "Reasoning:\n\n" reasoning))
                               (when (> (length (string/trim (row :text))) 0) (row :text))
                               (when (and content (> (length content) 0)) (string "Non-text content:\n\n```json\n" (json/encode content) "\n```"))]))
  (if (> (length parts) 0) (string/join parts "\n\n")
    (if (> (length (get message :tool_calls [])) 0) "" "[empty model response]")))

(defn images [s event text]
  (def parts @[{:type "text" :text text}])
  (each row (store/query s "SELECT mime,bytes FROM images WHERE event=? ORDER BY position" [event])
    (array/push parts {:type "image_url" :image_url {:url (string "data:" (row :mime) ";base64," (base64/encode (string (row :bytes))))}}))
  parts)
