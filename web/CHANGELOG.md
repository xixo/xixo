# Changelog

## [0.3.0](https://github.com/urisrb/uris/compare/client-v0.2.0...client-v0.3.0) (2026-09-28)


### Features

* any item can be asked about from its page, and the answer starts from that item ([bcacccc](https://github.com/urisrb/uris/commit/bcaccccbb71a58dcfa3af764f58938f47b176e6d))
* **server:** an item shows everything its analysis read out of it, embedded metadata included ([3ad191d](https://github.com/urisrb/uris/commit/3ad191d24297c85d6d6fea0e26cb8144112039ab))
* **server:** thumbnails and hi-res images are sized by two settings shared across the tenant ([08a80ec](https://github.com/urisrb/uris/commit/08a80eccf4ec4a5606b34b7c31f95d331cce1667))
* **server:** what analysis finds in a file are its tags, and keywords are gone ([b3780da](https://github.com/urisrb/uris/commit/b3780da93dcebdc6b6fd7343aedee68eeecead7d))
* **ui:** a place with the same bytes as another says so, and Split is Keep apart ([82e53d8](https://github.com/urisrb/uris/commit/82e53d80a5c8db4a3f07e18ef49084a8949899f0))
* **ui:** a run that is queued or thinking can be stopped from the item's page ([a073a28](https://github.com/urisrb/uris/commit/a073a28e63d516b0104b64a4d61c8d99b0c69de7))
* **ui:** items are tagged from their page, and the ones an answer drew on can be reviewed and tagged together ([9818bb3](https://github.com/urisrb/uris/commit/9818bb32dc7ac89fee0b6014fd977a0554eba323))
* **ui:** tags autocomplete from the ones that exist, a tag can be removed from an item, and connecting by hand reaches search ([cfa4cdc](https://github.com/urisrb/uris/commit/cfa4cdc0385ccaba0d028f431dc26fb479338981))
* **web:** activity reads as who did what to which thing ([fc93a61](https://github.com/urisrb/uris/commit/fc93a618ae0b1cb651a060b54fd6ca348f130dd5))


### Fixes

* **ui:** an item's connections load forty at a time instead of stopping at two hundred ([b87c698](https://github.com/urisrb/uris/commit/b87c698e2a8431c8763c2a87e56a61ee79507762))


### Documentation

* the client README documents what the package exports and how to build it ([6810c95](https://github.com/urisrb/uris/commit/6810c952a85340e3b001931e00a4e198da2c827f))

## [0.2.0](https://github.com/urisrb/uris/compare/client-v0.1.0...client-v0.2.0) (2026-09-12)


### ⚠ BREAKING CHANGES

* three mutations and one query are gone from the GraphQL schema, and merge_proposals is dropped. Nothing in the catalog is lost -- proposals were suggestions, never applied until settled.

### Features

* a feed and an item show their own runs ([0e5aafd](https://github.com/urisrb/uris/commit/0e5aafd21f6ac9bda75c6a559e9c8ab930b7fca5))
* a feed's items page and read like everything else in the catalog ([d6e22cc](https://github.com/urisrb/uris/commit/d6e22cc8847c308131c7182e2ead9100e6f92763))
* a search says how many matched, and can be walked past the first page ([e35f307](https://github.com/urisrb/uris/commit/e35f3072dd8c63e6787693d5cc4c351d26f2dca5))
* an item can be renamed, and the search box has a key ([d02f541](https://github.com/urisrb/uris/commit/d02f5411e3b07eff81830fe6f4d0b078ec40c76c))
* an item can carry a note in your own words ([6795c28](https://github.com/urisrb/uris/commit/6795c28684ef48ec4093733ce24945f986115a32))
* **catalog:** a note, a page or a file at an address is added without a drop ([e8d78a6](https://github.com/urisrb/uris/commit/e8d78a6cc202ad179882046bc9028ae5eff89ca2))
* feeds have a schedule, a page, and items you can see ([3cf5de0](https://github.com/urisrb/uris/commit/3cf5de0cc59e77ba5a944b93da1669d3ba187781))
* merge goes, and the proposals that fed it ([6196e11](https://github.com/urisrb/uris/commit/6196e1139f678c28fab60bbae77dd29e97e7fca3))
* **resources:** a resource is attached from the UI, and the type says what it needs ([689a7f9](https://github.com/urisrb/uris/commit/689a7f98e2ecc02253c2a1bd21962327733cf867))
* runs show their log, and tail it while they work ([c0d5c13](https://github.com/urisrb/uris/commit/c0d5c13f5f4b23aa802c0ecae0bca54d67e4b285))
* things can be put away, forgotten and deleted ([7de567e](https://github.com/urisrb/uris/commit/7de567e859369fdc605f4097771cfdedb6bd7e71))
* **web:** duplicates, merging and exporting all have a way in ([a1a5c6a](https://github.com/urisrb/uris/commit/a1a5c6a75fb313fa50b9234360face2742ee783b))
* **web:** the audit trail is a page, and an action that fails says so ([f05afd8](https://github.com/urisrb/uris/commit/f05afd80a50f3203d9187ab9d57babd4d3ad0987))


### Fixes

* **client:** the graphql peer accepts 17, and it stops being a runtime dependency ([2198b60](https://github.com/urisrb/uris/commit/2198b6048aace989059b1002236ff4927fb74012))
* **web:** the operations name what the schema calls things now ([6acd5b8](https://github.com/urisrb/uris/commit/6acd5b8c339da1f74ed916f1125283a4936f2c6f))
* **web:** the run trail stops refetching itself, and nothing is offered a sync it would refuse ([bfc94a3](https://github.com/urisrb/uris/commit/bfc94a3cad4f0c0c8baadbd87d2f14229c61c5f3))

## 0.1.0 (2026-09-06)


### Features

* **web:** @uris-to/client is publishable, at 0.1.0 ([0e0c4c2](https://github.com/urisrb/uris/commit/0e0c4c2f37106f103393d9cebb54dc3a54a7d669))
