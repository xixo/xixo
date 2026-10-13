# Changelog

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
