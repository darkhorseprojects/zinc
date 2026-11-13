CREATE TABLE journal(
  sequence INTEGER PRIMARY KEY,
  key TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL,
  data TEXT NOT NULL CHECK(json_valid(data)),
  image BLOB
) STRICT;
CREATE INDEX journal_path ON journal(kind,json_extract(data,'$.path'),sequence);
CREATE INDEX journal_world ON journal(kind,json_extract(data,'$.world'),sequence);
CREATE INDEX journal_owner ON journal(kind,json_extract(data,'$.owner'),sequence);
PRAGMA user_version=1;
