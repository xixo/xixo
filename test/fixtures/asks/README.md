# Ask eval

Questions with known answers, asked of a small catalog, to measure what the
ask pipeline gets right on a local model.

`files/` is the catalog. Nothing in it is real, and every domain is under
`.invalid`. The pantry workbook puts its Buy List past the first 6,000
characters and has Plan rows marked `Include? = No`, so a total read from the
wrong sheet comes out wrong. The chequing CSV needs arithmetic: no row holds
the August Fernwood total or the count of transactions over $100.

`cases.yml` lists each case as one or more turns, asked in order on the same
note so later turns are follow-ups. A turn passes when the ask finishes, every
`expect` matches the answer, and no `reject` does. An entry is a substring, a
`/regex/` with optional `i`, `m`, or `x` flags, or `near: [a, b]`, which needs
both terms within 60 characters of each other.

## Running it

    ./dev asks                      every case
    ./dev asks jars-per-size focaccia
    ASKS_FRESH=1 ./dev asks         analyze the files again from nothing
    ASKS_AGAINST=tmp/asks/<run>.json ./dev asks

The run uses its own `asks` tenant and copies the model backend from the
`uris` tenant, so the dev catalog stays out of it. Each run writes
`tmp/asks/<timestamp>.json` with every answer, its timing, and its model
calls. `ASKS_AGAINST` names an earlier run and prints what changed.
