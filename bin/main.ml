(* geohash: xkcd geohashing in the terminal.

   Two modes:
   - direct  : `geohash LAT LON [opts]`  fetches (with a spinner) and prints.
   - --daily : non-blocking shell-hook mode for .zshrc. Never touches the
               network in the foreground. If all needed DJIA values are
               cached it prints today's hash once; otherwise it spawns a
               detached background fetcher and returns immediately. The
               next shell that opens shows the result.

   State (in $XDG_CACHE_HOME/geohashing or ~/.cache/geohashing):
     djia/YYYY-MM-DD   cached DJIA openings (immutable once published)
     shown             last hash key shown in --daily mode
     fetch.lock        pid of a running background fetcher
     last_failure      timestamp of last failed background attempt (backoff) *)


open Geohash_lib

type opts = {
  mutable lat : float option;
  mutable lon : float option;
  mutable date : Geo.date option;
  mutable djia : string option;
  mutable force_east : bool option;
  mutable global : bool;
  mutable closest : bool;
  mutable centicule : bool;
  mutable simple : bool;
  mutable daily : bool;
  mutable save : bool;
}

let usage =
  {|Usage: geohash [OPTIONS] [LATITUDE LONGITUDE]
       geohash -g [OPTIONS]
       geohash setup                  Interactive: pick & save your home location
       geohash config set LAT LON     Save home location
       geohash config show|path|clear

Coordinates default to the saved home location (see `geohash setup`).

Compute the xkcd geohash (https://xkcd.com/426/) for your graticule.

Options:
  -d, --date YYYY-MM-DD   Hash date (default: today, local time)
  -j, --dow-jones VALUE   Use this DJIA opening instead of fetching
      --30w e|w           Force the 30W rule east or west (default: auto)
  -c, --closest           Nearest hash among the 9 surrounding graticules
                          and the globalhash
  -g, --global            Globalhash (coordinates optional)
      --centicule         Keep your own tenths digit (centicule hashing)
  -s, --simple            Machine-readable output (lat, lon[, km])
      --daily             Non-blocking shell-hook mode (for .zshrc)
      --save              Also save the given coordinates as home location
  -h, --help              Show this help
|}

let die fmt =
  Printf.ksprintf (fun s -> prerr_endline ("geohash: " ^ s); exit 2) fmt

let parse_args argv =
  let o =
    { lat = None; lon = None; date = None; djia = None; force_east = None;
      global = false; closest = false; centicule = false; simple = false;
      daily = false; save = false }
  in
  let positional = ref [] in
  let rec go = function
    | [] -> ()
    | ("-h" | "--help") :: _ -> print_string usage; exit 0
    | ("-d" | "--date") :: v :: rest ->
        (match Geo.of_iso v with
         | Some d -> o.date <- Some d
         | None -> die "invalid date %S (expected a real date as YYYY-MM-DD)" v);
        go rest
    | ("-j" | "--dow-jones") :: v :: rest ->
        if not (Geo.valid_djia v) then die "invalid Dow Jones value %S" v;
        (* kept as a string: "12345.60" must not become "12345.6" *)
        o.djia <- Some (String.trim v);
        go rest
    | "--30w" :: v :: rest ->
        (match String.lowercase_ascii v with
         | "e" | "east" -> o.force_east <- Some true
         | "w" | "west" -> o.force_east <- Some false
         | _ -> die "--30w expects e|east|w|west, got %S" v);
        go rest
    | ("-c" | "--closest") :: rest -> o.closest <- true; go rest
    | ("-g" | "--global") :: rest -> o.global <- true; go rest
    | "--centicule" :: rest -> o.centicule <- true; go rest
    | ("-s" | "--simple") :: rest -> o.simple <- true; go rest
    | "--daily" :: rest -> o.daily <- true; go rest
    | "--save" :: rest -> o.save <- true; go rest
    | [ ("-d" | "--date" | "-j" | "--dow-jones" | "--30w") as f ] ->
        die "option %s needs a value" f
    | a :: rest -> (
        (* negative coordinates look like flags, so try numbers first *)
        match float_of_string_opt a with
        | Some f when Float.is_finite f -> positional := f :: !positional; go rest
        | _ -> die "unknown argument %S (see --help)" a)
  in
  go (List.tl (Array.to_list argv));
  (match List.rev !positional with
   | [] -> (
       if o.save then die "--save needs LATITUDE LONGITUDE";
       match Config.load () with
       | Ok (Some c) -> o.lat <- Some c.lat; o.lon <- Some (if c.lon >= 180.0 then -180.0 else c.lon)
       | Ok None -> ()
       | Error e -> if o.daily then exit 0 else die "%s" e)
   | [ la; lo ] ->
       if la < -90.0 || la > 90.0 then die "latitude %g out of range [-90, 90]" la;
       if lo < -180.0 || lo > 180.0 then die "longitude %g out of range [-180, 180]" lo;
       o.lat <- Some la;
       (* 180 and -180 are the same meridian; keep floor() in range *)
       o.lon <- Some (if lo >= 180.0 then -180.0 else lo)
   | _ -> die "expected exactly two coordinates: LATITUDE LONGITUDE");
  if o.lat = None && not o.global then begin
    if o.daily then exit 0 (* never nag or fail inside a shell rc *);
    prerr_endline
      "geohash: no coordinates given and no home location saved.\n\
       Run `geohash setup` (interactive) or `geohash config set LAT LON`,\n\
       or pass LATITUDE LONGITUDE (see --help).";
    exit 2
  end;
  if o.save then begin
    match Config.save { lat = Option.get o.lat; lon = Option.get o.lon } with
    | Ok p -> Printf.eprintf "Saved home location to %s\n%!" p
    | Error e -> die "%s" e
  end;
  if o.global && o.closest then die "--global and --closest are exclusive";
  (match o.lat with
   | Some la when la >= 90.0 -> o.lat <- Some 89.999999
   | _ -> ());
  o

(* ---------- computation ---------- *)

type result = {
  pos : float * float;
  where : string;  (** graticule label or "global" *)
  dist : float option;
}

let east_of o g = Option.value o.force_east ~default:(Geo.is_east g)

let graticules o =
  match (o.lat, o.lon) with
  | Some la, Some lo when not o.global ->
      let g = Geo.graticule_of la lo in
      if o.closest then Geo.neighbours g else [ g ]
  | _ -> []

let needed_dates o hd =
  let gs = List.map (fun g -> Geo.djia_date ~east:(east_of o g) hd) (graticules o) in
  let gl = if o.global || o.closest then [ Geo.djia_date ~east:true hd ] else [] in
  List.sort_uniq Geo.compare_date (gs @ gl)

(* [lookup] maps a DJIA date to its value; all needed dates are present. *)
let compute o hd lookup =
  let djia_for east = lookup (Geo.djia_date ~east hd) in
  let here = match (o.lat, o.lon) with Some a, Some b -> Some (a, b) | _ -> None in
  let dist p = Option.map (fun h -> Geo.haversine h p) here in
  let local g =
    let la, lo = Geo.point g (Geo.fractions hd (djia_for (east_of o g))) in
    let la, lo =
      match here with
      | Some (hla, hlo) when o.centicule ->
          (Geo.replace_tenths ~dst:la ~src:hla, Geo.replace_tenths ~dst:lo ~src:hlo)
      | _ -> (la, lo)
    in
    { pos = (la, lo); where = Geo.graticule_label g; dist = dist (la, lo) }
  in
  let global () =
    let p = Geo.globalhash (Geo.fractions hd (djia_for true)) in
    { pos = p; where = "global"; dist = dist p }
  in
  if o.global then global ()
  else
    let cands = List.map local (graticules o) in
    let cands = if o.closest then global () :: cands else cands in
    List.fold_left
      (fun best c ->
        match (best.dist, c.dist) with
        | Some a, Some b when b < a -> c
        | _ -> best)
      (List.hd cands) (List.tl cands)

(* ---------- output ---------- *)

let tty_out = Unix.isatty Unix.stdout
let style code s = if tty_out then Printf.sprintf "\027[%sm%s\027[0m" code s else s
let bold = style "1"
let dim = style "2"
let cyan = style "36"

let render o hd r =
  let la, lo = r.pos in
  if o.simple then begin
    Printf.printf "%.6f\n%.6f\n" la lo;
    Option.iter (Printf.printf "%.2f\n") r.dist
  end
  else begin
    let title =
      if r.where = "global" then "Globalhash" else "Geohash " ^ r.where
    in
    Printf.printf "%s %s\n" (bold ("🌐 " ^ title)) (dim ("· " ^ Geo.to_iso hd));
    Printf.printf "  %s  %s\n" (bold (Printf.sprintf "%.6f, %.6f" la lo))
      (match r.dist with Some d -> dim (Printf.sprintf "(%.1f km away)" d) | None -> "");
    Printf.printf "  %s\n  %s\n  %s\n"
      (cyan (Printf.sprintf "https://www.google.com/maps/search/?api=1&query=%.6f,%.6f" la lo))
      (cyan (Printf.sprintf "https://www.openstreetmap.org/?mlat=%.6f&mlon=%.6f&zoom=10" la lo))
      (cyan (Printf.sprintf "https://geohashing.info/t:map/g:%.6f,%.6f/c:%.6f,%.6f/z:9" la lo la lo))
  end

(* ---------- direct mode ---------- *)

(* Runs [p] to completion on the Lwt loop, animating a spinner on stderr
   concurrently (only when stderr is a terminal and [show] is true). *)
let with_spinner ?(show = true) msg (p : 'a Lwt.t) : 'a =
  if not (show && Unix.isatty Unix.stderr) then Lwt_main.run p
  else begin
    let open Lwt.Syntax in
    let frames = [| "⠋"; "⠙"; "⠹"; "⠸"; "⠼"; "⠴"; "⠦"; "⠧"; "⠇"; "⠏" |] in
    let clear () = prerr_string "\r\027[K"; flush stderr in
    (* restore the line if the user hits Ctrl-C mid-fetch *)
    Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ -> clear (); exit 130));
    let rec spin i =
      Printf.eprintf "\r%s %s" frames.(i mod Array.length frames) msg;
      flush stderr;
      let* () = Lwt_unix.sleep 0.08 in
      spin (i + 1)
    in
    let r = Lwt_main.run (Lwt.pick [ p; (let* () = spin 0 in Lwt.fail Exit) ]) in
    clear ();
    Sys.set_signal Sys.sigint Sys.Signal_default;
    r
  end

