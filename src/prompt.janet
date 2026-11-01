(import spork/json :as json)
(import portable-agents/markdown :as markdown)
(import ./store)
(import ./schema)
(import ./model)
(import ./responses)
(import ./memory)

(defn report [s row mode]
  (assert (index-of mode ["render" "memory" "summaries"]) "unknown prompt view")
  (def data (json/decode (row :data) true true))
  (def request (data :request))
  (assert (request :body) "exact request was not recorded")
  (def body (json/decode (request :body) true true))
  (def messages (postwalk
    (fn [value]
      (cond (and (dictionary? value) (= "image_url" (value :type)))
            {:type "image_url" :image_url "[image bytes retained in exact request]"}
            (and (dictionary? value) (has-key? value :encrypted_content))
            (merge value {:encrypted_content "[encrypted replay retained in exact request]"}) value))
    (if (= "rerank" (get-in data [:input :role])) []
      (if (has-key? body :input) (responses/decode body) (body :messages)))))
  (def windows (data :views))
  (unless (= mode "render") (assert windows "this request has no memory windows"))
  (each key [:chronological :semantic]
    (when (and windows (= mode "memory"))
      (put (windows key) :text (if-let [index (get-in windows [key :message])]
                               (markdown/render ((messages index) :content)) ""))))
  (def sections @[])
  (when (= "rerank" (get-in data [:input :role]))
    (array/push sections @{:kind "M" :location "rerank input" :weight (data :estimate)}))
  (var inquiry false)
  (eachp [index message] messages
    (def content (markdown/render (message :content)))
    (def kind (cond (= index 0) "I"
                   (= index (get-in windows [:chronological :message])) "C"
                   (= index (get-in windows [:semantic :message])) "R"
                   (string/has-prefix? "## World source\n" content) "W"
                   (not inquiry) (do (set inquiry true) "U") "E"))
    (if (= kind "C")
      (each record (get-in windows [:chronological :records])
        (array/push sections @{:kind (if (record :children) "S" "C") :location (string "#" (record :id))
                              :weight (max 1 (- (record :next) (record :offset)))}))
      (array/push sections @{:kind kind :location (string "message " index)
                            :weight (max 1 (model/estimate [(schema/project message [:role :content])]))})))
  (when (body :tools)
    (array/push sections @{:kind "T" :location "tool definitions" :weight (store/estimate (json/encode (body :tools)))}))
  (def chronological (filter |(index-of ($ :kind) ["C" "S"]) sections))
  (when (> (length chronological) 0)
    (def cost (model/estimate [(messages (get-in windows [:chronological :message]))]))
    (def weight (sum (map |($ :weight) chronological)))
    (each section chronological (put section :weight (* cost (/ (section :weight) weight)))))
  (def total (sum (map |($ :weight) sections)))
  (def estimate (data :estimate))
  (def capacity (data :context))
  (def groups @[])
  (var weight 0) (var accounted 0)
  (each section sections
    (+= weight (section :weight))
    (def end (math/round (* estimate (/ weight total))))
    (put section :tokens (- end accounted)) (set accounted end)
    (unless (= (section :kind) (get (last groups) :kind))
      (array/push groups @{:kind (section :kind) :tokens 0}))
    (put (last groups) :tokens (+ ((last groups) :tokens) (section :tokens))))
  (def used (min 64 (max (length groups) (math/round (* 64 (/ estimate (or capacity estimate)))))))
  (def minimum (if (<= (length groups) 64) 1 0))
  (var through 0) (var columns 0)
  (def bar (string/join (seq [group :in groups]
    (+= through (group :tokens))
    (def end (min used (math/round (* (- used (* minimum (length groups))) (/ through estimate)))))
    (def width (+ minimum (- end columns))) (set columns end)
    (string/repeat (group :kind) width))))
  (def chart (string "[" bar (string/repeat "." (- 64 used)) "] ~" estimate
                     (if capacity (string " / " capacity " tokens") " tokens · capacity not recorded")))
  (def roots (catseq [key :in [:chronological :semantic]] (map |($ :id) (get-in windows [key :records] []))))
  (def summaries (map (fn [item]
                       (merge (schema/project item [:data] true) (json/decode (item :data) true true)))
    (store/query s `WITH RECURSIVE sources(id) AS (
      SELECT value FROM json_each(?) UNION SELECT c.value FROM sources s JOIN events e ON e.id=s.id,json_each(e.data,'$.children') c WHERE e.kind='summary'
    ) SELECT e.id,e.kind,e.text,e.data,e.author,e.at,e.id IN invalid_summaries invalidated FROM events e JOIN sources s ON s.id=e.id
      WHERE e.kind='summary' ORDER BY json_extract(e.data,'$.first'),json_extract(e.data,'$.height') DESC,e.id` [(string (json/encode roots))])))
  (def summary (string "Prompt #" (row :id) " · call " (row :branch)
                       (when windows (string " · through #" (windows :through) " · " (length (get-in windows [:chronological :records])) " chronological · "
                                             (length (get-in windows [:semantic :records])) " retrieved · " (length summaries) " summaries"))
                       "\n`" chart "`\nI instructions · S summaries · C originals · R retrieved · W world · U inquiry · E exchanges · T tools · M rerank · . available"))
  (def text (markdown/render
    {:name (string "Prompt #" (row :id)) :level 1
     :content [summary
       (case mode
         "render" [(string (request :method) " " (request :url))
                   {:name "Request parameters" :level 2 :content [(schema/project body [:messages :input :instructions] true)]}
                   (seq [[index message] :pairs messages]
                     {:name (string "Message " index " · " (message :role)) :level 2
                      :content [(schema/project message [:role :content] true) (message :content)]})]
         "summaries" (if (= 0 (length summaries)) "No summaries were used in this prompt."
                       (seq [node :in summaries]
                         [(string (if (= 1 (node :invalidated)) "Currently invalidated · " "") "Depth " (node :height)
                                  " · Children: " (json/encode (node :children))) (memory/render node)]))
         [(get-in windows [:chronological :text]) (get-in windows [:semantic :text])
          {:name "Retrieval candidates" :level 2
           :content [(string (length (get-in windows [:semantic :candidates])) " candidates · Cutoff: " (get-in windows [:semantic :cutoff]))
             (string "| Record | Score | Rerank request | Included |\n| --- | ---: | --- | --- |\n"
               (string/join (seq [candidate :in (get-in windows [:semantic :candidates])]
                 (string "| #" (candidate :id) " | " (candidate :score) " | #" (candidate :rerank) " | "
                   (if (find |(= ($ :id) (candidate :id)) (get-in windows [:semantic :records])) "yes" "no") " |")) "\n"))]}])]}))
  (def call (store/call s (row :task)))
  (merge {:event (row :id) :run (row :run) :branch (row :branch) :author (row :author) :at (row :at)
          :memory_range {:start (call :first) :end (call :last)}
          :world (data :world) :views windows :summaries summaries
          :composition {:estimate estimate :capacity capacity :sections (map |(schema/project $ [:weight] true) sections) :bar chart}
          :summary summary :text text}
         (if (= mode "render") {:request request} {})))
