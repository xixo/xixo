# Changelog

## [0.1.1](https://github.com/xixo/xixo/compare/server-v0.1.0...server-v0.1.1) (2026-10-11)


### Performance

* a catalog page, a search, and an item's page cost the same queries however many rows they hold, a resource's item count is batched, a run's log keeps following after the list refetches, Relate reports a change however it closes, and the offline page keeps its icon ([c07a0c8](https://github.com/xixo/xixo/commit/c07a0c889654a09a89a71b158dee72395bb6f54c))


### Refactoring

* run history subscribes only while a run is running and an open log follows its own run, the checklist reads Catalog's settings and is not asked for once hidden, health checks live in one model with one worker threshold, and the offline worker caches only its page ([0de2b68](https://github.com/xixo/xixo/commit/0de2b68fd0e2a0410190030667e680e748c9e638))

## 0.1.0 (2026-10-11)


### Features

* **server:** the server is released with a version, a changelog, and an image tagged with that version, and an upgrade starts with a backup ([c5aa88c](https://github.com/xixo/xixo/commit/c5aa88ccc6479c929853843c594c37b3da08f2cc))
