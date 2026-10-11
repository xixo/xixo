# Changelog

## [0.5.0](https://github.com/xixo/xixo/compare/client-v0.4.1...client-v0.5.0) (2026-10-11)


### Features

* **server:** a put-away resource is deleted, with every reference into it, and its key is free again ([ca3bad9](https://github.com/xixo/xixo/commit/ca3bad9b745bd885694eae8fa55f2be6a1337c52))
* **server:** a resource on a tailnet machine that is off reads offline, and its syncs wait for the machine ([602ca19](https://github.com/xixo/xixo/commit/602ca19a4f2032de0610dfb34fe2033624290949))
* **server:** a transport offers the machines it reaches as resources to attach ([602ca19](https://github.com/xixo/xixo/commit/602ca19a4f2032de0610dfb34fe2033624290949))
* **server:** how many frames of an animation the vision model reads is two settings, a share of its frames and a most ([ab9f5d7](https://github.com/xixo/xixo/commit/ab9f5d790952ad9b237e2eec5b03e62f1e19f02c))
* **server:** only an administrator attaches, changes, or removes a resource everyone shares, or chooses the defaults, and Sign in as an administrator asks masks for that privilege ([2409992](https://github.com/xixo/xixo/commit/24099927953ef8cadd8fc1609ca85e8815c9c4ba))
* **web:** an email's page lists the rest of its thread, oldest first ([b67bb4e](https://github.com/xixo/xixo/commit/b67bb4e578c983640c9e0ccde7cf1993c0e66f3b))


### Fixes

* a model server's card reads checking while its models are tried, and updates when they are ([819372a](https://github.com/xixo/xixo/commit/819372abcdae54e49830bed7f09a33c64338b3aa))
* **web:** a GIF plays on its item page, and opens as itself rather than as the still preview made from its first frame ([8e9d96c](https://github.com/xixo/xixo/commit/8e9d96ce68f14a41e02550b6c564cfce2f340e7f))

## [0.4.1](https://github.com/xixo/xixo/compare/client-v0.4.0...client-v0.4.1) (2026-10-04)


### Fixes

* **web:** the package lists keywords, so npm search finds xixo by graphql, urql, and actioncable ([701a3a0](https://github.com/xixo/xixo/commit/701a3a0f2c78e0e2fc09dab5e2d300bdbb400b93))

## [0.4.0](https://github.com/xixo/xixo/compare/client-v0.3.0...client-v0.4.0) (2026-10-04)


### ⚠ BREAKING CHANGES

* **web:** the package is xixo rather than @xixo/client.
* the package is @xixo/client, every URIS_ variable is XIXO_, and every uris: scope is xixo:, so masks tenants and tokens granted the old scopes ask again.

### Features

* a tailnet resource reaches services on a Tailscale or Headscale network, and a resource reached through a transport connects only to addresses the transport covers ([4dc3d4f](https://github.com/xixo/xixo/commit/4dc3d4fd8bc9c06b92f8755f0b9db6d79fa42899))
* **server:** a question is answered in one call from the parts of the catalog that bear on it, and totals over a table are worked out by uris ([566ef5e](https://github.com/xixo/xixo/commit/566ef5e5fbc55a8d9977f1edd3daf8722e323db4))
* **server:** an address feed is typed uris:address, so the type names what it is ([2257c4f](https://github.com/xixo/xixo/commit/2257c4fc221201005497de4e822798d0b8696d80))
* the project is named xixo, lives at xixo.to and github.com/xixo/xixo, and nothing answers to uris ([d4ce05e](https://github.com/xixo/xixo/commit/d4ce05e10c22feb4e5fd7f4ea841cc2bd42569ed))
* **web:** the client is published as xixo, so it installs with npm install xixo ([ff14b91](https://github.com/xixo/xixo/commit/ff14b919985f7c091862f82e4086505bdee355d5))


### Documentation

* the docs live at docs.xixo.network, and previews at whatever pages.dev address Cloudflare gave the project ([e201ba4](https://github.com/xixo/xixo/commit/e201ba4470e1be2b9888a0981d25849fd42e3781))

## [0.3.0](https://github.com/xixo/xixo/compare/client-v0.2.0...client-v0.3.0) (2026-09-28)


### Features

* any item can be asked about from its page, and the answer starts from that item ([bcacccc](https://github.com/xixo/xixo/commit/bcaccccbb71a58dcfa3af764f58938f47b176e6d))
* **server:** an item shows everything its analysis read out of it, embedded metadata included ([3ad191d](https://github.com/xixo/xixo/commit/3ad191d24297c85d6d6fea0e26cb8144112039ab))
* **server:** thumbnails and hi-res images are sized by two settings shared across the tenant ([08a80ec](https://github.com/xixo/xixo/commit/08a80eccf4ec4a5606b34b7c31f95d331cce1667))
* **server:** what analysis finds in a file are its tags, and keywords are gone ([b3780da](https://github.com/xixo/xixo/commit/b3780da93dcebdc6b6fd7343aedee68eeecead7d))
* **ui:** a place with the same bytes as another says so, and Split is Keep apart ([82e53d8](https://github.com/xixo/xixo/commit/82e53d80a5c8db4a3f07e18ef49084a8949899f0))
* **ui:** a run that is queued or thinking can be stopped from the item's page ([a073a28](https://github.com/xixo/xixo/commit/a073a28e63d516b0104b64a4d61c8d99b0c69de7))
* **ui:** items are tagged from their page, and the ones an answer drew on can be reviewed and tagged together ([9818bb3](https://github.com/xixo/xixo/commit/9818bb32dc7ac89fee0b6014fd977a0554eba323))
* **ui:** tags autocomplete from the ones that exist, a tag can be removed from an item, and connecting by hand reaches search ([cfa4cdc](https://github.com/xixo/xixo/commit/cfa4cdc0385ccaba0d028f431dc26fb479338981))
* **web:** activity reads as who did what to which thing ([fc93a61](https://github.com/xixo/xixo/commit/fc93a618ae0b1cb651a060b54fd6ca348f130dd5))


### Fixes

* **ui:** an item's connections load forty at a time instead of stopping at two hundred ([b87c698](https://github.com/xixo/xixo/commit/b87c698e2a8431c8763c2a87e56a61ee79507762))


### Documentation

* the client README documents what the package exports and how to build it ([6810c95](https://github.com/xixo/xixo/commit/6810c952a85340e3b001931e00a4e198da2c827f))

## [0.2.0](https://github.com/xixo/xixo/compare/client-v0.1.0...client-v0.2.0) (2026-09-12)


### ⚠ BREAKING CHANGES

* three mutations and one query are gone from the GraphQL schema, and merge_proposals is dropped. Nothing in the catalog is lost -- proposals were suggestions, never applied until settled.

### Features

* a feed and an item show their own runs ([0e5aafd](https://github.com/xixo/xixo/commit/0e5aafd21f6ac9bda75c6a559e9c8ab930b7fca5))
* a feed's items page and read like everything else in the catalog ([d6e22cc](https://github.com/xixo/xixo/commit/d6e22cc8847c308131c7182e2ead9100e6f92763))
* a search says how many matched, and can be walked past the first page ([e35f307](https://github.com/xixo/xixo/commit/e35f3072dd8c63e6787693d5cc4c351d26f2dca5))
* an item can be renamed, and the search box has a key ([d02f541](https://github.com/xixo/xixo/commit/d02f5411e3b07eff81830fe6f4d0b078ec40c76c))
* an item can carry a note in your own words ([6795c28](https://github.com/xixo/xixo/commit/6795c28684ef48ec4093733ce24945f986115a32))
* **catalog:** a note, a page or a file at an address is added without a drop ([e8d78a6](https://github.com/xixo/xixo/commit/e8d78a6cc202ad179882046bc9028ae5eff89ca2))
* feeds have a schedule, a page, and items you can see ([3cf5de0](https://github.com/xixo/xixo/commit/3cf5de0cc59e77ba5a944b93da1669d3ba187781))
* merge goes, and the proposals that fed it ([6196e11](https://github.com/xixo/xixo/commit/6196e1139f678c28fab60bbae77dd29e97e7fca3))
* **resources:** a resource is attached from the UI, and the type says what it needs ([689a7f9](https://github.com/xixo/xixo/commit/689a7f98e2ecc02253c2a1bd21962327733cf867))
* runs show their log, and tail it while they work ([c0d5c13](https://github.com/xixo/xixo/commit/c0d5c13f5f4b23aa802c0ecae0bca54d67e4b285))
* things can be put away, forgotten and deleted ([7de567e](https://github.com/xixo/xixo/commit/7de567e859369fdc605f4097771cfdedb6bd7e71))
* **web:** duplicates, merging and exporting all have a way in ([a1a5c6a](https://github.com/xixo/xixo/commit/a1a5c6a75fb313fa50b9234360face2742ee783b))
* **web:** the audit trail is a page, and an action that fails says so ([f05afd8](https://github.com/xixo/xixo/commit/f05afd80a50f3203d9187ab9d57babd4d3ad0987))


### Fixes

* **client:** the graphql peer accepts 17, and it stops being a runtime dependency ([2198b60](https://github.com/xixo/xixo/commit/2198b6048aace989059b1002236ff4927fb74012))
* **web:** the operations name what the schema calls things now ([6acd5b8](https://github.com/xixo/xixo/commit/6acd5b8c339da1f74ed916f1125283a4936f2c6f))
* **web:** the run trail stops refetching itself, and nothing is offered a sync it would refuse ([bfc94a3](https://github.com/xixo/xixo/commit/bfc94a3cad4f0c0c8baadbd87d2f14229c61c5f3))

## 0.1.0 (2026-09-06)


### Features

* **web:** @xixo/client is publishable, at 0.1.0 ([0e0c4c2](https://github.com/xixo/xixo/commit/0e0c4c2f37106f103393d9cebb54dc3a54a7d669))
