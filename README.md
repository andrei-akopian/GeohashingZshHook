# GeohashFetcher

xkcd [geohashing](https://geohashing.site/) in the terminal, written in OCaml
(stdlib + `unix` only; HTTP via the system `curl`).

## Build

```sh
dune build            # binary: _build/default/bin/geohash.exe
dune install          # or copy it onto your PATH as `geohash`
```

## Usage

```sh
geohash 43.66 -79.39                 # hash in your graticule
geohash 43.66 -79.39 -c              # nearest of 9 neighbouring graticules + globalhash
geohash -g                           # globalhash
geohash 43.66 -79.39 -d 2008-05-30   # a specific date
geohash 37.4 -122.1 -d 2005-05-26 -j 10458.68   # offline, DJIA given manually
geohash 43.66 -79.39 --centicule -s  # centicule, machine-readable
```

## Shell hook (non-blocking)

Add to `~/.zshrc`:

```sh
geohash 43.66447 -79.39243 --closest --daily
```

`--daily` never waits on the network. State machine, stored in
`${XDG_CACHE_HOME:-~/.cache}/geohashing`:

1. **already shown** today's hash for these coordinates → print nothing.
2. **all DJIA values cached** → print the hash, mark it shown.
3. **otherwise** → fork a detached background fetcher (lock file prevents
   duplicates; a failed attempt backs off 5 min) and return immediately.
   The next terminal you open shows the result.

## Edge cases handled

- DJIA not published yet (before 09:30 ET, future dates): clear message,
  exit 1 in direct mode; silent retry later in `--daily` mode.
- Offline / timeouts (5 s per source, 4 fallback sources).
- 30W rule (east of 30°W uses previous day's DJIA, from 2008-05-27 on);
  `--closest` near 30°W mixes both correctly.
- The `-0` graticules (e.g. London `51,-0`), antimeridian wrap, poles.
- DJIA kept as a string (`12345.60` ≠ `12345.6`), validated before hashing.
- Invalid dates (`2026-02-30`), out-of-range coordinates, negative
  coordinates as positional args.