(* all needed DJIA dates are fetched concurrently *)
let fetch_all dates =
  Lwt_list.map_p (fun d -> Lwt.map (fun r -> (d, r)) (Djia.fetch d)) dates

let run_direct o =
  let hd = Option.value o.date ~default:(Geo.today ()) in
  let lookup =
    match o.djia with
    | Some v -> fun _ -> v
    | None ->
        let dates = needed_dates o hd in
        let show = not (List.for_all (fun d -> Djia.cached d <> None) dates) in
        let results = with_spinner ~show "Fetching Dow Jones opening…" (fetch_all dates) in
        List.iter
          (function
            | d, Error e -> prerr_endline (Djia.error_message d e); exit 1
            | _ -> ())
          results;
        fun d ->
          match List.assoc d results with Ok v -> v | Error _ -> assert false
  in
  render o hd (compute o hd lookup)

(* ---------- daily (shell hook) mode ---------- *)

let state f = Filename.concat (Djia.cache_dir ()) f
let backoff_s = 300.0

let mtime f = try Some (Unix.stat f).st_mtime with Unix.Unix_error _ -> None

let pid_alive pid =
  try Unix.kill pid 0; true with Unix.Unix_error (Unix.ESRCH, _, _) -> false | _ -> true

(* Returns true if we acquired the lock. Stale locks (dead pid) are reclaimed. *)
let rec acquire_lock ?(retry = true) () =
  let lock = state "fetch.lock" in
  Djia.mkdir_p (Djia.cache_dir ());
  match Unix.openfile lock [ O_WRONLY; O_CREAT; O_EXCL ] 0o644 with
  | fd -> Unix.close fd; true
  | exception Unix.Unix_error (Unix.EEXIST, _, _) ->
      let holder = Option.bind (Djia.read_file lock) (fun s -> int_of_string_opt (String.trim s)) in
      let stale =
        match holder with
        | Some pid -> not (pid_alive pid)
        | None -> (match mtime lock with Some t -> Unix.time () -. t > 60.0 | None -> true)
      in
      if stale && retry then ((try Sys.remove lock with _ -> ()); acquire_lock ~retry:false ())
      else false
  | exception _ -> false

