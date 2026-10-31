# Changelog

## [0.4.0](https://github.com/xixo/xixo/compare/server-v0.3.0...server-v0.4.0) (2026-10-31)


### Features

* **server:** the machine xixo runs on is called Hub ([15e263c](https://github.com/xixo/xixo/commit/15e263ca226661d22b57e2ae1d5803ad9c1fe836))
* **web:** the catalog header is one scrolling row on a phone, with the views, the count, the type, the view switch, and the filters side by side ([e9d54a3](https://github.com/xixo/xixo/commit/e9d54a3ec384c84c77b14fe7013aca81f2d91659))


### Fixes

* **link:** xixo link on macOS exits with a status that brings it back when it is told to stop, and the supervisor logs why it stops ([83b12b8](https://github.com/xixo/xixo/commit/83b12b8a9ae19a124eea11f7402cfaddbd1324d1))
* **server:** a file kept in default storage counts and filters by its kind, the way a file with an original on a machine does ([d4b248a](https://github.com/xixo/xixo/commit/d4b248a06de199f0b9757fc1cfab4b26ed5d1c29))
* **server:** a machine that comes back has its offline folders and model servers checked at once, so they stop showing offline without a recheck by hand ([b1133e1](https://github.com/xixo/xixo/commit/b1133e1092cb51ea72e767393a6896c5795379ce))

## [0.3.0](https://github.com/xixo/xixo/compare/server-v0.2.0...server-v0.3.0) (2026-10-31)


### Features

* **catalog:** the catalog filters by machine, folder, analysis state, kind, and date, and keeps the filters in the URL ([df6304e](https://github.com/xixo/xixo/commit/df6304ec3e3984752c2054573e0e1980c8b7d48d))
* **link:** a long recording is heard in ten-minute parts spread across it, so a film's transcript covers the whole film and no part is too long to transcribe ([80e5010](https://github.com/xixo/xixo/commit/80e5010a5982e10c1b963ef95d6ff221dd7e555a))
* **link:** a machine installs only a xixo link that CI signed, and never an older release than it has run ([59ff790](https://github.com/xixo/xixo/commit/59ff7908ce7dbcc677c2f31f482c71d82e1527d4))
* **link:** a parts package fetches a part's build, unpacks it, runs it, checks its health, and rolls back ([a8b1802](https://github.com/xixo/xixo/commit/a8b1802860154235cb89cb3ad7afa0b3e823b781))
* **link:** a relayed write fetches its upload part by part while xixo is still receiving it ([3bd0ac5](https://github.com/xixo/xixo/commit/3bd0ac5ecef3e6eaa77357388e330619c3cbdbe9))
* **link:** a signed release carries the units and the apt packages, and a root update service installs it on every Linux machine with no rerun ([b34499f](https://github.com/xixo/xixo/commit/b34499f394a95df69b2e8892f7fc95e5202743d5))
* **link:** each file xixo link lists or writes names its device and inode, so xixo can tell a renamed file from a new one ([ad872a6](https://github.com/xixo/xixo/commit/ad872a616ce9a7f5fdbec9cac0841bf994e1438d))
* **link:** install makes the xixo-link-part account that the part units run as ([b86456d](https://github.com/xixo/xixo/commit/b86456d9cbaff21b21080e448c187ea40ca04802))
* **link:** linking up names the machine the way xixo shows it, links to its card, and says plainly what to do while it waits for approval ([34e95d8](https://github.com/xixo/xixo/commit/34e95d824318ef04adadd2d2dead12b08ef4b769))
* **link:** the link-up command numbers its steps, says why sudo asks for a password, keeps apt's output in a log, and ends with a summary of the machine ([c7e5ddf](https://github.com/xixo/xixo/commit/c7e5ddf7ac78d3dd81f28670c3d328d0dd911404))
* **link:** xixo link describes the machine, with its GPUs, battery, and readers, and the configuration keeps only folders, lend, and parts ([d9da24e](https://github.com/xixo/xixo/commit/d9da24ee650e1fdd5fe76873fe426f57d952db88))
* **link:** xixo link installs itself, signs a person in, and links a machine over ssh ([9c5b784](https://github.com/xixo/xixo/commit/9c5b784243d2dae04fe77a77b8b77f81ebbe4924))
* **link:** xixo link reads a part of a file by offset and length, and streams a write straight into the shared folder ([408d6f3](https://github.com/xixo/xixo/commit/408d6f38dd23aabe5e3e10d3ddd40d45907e03e2))
* **link:** xixo link removes a file only when its bytes match a SHA-256 xixo names, and a write keeps the modification time it is given ([4c8112a](https://github.com/xixo/xixo/commit/4c8112a7ee8f453c1f8e65de0eeefa5947d34c7d))
* **link:** xixo link takes a version that names its commit after the release it follows ([ed75654](https://github.com/xixo/xixo/commit/ed75654900bc3d49e9b63ad3a07350198f176fd8))
* **link:** xixo link updates itself to the build xixo names, checks its SHA-256, and goes back when the new one does not connect ([bd223c6](https://github.com/xixo/xixo/commit/bd223c6cf39e92cf9615f36bb8da8e60a8870a4c))
* **link:** xixo-link status shows the machine's name, its card in xixo, its folders, and how to check on it, and xixo-link alone lists what it can do ([e0c4a1f](https://github.com/xixo/xixo/commit/e0c4a1f8ea3fe6b3b5ff984a8333d9aa8af63c6d))
* **server:** a folder synced once follows every change xixo link sees, with or without a schedule ([20dea23](https://github.com/xixo/xixo/commit/20dea23f25cfc901ffd9d862012ef55ddfe14a3f))
* **server:** a machine describes itself when it links up, xixo plans what it does, and one approval with switches replaces the settings message ([26924e1](https://github.com/xixo/xixo/commit/26924e1d09b81414a4bce500a0fa335b3d64be23))
* **server:** a machine with a usable GPU runs the models part, and xixo attaches the Ollama it brings up ([4aee3d2](https://github.com/xixo/xixo/commit/4aee3d223025b0528f7afd41730cb4cba1fb5b8a))
* **server:** a model backend learns which of its models read images, picks one for the vision role, and never sends an image to a model that cannot read it ([5d75a51](https://github.com/xixo/xixo/commit/5d75a510c1ef2975dc02a3f4508b21d954c469c6))
* **server:** a recording heard in parts is transcribed part by part, and each line keeps its moment in the whole recording ([62ea6ac](https://github.com/xixo/xixo/commit/62ea6acb38829d685f5292a59ad8eeb233dde2f5))
* **server:** a renamed or touched file in a folder keeps its analysis, and only new bytes are analyzed again ([6be3a64](https://github.com/xixo/xixo/commit/6be3a64e9a2a8e45d441751d524bf5b47e680862))
* **server:** an administrator adds a machine from its description over the API, and the command line signs a person in through xixo ([a2f164d](https://github.com/xixo/xixo/commit/a2f164d903ad9eef4c8e96910a6d4957d1e7baf8))
* **server:** an image built from main holds the mac reader and names its commit, and a timer on the host keeps xixo up to date ([821dd32](https://github.com/xixo/xixo/commit/821dd32d74ead270a550063b3a85140c23de333c))
* **server:** an MCP client in a browser reads the protected resource metadata and calls /mcp from another origin ([1e58e45](https://github.com/xixo/xixo/commit/1e58e45fba795ba0744e3965cbb7aec1ee2d3fc3))
* **server:** every folder a machine shares is in the catalog, with no step to attach it ([01f4817](https://github.com/xixo/xixo/commit/01f481777d43a211a7469fc08fd80095f2066954))
* **server:** failed analyses can be started over, and they wait for the model server before they run ([5d002de](https://github.com/xixo/xixo/commit/5d002deb8ce39f08169dc472451ca4c0d29c81ce))
* **server:** move is an MCP tool of its own, with typed fields, and checks on or stops a move by its run ([fb2fe89](https://github.com/xixo/xixo/commit/fb2fe89e09d63e4329e407d97011dc2e180d5383))
* **server:** the link-up script hands the install to xixo link, and the docs cover linking a machine over ssh ([58b26b8](https://github.com/xixo/xixo/commit/58b26b8e023359115f596811d2c50dbb80747ef2))
* **server:** the tailnet transport, the Tailscale sidecar, and the unlinked-machines list go, since a found model server is attached through the machine ([aa4a3a6](https://github.com/xixo/xixo/commit/aa4a3a65dcf121be82f51e16efde449b50bb4a66))
* **server:** xixo has full access to what a machine shares, and each folder's owner decides whether it is writable ([07576bd](https://github.com/xixo/xixo/commit/07576bdcca41f3ad626302173302f5d3ecbe597a))
* **server:** xixo moves a folder or a selection of files from one machine to another, and removes each original only once its copy's SHA-256 matches ([0e373aa](https://github.com/xixo/xixo/commit/0e373aac654aca3056295771b07e408f0b02dd01))
* **server:** xixo tells an out-of-date xixo link to update to the build it ships, and serves the mac reader and the Linux updater ([820bb37](https://github.com/xixo/xixo/commit/820bb37ca6730eefedcb6a51c3f3f045697fc91b))
* **settings:** Settings &gt; Updates shows what the server runs and asks the updater to update now, pause, resume, roll back, or change channel ([d687e43](https://github.com/xixo/xixo/commit/d687e43663389944cd1eeec5e99587629be0b922))
* **updater:** the updater takes Update now, Pause, Resume, Roll back, and a channel from a request xixo writes ([86922e2](https://github.com/xixo/xixo/commit/86922e2cb06d1de79aa3502b31cc781a626c678b))
* **updater:** xixo-updater keeps a server on the builds CI signed, and rolls back a build that fails ([73a279a](https://github.com/xixo/xixo/commit/73a279a1dd1e6c3a9908ab7fab7f976697594b3f))
* **web:** a machine card lists the folders it shares as the folders in the catalog, with their items and sync state ([5d13329](https://github.com/xixo/xixo/commit/5d13329a894bf6608a20829ec8ef5855ee97fa9e))
* **web:** a machine's card names its xixo link version, says whether it is up to date, and has a switch to pause its updates ([64a3e22](https://github.com/xixo/xixo/commit/64a3e220f9da6580ed06b73916d3e06e1869a22b))
* **web:** a pass waiting for a model server says what it waits for, and its summary step reads as waiting, not failed ([d5861f4](https://github.com/xixo/xixo/commit/d5861f46cd65998b34f51c7f6c1aa3d758dfb538))
* **web:** Move files… on a folder, Move these… in the catalog, and Move to… on a file pick a folder and follow the move ([4a6817e](https://github.com/xixo/xixo/commit/4a6817e1bc6978d286247dd95cd9d42d60ede586))
* **web:** the link-up dialog and a machine asking to link up mark each folder xixo may write into as read and write ([eb379e6](https://github.com/xixo/xixo/commit/eb379e6095ba714498527fd2d9e275fd65d0e964))


### Fixes

* **link:** a hash names the file it read by device and inode, and a write syncs each folder it makes ([4b728de](https://github.com/xixo/xixo/commit/4b728de066bc875f0d5fc1841f8b9e01e800b3e9))
* **link:** a Mac goes back to the last release that connected, since staging no longer removes the release xixo link runs from ([1c736e5](https://github.com/xixo/xixo/commit/1c736e543a932a291d4face5a7472547d066812d))
* **link:** a Mac's link-up command shows its paths from ~, and names Full Disk Access once on a rerun ([1da6cb8](https://github.com/xixo/xixo/commit/1da6cb83bb00f7b6d6436f757fc5b815934527de))
* **link:** a new machine refuses releases older than its own build, and macOS keeps the serial only once a release connects ([6714d10](https://github.com/xixo/xixo/commit/6714d10428d4eb69c94d06242e4a84781be3bd78))
* **link:** a part runs as the system user xixo-link-part, and an unpacked build keeps its modes ([136558d](https://github.com/xixo/xixo/commit/136558db52cdc87332f53602454e579f700288e9))
* **link:** a part's build downloads through a client with no timeout, and its status file is readable by xixo link ([f335bc4](https://github.com/xixo/xixo/commit/f335bc40bd0f53d29466292cfd2677a254dbd02c))
* **link:** a part's builds run from the state directory systemd mounts without exec ([75de9b2](https://github.com/xixo/xixo/commit/75de9b26ebfdfe447a85321a34f37e379028b9a5))
* **link:** a request's deadline is held to one day, and the extraction README names it ([52a05a1](https://github.com/xixo/xixo/commit/52a05a15ba0b4fd253add99e6361554cb5f864e1))
* **link:** a rerun says it restarts xixo link whenever the service is installed, even while xixo link is already restarting into the new binary ([bb7805c](https://github.com/xixo/xixo/commit/bb7805cef6a37031be7328221de4f93b70907c9b))
* **link:** a thumbnail and a preview keep none of the original's EXIF tags or location, and are converted to sRGB ([9a3147c](https://github.com/xixo/xixo/commit/9a3147cd55af65c3bdc2abf84b0fc3676fdc3c34))
* **link:** adding a machine stops before xixo hears of it when sudo has no terminal to ask in, and a machine added again keeps its place ([d17adf4](https://github.com/xixo/xixo/commit/d17adf46f9b2c652fd096c4f64c6ced5b526092e))
* **link:** systemd and the macOS parent give xixo link 15 and 10 seconds to stop, so a restart never waits 90 ([e142652](https://github.com/xixo/xixo/commit/e142652fcbcfbe99af502a7f515aed245488d47d))
* **link:** the epub reader parses HTML with the x/net release that coalesces text nodes in linear time ([d6cd5fa](https://github.com/xixo/xixo/commit/d6cd5fa7dad33ffdb95ba04cee06ceb122d9638b))
* **link:** the link-up command asks systemd as root whether xixo link runs, so a machine without D-Bus does not stop at the last step ([d00fb47](https://github.com/xixo/xixo/commit/d00fb476a9823aaea7d83716b3bcdadc54b822c7))
* **link:** the mac reader follows the link to a shared file it reads in place, so a film's bit rate comes from the film's size ([9efed79](https://github.com/xixo/xixo/commit/9efed791ae15b97b65bbb0dbfbc0691e25fc712e))
* **link:** the models part on macOS makes its own state folder, so Ollama starts ([6680c19](https://github.com/xixo/xixo/commit/6680c19c4bcff3501b53dc25a3b7096a4b66f3cb))
* **link:** the part command reads the part's name before its flags, as the service unit passes them ([edcdffe](https://github.com/xixo/xixo/commit/edcdffef239af61c906c7381aef87a1b2320c720))
* **link:** the part command takes the shared --state flag for the part's own directory instead of defining it twice ([c7ad11e](https://github.com/xixo/xixo/commit/c7ad11e87ae31130ef2302f071502b495cb5919b))
* **link:** xixo link passes requests on to the model server its own part runs ([8368a1c](https://github.com/xixo/xixo/commit/8368a1c8659918a0dcb6907fb95bac730fd2d4bc))
* **link:** xixo link reads spreadsheets with excelize past six advisories, and builds with go1.26.10 ([73a279a](https://github.com/xixo/xixo/commit/73a279a1dd1e6c3a9908ab7fab7f976697594b3f))
* **link:** xixo link stops a request xixo gave up on, and extractions wait in their own queue ([f9b1e58](https://github.com/xixo/xixo/commit/f9b1e58038d347db1a486e606158b918a2ba6f86))
* **link:** xixo link stops within seconds when systemd asks, even in the middle of hashing a large file ([a876291](https://github.com/xixo/xixo/commit/a876291cedf6fab6d5726e0c38dd4105c5facafd))
* **link:** xixo link takes --updates systemd only when systemd runs it on Linux and --updates self only on macOS, and the container beside the server refuses --updates ([217a5ab](https://github.com/xixo/xixo/commit/217a5abe78e922adca217c009d9b943f5e33211d))
* **server:** /favicon.ico serves the xixo icon ([10d4db5](https://github.com/xixo/xixo/commit/10d4db5cbacd886bf284e718917bb8052428630c))
* **server:** a download is picked from a fixed list of the five files xixo serves, so no request parameter names a path ([fdd41b6](https://github.com/xixo/xixo/commit/fdd41b657c6ba030d2c559b2ba1126da9c794a62))
* **server:** a file larger than 4 GB is never lent to another machine, and waits for its own machine with a reason that says so ([db266f2](https://github.com/xixo/xixo/commit/db266f2b333652afaeac13f4b6803f10e88c8f67))
* **server:** a folder file whose time or size changed is hashed within seconds, so an edited copy leaves its twin and a new version joins at once ([f668674](https://github.com/xixo/xixo/commit/f668674864864b46baa3988ea3757b31b53444f8))
* **server:** a folder whose sync failed because its machine went offline syncs again when the machine says hello ([2816e5e](https://github.com/xixo/xixo/commit/2816e5e203a1153a9b544153b18e9c7a7d661c62))
* **server:** a HEAD request to /mcp gets the same 405 as GET, since its own route answers both ([bc7b66d](https://github.com/xixo/xixo/commit/bc7b66d4a28f971a8fc671540c1e131486f8b240))
* **server:** a job that loaded a machine minutes ago reads its latest check-in before calling it offline ([bebff62](https://github.com/xixo/xixo/commit/bebff6264010d0e383f010dcdc2f3113cf14b853))
* **server:** a line an analysis logs twice in one job is kept twice ([6a7bdce](https://github.com/xixo/xixo/commit/6a7bdce2ab8d83e484347641d70e5c1de4bc1f0c))
* **server:** a machine keeps the GPU memory xixo learned when it approved it ([812fe2e](https://github.com/xixo/xixo/commit/812fe2e2d782203f9aa8ae2600bf14d7d32d3c48))
* **server:** a machine lets xixo use the model server its own part runs ([ebe628e](https://github.com/xixo/xixo/commit/ebe628e04ce2e5a6ede5c62481994c2c9fd76665))
* **server:** a model backend's form has a Model field for every role left blank, so saving it keeps the default model ([883c909](https://github.com/xixo/xixo/commit/883c909d5aeb59d1d53e22e6765d3d5344abba99))
* **server:** a move never removes an original that another machine reaches on the same disk ([ab6d80c](https://github.com/xixo/xixo/commit/ab6d80c1b1500a629dad2b1b71b3a26781e13505))
* **server:** a move never removes the last copy of a file, even when two folders share a disk or two moves meet ([cd518ed](https://github.com/xixo/xixo/commit/cd518edd701aed39aae79fa2b4fa7b5adb672257))
* **server:** a move of a large file keeps its exchanges fresh, so the hourly sweep never takes one that is still carrying bytes ([d666b30](https://github.com/xixo/xixo/commit/d666b303d12f576acf05771ec6b4dd57a0d6d261))
* **server:** a subscriptions/listen request gets method not found, where it used to end in a 500 ([5d09121](https://github.com/xixo/xixo/commit/5d09121667f4d7cfb0ebca52811556389f9a2411))
* **server:** a summary cut off by its token budget keeps the entities, summary, and tags the model finished ([2adbf23](https://github.com/xixo/xixo/commit/2adbf23c8674e0c8eab55503d804daccc98ea846))
* **server:** a sync leaves a file whose analysis waits for a machine to wait, instead of cancelling it and queueing it again ([8cdd5b9](https://github.com/xixo/xixo/commit/8cdd5b9c6737a48559f435aa4b37462ae27b9116))
* **server:** a tenant adds the device grant to its masks client before the command line signs someone in ([e8e4dbf](https://github.com/xixo/xixo/commit/e8e4dbf94b3f9304745c28af00f86a0a9507eea8))
* **server:** an analysis waits for a model server on a machine that is asleep, and starts again when the machine says hello ([b31930f](https://github.com/xixo/xixo/commit/b31930fba264600adf403fc49dda18d4dae85505))
* **server:** an analysis waits in the queue however long the queue is, and its deadline starts when it runs ([6064d02](https://github.com/xixo/xixo/commit/6064d023d4d8941d3a3dbdf8a55bcab88591cba2))
* **server:** an image is described rather than transcribed, and an item says why it has no summary when a model could not write one ([3a9d2ce](https://github.com/xixo/xixo/commit/3a9d2cea5afd423e0cf080a6434220b046822a58))
* **server:** boot forgets resources whose type xixo no longer has instead of crashing ([b75fb6e](https://github.com/xixo/xixo/commit/b75fb6ee2850176bf4f9089bd3abc594acac98e8))
* **server:** chat with no model named asks the models part for its default model ([05a5635](https://github.com/xixo/xixo/commit/05a5635f271d72f57261f9562db78cfff107365d))
* **server:** every file is extracted again at its next analysis, so a preview made before EXIF was stripped is replaced ([9bc6990](https://github.com/xixo/xixo/commit/9bc6990ff59a543c35c8c7706b1c406965f2fbbb))
* **server:** every page carries a Content-Security-Policy, so script runs only from xixo and no other site can frame it ([ad3eb90](https://github.com/xixo/xixo/commit/ad3eb905a90e5aea4bd1075d9f8d2934d79ca861))
* **server:** images go only to a model its server says reads them, and every JSON request names its schema so LM Studio takes it ([ab9035c](https://github.com/xixo/xixo/commit/ab9035cdc0beb178bb489f98ed90107a4c8eb0f2))
* **server:** link.sh runs setup, unit, and up from the download it checked, so the updater's user never hands root a binary ([4f4765c](https://github.com/xixo/xixo/commit/4f4765ccce9eb78a80df455ef23a7aa4299632bd))
* **server:** only hashed Vite assets are cached for a year, and the service worker is revalidated on every load ([63c1464](https://github.com/xixo/xixo/commit/63c1464c887d7ef778023f229bb8d9307c5dd68e))
* **server:** rack 3.2.8 and crass 1.0.8 close four rack advisories and a CSS sanitizer bypass ([323549b](https://github.com/xixo/xixo/commit/323549b6443bc95127ab014aabba0097db05549f))
* **server:** routine work asks a thinking model not to think unless its backend says otherwise, so qwen3 summaries get an answer ([d983a19](https://github.com/xixo/xixo/commit/d983a1961b59b86326684790f83cfdca136412b0))
* **server:** the cable listener goes back to listening after its database connection fails ([ab1b444](https://github.com/xixo/xixo/commit/ab1b4449f9f2677617fd49f79e469be6176c488c))
* **server:** the health check reads SOLID_QUEUE_IN_PUMA as a switch, so false means false, and the run budget error says you, since a person's tokens share one budget ([284c084](https://github.com/xixo/xixo/commit/284c084e959d11404afd6a4ae82140aebb505443))
* **server:** the hourly job cleanup and the masks maintenance commands run from the default queue, which a worker always reads ([577f0de](https://github.com/xixo/xixo/commit/577f0de11f64abb31c59036beee7841e3c248b76))
* **server:** the hourly proof mark sweep runs in every tenant ([1855101](https://github.com/xixo/xixo/commit/185510115b842bd78099d51191c00b025d10909d))
* **server:** the proof mark sweep runs outside any tenant, since proof marks belong to none ([260309f](https://github.com/xixo/xixo/commit/260309f6325b8992a2d288ac733f0dabc52a1e89))
* **server:** the scheduler's recurring commands are enqueued again, so finished jobs are cleared every hour ([d6d2d28](https://github.com/xixo/xixo/commit/d6d2d2898e59a3e8c2c8d2fc26edac54dcb12bc9))
* **server:** the session cookie is SameSite=Lax, so a request another site starts never carries it ([5f54156](https://github.com/xixo/xixo/commit/5f54156bbec9a3ce3b3f7be85653320853e6e7e0))
* **server:** the web app manifest is served as application/manifest+json ([13a2d43](https://github.com/xixo/xixo/commit/13a2d43248785f16d6e266467dd0039ee635272f))
* **server:** xixo takes masks 0.12.1 and masks-server 0.10.0, which carry the Stage 1 security fixes ([57900e3](https://github.com/xixo/xixo/commit/57900e387139010037e8e20bb68323369e06d4db))
* **server:** xixo tells xixo link the deadline of each request, and tells it to stop a request xixo gave up on ([d619ba5](https://github.com/xixo/xixo/commit/d619ba56f1f108841113f62ff4791cd42c05681c))
* **server:** xixo waits for a folder file's hash as long as reading a file that size takes, so a large film is not asked for again every minute ([0db485e](https://github.com/xixo/xixo/commit/0db485ea1883d726935842a27ce3850bda3d6e50))
* **updater:** the gate moves a container whose image is gone, keeps a swap going when the updater stops, and says when it is idle ([3fc4f5a](https://github.com/xixo/xixo/commit/3fc4f5a4c43eeccd18473e0a2b726625503a111f))
* **updater:** the status xixo shows is written again after a swap fails, so it never describes the moment before ([44b142f](https://github.com/xixo/xixo/commit/44b142f0d920cd0450f54739e50314c4d949837c))
* **web:** a machine linked before updates is told to run the link-up command once, even when its version matches the build xixo ships ([3446a3b](https://github.com/xixo/xixo/commit/3446a3b63a2898de34afa06057bb85457fa88081))
* **web:** the add-to dialog no longer takes an onAdded callback, since a found model server is attached by the plan ([3c57436](https://github.com/xixo/xixo/commit/3c57436e6fdbbd869cc992af7e12d4b70f7752f9))
* **web:** the catalog and an item's page stay up when an analysis update arrives with nothing in it ([66bb776](https://github.com/xixo/xixo/commit/66bb776e6bec2104287ed2aed9d48083c9205cb9))
* **web:** the catalog shows how many items it holds, not how many rows have loaded ([c634440](https://github.com/xixo/xixo/commit/c6344400daf46d8bb82f07ba38e441df3b19f173))
* **web:** the page shown when a view fails says plainly that only the page failed and what to do next ([86ec095](https://github.com/xixo/xixo/commit/86ec09596391dd0d145c5ec0a554d33728962c75))


### Performance

* **link:** measuring a recording's sound keeps two numbers per audio frame, not every line ffmpeg printed ([e00dd53](https://github.com/xixo/xixo/commit/e00dd53b5c14a5346cff9c40b11feb0e08f24e39))
* **link:** on Linux, xixo link yields the processor and the disk to everything else, and reading a large file no longer pushes other files out of memory ([7a22896](https://github.com/xixo/xixo/commit/7a22896e08da8c639b2e280d72805d5554d496ab))
* **link:** xixo link reads a shared file where it lies, so a film larger than 4 GB is extracted on the machine that shares it ([0dd438c](https://github.com/xixo/xixo/commit/0dd438c9628dd8dabdae0bb96f3c316a2cb8a49e))
* **link:** xixo link remembers the SHA-256 of each large file it hashed, so asking again for an unchanged file reads nothing ([bcaaaa0](https://github.com/xixo/xixo/commit/bcaaaa0f2b9e79ca2131559e239ffa08644d3412))
* **server:** a sync settles each page of unchanged files in one query, so a walk of 5,000 unchanged files takes 0.4 seconds instead of 4.6 ([bfe6a57](https://github.com/xixo/xixo/commit/bfe6a571048230ff544152f73b22a45593565691))
* **server:** a wait for xixo link's answer polls less and less often, down to twice a second ([bcdc2ff](https://github.com/xixo/xixo/commit/bcdc2ff60aeac921d11e16d4f4be9cdf24f4c2c8))


### Documentation

* a guide to moving files between machines, and the move command, mutation, and queue in the reference ([6d77257](https://github.com/xixo/xixo/commit/6d7725705c1cc3032a8689d4a59e8625a39be2ad))
* adding a machine shows the numbered link-up steps, the summary xixo-link status prints, and a Mac rerun that keeps Full Disk Access ([305ba55](https://github.com/xixo/xixo/commit/305ba55684a9ef7c3cef6b98ad9b1b05e9975be2))
* every concept page, guide, and README says what xixo does now, in fewer words ([2300fe7](https://github.com/xixo/xixo/commit/2300fe7ad406e0ee043a34111f4c4fdea6e61780))
* **link:** the README describes the numbered install steps, xixo-link status and stage, the JSON answer to /link, and a Mac rerun that keeps Full Disk Access ([5abe57a](https://github.com/xixo/xixo/commit/5abe57aa0e70725558b109aadd7734a48a14b90d))
* pages, READMEs, and comments no longer claim what xixo stopped doing ([8c60593](https://github.com/xixo/xixo/commit/8c6059356dded7bcb72fb2128aa524a6eb92f7a5))
* prettier reflows the ssh linking prose ([7d018a8](https://github.com/xixo/xixo/commit/7d018a8428d460d43644a4fedf11eddeb11661c8))
* the guides and the link README say how a sync of an unchanged folder reads nothing, and how a renamed or touched file keeps its analysis ([a421940](https://github.com/xixo/xixo/commit/a4219403a4d5347c2564f3a1cb58ca7e00dcc925))
* the guides say a folder a machine shares joins the catalog by itself, and who sees it ([0c85844](https://github.com/xixo/xixo/commit/0c85844cbef47d955f963c9e0223a792b4efabdc))
* the guides say xixo may do everything with what a machine shares, and that a folder is writable when the link-up command names it with :rw ([48efe2a](https://github.com/xixo/xixo/commit/48efe2aae852cff5ec9d57fe61eb8084914c663c))
* the README points to docs.xixo.network and maps the code, and the docs hold the rest ([8459b50](https://github.com/xixo/xixo/commit/8459b50d24350619ab81b5317f3830082c4535ad))
* **updater:** self-hosting sets up xixo-updater in place of the host timer ([7e16cde](https://github.com/xixo/xixo/commit/7e16cde97c5fee69496954845eb108d3d4e6d638))


### Refactoring

* **server:** queue.yml reads the masks worker's process count from EmbeddedIssuer.processes, which keeps the file valid YAML ([a7f2d6f](https://github.com/xixo/xixo/commit/a7f2d6fe83e0913c7f105d6f63910044da5961c3))
* **server:** the built-in masks is chosen once at boot, its masks worker runs only when masks does, and its origin check reuses Tenant.origin_for ([3100b3c](https://github.com/xixo/xixo/commit/3100b3cfef0c24c04fd0de597e6b0462ba9d2f55))

## [0.2.0](https://github.com/xixo/xixo/compare/server-v0.1.1...server-v0.2.0) (2026-10-13)


### Features

* a linked machine offers its files, its extractors, and its model to MCP clients through xixo, and only the tools its own config names ([93956e9](https://github.com/xixo/xixo/commit/93956e9ed9067c19a405045d461591480af8dd3d))
* **agent:** a Mac reads documents, PDFs, images, audio, and video with what macOS ships, Vision reading text in images ([2f99904](https://github.com/xixo/xixo/commit/2f999048886414a21f68c8c7735e7c1215228507))
* **agent:** a machine runs xixo-agent, which enrolls its own key with masks, dials xixo over Action Cable with a DPoP-bound token, reports its health and model servers, and lists and reads only the folders its own configuration shares ([5b96007](https://github.com/xixo/xixo/commit/5b96007fb5aa16ad72c4227f1d913b483496d1ec))
* **agent:** a read can be limited to its first bytes, up to 1 MiB, and then answers with the whole file's size too ([a1fec0f](https://github.com/xixo/xixo/commit/a1fec0f1d218e8ebea57ea2cd07f962f6c60bd0d))
* **agent:** an extraction carries the server's settings for thumbnail and preview widths, animation frames, and how much audio to transcribe ([0eeea35](https://github.com/xixo/xixo/commit/0eeea35f1a78a1838475fa8e7bb8cc1c69b64d1e))
* **agent:** an extraction carries the share of an animation's frames to read, and thumbnails and previews are checked over the corpus, a camera raw's preview included ([747af59](https://github.com/xixo/xixo/commit/747af59d5c083e77444b097c51d58c01df39257f))
* **agent:** an unenrolled agent exits with status 78 and stays stopped, and its unit runs in a tighter sandbox ([dd90a41](https://github.com/xixo/xixo/commit/dd90a41f039218d26d2485d128f19055fdb8a78c))
* **agent:** the agent extracts text, data, calendars, contacts, passes, and anything else the way the server's analyzers did, and reads metadata and renders thumbnails and previews for every file ([9dc837c](https://github.com/xixo/xixo/commit/9dc837ce57633261aafc6bcb51d546ed6fdb46c6))
* **agent:** the agent fetches an upload from xixo over HTTPS with its own token and a fresh proof, and put frames are gone ([7a21592](https://github.com/xixo/xixo/commit/7a2159267527000652fefd0d22190e0d9b834cc4))
* **agent:** the agent has an extraction framework: extractors register by name in xixo's analyzer order, each says which programs it needs, and every program runs under a deadline, a 4 GiB data limit, and a process-group kill ([0a3efc0](https://github.com/xixo/xixo/commit/0a3efc0353791ee526b9ad894a41480a01e9248b))
* **agent:** the agent reads media, email, epub books, and spreadsheets: a recording's probe, loudness, and silences with a 16 kHz wav for transcription and frames for scene captions, a message's headers, thread, quoted history, and attachments as children, a book's details and chapters, and a workbook's sheets, tables, and rows ([92b2a68](https://github.com/xixo/xixo/commit/92b2a68d0b7915993bd91937b60fdd77826ebc0f))
* **agent:** the agent reads pdfs, office documents, and images: a pdf's text layer with OCR when it is sparse, a document's own headings and tables, and an image's size, spread, frames, location, and text, with raw photographs developed in its work dir ([fb7f494](https://github.com/xixo/xixo/commit/fb7f49415388d277a166c89df6b46471326998b9))
* **agent:** the agent reports the SHA-256 and size of what it reads with each extraction, and answers a hash request without sending any of the file's bytes ([caacf1f](https://github.com/xixo/xixo/commit/caacf1f628f008d717124d9b340108c3ba56fe53))
* **agent:** the agent runs on macOS as a launch agent, with extraction programs under sandbox-exec ([00465e7](https://github.com/xixo/xixo/commit/00465e73ec0b95b896cb42f1a13534400134858c))
* **agent:** xixo sends a file to the agent in pieces and asks it to extract an upload or a shared file, and the agent streams back each file it makes and then the steps, and says in its hello which extractors it can run ([bb2381f](https://github.com/xixo/xixo/commit/bb2381ffd8f4a8cb66585f29ef7ae063f721413f))
* **link:** a machine asking to link up says who runs it, its system and hardware, its disks, addresses, version, and the model servers it found ([fa79c51](https://github.com/xixo/xixo/commit/fa79c51db3ad2c9f85b41b10fea1fffd3a42caf2))
* **link:** xixo link links up with one command and an approval in the browser, and xixo sets what it may do ([7909012](https://github.com/xixo/xixo/commit/7909012c10a47ee83a1dee0d07ecf6064d39c5ec))
* **link:** xixo link on a Mac restarts by itself once macOS grants it Full Disk Access, so a shared Desktop or Documents starts reading without a command ([19872e0](https://github.com/xixo/xixo/commit/19872e0bc5ab85ad637252edc139e9f6d25a72b8))
* **link:** xixo link passes xixo's requests on to a model server on the machine, so one listening only on 127.0.0.1 still answers xixo ([ce112e0](https://github.com/xixo/xixo/commit/ce112e0d8d47b798a5e4bc602c418ec912882cd6))
* **link:** xixo link says what kind of machine it is and names a Mac's model, and reports a model server that answers only on the machine without an address ([82f38ef](https://github.com/xixo/xixo/commit/82f38ef445fd3a907438a7604fbb8a4476e2085a))
* **link:** xixo link watches its shared folders and tells xixo which paths changed ([692e281](https://github.com/xixo/xixo/commit/692e281fa0a7fd41f92b32fb17ad02a1ecb60fe3))
* **server:** a change xixo link reports in a shared folder is synced within seconds, path by path ([aa470eb](https://github.com/xixo/xixo/commit/aa470eb6e3df262540d2440d8da97af33eca22e9))
* **server:** a filesystem resource is a folder on a machine that its agent reads, and writes when the machine marks the folder writable ([7a3d5b9](https://github.com/xixo/xixo/commit/7a3d5b96651b7d6054a82f7005a64dfee57fd763))
* **server:** a machine is attached over SSH, xixo installs and enrolls its agent, and the agent's folders sync through a broker that asks it anything and streams bytes both ways ([e558c67](https://github.com/xixo/xixo/commit/e558c67d3ad2c50ea7bee894badb87c2a7cabfd4))
* **server:** a machine links up by running the install itself, with a single-use code that names its client to xixo ([ee6548b](https://github.com/xixo/xixo/commit/ee6548b6bf1ad919673d5e3182414aa5f4ddae5b))
* **server:** a machine links up with one command and an administrator's approval, and its access is changed any time on its card ([3f41089](https://github.com/xixo/xixo/commit/3f410892c30a6360c852f06af06ca2aa698d9f2c))
* **server:** a machine's agent sees only the folders it shares, because its unit empties /home, /root, /srv, /mnt, /media, /opt, and /var/lib and mounts each shared folder back read-only ([c3dd61a](https://github.com/xixo/xixo/commit/c3dd61aecefdf446d2145095c4baa7db5ea55a31))
* **server:** a machine's install puts the extraction programs on it with apt, a machine can lend files it cannot read to the server, and its card says which kinds it cannot read ([372b5df](https://github.com/xixo/xixo/commit/372b5df84817771df256b8262e6c0f6740ffa1f6))
* **server:** a model server added with no models picked answers with the first chat model it serves, so adding Ollama or LM Studio works in one click ([58ffdbf](https://github.com/xixo/xixo/commit/58ffdbf90b4b8950f171ade99db4bb45b85e51e0))
* **server:** a model server on a linked machine is reached through xixo link on it, and shows its machine offline instead of not working ([b179d87](https://github.com/xixo/xixo/commit/b179d87aef95e5e8af1bffb64da548e5ed18e880))
* **server:** a request to link up keeps what the machine says about itself, and says whether it came from the approver's address ([e4190ac](https://github.com/xixo/xixo/commit/e4190ac836ce1d6f109e8e01d1f6a2deb8a79da5))
* **server:** any linked machine that reads for others reads files for the rest, and a file no machine can read now waits for one instead of failing ([f10e75e](https://github.com/xixo/xixo/commit/f10e75e44c0a0fc40606a266b21898a072c93e66))
* **server:** each resource names the machine it lives on, and a machine's model servers say where xixo reaches them ([af9ba49](https://github.com/xixo/xixo/commit/af9ba494d7f0427ac2bf6db438ea6a45abd3c462))
* **server:** every file is read by a xixo agent, on the machine that holds it or beside the server, and the server keeps only what needs a model or the catalog ([7ed0027](https://github.com/xixo/xixo/commit/7ed002781aeaa8bfaf49ce384b0884773ab0da47))
* **server:** installing on a Mac that shares Desktop, Documents, or Downloads opens Full Disk Access and shows xixo-link in Finder, ready to drag in ([7cc4567](https://github.com/xixo/xixo/commit/7cc4567da40147c753cd999a8ba807942bd454cb))
* **server:** putting a machine away unenrolls it in masks and hangs up its agent at once, and installing again unenrolls the earlier client first ([0415756](https://github.com/xixo/xixo/commit/0415756de9921f09d24715b86238f72e5466f87e))
* **server:** the person who sets xixo up is its administrator from their first sign-in, and xixo names itself in lowercase to masks ([cb4d863](https://github.com/xixo/xixo/commit/cb4d863dfd059541752c211937bb99f067c0c264))
* **server:** xixo serves its own masks at /id unless MASKS_ISSUER_TEMPLATE names one, so a self-hosted install signs people in with no second server ([4404f4d](https://github.com/xixo/xixo/commit/4404f4de85aa2b4a4dc0973b483e0fdcc44772d8))
* **web:** a Linux machine that links itself up installs the programs that read files with apt, unless asked not to ([7736273](https://github.com/xixo/xixo/commit/77362739bdd38a4584b71340c00bb694c0d8abee))
* **web:** a Mac links up with its own commands, installing the agent in its Library and starting it as a launch agent ([276284b](https://github.com/xixo/xixo/commit/276284b6be8334f7623d5b914f05b1194057228e))
* **web:** a model server that answers only on its machine can be added from the machine's card, and xixo reaches it through xixo link ([a395495](https://github.com/xixo/xixo/commit/a39549525785f0d8c51a386de72afbe8f9818b4e))
* **web:** a parked pass says what it waits for, and each machine's card counts the files waiting for it ([d8ec043](https://github.com/xixo/xixo/commit/d8ec043bc4452ffaec553e55ce06489aa7f432bf))
* **web:** approving a machine shows its code large to check, then Approved, Linked up, and Connected as each happens ([48bb594](https://github.com/xixo/xixo/commit/48bb59446091ee1f37a87ee5b9ff6df5372d5be7))
* **web:** each machine's icon shows what kind of machine it is with its system's badge, and a model server that answers only on its machine says so instead of offering Add ([fb2e903](https://github.com/xixo/xixo/commit/fb2e903dfff5620f421ad20f9fb31cf48c14a4b5))
* **web:** each step of getting set up names what took care of it and links there ([7897914](https://github.com/xixo/xixo/commit/7897914868d3a2b29b03762f8eb85fb40754647e))
* **web:** linking up a machine is one line to copy and an Approve button, and each machine's card sets what xixo may do with it ([5dee61b](https://github.com/xixo/xixo/commit/5dee61b438e7e6937892f1457cddfec93c4b319f))
* **web:** linking up uses the xixo mark as its icon, and its two halves slide together into the mark as a machine links up ([e1c635a](https://github.com/xixo/xixo/commit/e1c635ae8415d6f887fbf41fd9eea142a735d17b))
* **web:** Resources leads with machines and a Link up panel, and every card says what a resource does for you ([8cdcf2f](https://github.com/xixo/xixo/commit/8cdcf2fffa9db61869d31d8b9ee27ff2bb7ee5e8))
* **web:** the approval page is titled with the machine's name and leads with its system, then lists its folders, account, hardware, addresses, and where it asked from ([ff150bb](https://github.com/xixo/xixo/commit/ff150bb362c012d6396a8d4de5bb3f458e8908b3))
* **web:** the button that approves a machine says Approve, since the heading already names it ([dd47d71](https://github.com/xixo/xixo/commit/dd47d710ab3529902ce070f8f0e399048b22b151))
* **web:** the page that approves a machine is centered, with the card's name, code, buttons, and steps centered in it ([9067e84](https://github.com/xixo/xixo/commit/9067e84598e264bcc37807b0e6bff760fccda643))
* **web:** the Resources page is a card per machine, holding what lives on it or is reached from it, and adding starts from a machine ([c8613b3](https://github.com/xixo/xixo/commit/c8613b321b762adcc9dc796e6c3289896494e202))


### Fixes

* **agent:** a machine installed over SSH writes the folders it marks writable, waits for its clock, works in a folder on disk, and converts office documents under its sandbox ([19578a8](https://github.com/xixo/xixo/commit/19578a87bea6ad48da48b6bbcd0e1ce8d8388ca0))
* **agent:** a machine's bytes leave it only when its config lends them, a refused assertion is retried, and extraction is bounded in time, disk, and memory ([80b0c50](https://github.com/xixo/xixo/commit/80b0c50bcd7626b2fb17815b6b9dd34f97789357))
* **agent:** a one-pixel image has no spread instead of an error, a raw that will not develop keeps its tagged size and location, and LibreOffice converts a hard link or copy into its own output folder and says what it printed when no pdf appears ([41e242e](https://github.com/xixo/xixo/commit/41e242e0b055c00548590323b5a8131938e850f3))
* **agent:** a program's data limit is set by sh just before it starts, so the race-instrumented tests pass, and exiftool gets 6 GiB, since its zip reader reserves about 5 GiB for a zip64 header's placeholder size and failed on every office file and book under 4 GiB ([5719433](https://github.com/xixo/xixo/commit/571943307b6a425473f7ae7ba85498d45287c872))
* **agent:** an agent xixo refuses at every connection for ten minutes stops as withdrawn, so the container beside the server enrolls again ([920cd4d](https://github.com/xixo/xixo/commit/920cd4d1c2595aed833351c4970db00c32798221))
* **agent:** the agent opens its next connection before its token expires and finishes old work there, leaves out names that are not UTF-8, and stops sharing a folder that now leads elsewhere ([e0bcbdc](https://github.com/xixo/xixo/commit/e0bcbdc7c4544964aaeb6017dc8d5a163800b841))
* **link:** when xixo answers with an error page, xixo link names only the status instead of printing the page ([b8a3324](https://github.com/xixo/xixo/commit/b8a3324a145861268ad26c09a80ca8ec689e3e5a))
* **link:** xixo link links itself up with its own token, and stops only when xixo says no machine is enrolled as it ([aab6140](https://github.com/xixo/xixo/commit/aab6140ebd6e207aa4801319af59486bf1519e39))
* **server:** a DPoP proof is good once across every process, kept in proof_marks ([fcbbea2](https://github.com/xixo/xixo/commit/fcbbea2f2ac77817e33a50df79ec1b47fc508aca))
* **server:** a file on a machine never crosses to xixo for its digest or its analysis: its agent reports the SHA-256, its own agent alone reads it, and the same file on two machines still becomes one item ([4f74d55](https://github.com/xixo/xixo/commit/4f74d554d4acd79ef504abbda8db514e6eef0283))
* **server:** a full sync that finds nothing where it found files calls nothing gone, and a folder its machine stopped sharing says so on its card ([e412eb8](https://github.com/xixo/xixo/commit/e412eb8da4b4b8c24eca6915042ec54467207264))
* **server:** a Mac loads xixo link even while the old copy is still stopping, a new machine is named without .local, and it keeps the system, model, and kind it linked up with ([633197a](https://github.com/xixo/xixo/commit/633197a9291d6a368bae7326439cce85b8f87f0a))
* **server:** a Mac starts xixo link as soon as it links up, and a release without a mac reader prints no curl error ([dd509b3](https://github.com/xixo/xixo/commit/dd509b3616bdea10dcc01126ea35e56d7e2d5d43))
* **server:** a machine links up with its own DPoP-bound token beside the code, and xixo tells xixo link plainly when it knows no machine for its client ([e6eb280](https://github.com/xixo/xixo/commit/e6eb280727b4fe2095fd6f3f37c9a09cc51a9694))
* **server:** a machine reached outside a tailnet is installed only against a host key it was given, and the client an install enrolls is kept even when the install fails afterward ([2caa398](https://github.com/xixo/xixo/commit/2caa398e3d9e13a29b3fc8510a3e032df0779ecc))
* **server:** a machine's download is chosen from the builds xixo holds, and the resources reference names :rw ([1584e57](https://github.com/xixo/xixo/commit/1584e574149187c6f5b01516602b5dc8516bfcba))
* **server:** a machine's files answer only its operators, one long call waits on it at a time, and write and chat count as reaching outward ([73fed50](https://github.com/xixo/xixo/commit/73fed501511ed5a527bfb7f6d695ad1ca24efe6a))
* **server:** a machine's socket belongs to the client that opened it, and a client the machine was enrolled past is hung up ([38be23f](https://github.com/xixo/xixo/commit/38be23f5f9186b04f8b146685c0c11ece578a863))
* **server:** a machine's SSH key goes when it is put away, a machine put away mid-install unenrolls its new client, and masks is asked before the row changes ([33a19fb](https://github.com/xixo/xixo/commit/33a19fb2631aed143f036358d85d0b64ac6ee781))
* **server:** dev serves xixo link for macOS too, so a Mac can link up to a dev xixo ([22e8118](https://github.com/xixo/xixo/commit/22e81181e2dd6b335170e504392825259cdd44f4))
* **server:** installing a machine again keeps only the standard tools, and never extract_unsandboxed ([39f1f95](https://github.com/xixo/xixo/commit/39f1f954d1c3fad4ab068c189fd4c64173089a0a))
* **server:** live updates reach a signed-in browser, whose tokens the socket now reads from the session in the cache ([857a019](https://github.com/xixo/xixo/commit/857a019653e8825a66ab3eb9c287d4c82d5aa482))
* **server:** live updates reach the browser again, because each one loads its record inside the subscriber's tenant ([8122059](https://github.com/xixo/xixo/commit/81220597e1d49c1fb0a9314ffaf350a91a93378c))
* **server:** only an administrator reaches a folder through a machine, and each folder on a machine is held for one owner ([c21ba69](https://github.com/xixo/xixo/commit/c21ba694eaacdbedb7fb5ac0a60af16eaff6f094))
* **server:** the agent beside the server is bound as soon as it first knocks, and a tenant not yet connected to masks is passed over ([266d607](https://github.com/xixo/xixo/commit/266d607fb52086b3c400431aedbad349c69e0374))
* **server:** the agent beside the server is bound only to a client a token xixo just handed it made, and never to one another machine is enrolled as ([7170c96](https://github.com/xixo/xixo/commit/7170c968975d93486a5d403a77c8ec5a653e0196))
* **server:** the agent beside the server reads healthy once it connects, and a failed check says what happened without an exception's class name ([9000f11](https://github.com/xixo/xixo/commit/9000f119893f7bf9673e4cfc85a9ccee7d00f75c))
* **server:** the broker answers a caller inside a transaction, holds an upload for the agent to fetch over HTTPS, and keeps every chunk however frames arrive ([b3115d1](https://github.com/xixo/xixo/commit/b3115d1f56c5d4f3cfb069dde4008ca87eff7d50))
* **server:** the built-in masks runs on masks 0.11 and masks-server 0.8, which carry Masks::Client.embed and the engine's page assets ([5c84205](https://github.com/xixo/xixo/commit/5c842054cb22b6b43736b0dbb5f8d37c6a04b256))
* **server:** the exchange sweeper keeps an agent's questions for two hours, past the longest a write through a machine can wait ([40402a8](https://github.com/xixo/xixo/commit/40402a8344f9b9fa94a3ec343a4c531f5779070b))
* the mac reader's architecture check names the file before -verify_arch, as lipo requires ([2022fb2](https://github.com/xixo/xixo/commit/2022fb22d0ee1b2939641bc50004bf86c7857f3e))
* **web:** a Mac that links itself up gets the mac reader of the server's own release, checked against its SHA-256 ([fb41472](https://github.com/xixo/xixo/commit/fb4147290858f8a5d608fee27899d226517db84d))
* **web:** a machine that goes offline keeps a calm card and says when it was last seen ([9d9982c](https://github.com/xixo/xixo/commit/9d9982c0df7fb36af40a0af17c72ca1947258956))
* **web:** a machine that links itself up writes the tools it offers and the folders it may write into ([1cd4827](https://github.com/xixo/xixo/commit/1cd482774c46b03d7c740ff788867caa34f75332))
* **web:** linking up a machine is a tile among the machines, and what it gives is said in the dialog where you decide ([99ca8d7](https://github.com/xixo/xixo/commit/99ca8d7d11adb21ab3c86af3e706c5338442fca1))
* **web:** the catalog, an item's passes, and runs survive a subscription's first, empty answer now that live updates reach the browser ([6192a3e](https://github.com/xixo/xixo/commit/6192a3e4e1525a630a6fdfdab32cbe6b64ed732a))
* **web:** the link-up commands ask for the code without leaving it in shell history and link up through xixo link, and subscriptions skip empty results and pass errors on ([7ed0088](https://github.com/xixo/xixo/commit/7ed00881c15ffebb5a61575b768e85bb867d2abc))


### Performance

* the server image builds its bundled agents on the build machine, so a cross-platform build compiles Go natively instead of under emulation ([87364aa](https://github.com/xixo/xixo/commit/87364aa5caf94b4ba1a468fc44e9cb5a535a4de3))


### Documentation

* a machine installed over SSH marks a folder writable with :rw, keeps its tools on a second install, and is removed with five commands ([66cffda](https://github.com/xixo/xixo/commit/66cffda33cbb35b0c8b4d8aa417b726f70f2f822))
* adding a machine is one command and an approval, and its access is chosen on its card ([1b13f65](https://github.com/xixo/xixo/commit/1b13f6533f1fde135aa63833b20320855858e4eb))
* Reference has a Development page with every ./dev command and flag, the test suites, and the dev stack's ENV vars ([4bfdf2e](https://github.com/xixo/xixo/commit/4bfdf2ede21992aa3935f4737a145a3799e9dc79))
* the Resources page and attaching are described machine by machine ([e3da20f](https://github.com/xixo/xixo/commit/e3da20f851685c3e21ded25af131662c989b4a2f))
* xixo is written in lowercase everywhere people read it ([e19f7c6](https://github.com/xixo/xixo/commit/e19f7c6fa35b868a328496574212cd8a5c00572a))


### Refactoring

* **link:** one head reader, one nesting rule, one lock on the wire, and OCR in batches of eight pages ([93251f2](https://github.com/xixo/xixo/commit/93251f26628f63dfb198cdb31f173b7fd4f2903c))
* **server:** the first administrator's sign-in reads the tenant the request already holds, and the fake disk passes its keywords straight through ([9bd0883](https://github.com/xixo/xixo/commit/9bd0883ced42b9f0340e87c92b7324316a63d05e))
* the program on each machine is xixo link, and the resource it attaches is a machine ([8fda7a0](https://github.com/xixo/xixo/commit/8fda7a06e20d745cf764e42d60016cfa6193b2b6))

## [0.1.1](https://github.com/xixo/xixo/compare/server-v0.1.0...server-v0.1.1) (2026-10-11)


### Performance

* a catalog page, a search, and an item's page cost the same queries however many rows they hold, a resource's item count is batched, a run's log keeps following after the list refetches, Relate reports a change however it closes, and the offline page keeps its icon ([c07a0c8](https://github.com/xixo/xixo/commit/c07a0c889654a09a89a71b158dee72395bb6f54c))


### Refactoring

* run history subscribes only while a run is running and an open log follows its own run, the checklist reads Catalog's settings and is not asked for once hidden, health checks live in one model with one worker threshold, and the offline worker caches only its page ([0de2b68](https://github.com/xixo/xixo/commit/0de2b68fd0e2a0410190030667e680e748c9e638))

## 0.1.0 (2026-10-11)


### Features

* **server:** the server is released with a version, a changelog, and an image tagged with that version, and an upgrade starts with a backup ([c5aa88c](https://github.com/xixo/xixo/commit/c5aa88ccc6479c929853843c594c37b3da08f2cc))
