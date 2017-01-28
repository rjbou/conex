open Conex_result
open Conex_core
open Conex_resource

(* to be called by opam (see http://opam.ocaml.org/doc/2.0/Manual.html#configfield-repository-validation-command, https://github.com/ocaml/opam/pull/2754/files#diff-5f9ccd1bb288197c5cf2b18366a73363R312):

%{quorum}% - a non-negative integer (--quorum)
%{anchors}% - list of digests, separated by "," (--trust-anchors -- to be used in full verification)
%{root}% - the repository root (--repository)

(we need --strict and --no-strict [initially default])

two modes of operation (%{incremental}% will just be "true" or "false"):

-full
%{dir}% is only defined for a full update, and is the dir to verify (--dir)

-incremental
%{patch}% - path to a patch (to be applied with -p1, generated by diff -ruaN dir1 dir2) (--patch)

exit code success = 0, failure otherwise

example:

repository-validation-command: [
   "conex" "--root" "%{root}%" "--trust-anchors" "%{anchors}%" "--patch" "%{patch}%"
]

> cat conex
#!/bin/bash -ue
echo "$*"
true

 *)

let verify_patch repo patch =
  let data = Conex_persistency.read_file patch in
  Conex_api.verify_diff repo data

let verify_full repo anchors =
  let valid id digest =
    if S.mem digest anchors then
      (Printf.printf "accepting ta %s\n%!" id ; true)
    else
      (Printf.printf "rejecting ta %s\n%!" id ; false)
  in
  match Conex_api.load_janitors ~valid repo with
  | Ok repo ->
    (* foreach package, read and verify authorisation (may need to load ids), releases, checksums *)
    S.fold (fun item repo ->
        repo >>= fun repo ->
        match Conex_api.verify_item repo item with
        | Ok r -> Ok r
        | Error e -> Error e)
      (Conex_repository.items repo) (Ok repo)
  | Error _ -> Error "couldn't load janitors"

let err_to_cmdliner = function
  | Ok _ -> `Ok ()
  | Error m -> `Error (false, m)

let verify_it repo quorum anchors incremental dir patch verbose quiet strict no_c =
  let level = match verbose, quiet with
    | true, false -> `Debug
    | false, true -> `Warn
    | _ -> `Info
  in
  Conex_api.Log.set_level level ;
  let styled = if no_c then false else match Conex_opts.terminal () with `Ansi_tty -> true | `None -> false
  in
  Conex_api.Log.set_styled styled ;
  let ta = s_of_list (List.flatten (List.map (Conex_utils.String.cuts ',') anchors)) in
  let r p =
    let p = Conex_provider.fs_ro_provider p in
    Conex_repository.repository ~strict ?quorum p
  in
  err_to_cmdliner
    (match incremental, patch, dir with
     | true, Some p, None -> verify_patch (r repo) p
     | false, None, Some d -> verify_full (r d) ta
     | _ -> Error "invalid combination of incremental, patch and dir")


open Cmdliner
open Conex_opts

let incremental =
  let doc = "do incremental verification" in
  Arg.(value & flag & info [ "incremental" ] ~doc)

let dir =
    let doc = "To be verified directory" in
    Arg.(value & opt (some dir) None & info [ "dir" ] ~doc)

let patch =
    let doc = "To be verified patch file" in
    Arg.(value & opt (some file) None & info [ "patch" ] ~doc)

let quiet =
    let doc = "Be quiet" in
    Arg.(value & flag & info [ "quiet" ] ~doc)

let verbose =
    let doc = "Increase verbosity" in
    Arg.(value & flag & info [ "verbose" ] ~doc)

let no_color =
    let doc = "No colored output" in
    Arg.(value & flag & info [ "no-color" ] ~doc)

let cmd =
  let doc = "Verify a signed repository" in
  let man = [
    `S "DESCRIPTION" ;
    `P "$(tname) verifies a digitally signed repository" ;
    `P "Both an incremental mode (receiving a repository and a patch file, and a full mode are available."
  ]
  in
  Term.(ret (const verify_it $ repo $ quorum $ anchors $ incremental $ dir $ patch $ verbose $ quiet $ strict $ no_color)),
  Term.info "conex_verify" ~version:"0.42.0" ~doc ~man

let () = match Term.eval cmd with `Ok () -> exit 0 | _ -> exit 1
