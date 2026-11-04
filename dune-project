(lang dune 3.0)

(name geohash)

(generate_opam_files true)

(source
 (github andrei/GeohashFetcher))

(authors "Andrei")

(maintainers "Andrei")

(license MIT)

(package
 (name geohash)
 (synopsis "xkcd geohashing in the terminal")
 (description
  "Computes xkcd geohashes (https://xkcd.com/426/) for your graticule, with a non-blocking shell hook, DJIA caching and saved home location.")
 (depends
  (ocaml (>= 5.0))
  dune))
