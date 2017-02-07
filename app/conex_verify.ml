open Conex_utils

(* this is the barebones verify with minimal dependencies
   (goal: cmdliner, opam-file-format, Unix, external openssl)
 *)

module type EXTLOGS = sig
  include LOGS

  type level = [ `Debug | `Info | `Warn | `Error ]
  val set_level : level -> unit
  val set_styled : bool -> unit
end

module Log : EXTLOGS = struct
  module Tag = struct
    type set
  end

  type ('a, 'b) msgf =
    (?header:string -> ?tags:Tag.set ->
     ('a, Format.formatter, unit, 'b) format4 -> 'a) -> 'b
  type 'a log = ('a, unit) msgf -> unit

  type src

  type level = [ `Debug | `Info | `Warn | `Error ]
  let curr_level = ref `Warn
  let set_level lvl = curr_level := lvl
  let level_to_string = function
    | `Debug -> "DEBUG"
    | `Info -> "INFO"
    | `Warn -> "WARN"
    | `Error -> "ERROR"

  let curr_styled = ref true
  let set_styled b = curr_styled := b
  let style level txt =
    if !curr_styled then
      let rst = "\027[m" in
      match level with
      | `Debug -> "\027[32m" ^ txt ^ rst
      | `Info -> "\027[34m" ^ txt ^ rst
      | `Warn -> "\027[33m" ^ txt ^ rst
      | `Error -> "\027[31m" ^ txt ^ rst
    else
      txt

  let report level k msgf =
    let k _ = k () in
    msgf @@ fun ?header ?tags:_ fmt ->
    let hdr = match header with None -> "" | Some s -> s ^ " " in
    Format.kfprintf k Format.std_formatter ("%s[%s] @[" ^^ fmt ^^ "@]@.") hdr (style level (level_to_string level))

  let kunit _ = ()
  let kmsg : type a b. (unit -> b) -> level -> (a, b) msgf -> b =
    fun k level msgf ->
      let doit =
        match level, !curr_level with
        | `Info, `Debug | `Info, `Info | `Info, `Error -> true
        | `Warn, `Warn | `Warn, `Error -> true
        | `Error, _ -> true
        | `Debug, `Debug -> true
        | _ -> false
      in
      if doit then report level k msgf else k ()

  let debug ?src:_ msgf = kmsg kunit `Debug msgf
  let info ?src:_ msgf = kmsg kunit `Info msgf
  let warn ?src:_ msgf = kmsg kunit `Warn msgf
  let err ?src:_ msgf = kmsg kunit `Error msgf
end

module C = Conex.Make(Log)(Conex_nocrypto.V)

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
module IO = Conex_io

let verify_patch io repo patch =
  Conex_persistency.read_file patch >>= C.verify_diff io repo

let verify_full io repo anchors =
  let valid id digest =
    if S.mem digest anchors then
      (Log.debug (fun m -> m "accepting ta %s" id) ; true)
    else
      (Log.debug (fun m -> m "rejecting ta %s" id) ; false)
  in
  C.load_janitors ~valid io repo >>= fun repo ->
  C.load_ids io repo >>= fun repo ->
  IO.items io >>= fun items ->
  foldS (C.verify_item io) repo items

let err_to_cmdliner = function
  | Ok _ -> `Ok ()
  | Error m -> `Error (false, m)

let verify_it repodir quorum anchors incremental dir patch verbose quiet strict no_c =
  let level = match verbose, quiet with
    | true, false -> `Debug
    | false, true -> `Warn
    | _ -> `Info
  in
  Log.set_level level ;
  let styled = if no_c then false else match Conex_opts.terminal () with `Ansi_tty -> true | `None -> false
  in
  Log.set_styled styled ;
  let ta = s_of_list (List.flatten (List.map (Conex_utils.String.cuts ',') anchors)) in
  err_to_cmdliner
    (let repo = Conex_repository.repository ~strict ?quorum () in
     match incremental, patch, dir with
     | true, Some p, None ->
       Conex_unix_provider.fs_ro_provider repodir >>= fun io ->
       Log.debug (fun m -> m "repository %a" Conex_io.pp io) ;
       verify_patch io repo p
     | false, None, Some d ->
       Conex_unix_provider.fs_ro_provider d >>= fun io ->
       Log.debug (fun m -> m "repository %a" Conex_io.pp io) ;
       verify_full io repo ta
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
