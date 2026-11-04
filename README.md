# GeohashFetcher

> [!WARNING] 
> This tool is made with LLM. Author has less than used it less than _1_ times so far.

Calculator for xkcd [geohashing game](https://geohashing.site/) in the terminal, written in OCaml by Opus 5.5. Idea of the game is to travel to random coordinates every day (the same of all users based on the day's Dow Jones index values).

The tool is lightweight and intended to be triggered from `.zshrc` every time a terminal is opened. Caching is used to limit resource use.

---

Networking uses [`http-lwt-client`](https://github.com/robur-coop/http-lwt-client) (pure-OCaml TLS, system CA store, redirects) on top of `lwt`, so fetches are asynchronous with a live spinner and a hard 5 s timeout per request.

## Building and installing

### 1. Prerequisites (one-time)

```sh
brew install opam gmp pkg-config   # OCaml package manager + C deps of the TLS stack
opam init                         # creates ~/.opam and offers to edit ~/.zshrc (say yes)
```

`opam init` adds a block to `~/.zshrc` that sources
`~/.opam/opam-init/init.zsh`; that is what puts the active switch's `bin/`
on your `PATH` in every new shell.

A *switch* is an isolated OCaml installation (compiler + packages). Create
one, or repair an existing empty one:

```sh
opam switch create default ocaml-base-compiler.5.5.2   # new switch
# or, if `default` exists but `ocaml -version` fails:
opam install --switch default ocaml-base-compiler.5.5.2

eval $(opam env)                  # load it into *this* shell
ocaml -version                    # -> 5.5.2
```

### 2. Dependencies

From the project root:

```sh
opam install . --deps-only --with-test            # lwt, http-lwt-client, ...
opam install . --deps-only --with-dev-setup       # optional: ocaml-lsp-server, ocamlformat
```

The dependency list lives in `dune-project`; `geohash.opam` is generated
from it on every `dune build` (don't edit it by hand).

### 3. Compile and test

```sh
dune build                        # binary at _build/default/bin/main.exe
dune test                         # unit tests in test/
dune build --profile release      # optimised, warnings not fatal
./_build/default/bin/main.exe --help
```

### 4. Put `geohash` on your PATH

Pick **one**:

**a) Install into the opam switch (recommended).** The switch's `bin/`
(`~/.opam/default/bin`) is already on `PATH` via the opam shell hook.

```sh
opam pin add --kind=path geohash .   # build + install from the working tree
which geohash                        # -> ~/.opam/default/bin/geohash
opam reinstall geohash               # after changing the code
opam remove geohash && opam pin remove geohash   # uninstall
```

`--kind=path` builds from the files on disk. Without it opam pins the git
repo and only sees *committed* changes.

**b) `dune install`** into the current switch (same destination, no pin):

```sh
dune build --profile release && dune install
dune uninstall                       # to remove
```

**c) Copy a standalone binary** somewhere independent of opam, e.g.
`~/.local/bin` (useful if you later switch compilers or delete the switch):

```sh
dune build --profile release
mkdir -p ~/.local/bin
install -m 755 _build/default/bin/main.exe ~/.local/bin/geohash
# ensure it's on PATH (once):
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

OCaml libraries are linked statically, so the copied binary keeps working
without opam. The one dynamic dependency is GMP (pulled in by the TLS
stack), so keep `brew install gmp` around — check with
`otool -L ~/.local/bin/geohash`.

Verify: open a new terminal and run `geohash --help`. If you get
`command not found`, check `echo $PATH` and that `~/.zshrc` sources opam
(option a/b) or exports `~/.local/bin` (option c).

> **Tip — shell hook ordering:** if you use the `--daily` hook (below) with
> option a/b, put it *after* the opam block in `~/.zshrc`, otherwise
> `geohash` isn't on `PATH` yet. Option c avoids this entirely.

### Layout

```
dune-project        package metadata + dependencies (source of truth)
src/                library: geo (algorithm), djia (fetch+cache),
                    http (async client), config (home location, IP lookup)
bin/main.ml         CLI
test/test_geo.ml    unit tests
```

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
