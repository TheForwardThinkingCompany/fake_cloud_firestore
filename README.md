# Fake Cloud Firestore

Contains FT's changes on Fake Cloud Firestore:
- Added clearing of all data fake data on `clear()` method
- Added local fake data caching functionality. Possible usage in tests.
  - `cacheStore()` - stores fake data in local cache
  - `cacheRestore()` - restores fake data from local cache
  - `cacheClear()` - clears local cache

Fork of: https://github.com/atn832/fake_cloud_firestore