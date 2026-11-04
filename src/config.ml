(* Persistent home location: ${XDG_CONFIG_HOME:-~/.config}/geohashing/config

   Format (one key=value per line, '#' comments allowed):
     lat=43.664473
     lon=-79.392430 *)

type t = { lat : float; lon : float }

let path () =
  let base =
    match Sys.getenv_opt "XDG_CONFIG_HOME" with
    | Some d when d <> "" -> d
    | _ -> Filename.concat (Option.value (Sys.getenv_opt "HOME") ~default:".") ".config"
  in
  Filename.concat (Filename.concat base "geohashing") "config"

let valid_lat x = Float.is_finite x && x >= -90.0 && x <= 90.0
let valid_lon x = Float.is_finite x && x >= -180.0 && x <= 180.0

(* Ok None: no config file. Error: file exists but is unusable. *)
let load () : (t option, string) result =
  let p = path () in
  if not (Sys.file_exists p) then Ok None
  else
    match Djia.read_file p with
    | None -> Error (Printf.sprintf "cannot read %s" p)
    | Some s -> (
        let kv =
          String.split_on_char '\n' s
          |> List.filter_map (fun line ->
                 let line = String.trim line in
                 if line = "" || line.[0] = '#' then None
                 else
                   match String.index_opt line '=' with
                   | None -> None
                   | Some i ->
                       Some
                         ( String.trim (String.sub line 0 i),
                           String.trim (String.sub line (i + 1) (String.length line - i - 1)) ))
        in
        let num k = Option.bind (List.assoc_opt k kv) float_of_string_opt in
        match (num "lat", num "lon") with
        | Some lat, Some lon when valid_lat lat && valid_lon lon -> Ok (Some { lat; lon })
        | _ ->
            Error
              (Printf.sprintf
                 "%s is invalid (need lat=… and lon=… in range).\n\
                  Fix it with `geohash config set LAT LON` or `geohash setup`." p))

let save { lat; lon } =
  let p = path () in
  Djia.write_file p
    (Printf.sprintf "# geohash home location (written by `geohash`)\nlat=%.6f\nlon=%.6f\n" lat lon);
  match load () with
  | Ok (Some _) -> Ok p
  | _ -> Error (Printf.sprintf "could not write %s" p)

(* ---------- IP geolocation (approximate, city-level) ---------- *)

(* Minimal extraction of a JSON scalar: "key": "value" or "key": 12.3 *)
let json_field body key =
  let pat = "\"" ^ key ^ "\"" in
  let n = String.length body and m = String.length pat in
  let rec find i =
    if i + m > n then None
    else if String.sub body i m = pat then Some (i + m)
    else find (i + 1)
  in
  Option.bind (find 0) (fun i ->
      let i = ref i in
      while !i < n && (body.[!i] = ' ' || body.[!i] = ':' || body.[!i] = '\t') do incr i done;
      if !i >= n then None
      else if body.[!i] = '"' then
        Option.map (fun j -> String.sub body (!i + 1) (j - !i - 1)) (String.index_from_opt body (!i + 1) '"')
      else
        let j = ref !i in
        while !j < n && not (List.mem body.[!j] [ ','; '}'; '\n'; ' ' ]) do incr j done;
        Some (String.sub body !i (!j - !i)))

type guess = { g_lat : float; g_lon : float; place : string }

let place_of body keys =
  List.filter_map (fun k -> Option.bind (json_field body k) (fun v -> if v = "" then None else Some v)) keys
  |> String.concat ", "

let from_ipinfo body =
  match json_field body "loc" with
  | Some loc -> (
      match String.split_on_char ',' loc |> List.map float_of_string_opt with
      | [ Some g_lat; Some g_lon ] ->
          Some { g_lat; g_lon; place = place_of body [ "city"; "region"; "country" ] }
      | _ -> None)
  | None -> None

let from_ipapi body =
  let num k = Option.bind (json_field body k) float_of_string_opt in
  match (num "latitude", num "longitude") with
  | Some g_lat, Some g_lon ->
      Some { g_lat; g_lon; place = place_of body [ "city"; "region"; "country_name" ] }
  | _ -> None

let guess_from_ip ?tick () =
  let providers = [ ("https://ipinfo.io/json", from_ipinfo); ("https://ipapi.co/json/", from_ipapi) ] in
  let rec go = function
    | [] -> None
    | (url, parse) :: rest -> (
        match Http.get ?tick url with
        | Ok (200, body) -> (
            match parse body with
            | Some g when valid_lat g.g_lat && valid_lon g.g_lon -> Some g
            | _ -> go rest)
        | _ -> go rest)
  in
  go providers
