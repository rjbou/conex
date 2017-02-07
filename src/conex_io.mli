(** IO operations

    Conex relies on providers to read data from and write data to.  Each access
    consists of a {!path} used as key.  Only basic file types are supported (no
    symbolic links).
*)

open Conex_utils
open Conex_resource

(** A provider contains its base directory, a description, and read/write/exist
    functionality.  TODO: define instead a module type. *)
type t = {
  basedir : string ;
  description : string ;
  file_type : path -> (file_type, string) result ;
  read : path -> (string, string) result ;
  write : path -> string -> (unit, string) result ;
  read_dir : path -> (item list, string) result ;
  exists : path -> bool ;
}

(** [pp t] is a pretty printer for [t]. *)
val pp : t fmt

type cc_err = [ `FileNotFound of name | `NotADirectory of name ]
val compute_release : (string -> Digest.t) -> t -> Uint.t -> name -> (Release.t, cc_err) result

val pp_cc_err : Format.formatter -> cc_err -> unit

val compute_package : t -> Uint.t -> name -> (Package.t, string) result

val ids : t -> (S.t, string) result
val items : t -> (S.t, string) result
val subitems : t -> name -> (S.t, string) result

type r_err = [ `NotFound of typ * name | `ParseError of typ * name * string | `NameMismatch of typ * name * name ]

val pp_r_err : Format.formatter -> r_err -> unit

val read_id : t -> identifier ->
  ([ `Author of Author.t | `Team of Team.t ],
   [> r_err ]) result

val read_team : t -> identifier -> (Team.t, [> r_err ]) result
val write_team : t -> Team.t -> (unit, string) result

val read_author : t -> identifier -> (Author.t, [> r_err ]) result
val write_author : t -> Author.t -> (unit, string) result

val read_authorisation : t -> name -> (Authorisation.t, [> r_err ]) result
val write_authorisation : t -> Authorisation.t -> (unit, string) result

val read_package : t -> name -> (Package.t, [> r_err ]) result
val write_package : t -> Package.t -> (unit, string) result

val read_release : t -> name -> (Release.t, [> r_err ]) result
val write_release : t -> Release.t -> (unit, string) result
