open Geohash_lib

let check name cond = if not cond then (Printf.eprintf "FAIL: %s\n" name; exit 1)
let close a b = Float.abs (a -. b) < 1e-6

let () =
  (* Reference example from https://geohashing.site/geohashing/The_Algorithm *)
  let d = Option.get (Geo.of_iso "2005-05-26") in
  let la, lo = Geo.point (Geo.graticule_of 37.4 (-122.1)) (Geo.fractions d "10458.68") in
  check "reference lat" (close la 37.857713);
  check "reference lon" (close lo (-122.544543));
  (* -0 graticule keeps its sign *)
  let la, lo = Geo.point (Geo.graticule_of (-0.5) (-0.5)) (Geo.fractions d "10458.68") in
  check "-0 lat" (close la (-0.857713));
  check "-0 lon" (close lo (-0.544543));
  check "-0 label" (Geo.graticule_label (Geo.graticule_of (-0.5) 51.2) = "-0,51");
  (* 30W rule *)
  let d2 = Option.get (Geo.of_iso "2008-05-30") in
  check "30W east" (Geo.djia_date ~east:true d2 = Option.get (Geo.of_iso "2008-05-29"));
  check "30W west" (Geo.djia_date ~east:false d2 = d2);
  check "pre-30W" (Geo.djia_date ~east:true d = d);
  (* dates *)
  check "bad date" (Geo.of_iso "2026-02-30" = None);
  check "leap" (Geo.of_iso "2024-02-29" <> None);
  check "add_days" (Geo.add_days (Option.get (Geo.of_iso "2026-03-01")) (-1) = Option.get (Geo.of_iso "2026-02-28"));
  (* antimeridian *)
  check "wrap" (List.exists (fun (g : Geo.graticule) -> g.klon = -180) (Geo.neighbours (Geo.graticule_of 10.0 179.5)));
  (* centicule *)
  check "centicule" (close (Geo.replace_tenths ~dst:43.966061 ~src:43.66) 43.666061);
  check "centicule neg" (close (Geo.replace_tenths ~dst:(-79.119968) ~src:(-79.39)) (-79.319968));
  (* djia validation *)
  check "djia ok" (Geo.valid_djia "12345.60\n");
  check "djia bad" (not (Geo.valid_djia "error"));
  check "djia html" (not (Geo.valid_djia "<html>"));
  print_endline "all tests passed"
