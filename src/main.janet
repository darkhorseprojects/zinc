(import pa)
(import ./executor)
(import ./request)

(defn main []
  (def host (executor/open))
  (pa/serve {:invoke (partial request/invoke host) :describe request/describe :prepare request/prepare
    :activate (partial request/activate host) :position (partial request/position host) :append (partial request/append host)}))
