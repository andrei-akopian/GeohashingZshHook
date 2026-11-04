# GeohashFetcher

xkcd [geohashing](https://geohashing.site/) in the terminal, written in OCaml
(stdlib + `unix` only; HTTP via the system `curl`).

## Setup (opam)

```sh
# one-time: the `default` switch with a compiler + dev tools
opam switch create default ocaml-base-compiler.5.5.2   # or: opam install ocaml-base-compiler.5.5.2
opam install dune ocaml-lsp-server ocamlformat
eval $(opam env)      # ~/.zshrc already sources opam-init, so new shells get this

# build / test / install
dune build            # -> _build/default/bin/main.exe
dune test
opam pin add --kind=path geohash .   # install `geohash` into the switch; re-run `opam reinstall geohash` after changes
```

`geohash.opam` is generated from `dune-project`; edit that instead.

Layout: `src/` library (`geo`, `djia`, `http`, `config`), `bin/main.ml` CLI,
`test/` unit tests.

## Home location

```sh
geohash setup                     # interactive: suggests location from your IP
geohash config set 43.66 -79.39   # non-interactive
geohash 43.66 -79.39 --save       # compute and save in one go
geohash config show | path | clear
```

Stored in `${XDG_CONFIG_HOME:-~/.config}/geohashing/config`. Once set,
coordinates are optional everywhere.

## Usage

```sh
geohash                              # hash in your home graticule
geohash -c                           # nearest of 9 neighbouring graticules + globalhash
geohash -g                           # globalhash
geohash 51.5 -0.1 -d 2008-05-30      # explicit place & date
geohash 37.4 -122.1 -d 2005-05-26 -j 10458.68   # offline, DJIA given manually
geohash --centicule -s               # centicule, machine-readable
```

## Shell hook (non-blocking)

Add to `~/.zshrc`:

```sh
geohash --closest --daily   # uses saved home location; silent if none
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
