CREATE TABLE events(
  id INTEGER PRIMARY KEY AUTOINCREMENT CHECK(id<=9007199254740991),
  parent INTEGER REFERENCES events(id),
  key TEXT UNIQUE,
  kind TEXT NOT NULL,
  data TEXT NOT NULL CHECK(json_valid(data)),
  created REAL NOT NULL DEFAULT(unixepoch('subsec'))
) STRICT;
CREATE INDEX event_parent ON events(parent,kind,id);
CREATE UNIQUE INDEX event_result ON events(parent) WHERE kind='result';
CREATE TABLE claims(
  task INTEGER PRIMARY KEY REFERENCES events(id),
  token TEXT NOT NULL,
  expires REAL NOT NULL
) STRICT;
CREATE VIRTUAL TABLE event_fts USING fts5(text,tokenize='unicode61 remove_diacritics 0');
CREATE VIRTUAL TABLE event_words USING fts5vocab(event_fts,'row');
CREATE TRIGGER event_index AFTER INSERT ON events WHEN json_type(new.data,'$.text')='text' BEGIN
  INSERT INTO event_fts(rowid,text) VALUES(new.id,json_extract(new.data,'$.text'));
END;
PRAGMA user_version=1;
