(* Async HTTP(S) GET built on http-lwt-client (pure-OCaml TLS, system CA
   store via ca-certs, follows redirects). Every request is bounded by a
   timeout so a dead network can never hang the caller. *)

open Lwt.Syntax

let user_agent = "geohash-ocaml/1.0 (+https://geohashing.site)"

(* Returns Ok (status, body) or Error message. Never raises. *)
let get ?(timeout_s = 5.0) url : (int * string, string) result Lwt.t =
  let request =
    let* r =
      Http_lwt_client.request ~follow_redirect:true
        ~headers:[ ("User-Agent", user_agent) ]
        url
        (fun _resp acc chunk -> Lwt.return (acc ^ chunk))
        ""
    in
    Lwt.return
      (match r with
       | Ok (resp, body) -> Ok (Http_lwt_client.Status.to_code resp.status, body)
       | Error (`Msg m) -> Error m)
  in
  let timeout =
    let+ () = Lwt_unix.sleep timeout_s in
    Error "timed out"
  in
  Lwt.catch
    (fun () -> Lwt.pick [ request; timeout ])
    (fun e -> Lwt.return (Error (Printexc.to_string e)))
