(import spork/json :as json)
(import spork/utf8 :as utf8)
(import ./schema)
(import ./effects)

(defn encode [config selected input maximum]
  (def endpoint (get-in config [:providers (keyword (selected :provider))]))
  (var body (merge (endpoint :parameters) {:model (selected :id)}))
  (if (= "rerank" (get input :role "chat"))
    (merge-into body {:query (input :query) :documents (input :documents) :top_n (length (input :documents))})
    (do
      (merge-into body {:messages (input :messages) :stream (= "responses" (selected :protocol))})
      (unless (= "none" (selected :output-field)) (put body (keyword (selected :output-field)) maximum))
      (when (input :tools)
        (put body :tools (input :tools))
        (when (selected :parallel) (put body :parallel_tool_calls true)))
      (unless (= "default" (config :thinking))
        (case (when (selected :control) (keyword (selected :control)))
          :reasoning (put body :reasoning (if (and (= "none" (config :thinking)) (not= "responses" (selected :protocol))) {:enabled false} {:effort (config :thinking)}))
          :reasoning_effort (put body :reasoning_effort (config :thinking))))
      (when (endpoint :cache-key) (put body :prompt_cache_key (endpoint :cache-key)))
      (if (= "responses" (selected :protocol))
        (do
          (def items @[])
          (def result (merge (schema/project body [:messages :reasoning_effort] true)
                            {:input items :store false :include ["reasoning.encrypted_content"]}))
          (eachp [index message] (body :messages)
            (def content (message :content))
            (case (message :role)
              "system" (if (= index 0) (put result :instructions content)
                           (array/push items {:role "developer" :content content}))
              "user" (array/push items {:role "user" :content
                                        (if (string? content) [{:type "input_text" :text content}]
                                          (map (fn [part]
                                                 (case (part :type)
                                                   "text" {:type "input_text" :text (part :text)}
                                                   "image_url" {:type "input_image" :image_url (get-in part [:image_url :url])
                                                                :detail (get-in part [:image_url :detail] "auto")}
                                                   (error "unsupported Responses user content"))) content))})
              "assistant"
              (if (and (= (selected :reference) (get-in message [:response :model]))
                       (= (selected :protocol) (get-in message [:response :protocol])))
                (array/concat items (get-in message [:response :items]))
                (do
                  (def text (if (indexed? content)
                              (string/join (map (fn [part] (assert (= "text" (part :type)) "unsupported Responses assistant content") (part :text)) content) "\n")
                              (if (and (string? content) (> (length content) 0)) content (or (message :refusal) ""))))
                  (when (> (length text) 0) (array/push items {:role "assistant" :content text}))
                  (each call (get message :tool_calls [])
                    (array/push items {:type "function_call" :call_id (call :id)
                                       :name (get-in call [:function :name]) :arguments (get-in call [:function :arguments])}))))
              "tool" (array/push items {:type "function_call_output" :call_id (message :tool_call_id) :output content})
              (error "unsupported Responses message role")))
          (unless (has-key? result :instructions) (put result :instructions ""))
          (when (body :tools)
            (put result :tools (map |(if (= "function" ($ :type)) (merge ($ :function) {:type "function" :strict false}) $) (body :tools))))
          (when (body :reasoning_effort) (put result :reasoning {:effort (body :reasoning_effort)}))
          (unless (= "none" (get-in result [:reasoning :effort]))
            (put result :reasoning (merge {:summary "auto"} (get result :reasoning {}))))
          (set body result))
        (put body :messages (map (fn [message]
          (def replay (and (= (selected :reference) (get-in message [:response :model]))
                           (= (selected :protocol) (get-in message [:response :protocol]))
                           (selected :preserve-reasoning)))
          (schema/project message (array/concat @[:response]
            (if replay [] [:reasoning :reasoning_content :reasoning_details])) true)) (body :messages))))))
  (schema/encode body))