let spawn_background_fetch dates =
  let recent_failure =
    match mtime (state "last_failure") with
    | Some t -> Unix.time () -. t < backoff_s
    | None -> false
  in
  if (not recent_failure) && acquire_lock () then
    match Unix.fork () with
    | 0 -> (
        (* child: detach fully from the terminal so the shell never waits *)
        ignore (Unix.setsid ());
        match Unix.fork () with
        | 0 ->
            let null = Unix.openfile "/dev/null" [ O_RDWR ] 0 in
            List.iter (fun fd -> Unix.dup2 null fd) [ Unix.stdin; Unix.stdout; Unix.stderr ];
            Djia.write_file (state "fetch.lock") (string_of_int (Unix.getpid ()));
            let ok =
              try
                Lwt_main.run (fetch_all dates)
                |> List.for_all (fun (_, r) -> Result.is_ok r)
              with _ -> false
            in
            if ok then (try Sys.remove (state "last_failure") with _ -> ())
            else Djia.write_file (state "last_failure") (string_of_float (Unix.time ()));
            (try Sys.remove (state "fetch.lock") with _ -> ());
            Unix._exit 0
        | _ -> Unix._exit 0)
    | pid -> ignore (Unix.waitpid [] pid) (* reaps the short-lived middle process *)
    | exception _ -> (try Sys.remove (state "fetch.lock") with _ -> ())

