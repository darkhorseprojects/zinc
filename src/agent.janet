(import ./config)

(defn run [input invoke evaluate context rounds]
  (label answer
  (var exchanges @[])
  (repeat rounds
    (def messages (context invoke input exchanges))
    (set exchanges (messages :exchanges))
    (def response (invoke "model/chat" [{:messages (messages :messages) :tools true :manifest (messages :manifest)}]))
    (def start (length exchanges))
    (array/push exchanges (response :message))
    (case (response :stop)
      "tools"
      (do
        (def tasks (map (fn [call]
          (invoke "async" [(fn []
            (try
              (do (when (call :error) (error (call :error)))
                (evaluate (call :code)))
              ([err] {:error (config/diagnostic err)})))])) (response :calls)))
        (each [i task] (pairs tasks)
          (def value (invoke "await" [task]))
          (array/push exchanges {:role "tool" :call (((response :calls) i) :id)
            :parts [{:type "text" :text (config/encode value)}]})))
      "continue" nil
      "answer" (return answer (response :text))
      "refused" (return answer (response :text))
      "blocked" (error {:code "ModelBlocked" :message "The provider blocked this request."})
      (error {:code "IncompleteModelResponse" :message "The model did not finish its response."}))
    (invoke "memory/record" [{:text (config/encode (array/slice exchanges start))}]))
  (error {:code "RoundLimit" :message "Model round limit exhausted."})))
