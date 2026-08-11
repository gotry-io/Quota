ALTER TABLE usage_submissions ADD COLUMN rejection_reason TEXT
  CHECK (rejection_reason IS NULL OR rejection_reason = 'duplicate_fact_identity');
