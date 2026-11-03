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
}

let usage =
  {|Usage: geohash [OPTIONS] LATITUDE LONGITUDE
       geohash -g [OPTIONS]

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
  -h, --help              Show this help
|}

let die fmt =
  Printf.ksprintf (fun s -> prerr_endline ("geohash: " ^ s); exit 2) fmt

let parse_args argv =
  let o =
    { lat = None; lon = None; date = None; djia = None; force_east = None;
      global = false; closest = false; centicule = false; simple = false;
      daily = false }
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
   | [] -> ()
   | [ la; lo ] ->
       if la < -90.0 || la > 90.0 then die "latitude %g out of range [-90, 90]" la;
       if lo < -180.0 || lo > 180.0 then die "longitude %g out of range [-180, 180]" lo;
       o.lat <- Some la;
       (* 180 and -180 are the same meridian; keep floor() in range *)
       o.lon <- Some (if lo >= 180.0 then -180.0 else lo)
   | _ -> die "expected exactly two coordinates: LATITUDE LONGITUDE");
  if o.lat = None && not o.global then (print_string usage; exit 2);
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

let spinner msg =
  if not (Unix.isatty Unix.stderr) then (ignore, ignore)
  else begin
    let frames = [| "⠋"; "⠙"; "⠹"; "⠸"; "⠼"; "⠴"; "⠦"; "⠧"; "⠇"; "⠏" |] in
    let i = ref 0 in
    let clear () = prerr_string "\r\027[K"; flush stderr in
    (* restore the line if the user hits Ctrl-C mid-fetch *)
    Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ -> clear (); exit 130));
    let tick () =
      Printf.eprintf "\r%s %s" frames.(!i mod Array.length frames) msg;
      flush stderr;
      incr i
    in
    (tick, clear)
  end

let fetch_all ?tick dates = List.map (fun d -> (d, Djia.fetch ?tick d)) dates

let run_direct o =
  let hd = Option.value o.date ~default:(Geo.today ()) in
  let lookup =
    match o.djia with
    | Some v -> fun _ -> v
    | None ->
        let dates = needed_dates o hd in
        let tick, clear =
          if List.for_all (fun d -> Djia.cached d <> None) dates then (ignore, ignore)
          else spinner "Fetching Dow Jones opening…"
        in
        let results = fetch_all ~tick dates in
        clear ();
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
                fetch_all dates
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

let () =
  let o = parse_args Sys.argv in
  if o.daily then (try run_daily o with _ -> () (* never break a shell *))
  else run_direct o
