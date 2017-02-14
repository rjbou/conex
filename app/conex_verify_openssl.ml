open Conex_utils

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

module V = Conex_verify.VERIFY (Log) (Conex_openssl.O_V)

let setup repo quorum anchors incremental dir patch verbose quiet strict no_c =
  let level = match verbose, quiet with
    | true, false -> `Debug
    | false, true -> `Warn
    | _ -> `Info
  in
  Log.set_level level ;
  let styled = if no_c then false else match Conex_opts.terminal () with `Ansi_tty -> true | `None -> false
  in
  Log.set_styled styled ;
  V.verify_it repo quorum anchors incremental dir patch strict

open Conex_opts
open Cmdliner

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
  Term.(ret (const setup $ repo $ quorum $ anchors $ incremental $ dir $ patch $ verbose $ quiet $ strict $ no_color)),
  Term.info "conex_verify_openssl" ~version:"%%VERSION_NUM%%"
    ~doc:Conex_verify.doc ~man:Conex_verify.man

let () = match Term.eval cmd with `Ok () -> exit 0 | _ -> exit 1