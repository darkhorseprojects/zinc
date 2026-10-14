(defn echo
  "(example/echo text) — Return text with the provided prefix."
  [text config]
  (string (config :prefix) text))

(defn- hidden [config] (error "private implementation"))
