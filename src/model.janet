(import spork/utf8 :as utf8)
(import spork/json :as json)
(import spork/base64 :as base64)
(import ./store)
(import ./http)

(def- tool
  {:type "function"
   :function {:name "run_janet"
              :description "Evaluate Janet source. One tool call uses the current environment. Multiple calls in one response use separate children with the same source and history snapshot. Child source changes do not merge automatically."
              :parameters {:type "object"
                           :additionalProperties false
                           :required ["code"]
                           :properties {:code {:type "string"}}}}})

(defn estimate [messages]
  (store/estimate (json/encode (map (fn [message]
                                      (if (indexed? (message :content))
                                        (merge message {:content (map |(if (= "image_url" ($ :type))
                                                                         {:type "image_url" :image_url "[image bytes accounted separately]"} $) (message :content))})
                                        message)) messages))))

(defn- delta [previous value &opt field]
  (cond
    (dictionary? value) (let [result (or previous @{})]
                         (each [key item] (pairs value)
                           (unless (or (nil? item) (and (= field :tool_calls) (= key :index))) (put result key (delta (result key) item key)))) result)
    (indexed? value) (let [result (or previous @[])]
                      (eachp [position item] value
                        (def index (get item :index position))
                        (assert (and (int? index) (<= 0 index (length result))) "invalid streamed index")
                        (put result index (delta (get result index) item field))) result)
    (and (string? value) (index-of field [:content :refusal :reasoning :reasoning_content :text :data :summary :name :arguments])) (string (or previous "") value)
    value))

(defn request [config reference path &opt body s]
  (def provider (get-in config [:providers (keyword (reference :provider))]))
  (def supplied (when body (json/decode body true true)))
  (when (and body (has-key? provider :models))
    (assert (index-of (supplied :model) (provider :models)) "model is not granted"))
  (def streaming (get supplied :stream false))
  (def value @{:message @{}})
  (var pending "") (var done false)
  (def response
    (http/request config provider (if body "POST" "GET") path body
      (when streaming
        (fn [chunk]
          (set pending (string/replace-all "\r\n" "\n" (string pending chunk)))
          (var boundary nil)
          (while (set boundary (string/find "\n\n" pending))
            (def data (string/trim (string/join (seq [line :in (string/split "\n" (string/slice pending 0 boundary)) :when (string/has-prefix? "data:" line)] (string/slice line 5)) "\n")))
            (set pending (string/slice pending (+ boundary 2)))
            (unless (= "" data)
              (assert (not done) "trailing model stream data")
              (if (= "[DONE]" data) (set done true)
                (let [part (json/decode data true true)]
                  (when-let [failure (or (part :error) (get-in part [:choices 0 :error]))] (error (string "provider error: " (json/encode failure))))
                  (when (part :usage) (put value :usage (part :usage)))
                  (each choice (get part :choices [])
                    (assert (= 0 (choice :index)) "expected one assistant stream")
                    (when (choice :finish_reason) (put value :finish-reason (choice :finish_reason)))
                    (delta (value :message) (choice :delta)))))))
          (when (and s (not= "summarize" ((dyn :zinc/call) :kind)))
            (store/checkpoint s (merge ((dyn :zinc/call) :checkpoint)
                                       {:message (tabseq [[key item] :in (pairs (value :message))
                                                        :unless (and (= "none" (config :thinking)) (index-of key [:reasoning :reasoning_content :reasoning_details]))] key item)})))))))
  (assert (<= 200 (response :status) 299) (string "model HTTP " (response :status) ": " (response :body)))
  (def value (if streaming
              (do (assert (and done (= "" pending) (value :finish-reason)) "incomplete model stream") value)
              (json/decode (response :body) true true)))
  (assert (dictionary? value) "model response must be an object")
  (when-let [failure (value :error)]
    (error (string "provider error: " (json/encode failure))))
  value)

