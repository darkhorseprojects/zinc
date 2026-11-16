(import ./config)
(import ./model)
(import ./memory)

(defn summarize [invoke spec &opt text]
  (def response (unless text (invoke :chat [{:summary true :output (spec :limit) :messages
    [{:role "system" :parts [{:type "text" :text (string memory/instructions " Limit: " (spec :limit) " UTF-8 bytes, including citations.")} ]}
     {:role "user" :parts [{:type "text" :text (spec :text)}]}]}])))
  (when response (assert (= "answer" (response :stop)) "summary generation did not finish"))
  (invoke :memory-save [spec (or text (response :text))]))
(defn manual [invoke request]
  (def specs (invoke :memory-summary [request]))
  (when (request :text) (assert (= 1 (length specs)) "manual text requires one selected subtree"))
  (map |(summarize invoke $ (request :text)) specs))
(defn compose [invoke input exchanges]
  (def public (invoke :exposure []))
  (def system {:role "system" :parts [{:type "text" :text (string (public :instructions) "\n\n"
    (public :documentation) "\n\nSettings and resources:\n" (config/encode (tabseq [k :in [:settings :resources :bindings]] k (public k)))
    "\n\nCurrent world bindings:\n```janet\n" (invoke "world/view" []) "\n```")}]})
  (def parts @[{ :type "text" :text (get input :text "")}])
  (each image (get input :images []) (array/push parts {:type "image" :url (string "data:" (image :type) ";base64," (image :data))}))
  (def user {:role "user" :parts parts}) (def live (array/slice exchanges))
  (while (and (not (empty? live)) (> (model/estimate [system user live]) (/ (public :capacity) 2)))
    (array/remove live 0) (while (and (not (empty? live)) (= "tool" ((first live) :role))) (array/remove live 0)))
  (def room (- (public :capacity) (model/estimate [system user live model/tool]) 768))
  (assert (> room 128) "instructions, bindings and exchanges exhaust context")
  (var plan (invoke :memory-plan [(get input :text "") room]))
  (while (plan :summary) (summarize invoke (plan :summary)) (set plan (invoke :memory-plan [(get input :text "") room])))
  (def ranks (if (empty? (plan :candidates)) [] (invoke :rerank [{:query (get input :text "") :documents (map |($ :text) (plan :candidates))}])))
  (def evidence (memory/finish plan ranks (public :settings)))
  (def messages @[system])
  (each key [:chronological :semantic] (unless (empty? (evidence key))
    (array/push messages {:role "user" :parts [{:type "text" :text (string key " evidence:\n" (evidence key))}]})))
  (array/push messages user) (array/concat messages live)
  {:messages messages :exchanges live :manifest (evidence :manifest)})
(defn run [input invoke evaluate rounds]
  (label answer
    (var exchanges @[])
    (repeat rounds
      (def context (compose invoke input exchanges)) (set exchanges (context :exchanges))
      (def response (invoke :chat [{:messages (context :messages) :tools true :manifest (context :manifest)}]))
      (array/push exchanges (response :message))
      (case (response :stop)
        "tools" (do
          (def tasks (map (fn [call] (invoke "ev/go" [(fn []
            (try (do (when (call :error) (error (call :error))) (evaluate (call :code)))
              ([err fiber] {:error (config/diagnostic err fiber)})))])) (response :calls)))
          (each [i task] (pairs tasks)
            (def value (invoke "await" [task]))
            (invoke :message [{:id (string (response :output) "/result/" i) :type "tool-result" :language "json" :text (config/encode value)}
              (if (and (dictionary? value) (value :error)) "error" "ok")])
            (array/push exchanges {:role "tool" :call (((response :calls) i) :id) :parts [{:type "text" :text (config/encode value)}]})))
        "continue" nil
        "answer" (return answer (response :text))
        "refused" (return answer (response :text))
        "blocked" (error {:code "ModelBlocked" :message "Provider blocked this request."})
        (error {:code "IncompleteModelResponse" :message "The model did not finish its response."})))
    (error {:code "RoundLimit" :message "Model round limit exhausted."})))
