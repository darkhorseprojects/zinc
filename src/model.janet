(import jurl :as http)
(import spork/utf8 :as utf8)
(import jurl/native :as curl)
(import spork/json :as json)
(import spork/base64 :as base64)
(import ./store)

(defn used [s run]
  (((store/query s "SELECT coalesce(sum(u.total),0) used FROM usage u JOIN events e ON e.id=u.request WHERE e.actor=? AND e.run=?" [(s :actor) run]) 0) "used"))

(defn admit [s reference input size output]
  (store/transact s
                  (def current (dyn :zinc/task))
                  (def scope (current :scope))
                  (store/checkpoint s (current :checkpoint))
                  (def event (store/append s scope "model-admission" (reference :reference)
                                           {:input input :estimate size :output output} nil (current :id)))
                  (store/checkpoint s (merge (current :checkpoint) {:request (event "id")}))
                  {:id (event "id") :output output}))

(defn charge [s request reference raw]
  (def previous (first (store/query s "SELECT total FROM usage WHERE request=?" [request])))
  (when (and previous (previous "total") (raw :total_tokens))
    (assert (>= (raw :total_tokens) (previous "total")) "reported usage decreased"))
  (store/query s `INSERT INTO usage(request,provider,model,input,output,total,reasoning,cached,raw) VALUES(?,?,?,?,?,?,?,?,?)
    ON CONFLICT(request) DO UPDATE SET input=excluded.input,output=excluded.output,total=excluded.total,
      reasoning=coalesce(excluded.reasoning,usage.reasoning),cached=coalesce(excluded.cached,usage.cached),raw=excluded.raw`
               [request (reference :provider) (reference :id) (raw :prompt_tokens) (raw :completion_tokens) (raw :total_tokens)
                (get-in raw [:completion_tokens_details :reasoning_tokens]) (get-in raw [:prompt_tokens_details :cached_tokens]) (string (json/encode raw))]))

