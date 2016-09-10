open Core

type pub =
  | RSA_pub of Nocrypto.Rsa.pub

let decode_key data =
  match X509.Encoding.Pem.Public_key.of_pem_cstruct (Cstruct.of_string data) with
  | [ `RSA pub ] -> Some (RSA_pub pub)
  | _ -> None

let encode_key = function
  | RSA_pub pub -> Cstruct.to_string (X509.Encoding.Pem.Public_key.to_pem_cstruct1 (`RSA pub))

(*BISECT-IGNORE-BEGIN*)
let pp_key ppf = function
  | RSA_pub p -> Format.fprintf ppf "%d bits RSA key:@.%s@."
                                (Nocrypto.Rsa.pub_bits p)
                                (encode_key (RSA_pub p))
(*BISECT-IGNORE-END*)

type t = {
  counter : int64 ;
  version : int64 ;
  keyid : identifier ;
  key : pub option ;
  role : role ;
}

let equal a b =
  a.counter = b.counter &&
  a.keyid = b.keyid &&
  a.role = b.role &&
  a.key = b.key

(*BISECT-IGNORE-BEGIN*)
let pp_publickey ppf p =
  let pp_opt_key ppf = function
    | None -> Format.pp_print_string ppf "none"
    | Some x -> pp_key ppf x
  in
  Format.fprintf ppf "keyid: %a@ role: %a@ counter: %Lu@ key: %a@."
    pp_id p.keyid
    pp_role p.role
    p.counter
    pp_opt_key p.key
(*BISECT-IGNORE-END*)

let publickey ?(counter = 0L) ?(version = 0L) ?(role = `Author) keyid key =
  match key with
  | Some (RSA_pub p) when Nocrypto.Rsa.pub_bits p < 2048 -> Error "RSA key too small"
  | _ -> Ok { counter ; version ; role ; keyid ; key }

module Pss_sha256 = Nocrypto.Rsa.PSS (Nocrypto.Hash.SHA256)

let verify pub data (id, sigval) =
  match Nocrypto.Base64.decode (Cstruct.of_string sigval) with
  | None -> Error (`InvalidBase64Encoding (id, sigval))
  | Some signature ->
    let data = Signature.extend_data data id in
    let cs_data = Cstruct.of_string data in
    match pub.key with
    | Some (RSA_pub key) ->
      if Pss_sha256.verify ~key ~signature cs_data then
        Ok id
      else
        let s = Cstruct.to_string signature in
        Error (`InvalidSignature (id, s, data))
    | None -> Error (`InvalidPublicKey id)
