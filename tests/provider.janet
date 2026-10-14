(import spork/json :as json)

(defn request [url method body headers send config]
  (send (string (json/encode
    (cond
      (string/find "/v1/models" url) {:data [{:id "fixture"}]}
      (string/find "/props" url) {:default_generation_settings {:n_ctx 8192}
                                 :chat_template_caps {:supports_tools true :supports_tool_calls true}}
      {:choices [{:index 0 :message {:role "assistant" :content "fixture answer"} :finish_reason "stop"}]
       :usage {:prompt_tokens 10 :completion_tokens 2 :total_tokens 12}}))))
  {:status 200 :error :ok})