(defn request [config reference path &opt body]
  (def endpoint (get-in config [:providers (keyword (reference :provider))]))
  (def supplied (when body (json/decode body true true)))
  (when (and body (has-key? endpoint :models))
    (assert (has-key? (endpoint :models) (keyword (supplied :model))) "model is not granted"))
  (def streaming (get supplied :stream false))
  (def line @"") (def data @[]) (def items @{})
  (var carriage false) (var first-line true) (var last-event nil)
  (var terminal nil) (var response nil) (var confirmed false)
  (try
    (do
      (set response (effects/request config endpoint (if body "POST" "GET") path body
        (when streaming
          (fn [chunk]
            (each byte (string/bytes chunk)
              (when terminal (break))
              (if (and carriage (= byte 10)) (set carriage false)
                (do
                  (set carriage (= byte 13))
                  (if (index-of byte [10 13])
                    (do
                      (var field (string line))
                      (buffer/clear line)
                      (when first-line
                        (set first-line false)
                        (when (string/has-prefix? "\xEF\xBB\xBF" field) (set field (string/slice field 3))))
                      (if (= "" field)
                        (when (> (length data) 0)
                          (def payload (string/join data "\n"))
                          (array/clear data)
                          (when (= "[DONE]" payload)
                            (set confirmed true)
                            (error {:code "IncompleteModelStream" :message "Responses stream ended without a terminal response."}))
                          (assert (utf8/is-valid? payload) "model stream is not UTF-8")
                          (def part (json/decode payload true true))
                          (assert (and (dictionary? part) (string? (part :type))) "invalid Responses event")
                          (set last-event (part :type))
                          (when (index-of last-event ["error" "response.failed"])
                            (set confirmed true)
                            (def failure (if (= last-event "response.failed") (get-in part [:response :error]) (or (part :error) part)))
                            (assert (and (dictionary? failure) (string? (failure :message))) "invalid provider error")
                            (error {:code (string (or (failure :code) "ProviderError"))
                                    :message (failure :message) :detail (string (json/encode part))}))
                          (when (= last-event "response.output_item.done")
                            (def index (part :output_index))
                            (assert (and (int? index) (>= index 0) (dictionary? (part :item)) (not (has-key? items index)))
                                    "invalid or duplicate Responses output item")
                            (put items index (part :item)))
                          (when (index-of last-event ["response.completed" "response.incomplete"])
                            (set confirmed true)
                            (def status (if (= last-event "response.completed") "completed" "incomplete"))
                            (def completed (part :response))
                            (assert (and (dictionary? completed)
                                         (or (not (has-key? completed :status)) (= status (completed :status))))
                                    "invalid Responses terminal event")
                            (def output @[])
                            (each index (sorted (keys items))
                              (assert (= index (length output)) "missing finalized Responses output item")
                              (array/push output (items index)))
                            (set terminal (merge completed {:status status :output output}))))
                        (when (string/has-prefix? "data:" field)
                          (def value (string/slice field 5))
                          (array/push data (if (string/has-prefix? " " value) (string/slice value 1) value)))))
                    (buffer/push-byte line byte)))))
            (not (nil? terminal))))))
      (set confirmed true)
      (unless (<= 200 (response :status) 299)
        (def payload (when (string/find "application/json" (get-in response [:headers "content-type"] ""))
          (json/decode (response :body) true true)))
        (def failure (get payload :error))
        (error {:code (string (or (get failure :code) (string "HTTP" (response :status))))
                :message (or (get failure :message) (get payload :message) (response :message))
                :detail (response :body)}))
      (def value (if streaming
        (do
          (unless terminal (error {:code "IncompleteModelStream" :message "Responses stream closed without a terminal response."}))
          terminal)
        (json/decode (response :body) true true)))
      (assert (dictionary? value) "model response must be an object")
      (when-let [failure (or (value :error) (get-in value [:choices 0 :error]))]
        (error {:code (string (or (failure :code) "ProviderError"))
                :message (failure :message) :detail (string (json/encode failure))}))
      value)
    ([err fiber]
      (def failure (schema/diagnostic "ProviderError" err fiber))
      (error (merge failure
        (if (and response (not (get err :detail))) {:detail (string (get failure :detail "") "\n" (response :body))} {})
        {:context (merge (get failure :context {})
          {:provider (reference :provider) :path path :status (get response :status)
           :model (reference :id) :protocol (reference :protocol) :last-event last-event :finalized-items (length items)
           :outcome (if confirmed "failed" (get-in failure [:context :outcome] "unknown"))})})))))

