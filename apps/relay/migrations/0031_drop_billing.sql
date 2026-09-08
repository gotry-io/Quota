-- ADR 0048: sync is free, so nothing bills, grants, or gates it any more.
DROP TABLE code_redemptions;
DROP TABLE redemption_codes;
DROP TABLE entitlement_events;
DROP TABLE entitlements;