let run_daily o =
  let hd = Option.value o.date ~default:(Geo.today ()) in
  let key =
    Printf.sprintf "%s %s %s" (Geo.to_iso hd)
      (Option.fold ~none:"-" ~some:string_of_float o.lat)
      (Option.fold ~none:"-" ~some:string_of_float o.lon)
  in
  if Option.map String.trim (Djia.read_file (state "shown")) = Some key then ()
  else
    let dates = needed_dates o hd in
    let lookup =
      match o.djia with
      | Some v -> Some (fun _ -> v)
      | None ->
          let vals = List.map (fun d -> (d, Djia.cached d)) dates in
          if List.for_all (fun (_, v) -> v <> None) vals then
            Some (fun d -> Option.get (List.assoc d vals))
          else None
    in
    match lookup with
    | Some f ->
        render o hd (compute o hd f);
        Djia.write_file (state "shown") key
    | None -> spawn_background_fetch dates

(* ---------- config subcommands ---------- *)

let tilde p =
  match Sys.getenv_opt "HOME" with
  | Some h when String.length p > String.length h && String.sub p 0 (String.length h) = h ->
      "~" ^ String.sub p (String.length h) (String.length p - String.length h)
  | _ -> p

let parse_coord_pair s =
  (* accepts "43.66, -79.39", "43.66 -79.39" (as copied from Google Maps) *)
  match
    String.map (fun c -> if c = ',' then ' ' else c) s
    |> String.split_on_char ' ' |> List.filter (( <> ) "")
    |> List.map float_of_string_opt
  with
  | [ Some a; Some b ] -> Some (a, b)
  | _ -> None

