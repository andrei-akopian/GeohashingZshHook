(* Pure geohashing logic: dates, hashing, graticules, distances.
   Algorithm reference: https://geohashing.site/geohashing/The_Algorithm *)

(* ---------- Dates (proleptic Gregorian, no timezone) ---------- *)

type date = { y : int; m : int; d : int }

let days_from_civil { y; m; d } =
  (* Howard Hinnant's algorithm: days since 1970-01-01 *)
  let y = if m <= 2 then y - 1 else y in
  let era = (if y >= 0 then y else y - 399) / 400 in
  let yoe = y - (era * 400) in
  let mp = (m + 9) mod 12 in
  let doy = ((153 * mp) + 2) / 5 + d - 1 in
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (era * 146097) + doe - 719468

let civil_from_days z =
  let z = z + 719468 in
  let era = (if z >= 0 then z else z - 146096) / 146097 in
  let doe = z - (era * 146097) in
  let yoe = (doe - (doe / 1460) + (doe / 36524) - (doe / 146096)) / 365 in
  let doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100)) in
  let mp = ((5 * doy) + 2) / 153 in
  let d = doy - (((153 * mp) + 2) / 5) + 1 in
  let m = if mp < 10 then mp + 3 else mp - 9 in
  let y = yoe + (era * 400) + if m <= 2 then 1 else 0 in
  { y; m; d }

let add_days dt n = civil_from_days (days_from_civil dt + n)
let compare_date a b = compare (days_from_civil a) (days_from_civil b)
let to_iso { y; m; d } = Printf.sprintf "%04d-%02d-%02d" y m d
let to_path { y; m; d } = Printf.sprintf "%04d/%02d/%02d" y m d

let of_iso s =
  try
    Scanf.sscanf s "%4d-%2d-%2d%!" (fun y m d ->
        let dt = { y; m; d } in
        (* round-trip check rejects 2026-02-30 etc. *)
        if m >= 1 && m <= 12 && civil_from_days (days_from_civil dt) = dt then
          Some dt
        else None)
  with _ -> None

let today () =
  let t = Unix.localtime (Unix.time ()) in
  { y = t.tm_year + 1900; m = t.tm_mon + 1; d = t.tm_mday }

(* ---------- 30W rule ---------- *)

let rule_30w_start = { y = 2008; m = 5; d = 27 }

(* Which DJIA opening is used for a hash on [date] in the given hemisphere. *)
let djia_date ~east date =
  if east && compare_date date rule_30w_start >= 0 then add_days date (-1)
  else date

(* ---------- Graticules ----------
   A graticule is identified by k = floor(coordinate). This handles the
   "-0" graticule correctly: k = -1 is the graticule labelled "-0",
   which spans (-1, 0]. *)

type graticule = { klat : int; klon : int }

let graticule_of lat lon =
  { klat = int_of_float (Float.floor lat); klon = int_of_float (Float.floor lon) }

let label k = if k >= 0 then string_of_int k else "-" ^ string_of_int (-(k + 1))
let graticule_label g = label g.klat ^ "," ^ label g.klon

(* East of 30W: graticule longitude label > -30, i.e. k >= -30. *)
let is_east g = g.klon >= -30

(* Longitude wraps around the antimeridian; latitude does not. *)
let wrap_lon k = ((k + 180) mod 360 + 360) mod 360 - 180

let neighbours g =
  List.concat_map
    (fun dlat ->
      List.filter_map
        (fun dlon ->
          let klat = g.klat + dlat in
          if klat < -90 || klat > 89 then None
          else Some { klat; klon = wrap_lon (g.klon + dlon) })
        [ -1; 0; 1 ])
    [ -1; 0; 1 ]
  |> List.sort_uniq compare

(* ---------- Hashing ---------- *)

let hex_fraction s =
  let r = ref 0.0 and scale = ref (1.0 /. 16.0) in
  String.iter
    (fun c ->
      let v = int_of_string ("0x" ^ String.make 1 c) in
      r := !r +. (float v *. !scale);
      scale := !scale /. 16.0)
    s;
  !r

(* Returns the two fractional offsets (lat, lon) in [0,1). *)
let fractions date djia =
  let h = Digest.to_hex (Digest.string (to_iso date ^ "-" ^ djia)) in
  (hex_fraction (String.sub h 0 16), hex_fraction (String.sub h 16 16))

let apply_frac k f = if k >= 0 then float k +. f else float (k + 1) -. f

let point g (flat, flon) = (apply_frac g.klat flat, apply_frac g.klon flon)

let globalhash (flat, flon) = ((flat *. 180.0) -. 90.0, (flon *. 360.0) -. 180.0)

(* Centicule: replace the tenths digit of [dst] with the tenths digit of
   [src]. Done numerically (the original string replace broke on values
   like 43.4 -> "43.4" containing ".4" in other places, scientific
   notation, etc.). *)
let replace_tenths ~dst ~src =
  let tenths x = Float.of_int (int_of_float (Float.abs x *. 10.0) mod 10) in
  let a = Float.abs dst in
  let whole = Float.trunc a in
  let rest = (a -. whole) *. 10.0 in
  let below = rest -. Float.trunc rest in
  let v = whole +. ((tenths src +. below) /. 10.0) in
  if dst < 0.0 then -.v else v

(* ---------- Distance ---------- *)

let haversine (lat1, lon1) (lat2, lon2) =
  let r = 6371.0 and rad x = x *. Float.pi /. 180.0 in
  let dphi = rad (lat2 -. lat1) and dl = rad (lon2 -. lon1) in
  let a =
    (sin (dphi /. 2.0) ** 2.0)
    +. (cos (rad lat1) *. cos (rad lat2) *. (sin (dl /. 2.0) ** 2.0))
  in
  2.0 *. r *. atan2 (sqrt a) (sqrt (Float.max 0.0 (1.0 -. a)))

(* ---------- Validation ---------- *)

let valid_djia s =
  let s = String.trim s in
  s <> ""
  && String.length s < 16
  && String.for_all (fun c -> (c >= '0' && c <= '9') || c = '.') s
  && List.length (String.split_on_char '.' s) <= 2
  && s.[0] <> '.'