(defn catalogue [config role &opt provider]
  (assert (index-of role ["chat" "rerank"]) "unsupported model role")
  (def models @[])
  (each name (if provider [(keyword provider)] (keys (config :providers)))
    (def response (request config {:provider (string name)}
                           (if (= :openrouter name) (string "/v1/models?output_modalities=" (if (= role "chat") "text" "rerank")) "/v1/models")))
    (assert (indexed? (response :data)) "invalid model catalogue")
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
                      (request config ref (string "/props?model=" ((module/value (require "jurl/native") 'escape) id))) catalogued))
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
        (def output (when (= provider "openrouter") (get-in record [:top_provider :max_completion_tokens])))
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
  (def event
    (or (when pending (first (store/query s "SELECT id,data,text FROM events WHERE parent=? AND kind='model-outcome'" [pending])))
        (do
          (default selected (profile s (input :model) (keyword role)))
          (assert (= (selected :reference) (input :model)) "profile does not match admitted model")
          (def body @{:model (selected :id)})
          (var size 0) (var maximum 0)
          (if (= role "rerank")
            (do
              (assert (> (length (input :query)) 0) "rerank query must remain nonempty")
              (each passage (input :documents)
                (def cost (store/estimate (string (input :query) passage)))
                (assert (< cost (selected :context)) "original rerank query/passage exceeds capacity")
                (+= size cost))
              (merge-into body {:query (input :query) :documents (input :documents) :top_n (length (input :documents))}))
            (do
              (each message (input :messages)
                (each part (if (indexed? (message :content)) (message :content) [])
                  (when (= "image_url" (part :type)) (assert (selected :images) "model does not support image input"))))
              (set size (+ (estimate (input :messages)) (if (input :tools) (store/estimate (json/encode (input :tools))) 0)))
              (assert (<= size (get config :context-quota math/inf)) "model input exceeds context quota")
              (def caps (map (fn [cap] (assert (and (int? cap) (>= cap 0)) "invalid output limit") (if (= cap 0) math/inf cap)) [(config :output) (get input :output 0)]))
              (set maximum (min (or (selected :output) (selected :context)) ;caps (- (selected :context) size)))
              (assert (> maximum 0) "approximate context capacity exhausted")
              (merge-into body {:messages (input :messages) :max_tokens maximum :stream true :stream_options {:include_usage true}})
              (when (input :tools)
                (each definition (input :tools) (assert (index-of definition (selected :tools)) "model does not support tool"))
                (put body :tools (input :tools))
                (when (selected :parallel) (put body :parallel_tool_calls true)))
              (unless (= "default" (config :thinking))
                (case (selected :control)
                  :reasoning (put body :reasoning (if (= "none" (config :thinking)) {:enabled false} {:effort (config :thinking)}))
                  :reasoning_effort (put body :reasoning_effort (config :thinking))))
              (when (= "openrouter" (selected :provider)) (put body :provider {:require_parameters true :allow_fallbacks false}))))
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
                                         (store/checkpoint s (merge (current :checkpoint) {:request (event :id) :message nil})) (event :id)))
          (def value (request config selected endpoint wire s))
          (def result
            (try
              (do
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
                      (assert (or (nil? content) (string? content) (indexed? content)) "invalid assistant content")
                      (each text (if (indexed? content) (seq [part :in content :when (= "text" (part :type))] (part :text)) [(if (nil? content) (or (message :refusal) "") content)])
                        (assert (and (string? text) (utf8/is-valid? text)) "invalid assistant text"))
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
                                               (def arguments (json/decode (get-in call [:function :arguments]) true true))
                                               (assert (and (dictionary? arguments) (= [:code] (tuple/slice (sort (keys arguments))))
                                                            (string? (arguments :code)) (> (length (arguments :code)) 0)) "invalid Janet tool source")
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
              ([err] (error {:code "InvalidModelResponse" :message (string err) :detail (string (json/encode value)) :context {:request admission}}))))
          (store/transact s
                          (assert (first (store/query s "SELECT id FROM main.call_controls WHERE id=? AND owner=? AND state IN ('running','waiting','uncertain','cancelled')"
                                                      [(current :id) (current :owner)])) "model completion fenced")
                          (put (current :checkpoint) :message nil)
                          (store/query s (string "UPDATE " (s :journal) ".call_payloads SET checkpoint=? WHERE id=?") [(string (json/encode (current :checkpoint))) (current :id)])
                          (def content (get-in result [:message :content]))
                          (store/append s (current :scope) "model-outcome"
                                        (cond (string? content) content
                                          (indexed? content) (string/join (seq [part :in content :when (= "text" (part :type))] (part :text)) "\n")
                                          (get-in result [:message :refusal] "")) result admission (current :id))))))
  (merge (json/decode (event :data) true true) {:event (event :id) :text (event :text)}))

(defn render [row]
  (def message (if (row :public_message) (json/decode (row :public_message) true true) {}))
  (def reasoning (or (message :reasoning_content) (message :reasoning)
                     (string/join (seq [part :in (get message :reasoning_details []) :when (and (dictionary? part) (string? (part :text)))] (part :text)) "\n")))
  (def content (message :content))
  (def text (cond (string? content) (if (= "" content) (get message :refusal "") content)
                 (indexed? content) (string/join (seq [part :in content :when (= "text" (part :type))] (part :text)) "\n") (or (message :refusal) (row :text))))
  (def content (when (and (not= "model-admission" (row :kind)) (indexed? content)) (filter |(not= "text" ($ :type)) content)))
  (def parts (filter identity [(when (> (length reasoning) 0) (string "> " (string/replace-all "\n" "\n> " reasoning)))
                               (when (> (length (string/trim text)) 0) text)
                               (when (and content (> (length content) 0)) (string "Non-text content:\n\n```json\n" (json/encode content) "\n```"))]))
  (if (> (length parts) 0) (string/join parts "\n\n")
    (if (> (length (get message :tool_calls [])) 0) "" "[empty model response]")))

(defn images [s event text]
  (def parts @[{:type "text" :text text}])
  (each row (store/query s "SELECT mime,bytes FROM images WHERE event=? ORDER BY position" [event])
    (array/push parts {:type "image_url" :image_url {:url (string "data:" (row :mime) ";base64," (base64/encode (string (row :bytes))))}}))
  parts)
