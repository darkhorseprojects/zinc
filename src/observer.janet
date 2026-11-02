(import spork/json :as json)
(import ./store)
(import ./memory)
(import ./model)

(defn message [event config]
  (when (event :branch)
    (def data (json/decode (event :data) true true))
    (def origin (data :world))
    (def durable (= 0 (event :branch_temporary)))
    (def body (case (event :kind)
      "response" (model/render event)
      "completed" (if (event :public_message) (model/render event) (event :text))
      "model-outcome" (when (and (= "chat" (data :role)) (data :visible)) (model/render event))
      "interruption" (when (= "uncertain" (data :state)) (event :text))
      "artifact" (when (data :display) (event :text))
      "saved" (string "Saved " (data :ref) " @ " (string/slice (data :base) 0 7) "\n" (event :text))
      "summary" (string "summary " (if durable "#" "local ") (event :id) " · " (data :count)
                        " records · source range " (data :first) "–" (data :last))
      (when (and (not= false (data :display)) (index-of (event :kind) ["code-admission" "tool-result" "tool-ambiguity" "error" "launch-uncertain"]))
        (if-let [failure (data :error)]
          (string/trim (string (get-in failure [:context :output] "") "\n" (failure :code) ": " (failure :message))) (event :text)))))
    (when body
      (merge {:body (if (and (event :public_message) (data :status) (not (index-of (data :status) ["complete" "tools"])))
               (string body "\n\n[" (data :status) "]") body)
       :kind (event :kind) :agent (config :identity)
       :caller (if-let [parent (event :branch_parent)]
                 {:agent (config :identity) :request (event :request) :branch parent} (or (config :caller) :null))
       :prompt (if (or (data :turn) (= "model-outcome" (event :kind))) (event :parent) :null)
       :related (if (and (not (data :turn)) (index-of (event :kind) ["tool-result" "tool-ambiguity" "completed"])) (or (event :parent) :null) :null)
       :status (or (data :status) (case (event :kind) "code-admission" "admitted" "error" "failed" "tool-ambiguity" "uncertain" "launch-uncertain" "uncertain" "interruption" "uncertain"
                                  (if (or (data :error) (= false (data :ok))) "failed" "complete")))
       :run (event :run) :branch (event :branch) :request (event :request)
       :persist durable :sequence (event :id)
       :world {:path (origin :path) :blob (or (data :blob) (origin :blob)) :ref (or (data :ref) (origin :ref))}}
             (when (data :error) {:diagnostic (data :error)})))))

(defn drain [s run progress]
  (while true
    (def records (memory/events s run (progress 0)))
    (each event records
      (when-let [frame (message event (s :config))] (print (json/encode frame)))
      (put progress 0 (event :id)))
    (when (< (length records) 256) (break))))

(defn outcome [s call]
  (def row (store/call s (call :id)))
  (def result (first (store/query s "SELECT data FROM events WHERE call=? AND kind='call-result' ORDER BY id DESC LIMIT 1" [(call :id)])))
  (def data (when result (json/decode (result :data) true true)))
  (merge {:run (call :run) :branch (call :id) :state (row :state)
          :value (if (and (= "done" (row :state)) (= "text" (row :kind)))
                   {:text ((first (store/query s "SELECT text FROM memory_records WHERE branch=? AND kind='completed' ORDER BY id DESC LIMIT 1" [(call :id)])) :text)}
                   (get data :value))}
         (when (get data :error) {:error (data :error)})))

(defn receipt [call]
  {:type "admission" :run (call :run) :branch (call :id) :request (call :request)
   :persist (= 0 (call :temporary))})

(defn run [s call progress]
  (print (json/encode (receipt call)))
  (put progress 1 true)
  (while true
    (def pending (store/query s `SELECT c.state,c.lease_expires,
      min(coalesce(c.expires,1e999),coalesce(r.expires,1e999)) expires FROM main.call_controls c
      JOIN main.call_controls r ON r.id=coalesce(c.root,c.id) JOIN call_payloads p ON p.id=c.id
      WHERE p.run=? AND c.kind<>'summarize' AND c.state IN ('queued','running','waiting')` [(call :run)]))
    (drain s (call :run) progress)
    (when (= 0 (length pending)) (break))
    (each row pending
      (assert (and (> (row :expires) (os/clock))
                   (or (= "queued" (row :state)) (> (row :lease_expires) (os/clock))))
              "executor lease or deadline expired; inspect before resuming"))
    (ev/sleep store/interval))
  (outcome s call))
