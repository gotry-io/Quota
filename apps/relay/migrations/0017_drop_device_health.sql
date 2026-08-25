-- Device Health is gone. The Account device list says when a device was last seen and when its
-- newest reading was taken, which is what a reader ever needed; the rest was one device asserting
-- something about another.
DROP TABLE IF EXISTS device_health;
