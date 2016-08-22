open Core

(* our keystore *)
type t

(* with a constructor *)
val empty : t
val size : t -> int
(* retrieval functions *)
val mem : t -> identifier -> bool
val find : t -> identifier -> Publickey.t
(* common modification *)
val add : t -> Publickey.t -> t
val remove : t -> identifier -> t

(* verify a signature, given a store, a resource, and some data *)
val verify : t -> resource -> string -> Signature.t ->
  (identifier, error) result
