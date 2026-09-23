local decoder = require("lunajson.decoder")
local encoder = require("lunajson.encoder")
return { decode = decoder(), encode = encoder() }
