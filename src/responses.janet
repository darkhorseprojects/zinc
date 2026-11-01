(import ./schema)

(defn encode [body reference]
  (def input @[])
  (def result (merge (schema/project body [:messages :stream_options :reasoning_effort] true)
                    {:input input :store false :include ["reasoning.encrypted_content"]}))
  (eachp [index message] (body :messages)
    (def content (message :content))
    (case (message :role)
      "system" (if (= index 0) (put result :instructions content)
                   (array/push input {:role "developer" :content content}))
      "user" (array/push input {:role "user" :content
                                (if (string? content) [{:type "input_text" :text content}]
                                  (map (fn [part]
                                         (case (part :type)
                                           "text" {:type "input_text" :text (part :text)}
                                           "image_url" {:type "input_image" :image_url (get-in part [:image_url :url])
                                                        :detail (get-in part [:image_url :detail] "auto")}
                                           (error "unsupported Responses user content"))) content))})
      "assistant"
      (if (= reference (get-in message [:response :model]))
        (array/concat input (get-in message [:response :items]))
        (do
          (def text (if (indexed? content)
                      (string/join (map (fn [part] (assert (= "text" (part :type)) "unsupported Responses assistant content") (part :text)) content) "\n")
                      (if (and (string? content) (> (length content) 0)) content (or (message :refusal) ""))))
          (when (> (length text) 0) (array/push input {:role "assistant" :content text}))
          (each call (get message :tool_calls [])
            (array/push input {:type "function_call" :call_id (call :id)
                               :name (get-in call [:function :name]) :arguments (get-in call [:function :arguments])}))))
      "tool" (array/push input {:type "function_call_output" :call_id (message :tool_call_id) :output content})
      (error "unsupported Responses message role")))
  (unless (has-key? result :instructions) (put result :instructions ""))
  (when (body :tools)
    (put result :tools (map |(if (= "function" ($ :type)) (merge ($ :function) {:type "function" :strict false}) $) (body :tools))))
  (when (body :reasoning_effort) (put result :reasoning {:effort (body :reasoning_effort)}))
  (unless (= "none" (get-in result [:reasoning :effort]))
    (put result :reasoning (merge {:summary "auto"} (get result :reasoning {}))))
  result)

(defn decode [body]
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
            :metadata (schema/project item [:role :content :arguments :output :summary] true)}) (body :input))))

(defn message [response reference]
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
  {:role "assistant" :content (string/join text "\n") :refusal (string/join refusal "\n")
   :reasoning_content (string/join reasoning "\n") :tool_calls calls
   :response {:model reference :items (response :output)
              :reasoning-tokens (get-in response [:usage :output_tokens_details :reasoning_tokens] 0)}})

(defn event [state part reference]
  (def updates @[])
  (case (part :type)
    "error" (error "Responses stream error")
    "response.failed" (error "Responses generation failed")
    "response.output_item.added"
    (when (= "function_call" (get-in part [:item :type]))
      (def indices (get state :indices @{}))
      (put state :indices indices)
      (def index (length indices))
      (assert (not (has-key? indices (part :output_index))) "duplicate Responses output index")
      (put indices (part :output_index) index)
      (def item (part :item))
      (array/push updates {:tool_calls [{:index index :id (item :call_id) :type "function"
                                        :function {:name (item :name) :arguments (get item :arguments "")}}]}))
    "response.output_text.delta" (array/push updates {:content (part :delta)})
    "response.refusal.delta" (array/push updates {:refusal (part :delta)})
    "response.reasoning_summary_part.added" (when (> (part :summary_index) 0) (array/push updates {:reasoning_content "\n"}))
    "response.reasoning_summary_text.delta" (array/push updates {:reasoning_content (part :delta)})
    "response.function_call_arguments.delta"
    (do
      (def index (get-in state [:indices (part :output_index)]))
      (assert (int? index) "Responses arguments have no function call")
      (array/push updates {:tool_calls [{:index index :function {:arguments (part :delta)}}]}))
    nil)
  (when (index-of (part :type) ["response.completed" "response.done" "response.incomplete"])
    (def response (part :response))
    (assert (index-of (response :status) ["completed" "incomplete"]) "Responses did not complete")
    (def final (message response reference))
    (put state :message final)
    (put state :finish-reason (if (= "completed" (response :status))
                               (if (> (length (final :tool_calls)) 0) "tool_calls" "stop")
                               (if (= "content_filter" (get-in response [:incomplete_details :reason])) "content_filter" "length")))
    (when-let [usage (response :usage)]
      (put state :usage {:prompt_tokens (usage :input_tokens) :completion_tokens (usage :output_tokens)
                         :total_tokens (usage :total_tokens)
                         :prompt_tokens_details {:cached_tokens (get-in usage [:input_tokens_details :cached_tokens])}
                         :completion_tokens_details {:reasoning_tokens (get-in usage [:output_tokens_details :reasoning_tokens])}
                         :response usage}))
    (put state :done true))
  updates)
