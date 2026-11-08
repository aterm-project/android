-- Daily aggregate provider results, shared by all service nodes. No endpoint,
-- account, token, payload, or provider response data is retained.
CREATE TABLE notification_push_delivery_daily (
    provider TEXT NOT NULL CHECK (provider IN ('apns','fcm_v1')),
    outcome TEXT NOT NULL CHECK (outcome IN ('accepted','invalid_token','retryable_failure')),
    day_start INTEGER NOT NULL CHECK (day_start >= 0 AND day_start % 86400 = 0),
    count INTEGER NOT NULL CHECK (count > 0),
    PRIMARY KEY(provider,outcome,day_start)
);
