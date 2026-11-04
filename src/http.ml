(* Non-blocking HTTP GET via a curl subprocess. Output is polled with
   select(), calling [tick] every ~80ms so callers can animate a spinner
   (or do nothing in background mode). *)

let get ?(tick = ignore) ?(timeout_s = 5) url =
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
  | exception Unix.Unix_error (e, _, _) -> Error (Unix.error_message e)
  | r, pid -> (
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
          | None -> Error "malformed response"
          | Some i ->
              let code =
                String.sub out (i + 1) (String.length out - i - 1)
                |> String.trim |> int_of_string_opt |> Option.value ~default:0
              in
              Ok (code, String.sub out 0 i))
      | Unix.WEXITED 28 -> Error "timed out"
      | Unix.WEXITED 127 -> Error "curl not found"
      | Unix.WEXITED 6 -> Error "could not resolve host"
      | Unix.WEXITED 7 -> Error "could not connect"
      | Unix.WEXITED n -> Error (Printf.sprintf "curl exit %d" n)
      | _ -> Error "curl killed")