(defn transfer [[config url method body headers channel cancel transport]]
  (def client (curl/new))

  (defer (curl/reset client)
    (try
      (do
        (def response
          (if transport
            ((module/value (require (transport :module)) 'request)
             url method body headers (fn [chunk] (ev/give-supervisor :packet {:chunk (string chunk)}))
             (transport :config))
          (http/request
            {:client client
             :url url
             :method (keyword (string/ascii-lower method))
             :body body
             :headers (tabseq [[key value] :in (pairs headers) :unless (nil? value)] key value)
             :options
             {:followlocation false
              :ssl-verifypeer true
              :ssl-verifyhost 2
              :timeout-ms (config :http-ms)
              :connecttimeout-ms (min 10000 (config :http-ms))
              :protocols "http,https"
              :noprogress false
              :xferinfofunction (fn [& counts] (= 0 (ev/count cancel)))}
             :stream
             (fn [chunk]
               (ev/give-supervisor :packet {:chunk (string chunk)}))})))

        (ev/give channel [:packet {:status (response :status) :error (response :error)}]))
      ([err] (when (= 0 (ev/count cancel)) (ev/give channel [:packet {:failure (string err)}]))))))

(defn http-request [config url method body headers]
  (def channel (ev/thread-chan))
  (def cancel (ev/thread-chan 1))
  (def provider (find |(string/has-prefix? (($ 1) :url) url) (pairs (config :providers))))
  (ev/thread transfer [config url method body headers channel cancel (get-in provider [1 :transport])] :n channel)
  (def current (dyn :zinc/task))
  (def watcher (when current (ev/go (fn []
                                      (def s (store/open config))
                                      (defer (store/close s)
                                        (try (while true
                                               (ev/sleep 0.1)
                                               (def row (store/task s (current :id)))
                                               (unless (and (= (row "attempt") (current :generation))
                                                            (index-of (row "state") ["running" "waiting"]))
                                                 (ev/give cancel true)
                                                 (ev/give channel [:packet {:failure "HTTP job cancelled"}])
                                                 (break)))
                                          ([err] nil)))))))
  {:channel channel :cancel cancel :watcher watcher})

(defn cancel [transfer]
  (when (and (transfer :watcher) (not= :dead (fiber/status (transfer :watcher))))
    (ev/cancel (transfer :watcher) "finished"))
  (when (= 0 (ev/count (transfer :cancel)))
    (ev/give (transfer :cancel) true))

  (while (not (index-of (first (ev/take (transfer :channel))) [:ok :error])))
  (ev/chan-close (transfer :channel)))

(defn collect-http [transfer]
  (defer (cancel transfer)
    (def bytes @"")
    (var response nil)

    (while (not response)
      (def packet (get (ev/take (transfer :channel)) 1))
      (assert packet "HTTP transfer closed")
      (if (packet :chunk)
        (buffer/push-string bytes (packet :chunk))
        (set response packet)))

    (when (response :failure) (error (response :failure)))
    (assert (= :ok (response :error)) "HTTP transfer failed; effects may have happened")

    (if (utf8/is-valid? bytes)
      {:status (response :status) :body (string bytes)}
      {:status (response :status) :data (base64/encode (string bytes))})))

(def tool {:type "function" :function {:name "run_janet" :description "Evaluate Janet in the current world." :parameters
                                       {:type "object" :additionalProperties false :required ["code"] :properties {:code {:type "string"}}}}})

(defn estimate [messages]
  (store/estimate (json/encode (map (fn [message]
                                   (if (indexed? (message :content))
                                     (merge message {:content (map |(if (= "image_url" ($ :type)) {:type "image_url" :image_url "[image bytes accounted separately]"} $) (message :content))}) message)) messages))))

(defn request [config reference method path &opt body headers]
  (def provider ((config :providers) (keyword (reference :provider))))
  (assert provider "provider is not configured")
  (http-request config (string (provider :url) path) method (when body (json/encode body))
                (merge {:content-type "application/json" :accept "application/json, text/event-stream"
                        :authorization (when (provider :token) (string "Bearer " (provider :token)))} (or headers {}))))

(defn collect [transfer &opt preserve-nulls]
  (def response (collect-http transfer))

  (assert (<= 200 (response :status) 299)
          (string "model HTTP status " (response :status)))
  (assert (response :body) "model response is not UTF-8")

  (json/decode (response :body) true (not preserve-nulls)))

(defn catalogue [config role]
  (assert (index-of role ["chat" "rerank"]) "unsupported model role")
  (def models @[])
  (each name (keys (config :providers))
    (def ref {:provider (string name)})
    (def response (collect (request config ref "GET" (if (= :openrouter name) (string "/v1/models?output_modalities=" (if (= role "chat") "text" "rerank")) "/v1/models"))))
    (assert (and (dictionary? response) (indexed? (response :data))) "invalid model catalogue")
    (def identities @{})
    (each record (response :data)
      (def reference (string name ":" (record :id)))
      (assert (and (dictionary? record) (string? (record :id)) (> (length (record :id)) 0)
                   (not (identities (record :id)))) "invalid or duplicate model ID")
      (put identities (record :id) true)
      (array/push models {:ref reference :name (get record :name (record :id))})))
  (sorted models |(< ($0 :ref) ($1 :ref))))

(defn profile [config reference role]
  (def split (string/find ":" reference))
  (assert split "model reference must be provider:id")
  (def provider (string/slice reference 0 split))
  (def id (string/slice reference (+ split 1)))
  (assert (and (not= "" id) (index-of provider ["llama" "openrouter"])) "unsupported model reference")
  (def ref {:provider provider :id id :reference reference})
  (def record
    (if (= provider "llama")
      (do
        (assert (find |(= ($ :ref) reference) (catalogue config (string role))) "exact model is unavailable")
        (collect (request config ref "GET" (string "/props?model=" (curl/escape id)))))
      (do
        (def catalog (collect (request config ref "GET" (string "/v1/models?output_modalities=" (if (= role :rerank) "rerank" "text"))) true))
        (def record (find |(= ($ :id) id) (catalog :data)))
        (assert record "exact model is unavailable") record)))
  (def context
    (if (= provider "llama")
      (get-in record [:default_generation_settings :n_ctx])
      (if (= role :chat)
        (do
          (assert (and (int? (record :context_length))
                       (int? (get-in record [:top_provider :context_length]))
                       (> (get-in record [:top_provider :context_length]) 1))
                  "invalid provider context capacity")
          (min (record :context_length) (get-in record [:top_provider :context_length])))
        (record :context_length))))
  (assert (and (int? context) (<= 2 context 9007199254740991)) "invalid provider context capacity")
  (def parameters (get record :supported_parameters []))
  (def reasoning (record :reasoning))
  (def thinking (config :thinking))
  (when (and (= role :chat) (= provider "openrouter") (not= thinking "default"))
    (if (= thinking "none") (assert (not= true (get reasoning :mandatory)) "model requires reasoning")
      (assert (or (= :null (get reasoning :supported_efforts))
                  (and (indexed? (get reasoning :supported_efforts))
                       (index-of thinking (reasoning :supported_efforts)))
                  (= true (get reasoning :supports_max_tokens)))
              (string (ref :reference) " does not advertise thinking=" thinking "; use default or an advertised effort"))))
  (def control (if (= provider "llama")
                 (when (get-in record [:chat_template_caps :supports_reasoning_effort]) "reasoning_effort")
                 (cond (index-of "reasoning" parameters) "reasoning" (index-of "reasoning_effort" parameters) "reasoning_effort")))
  (when (and (= role :chat) (not (index-of thinking ["default" "none"])))
    (assert control "thinking effort is unsupported"))
  (def advertised (when (= provider "openrouter") (get-in record [:top_provider :max_completion_tokens])))
  (def output (unless (= :null advertised) advertised))
  (when output (assert (and (int? output) (<= 1 output context)) "invalid provider output capacity"))

  (merge ref {:context context :output output
              :tools (if (= provider "llama") (and (get-in record [:chat_template_caps :supports_tools]) (get-in record [:chat_template_caps :supports_tool_calls])) (not (nil? (index-of "tools" parameters))))
              :parallel (if (= provider "llama") (get-in record [:chat_template_caps :supports_parallel_tool_calls]) (not (nil? (index-of "parallel_tool_calls" parameters))))
              :images (if (= provider "llama") (get-in record [:modalities :vision]) (not (nil? (index-of "image" (get-in record [:architecture :input_modalities] [])))))
              :control control}))

(defn account [s request profile raw]
  (each field [:prompt_tokens :completion_tokens :total_tokens]
    (when (has-key? raw field) (assert (and (int? (raw field)) (>= (raw field) 0)) "invalid reported usage")))
  (store/transact s
                  (charge s (request :id) profile raw)
                  (store/append s ((dyn :zinc/task) :scope) "usage" "provider usage report" {:usage raw}
                                (request :id) ((dyn :zinc/task) :id))))

(defn stream [s input &opt selected]
  (def config (s :config))
  (default selected (profile config (input :model) :chat))
  (assert (= (selected :reference) (input :model)) "profile does not match admitted model")
  (def scope ((dyn :zinc/task) :scope))
  (def messages (input :messages))
  (each message messages
    (when (indexed? (message :content))
      (each part (message :content) (when (= "image_url" (part :type)) (assert (selected :images) "model does not support image input")))))
  (def size (+ (estimate messages) (if (input :tools) (store/estimate (json/encode (input :tools))) 0)))
  (assert (<= size (config :context-quota)) "model input exceeds context quota")
  (def requested (get input :output (config :output)))
  (assert (and (int? requested) (>= requested 0)) "invalid requested output limit")
  (def cap (if (= 0 (min requested (config :output))) (max requested (config :output)) (min requested (config :output))))
  (def maximum (min (or (selected :output) (selected :context))
                    (if (= 0 cap) (or (selected :output) (math/floor (/ (selected :context) 2))) cap)
                    (- (selected :context) size)))
  (assert (> maximum 0) "approximate context capacity exhausted")
  (def admission (admit s selected input size maximum))
  (def body @{:model (selected :id) :messages messages :max_tokens (admission :output) :stream true :stream_options {:include_usage true}})
  (when (input :tools)
    (assert (selected :tools) "model does not support tools")
    (put body :tools (input :tools))
    (when (selected :parallel) (put body :parallel_tool_calls true)))
  (unless (= "default" (config :thinking))
    (case (selected :control)
      "reasoning" (put body :reasoning (if (= "none" (config :thinking)) {:enabled false} {:effort (config :thinking)}))
      "reasoning_effort" (put body :reasoning_effort (config :thinking))))
  (when (= "openrouter" (selected :provider)) (put body :provider {:require_parameters true :allow_fallbacks false}))
  (def transfer (request config selected "POST" "/v1/chat/completions" body))

  (defer (cancel transfer)
    (def content @"")
    (def thoughts @"")
    (def calls @{})
    (def reasoning-details @[])

    (var pending "")
    (var data @[])
    (var done false)
    (var finish nil)
    (var usage nil)
    (var status nil)
    (var format nil)
    (var terminal nil)

    (while (not status)
      (var packet (or terminal (get (ev/take (transfer :channel)) 1)))
      (assert packet "HTTP transfer closed")
      (when (and (= :json format) (not (packet :chunk)))
        (assert (and (= :ok (packet :error)) (<= 200 (packet :status) 299)) "chat transport failed")
        (def value (json/decode pending true true))
        (assert (and (dictionary? value) (indexed? (value :choices))) "invalid chat response")
        (each choice (value :choices)
          (def message (choice :message))
          (assert (dictionary? message) "missing assistant message")
          (eachp [position call] (get message :tool_calls []) (put call :index position))
          (put choice :delta message)
          (put choice :message nil))
        (set terminal packet)
        (set packet {:chunk (string "data: " (json/encode value) "\n\ndata: [DONE]\n\n")})
        (set pending "")
        (set format :sse))

      (if (packet :chunk)
        (do
          (set pending (string pending (packet :chunk)))
          (unless format
            (def prefix (string/triml pending))
            (when (> (length prefix) 0)
              (set format (if (string/has-prefix? "{" prefix) :json :sse))))
          (var boundary nil)

          (while (and (= :sse format) (set boundary (string/find "\n" pending)))
            (def line (string/trimr (string/slice pending 0 boundary) "\r"))
            (set pending (string/slice pending (+ boundary 1)))

            (cond
              (string/has-prefix? "data:" line)
              (array/push data (string/triml (string/slice line 5) " "))

              (and (= "" line) (> (length data) 0))
              (do
                (assert (not done) "stream data after terminal marker")
                (def payload (string/join data "\n"))
                (set data @[])

                (if (= payload "[DONE]")
                  (set done true)
                  (do
                    (def value (json/decode payload true true))
                    (assert (and (dictionary? value) (not (value :error)))
                            "provider reported a stream error")

                    (when (value :usage)
                      (assert (dictionary? (value :usage)) "invalid usage report")
                      (set usage (merge (or usage {}) (value :usage)))
                      (account s admission selected usage))

                    (assert (and (array? (value :choices)) (<= (length (value :choices)) 1))
                            "invalid chat choices")

                    (when (= 0 (length (value :choices)))
                      (assert (and finish (value :usage)) "unexpected empty choices"))

                    (each choice (value :choices)
                      (assert (and (dictionary? choice) (= 0 (choice :index))) "invalid choice index")
                      (unless (choice :delta) (assert finish "missing chat delta"))
                      (def delta (get choice :delta {}))
                      (assert (dictionary? delta) "invalid chat delta")
                      (assert (index-of (delta :role) [nil "assistant"]) "invalid chat role")

                      (when finish
                        (assert (index-of (choice :finish_reason) [nil finish]) "finish reason changed")
                        (each item (values delta)
                          (assert (or (nil? item) (= item "")
                                      (and (indexed? item) (= 0 (length item))))
                                  "chat data after finish")))

                      (each [text buffer channel-name]
                        [[(delta :content) content "content"]
                         [(or (delta :reasoning_content) (delta :reasoning)) thoughts "reasoning"]]
                        (when (and text (not= text ""))
                          (assert (string? text) "invalid stream text")
                          (buffer/push-string buffer text)

                          (store/transact s
                                          (store/checkpoint s ((dyn :zinc/task) :checkpoint))
                                          (store/append s scope "delta" text
                                                        {:channel channel-name :visible (or (= channel-name "content") (not= "none" (config :thinking)))}
                                                        (admission :id) ((dyn :zinc/task) :id)))))

                      (assert (indexed? (get delta :reasoning_details [])) "invalid reasoning details")
                      (each detail (get delta :reasoning_details [])
                        (assert (dictionary? detail) "invalid reasoning detail")
                        (array/push reasoning-details detail))

                      (assert (indexed? (get delta :tool_calls [])) "invalid tool deltas")
                      (each call (get delta :tool_calls [])
                        (def index (call :index))
                        (assert (and (int? index) (<= 0 index (- (config :tool-calls) 1)))
                                "invalid tool index")
                        (assert (index-of (call :type) [nil "function"]) "invalid tool type")

                        (unless (calls index)
                          (put calls index @{:id @"" :name @"" :arguments @""}))
                        (def assembled (calls index))

                        (when (call :id)
                          (assert (string? (call :id)) "invalid tool ID")
                          (if (= 0 (length (assembled :id))) (buffer/push-string (assembled :id) (call :id))
                            (assert (= (string (assembled :id)) (call :id)) "tool ID changed")))

                        (each key [:name :arguments]
                          (def fragment (get-in call [:function key]))
                          (when fragment
                            (assert (string? fragment) "invalid function fragment")
                            (unless (and (= key :name) (= fragment (string (assembled key))))
                              (buffer/push-string (assembled key) fragment)))))

                      (when (choice :finish_reason)
                        (assert (index-of (choice :finish_reason) ["stop" "tool_calls"])
                                "incomplete completion")
                        (set finish (choice :finish_reason))))))))))
        (set status packet)))

    (when (status :failure) (error (status :failure)))
    (assert (and (= :ok (status :error)) (<= 200 (status :status) 299)) "chat transport failed")
    (assert (and done finish (= 0 (length data)) (= "" (string/trim pending)))
            "incomplete model stream")
    (assert (and (utf8/is-valid? content) (utf8/is-valid? thoughts)) "invalid assistant UTF-8")

    (def tools @[])
    (def identities @{})

    (each index (sort (keys calls))
      (assert (= index (length tools)) "noncontiguous tool outcomes")
      (def call (calls index))
      (assert (and (= "run_janet" (string (call :name))) (> (length (call :id)) 0))
              "unsupported model tool")
      (assert (not (identities (string (call :id)))) "duplicate tool call ID")
      (put identities (string (call :id)) true)

      (def arguments (json/decode (call :arguments) true true))
      (assert (and (dictionary? arguments)
                   (= [:code] (tuple/slice (sort (keys arguments))))
                   (string? (arguments :code))
                   (> (length (arguments :code)) 0))
              "invalid Janet tool source")
      (array/push tools {:id (string (call :id)) :code (arguments :code)}))

    (assert (if (= finish "tool_calls") (and (input :tools) (> (length tools) 0))
              (and (= 0 (length tools)) (> (length content) 0)))
            "finish reason does not match response")

    {:text (string content)
     :reasoning (string thoughts)
     :reasoning-details reasoning-details
     :reasoning-visible (not= "none" (config :thinking))
     :tools tools
     :usage usage
     :model selected
     :request (admission :id)}))

(defn rerank [s input]
  (def config (s :config))
  (def selected (profile config (get input :model (config :rerank)) :rerank))
  (def query (input :query))
  (def documents (input :documents))
  (assert (> (length query) 0) "rerank query must remain nonempty")
  (each passage documents
    (assert (< (store/estimate (string query passage)) (selected :context)) "original rerank query/passage exceeds capacity"))
  (def admission (admit s selected input (sum (map |(store/estimate (string query $)) documents)) 0))
  (def result (collect (request config selected "POST" "/v1/rerank"
                                {:model (selected :id) :query query :documents documents :top_n (length documents)})))
  (account s admission selected (get result :usage {}))
  (def seen @{})
  (each ranked (result :results)
    (assert (and (int? (ranked :index)) (<= 0 (ranked :index) (- (length documents) 1))
                 (not (seen (ranked :index))) (number? (ranked :relevance_score)) (< (math/abs (ranked :relevance_score)) math/inf)) "invalid rerank result")
    (put seen (ranked :index) true))
  (assert (= (length seen) (length documents)) "incomplete rerank results")
  {:results (sort (result :results) (fn [a b] (if (= (a :relevance_score) (b :relevance_score)) (< (a :index) (b :index)) (> (a :relevance_score) (b :relevance_score)))))
   :usage (result :usage) :request (admission :id)})

(defn call [s input &opt request selected]
  (def input (merge {:model ((s :config) (if (= "rerank" (input :role)) :rerank :chat))} input))
  (assert (index-of (get input :role "chat") ["chat" "rerank"]) "unknown model role")
  (def cached (when request
                (first (store/query s "SELECT data FROM events WHERE actor=? AND parent=? AND kind='model-outcome'"
                                    [(s :actor) request]))))
  (if cached (json/decode (cached "data") true true)
    (let [result (if (= "rerank" (input :role)) (rerank s input) (stream s input selected))]
      (store/transact s
                      (store/append s ((dyn :zinc/task) :scope) "model-outcome" "Model outcome committed." result
                                    (result :request) ((dyn :zinc/task) :id)))
      result)))

(defn images [s event text]
  (def parts @[{:type "text" :text text}])
  (each row (store/query s "SELECT mime,bytes FROM images WHERE event=? ORDER BY position" [event])
    (array/push parts {:type "image_url" :image_url {:url (string "data:" (row "mime") ";base64," (base64/encode (string (row "bytes"))))}}))
  parts)