(defn decode [selected response]
  (def value (if (= "responses" (selected :protocol))
    (do
      (assert (index-of (response :status) ["completed" "incomplete"]) "Responses did not complete")
      (assert (indexed? (response :output)) "invalid Responses output")
      (def text @[]) (def refusal @[]) (def reasoning @[]) (def calls @[])
      (var phase nil) (var bottom nil)
      (each item (response :output)
        (unless (= "reasoning" (item :type)) (set bottom item))
        (case (item :type)
          "message"
          (do
            (assert (and (= "assistant" (item :role)) (indexed? (item :content))) "invalid Responses assistant message")
            (set phase (item :phase))
            (when phase (assert (index-of phase ["commentary" "partial_answer" "final_answer"]) "unsupported Responses message phase"))
            (each part (item :content)
              (case (part :type)
                "output_text" (unless (index-of phase ["commentary" "partial_answer"]) (array/push text (part :text)))
                "refusal" (array/push refusal (part :refusal)))))
          "reasoning" (each part (get item :summary []) (array/push reasoning (part :text)))
          "function_call" (do
                            (assert (and (string? (item :call_id)) (string? (item :name)) (string? (item :arguments))) "invalid Responses function call")
                            (when (and (= "completed" (response :status)) (has-key? item :status))
                              (assert (= "completed" (item :status)) "unfinished Responses function call"))
                            (array/push calls {:id (item :call_id) :type "function"
                                               :function {:name (item :name) :arguments (item :arguments)}}))))
      {:message {:role "assistant" :content (string/join text "\n") :refusal (string/join refusal "\n")
                 :reasoning_content (string/join reasoning "\n") :tool_calls calls
                 :response {:model (selected :reference) :protocol (selected :protocol) :items (response :output)
                            :phase phase :end-turn (response :end_turn)
                            :reasoning-tokens (get-in response [:usage :output_tokens_details :reasoning_tokens] 0)}}
       :final (and (= "message" (get bottom :type)) (not= false (response :end_turn))
         (not (index-of (get bottom :phase) ["commentary" "partial_answer"])))
       :finish-reason (if (= "completed" (response :status))
                        (if (> (length calls) 0) "tool_calls" "stop")
                        (case (get-in response [:incomplete_details :reason])
                          "content_filter" "content_filter" "max_output_tokens" "length" "incomplete"))
       :usage (when-let [usage (response :usage)]
                {:prompt_tokens (usage :input_tokens) :completion_tokens (usage :output_tokens) :total_tokens (usage :total_tokens)
                 :prompt_tokens_details {:cached_tokens (get-in usage [:input_tokens_details :cached_tokens])}
                 :completion_tokens_details {:reasoning_tokens (get-in usage [:output_tokens_details :reasoning_tokens])}
                 :response usage})})
    (do
      (assert (and (indexed? (response :choices)) (= 1 (length (response :choices)))) "expected one assistant choice")
      (def choice ((response :choices) 0))
      (assert (string? (choice :finish_reason)) "missing assistant finish reason")
      (assert (dictionary? (choice :message)) "invalid Chat Completions message")
      {:message (merge (choice :message)
                  {:response {:model (selected :reference) :protocol (selected :protocol)
                              :reasoning-tokens (get-in response [:usage :completion_tokens_details :reasoning_tokens] 0)}})
       :final (and (= "stop" (choice :finish_reason)) (= 0 (length (get-in choice [:message :tool_calls] []))))
       :finish-reason (choice :finish_reason)
       :native-finish-reason (choice :native_finish_reason) :usage (response :usage)})))
  (def finish (value :finish-reason))
  (def message (value :message))
  (def status (cond
    (= "content_filter" finish) "blocked"
    (> (length (get message :refusal "")) 0) "refused"
    (and (index-of finish ["stop" "tool_calls"]) (value :final)) "complete"
    (and (index-of finish ["stop" "tool_calls"]) (> (length (get message :tool_calls [])) 0)) "tools"
    (= "stop" finish) "continue"
    (error {:code "IncompleteModelResponse" :message (string "Model response ended with " finish ".")
      :context {:finish-reason finish :native-finish-reason (value :native-finish-reason)
        :response-status (response :status) :incomplete-details (response :incomplete_details)}})))
  (merge (schema/project value [:final] true) {:status status}))

(defn messages [body]
  (if (has-key? body :messages) (body :messages)
    (array/concat @[{:role "system" :content (body :instructions)}]
      (map (fn [item]
             {:role (get item :role (item :type))
              :content (case (item :type)
                         "function_call" (item :arguments)
                         "function_call_output" (item :output)
                         "reasoning" (map |{:type "text" :text ($ :text)} (get item :summary []))
                         (let [content (item :content)]
                           (if (string? content) content
                             (map |(case ($ :type)
                                     "input_text" {:type "text" :text ($ :text)}
                                     "output_text" {:type "text" :text ($ :text)}
                                     "input_image" {:type "image_url" :image_url {:url ($ :image_url) :detail ($ :detail)}}
                                     "refusal" {:type "text" :text ($ :refusal)} $) content))))
              :metadata (schema/project item [:role :content :arguments :output :summary] true)}) (body :input)))))
