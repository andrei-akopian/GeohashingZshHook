(lang dune 3.13)

(name geohash)

(generate_opam_files true)

(source
 (github andrei/GeohashFetcher))

(authors "Andrei")

(maintainers "Andrei")

(license MIT)

(package
 (name geohash)
 (synopsis "Terminal client for xkcd geohashing")
 (description
  "Computes xkcd geohashes (https://xkcd.com/426/) for your graticule, with a non-blocking shell hook, DJIA caching and saved home location.")
 (depends
  (ocaml (>= 5.0))
  dune
  (lwt (>= 5.6))
  (http-lwt-client (>= 0.3))
  (ocamlformat :with-dev-setup)
  (ocaml-lsp-server :with-dev-setup)))