let run_setup () =
  if not (Unix.isatty Unix.stdin) then die "setup is interactive; use `geohash config set LAT LON` in scripts";
  let current = match Config.load () with Ok c -> c | Error _ -> None in
  print_endline (bold "📍 Geohash home location");
  Option.iter
    (fun (c : Config.t) -> Printf.printf "  Current: %.6f, %.6f %s\n" c.lat c.lon (dim ("(" ^ tilde (Config.path ()) ^ ")")))
    current;
  let guess = with_spinner "Looking up approximate location from your IP…" (Config.guess_from_ip ()) in
  (match guess with
   | Some g ->
       Printf.printf "  Your IP suggests: %s %s\n" (bold (Printf.sprintf "%.4f, %.4f" g.g_lat g.g_lon))
         (dim (if g.place = "" then "" else "(" ^ g.place ^ ")"));
       print_endline (dim "  IP location is approximate (city-level). For precision, paste exact\n  coordinates, e.g. right-click → copy in Google Maps.")
   | None -> print_endline (dim "  Could not guess location from IP (offline?). Enter it manually."));
  let default =
    match (current, guess) with
    | Some c, _ -> Some (c.lat, c.lon)
    | None, Some g -> Some (g.g_lat, g.g_lon)
    | None, None -> None
  in
  let read prompt =
    print_string prompt;
    flush stdout;
    match In_channel.input_line stdin with
    | Some l -> String.trim l
    | None -> print_newline (); print_endline "Aborted, nothing saved."; exit 1
  in
  let rec ask label valid range def =
    let prompt =
      match def with
      | Some d -> Printf.sprintf "%s [%s]: " label (Printf.sprintf "%.6f" d)
      | None -> label ^ ": "
    in
    match read prompt with
    | "" when def <> None -> `One (Option.get def)
    | s -> (
        match (float_of_string_opt s, parse_coord_pair s) with
        | Some x, _ when valid x -> `One x
        | _, Some p -> `Both p
        | _ ->
            Printf.printf "  %s\n" (style "31" (Printf.sprintf "Please enter a number in %s." range));
            ask label valid range def)
  in
  let rec pick () =
    let lat, lon =
      match ask "Latitude " Config.valid_lat "[-90, 90]" (Option.map fst default) with
      | `Both p -> p
      | `One lat -> (
          match ask "Longitude" Config.valid_lon "[-180, 180]" (Option.map snd default) with
          | `One lon -> (lat, lon)
          | `Both (_, lon) -> (lat, lon))
    in
    if not (Config.valid_lat lat && Config.valid_lon lon) then (
      print_endline (style "31" "  Coordinates out of range, try again.");
      pick ())
    else (lat, lon)
  in
  let lat, lon = pick () in
  match String.lowercase_ascii (read (Printf.sprintf "Save %.6f, %.6f? [Y/n]: " lat lon)) with
  | "" | "y" | "yes" -> (
      match Config.save { lat; lon } with
      | Ok p ->
          Printf.printf "%s Saved to %s\n" (style "32" "✓") (tilde p);
          print_endline (dim "  Try: geohash -c    ·    shell hook: geohash --closest --daily")
      | Error e -> die "%s" e)
  | _ -> print_endline "Nothing saved."

let run_config = function
  | [ "set"; a; b ] -> (
      match (float_of_string_opt a, float_of_string_opt b) with
      | Some lat, Some lon when Config.valid_lat lat && Config.valid_lon lon -> (
          match Config.save { lat; lon } with
          | Ok p -> Printf.printf "Saved %.6f, %.6f to %s\n" lat lon (tilde p)
          | Error e -> die "%s" e)
      | _ -> die "usage: geohash config set LAT LON  (lat in [-90,90], lon in [-180,180])")
  | [ "show" ] | [] -> (
      match Config.load () with
      | Ok (Some c) -> Printf.printf "%.6f %.6f\n" c.lat c.lon
      | Ok None -> die "no home location saved (run `geohash setup`)"
      | Error e -> die "%s" e)
  | [ "path" ] -> print_endline (Config.path ())
  | [ "clear" ] ->
      (try Sys.remove (Config.path ()) with Sys_error _ -> ());
      print_endline "Home location cleared."
  | _ -> die "usage: geohash config [show | set LAT LON | path | clear]"

let () =
  match Array.to_list Sys.argv with
  | _ :: "setup" :: [] -> run_setup ()
  | _ :: "config" :: rest -> run_config rest
  | _ ->
      let o = parse_args Sys.argv in
      if o.daily then (try run_daily o with _ -> () (* never break a shell *))
      else run_direct o
