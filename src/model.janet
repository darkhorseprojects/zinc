(import spork/utf8 :as utf8)
(import spork/json :as json)
(import spork/base64 :as base64)
(import ./store)
(import sqlite3 :as sql)

(defn transfer [[config provider method path body current limits]]
  (setdyn :pa/limits limits)
  (assert provider "provider is not configured")
  (def db (when current (sql/open (config :store))))
  (when db (sql/eval db "PRAGMA busy_timeout=5000;"))
  (def native (unless (provider :transport) (require "jurl/native")))
  (def client (when native ((module/value native 'new))))
  (def bytes @"")
  (var next-check 0)
  (var permitted true)
  (defer (do (when client ((module/value native 'reset) client)) (when db (sql/close db)))
    (def check (fn [& counts]
                 (when (and current (>= (os/clock) next-check))
                   (set next-check (+ (os/clock) 0.1))
                   (set permitted (not (nil? (first
                     (sql/eval db "SELECT id FROM live_calls WHERE id=? AND source=? AND owner=?"
                       [(current :id) (config :source) (current :owner)]))))))
                 permitted))
    (assert (check) "HTTP job fenced")
    (def url (string (provider :url) path))
    (def headers {:content-type "application/json" :accept "application/json"
                  :authorization (when (provider :token) (string "Bearer " (provider :token)))})
    (def response
      (if-let [transport (provider :transport)]
        (with-dyns [:capability/config (transport :config)]
          ((module/value (require (transport :module)) 'request) url method body headers))
        (do
          (def options {:url url :customrequest method :postfields body
            :httpheader (seq [[name value] :in (pairs headers) :unless (nil? value)] (string name ": " value))
            :writefunction (fn [chunk]
              (assert (<= (+ (length bytes) (length chunk)) (config :response-bytes)) "HTTP response exceeds byte limit")
              (buffer/push-string bytes chunk))
            :followlocation false :ssl-verifypeer true :ssl-verifyhost 2
            :timeout-ms (config :http-ms) :connecttimeout-ms (min 10000 (config :http-ms))
            :protocols "http,https" :noprogress false :xferinfofunction check})
          (each [key value] (pairs options) (unless (nil? value) (put client key value)))
          (def status (:perform client))
          {:error status :status (client :response-code) :body (string bytes)})))
    (def data (response :body))
    (assert (<= (length data) (config :response-bytes)) "HTTP response exceeds byte limit")
    (assert (= :ok (response :error)) (string "HTTP transfer failed: " (response :error) "; effects may have happened"))
    (assert (utf8/is-valid? data) "model response is not UTF-8")
    (assert (<= 200 (response :status) 299) (string "model HTTP " (response :status) ": " data))
    data))

(def tool
  {:type "function" :function
   {:name "run_janet" :description "Evaluate Janet in the current world."
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
  (def current (dyn :zinc/call))
  (def args [{:store (config :store) :source (config :source) :response-bytes (config :response-bytes) :http-ms (config :http-ms)}
    provider method path (when body (json/encode body)) (when current {:id (current :id) :owner (current :owner)}) (dyn :pa/limits)])
  (def output (if (provider :transport) (transfer args)
    (let [finished (ev/thread-chan 1)]
      (ev/thread transfer args :n finished)
      (defer (ev/chan-close finished)
        (def [status result] (ev/take finished))
        (assert (= :ok status) (string result)) result))))
  (def value (json/decode output true (not preserve-nulls)))
  (assert (dictionary? value) "model response must be an object")
  (when (value :error) (error (string "provider error: " (json/encode (value :error)))))
  value)

(defn catalogue [config role &opt provider]
  (assert (index-of role ["chat" "rerank"]) "unsupported model role")
  (def models @[])
  (each name (if provider [(keyword provider)] (keys (config :providers)))
    (def response (request config {:provider (string name)} "GET"
                           (if (= :openrouter name) (string "/v1/models?output_modalities=" (if (= role "chat") "text" "rerank")) "/v1/models") nil provider))
    (assert (and (dictionary? response) (indexed? (response :data))) "invalid model catalogue")
    (def identities @{})
    (each record (response :data)
      (assert (and (dictionary? record) (string? (record :id)) (> (length (record :id)) 0)
                   (not (identities (record :id)))) "invalid or duplicate model ID")
      (put identities (record :id) true)
      (array/push models (merge record {:ref (string name ":" (record :id)) :name (get record :name (record :id))}))))
  (sorted models |(< ($0 :ref) ($1 :ref))))

(defn profile [s reference role]
  (def config (s :config))
  (def key [(config :providers) reference role (config :thinking)])
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
      (def control (if (= provider "llama")
        (when (get-in record [:chat_template_caps :supports_reasoning_effort]) :reasoning_effort)
        (cond (index-of "reasoning" parameters) :reasoning (index-of "reasoning_effort" parameters) :reasoning_effort)))
      (when (and (= role :chat) (not (index-of (config :thinking) ["default" "none"])))
        (assert control "thinking effort is unsupported"))
      (def advertised (when (= provider "openrouter") (get-in record [:top_provider :max_completion_tokens])))
      (def output (unless (= :null advertised) advertised))
      (when output (assert (and (int? output) (<= 1 output context)) "invalid provider output capacity"))
      (def selected (merge ref {:context context :output output :control control
        :tools (if (= provider "llama")
          (and (get-in record [:chat_template_caps :supports_tools]) (get-in record [:chat_template_caps :supports_tool_calls]))
          (not (nil? (index-of "tools" parameters))))
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
    "SELECT id,data FROM events WHERE source=? AND parent=? AND kind='model-outcome'" [(s :source) pending]))))
  (if cached (merge (json/decode (cached :data) true true) {:event (cached :id)})
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
          (assert (<= size (config :context-quota)) "model input exceeds context quota")
          (def requested (get input :output (config :output)))
          (assert (and (int? requested) (>= requested 0)) "invalid requested output limit")
          (def cap (if (= 0 (min requested (config :output))) (max requested (config :output)) (min requested (config :output))))
          (def maximum (min (or (selected :output) (selected :context))
            (if (= 0 cap) (or (selected :output) (math/floor (/ (selected :context) 2))) cap) (- (selected :context) size)))
          (assert (> maximum 0) "approximate context capacity exhausted")
          (def body @{:model (selected :id) :messages (input :messages) :max_tokens maximum :stream false})
          (when (input :tools)
            (assert (selected :tools) "model does not support tools")
            (put body :tools (input :tools))
            (when (selected :parallel) (put body :parallel_tool_calls true)))
          (unless (= "default" (config :thinking))
            (case (selected :control)
              :reasoning (put body :reasoning (if (= "none" (config :thinking)) {:enabled false} {:effort (config :thinking)}))
              :reasoning_effort (put body :reasoning_effort (config :thinking))))
          (when (= "openrouter" (selected :provider)) (put body :provider {:require_parameters true :allow_fallbacks false}))
          [body size maximum])))
      (def current (dyn :zinc/call))
      (def admission (store/transact s
        (store/checkpoint s)
        (store/charge s 1 0)
        (def event (store/append s (current :scope) "model-admission" (selected :reference)
          {:input input :estimate size :output maximum} nil (current :id)))
        (store/checkpoint s (merge (current :checkpoint) {:request (event :id)})) (event :id)))
      (def value (request config selected "POST" (if (= role "rerank") "/v1/rerank" "/v1/chat/completions") body))
      (account s admission selected (value :usage))
      (def result (merge
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
            (def message (choice :message))
            (assert (and (dictionary? message) (= "assistant" (message :role))) "invalid assistant message")
            (def content (message :content))
            (def text (cond (nil? content) (or (message :refusal) "") (string? content) content
              (indexed? content) (string/join (seq [part :in content :when (= "text" (part :type))] (part :text)) "\n")
              (error "invalid assistant content")))
            (def refusal (message :refusal))
            (when refusal (assert (string? refusal) "invalid refusal"))
            (def reasoning (or (message :reasoning_content) (message :reasoning) ""))
            (assert (and (string? text) (string? reasoning) (utf8/is-valid? text) (utf8/is-valid? reasoning)) "invalid assistant text")
            (def calls (or (message :tool_calls) []))
            (assert (and (indexed? calls) (<= (length calls) (config :tool-calls))) "invalid tool calls")
            (def identities @{})
            (var invalid nil)
            (def tools (try (if (= "tool_calls" (choice :finish_reason)) (map (fn [call]
              (assert (and (dictionary? call) (= "function" (call :type)) (string? (call :id))
                (> (length (call :id)) 0) (not (identities (call :id))) (= "run_janet" (get-in call [:function :name]))) "invalid or duplicate tool call")
              (put identities (call :id) true)
              (def arguments (json/decode (get-in call [:function :arguments]) true true))
              (assert (and (dictionary? arguments) (= [:code] (tuple/slice (sort (keys arguments))))
                (string? (arguments :code)) (> (length (arguments :code)) 0)) "invalid Janet tool source")
              {:id (call :id) :code (arguments :code)}) calls) []) ([err] (set invalid (string err)) [])))
            (assert (indexed? (or (message :reasoning_details) [])) "invalid reasoning details")
            {:text text :message message :finish-reason (choice :finish_reason) :error invalid :tools tools
             :reasoning-visible (not= "none" (config :thinking))
             :status (cond invalid "invalid" (and refusal (> (length refusal) 0)) "refused"
               (= "length" (choice :finish_reason)) "truncated" (= "content_filter" (choice :finish_reason)) "blocked"
               (and (= "tool_calls" (choice :finish_reason)) (input :tools) (> (length tools) 0)) "tools"
               (and (= "stop" (choice :finish_reason)) (= 0 (length calls))) "complete" "invalid")}))
        {:usage (value :usage) :model selected :request admission :role role :turn (get input :turn false)
         :visible (and (not (input :turn)) (not= "summarize" (current :kind)))}))
      (def event (store/transact s
        (assert (first (store/query s "SELECT id FROM main.call_controls WHERE id=? AND source=? AND owner=? AND state IN ('running','waiting','uncertain','cancelled')"
          [(current :id) (s :source) (current :owner)])) "model completion fenced")
        (store/append s (current :scope) "model-outcome" "Model outcome committed." result admission (current :id))))
      (merge result {:event (event :id)}))))

(defn render [row data]
  (def message (if (row :public_message) (json/decode (row :public_message) true true) {}))
  (def parts @[])
  (def reasoning (string/join (distinct (filter |(and (string? $) (> (length (string/trim $)) 0))
    (array/concat @[(message :reasoning_content) (message :reasoning)]
      (map |(if (and (dictionary? $) (has-key? $ :text)) (if (string? ($ :text)) ($ :text) (string (json/encode ($ :text)))) (string (json/encode $))) (get message :reasoning_details []))))) "\n"))
  (when (> (length reasoning) 0)
    (array/push parts (string "> " (string/replace-all "\n" "\n> " (string/replace-all "\r" "\n" (string/replace-all "\r\n" "\n" (string/trimr reasoning)))))))
  (def text (if (data :results) (string (json/encode (data :results))) (row :text)))
  (when (> (length (string/trim text)) 0) (array/push parts text))
  (def extra (tabseq [[key value] :in (pairs message) :unless (index-of key [:role :content :refusal :tool_calls :reasoning :reasoning_content :reasoning_details])] key value))
  (each value [(when (indexed? (message :content)) (filter |(not= "text" ($ :type)) (message :content)))
              (when (index-of (data :status) ["invalid" "truncated"]) (message :tool_calls)) extra]
    (when (and value (> (length value) 0)) (array/push parts (string "```json\n" (json/encode value) "\n```"))))
  (unless (index-of (get data :status "complete") ["complete" "tools"]) (array/push parts (string "[" (data :status) "]")))
  (when (= 0 (length parts)) (array/push parts "[empty model response]"))
  (when (= "model-outcome" (row :kind)) (array/insert parts 0 (string "**" (data :role) " model outcome**")))
  (string/join parts "\n\n"))

(defn images [s event text]
  (def parts @[{:type "text" :text text}])
  (each row (store/query s "SELECT mime,bytes FROM images WHERE event=? ORDER BY position" [event])
    (array/push parts {:type "image_url" :image_url {:url (string "data:" (row :mime) ";base64," (base64/encode (string (row :bytes))))}}))
  parts)
