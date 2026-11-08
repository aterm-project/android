ALTER TABLE instance_meta
ADD COLUMN signing_key_transitions_json TEXT NOT NULL DEFAULT '[]';
