(import ./config)
(import ./model)
(import ./memory)

(defn summarize [invoke spec &opt text]
  (if (indexed? spec) spec
    (do
      (def response (unless text (invoke :chat [{:summary true :node (spec :node) :recipe (spec :recipe)
        :quota (spec :limit) :messages
        [{:role "system" :parts [{:type "text" :text (string memory/instructions " Limit: " (spec :limit) " UTF-8 bytes, including citations.")}]}
         {:role "user" :parts [{:type "text" :text (spec :text)}]}]}])))
      (when response (assert (= "answer" (response :stop)) "summary generation did not finish"))
      (invoke :memory-save [spec (or text (response :text))]))))
(defn manual [invoke request]
  (label complete
    (while true
      (def specs (invoke :memory-summary [request]))
      (when (request :text)
        (return complete [(summarize invoke (first specs) (request :text))]))
      (when (every? (map indexed? specs)) (return complete specs))
      (each spec specs (unless (indexed? spec) (summarize invoke spec))))))
(defn assemble [invoke input exchanges]
  (def public (invoke :exposure []))
  (def system {:role "system" :parts [{:type "text" :text (string (public :instructions) "\n\n" (public :documentation))}]})
  (def state {:role "user" :parts [{:type "text" :text (string "Settings and resources:\n"
    (config/encode (tabseq [k :in [:settings :resources]] k (public k)))
    "\n\nSaved world bindings (evidence):\n```clojure\n" (invoke "world/view" []) "\n```")}]})
  (def parts @[{ :type "text" :text (get input :text "")}])
  (each image (get input :images []) (array/push parts {:type "image" :url (string "data:" (image :type) ";base64," (image :data))}))
  (def user {:role "user" :parts parts})
  (def fixed (model/estimate [system state user exchanges model/tool]))
  (def ceiling (- (public :window) (public :reserve)))
  (assert (<= fixed ceiling) "fixed input and output reserve exceed model window")
  (var room (min (public :memory) (- ceiling fixed)))
  (def excluded (distinct (array/concat @[(input :source)] (catseq [m :in exchanges] (get m :sources [])))))
  (def plan (merge (invoke :memory-plan [(get input :text "") room excluded])))
  (def ranks (if (empty? (plan :candidates)) []
    (invoke :rerank [{:query (get input :text "") :documents (map |($ :text) (plan :candidates))}])))
  (label assembled (while true
    (put plan :room room)
    (var evidence (invoke :memory-select [plan ranks]))
    (while (evidence :summary)
      (summarize invoke (evidence :summary))
      (set evidence (invoke :memory-select [plan ranks])))
    (def messages @[system state])
    (each key [:chronological :semantic] (unless (empty? (evidence key))
      (array/push messages {:role "user" :parts [{:type "text" :text (string key " evidence:\n" (evidence key))}]})))
    (array/push messages user) (array/concat messages exchanges)
    (def size (model/estimate [messages model/tool]))
    (if (<= size ceiling) (return assembled {:messages messages :manifest (evidence :manifest)})
      (do (-= room (max 1 (- size ceiling))) (assert (> room 0) "prompt exceeds model window"))))))
(defn run [input invoke rounds]
  (label answer
    (def exchanges @[])
    (repeat rounds
      (def changes (invoke :updates []))
      (each change changes (array/push exchanges {:role "user" :sources [(change :id)]
        :parts [{:type "text" :text (string "Execution outcome [#" (change :id) "]:\n" (change :text))}]}))
      (def context (assemble invoke input exchanges))
      (def response (invoke :chat [{:messages (context :messages) :tools true :manifest (context :manifest)}]))
      (array/push exchanges (response :message))
      (each call (response :calls)
        (def admission (invoke :admission [(response :output) (call :id)]))
        (array/push exchanges {:role "tool" :call (call :id)
          :parts [{:type "text" :text (config/encode admission)}]}))
      (case (response :stop)
        "tools" nil
        "continue" nil
        "answer" (if (invoke :pending []) (invoke :listen []) (return answer (response :text)))
        "refused" (if (invoke :pending []) (invoke :listen []) (return answer (response :text)))
        "blocked" (error {:code "ModelBlocked" :message "Provider blocked the request."})
        (error {:code "IncompleteModelResponse" :message "Provider did not complete the response."})))
    (error {:code "RoundLimit" :message "Model round limit exhausted."})))
