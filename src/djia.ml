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

(* ---------- network ---------- *)

open Lwt.Syntax

let fetch_one url =
  let+ r = Http.get url in
  match r with
  | Ok (200, body) when Geo.valid_djia body -> `Value (String.trim body)
  | Ok _ -> `Answered
  | Error e -> `Failed e

(* Tries each source in order; a value is cached forever once found. *)
let fetch date : (string, error) result Lwt.t =
  match cached date with
  | Some v -> Lwt.return (Ok v)
  | None ->
      let rec go answered last_err = function
        | [] ->
            Lwt.return
              (Error (if answered then Not_yet_available else Unreachable last_err))
        | src :: rest -> (
            let* r = fetch_one (src ^ Geo.to_path date) in
            match r with
            | `Value v -> write_file (cache_path date) v; Lwt.return (Ok v)
            | `Answered -> go true last_err rest
            | `Failed e -> go answered e rest)
      in
      go false "no sources" sources
