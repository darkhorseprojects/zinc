(import spork/json :as json)
(import ./schema)
(import ./io)
(import ./protocol)

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
        (case (selected :control)
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
              (if (= (selected :reference) (get-in message [:response :model]))
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
        (put body :messages (map |(schema/project $ [:response] true) (body :messages))))))
  (schema/encode body))

(defn request [config reference path &opt body]
  (def endpoint (get-in config [:providers (keyword (reference :provider))]))
  (def supplied (when body (json/decode body true true)))
  (when (and body (has-key? endpoint :models))
    (assert (has-key? (endpoint :models) (keyword (supplied :model))) "model is not granted"))
  (def streaming (get supplied :stream false))
  (var pending "") (var terminal nil) (var response nil) (var confirmed false)
  (try
    (do
      (set response (io/request config endpoint (if body "POST" "GET") path body
        (when streaming
          (fn [chunk]
            (set pending (string/replace-all "\r\n" "\n" (string pending chunk)))
            (var boundary nil)
            (while (set boundary (string/find "\n\n" pending))
              (def data (string/trim (string/join (seq [line :in (string/split "\n" (string/slice pending 0 boundary)) :when (string/has-prefix? "data:" line)] (string/slice line 5)) "\n")))
              (set pending (string/slice pending (+ boundary 2)))
              (unless (= "" data)
                (if (= "[DONE]" data)
                  (assert terminal "Responses stream has no terminal response")
                  (do
                    (assert (nil? terminal) "trailing model stream data")
                    (def part (json/decode data true true))
                    (case (part :type)
                      "error" (do (set confirmed true)
                        (error {:code (or (part :code) "ProviderError")
                                :message (part :message) :detail (string (json/encode part))}))
                      "response.failed"
                      (let [failure (get-in part [:response :error])]
                        (set confirmed true)
                        (error {:code (or (failure :code) "ProviderError")
                                :message (failure :message) :detail (string (json/encode part))})))
                    (when (index-of (part :type) ["response.completed" "response.done" "response.incomplete"])
                      (set terminal (part :response)))))))))))
      (set confirmed true)
      (unless (<= 200 (response :status) 299)
        (def payload (when (string/find "application/json" (get-in response [:headers "content-type"] ""))
          (json/decode (response :body) true true)))
        (def failure (get payload :error))
        (error {:code (or (get failure :code) (string "HTTP" (response :status)))
                :message (or (get failure :message) (get payload :message) (response :message))
                :detail (response :body)}))
      (def value (if streaming
        (do (assert (and terminal (= "" (string/trim pending))) "incomplete Responses stream") terminal)
        (json/decode (response :body) true true)))
      (assert (dictionary? value) "model response must be an object")
      (when-let [failure (or (value :error) (get-in value [:choices 0 :error]))]
        (error {:code (or (failure :code) "ProviderError")
                :message (failure :message) :detail (string (json/encode failure))}))
      value)
    ([err fiber]
      (def failure (protocol/diagnostic "ProviderError" err fiber))
      (error (merge failure
        (if (and response (not (get err :detail))) {:detail (string (get failure :detail "") "\n" (response :body))} {})
        {:context (merge (get failure :context {})
          {:provider (reference :provider) :path path :status (get response :status)
           :outcome (if confirmed "failed" (get-in failure [:context :outcome] "unknown"))})})))))

(defn decode [selected response]
  (if (= "responses" (selected :protocol))
    (do
      (assert (index-of (response :status) ["completed" "incomplete"]) "Responses did not complete")
      (assert (indexed? (response :output)) "invalid Responses output")
      (def text @[]) (def refusal @[]) (def reasoning @[]) (def calls @[])
      (each item (response :output)
        (case (item :type)
          "message" (each part (item :content)
                      (case (part :type)
                        "output_text" (array/push text (part :text))
                        "refusal" (array/push refusal (part :refusal))))
          "reasoning" (each part (get item :summary []) (array/push reasoning (part :text)))
          "function_call" (do
                            (assert (and (string? (item :call_id)) (string? (item :name)) (string? (item :arguments))) "invalid Responses function call")
                            (array/push calls {:id (item :call_id) :type "function"
                                               :function {:name (item :name) :arguments (item :arguments)}}))))
      {:message {:role "assistant" :content (string/join text "\n") :refusal (string/join refusal "\n")
                 :reasoning_content (string/join reasoning "\n") :tool_calls calls
                 :response {:model (selected :reference) :items (response :output)
                            :reasoning-tokens (get-in response [:usage :output_tokens_details :reasoning_tokens] 0)}}
       :finish-reason (if (= "completed" (response :status))
                        (if (> (length calls) 0) "tool_calls" "stop")
                        (if (= "content_filter" (get-in response [:incomplete_details :reason])) "content_filter" "length"))
       :usage (when-let [usage (response :usage)]
                {:prompt_tokens (usage :input_tokens) :completion_tokens (usage :output_tokens) :total_tokens (usage :total_tokens)
                 :prompt_tokens_details {:cached_tokens (get-in usage [:input_tokens_details :cached_tokens])}
                 :completion_tokens_details {:reasoning_tokens (get-in usage [:output_tokens_details :reasoning_tokens])}
                 :response usage})})
    (do
      (assert (and (indexed? (response :choices)) (= 1 (length (response :choices)))) "expected one assistant choice")
      (def choice ((response :choices) 0))
      (assert (string? (choice :finish_reason)) "missing assistant finish reason")
      {:message (choice :message) :finish-reason (choice :finish_reason) :usage (response :usage)})))

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
