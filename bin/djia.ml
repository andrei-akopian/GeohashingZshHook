(* DJIA opening values: on-disk cache + network fetch with fallbacks. *)

let sources =
  [
    "http://geo.crox.net/djia/";
    "http://www1.geo.crox.net/djia/";
    "http://www2.geo.crox.net/djia/";
    "http://carabiner.peeron.com/xkcd/map/data/";
  ]

type error =
  | Not_yet_available  (** a source answered, but has no value for this date *)
  | Unreachable of string  (** no source answered (offline, DNS, timeouts) *)

let error_message date = function
  | Not_yet_available ->
      Printf.sprintf
        "The Dow Jones opening for %s is not published yet (NYSE opens 09:30 \
         America/New_York; weekends/holidays use the previous open).\n\
         Try again later, or pass it manually with -j VALUE."
        (Geo.to_iso date)
  | Unreachable why ->
      Printf.sprintf
        "Could not reach any Dow Jones source (%s).\n\
         Check your connection, or pass the value manually with -j VALUE."
        why

(* ---------- cache ---------- *)

let cache_dir () =
  let base =
    match Sys.getenv_opt "XDG_CACHE_HOME" with
    | Some d when d <> "" -> d
    | _ -> Filename.concat (Sys.getenv_opt "HOME" |> Option.value ~default:".") ".cache"
  in
  Filename.concat base "geohashing"

let rec mkdir_p d =
  if not (Sys.file_exists d) then begin
    mkdir_p (Filename.dirname d);
    try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let read_file path =
  try
    let ic = open_in_bin path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
        Some (really_input_string ic (in_channel_length ic)))
  with _ -> None

(* Atomic write: concurrent shells never see a half-written file. *)
let write_file path contents =
  try
    mkdir_p (Filename.dirname path);
    let tmp = Printf.sprintf "%s.%d.tmp" path (Unix.getpid ()) in
    let oc = open_out_bin tmp in
    output_string oc contents;
    close_out oc;
    Unix.rename tmp path
  with _ -> ()

let cache_path date = Filename.concat (Filename.concat (cache_dir ()) "djia") (Geo.to_iso date)

let cached date =
  match read_file (cache_path date) with
  | Some s when Geo.valid_djia s -> Some (String.trim s)
  | _ -> None

(* ---------- network ----------
   HTTP is done by a curl subprocess whose output we poll with select(),
   calling [tick] every ~80ms so the caller can animate a spinner (or
   simply do nothing in background mode). No blocking reads. *)

let timeout_s = 5

let fetch_one ~tick url =
  match
    let r, w = Unix.pipe ~cloexec:true () in
    let null = Unix.openfile "/dev/null" [ O_RDWR ] 0 in
    let pid =
      Unix.create_process "curl"
        [| "curl"; "-sS"; "-L"; "-m"; string_of_int timeout_s;
           "-w"; "\n%{http_code}"; url |]
        null w null
    in
    Unix.close w;
    Unix.close null;
    (r, pid)
  with
  | exception Unix.Unix_error (e, _, _) -> `Failed (Unix.error_message e)
  | r, pid ->
      let buf = Buffer.create 64 and chunk = Bytes.create 4096 in
      let rec loop () =
        tick ();
        match Unix.select [ r ] [] [] 0.08 with
        | [], _, _ -> loop ()
        | _ ->
            let n = Unix.read r chunk 0 4096 in
            if n > 0 then (Buffer.add_subbytes buf chunk 0 n; loop ())
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
      in
      (try loop () with Unix.Unix_error _ -> ());
      Unix.close r;
      let _, status = Unix.waitpid [] pid in
      let out = Buffer.contents buf in
      match status with
      | Unix.WEXITED 0 -> (
          match String.rindex_opt out '\n' with
          | None -> `Answered
          | Some i ->
              let body = String.sub out 0 i in
              let code = String.trim (String.sub out (i + 1) (String.length out - i - 1)) in
              if code = "200" && Geo.valid_djia body then `Value (String.trim body)
              else `Answered)
      | Unix.WEXITED 28 -> `Failed "timed out"
      | Unix.WEXITED 127 -> `Failed "curl not found"
      | Unix.WEXITED n -> `Failed (Printf.sprintf "curl exit %d" n)
      | _ -> `Failed "curl killed"

let fetch ?(tick = ignore) date =
  match cached date with
  | Some v -> Ok v
  | None ->
      let rec go answered last_err = function
        | [] -> Error (if answered then Not_yet_available else Unreachable last_err)
        | src :: rest -> (
            match fetch_one ~tick (src ^ Geo.to_path date) with
            | `Value v -> write_file (cache_path date) v; Ok v
            | `Answered -> go true last_err rest
            | `Failed e -> go answered e rest)
      in
      go false "no sources" sources
