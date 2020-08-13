open Conex_utils
open Conex_resource

module OpamParserTypes = OpamParserTypes.FullPos

let np pelem =
  OpamParserTypes.({
    pelem;
    pos = { filename = "";
    start = 0, 0;
    stop = 0, 0;
  }})

let rec encode_s = function
  | Wire.Map s ->
    np @@
    if s = M.empty then
      OpamParserTypes.Ident "emptymap"
    else
      let data = np @@ M.fold (fun k v acc ->
          (np @@ OpamParserTypes.(List (np [ np @@ Ident k ; encode_s v ]))) :: acc)
          s []
      in
      OpamParserTypes.List data
  | Wire.List l -> np @@ OpamParserTypes.List (np @@ List.map encode_s l)
  | Wire.Identifier i -> np @@ OpamParserTypes.Ident i
  | Wire.Data s -> np @@ OpamParserTypes.String s
  | Wire.Bigint i -> np @@ OpamParserTypes.Ident ("0x" ^ Uint.to_string i)
  | Wire.Smallint i -> np @@ OpamParserTypes.Int i
  | Wire.Pair (i, s) -> np @@ OpamParserTypes.Group (np @@ [ encode_s i ; encode_s s ])
  | Wire.And (a, b) -> np @@ OpamParserTypes.Logop (np @@ `And, encode_s a, encode_s b)
  | Wire.Or (a, b) -> np @@ OpamParserTypes.Logop (np @@ `Or, encode_s a, encode_s b)

let encode t =
  let file_contents =
    M.fold (fun k v acc ->
        (np @@ OpamParserTypes.Variable (np @@ k, encode_s v)) :: acc)
      t []
  in
  let file = { OpamParserTypes.file_contents ; file_name = "" } in
  (* TODO use OpamPrinter.Preserved.items txt orig f here, requires  old data *)
  OpamPrinter.FullPos.format_opamfile Format.str_formatter file ;
  Format.flush_str_formatter ()

let rec decode_s s =
  match s.OpamParserTypes.pelem with
  | OpamParserTypes.Ident data ->
    if String.is_prefix ~prefix:"0x" data then
      match Uint.of_string (String.slice ~start:2 data) with
      | None -> Error "cannot parse unsigned integer"
      | Some x -> Ok (Wire.Bigint x)
    else if data = "emptymap" then
      Ok (Wire.Map M.empty)
    else
      Ok (Wire.Identifier data)
  | OpamParserTypes.String s -> Ok (Wire.Data (String.trim s))
  | OpamParserTypes.List { OpamParserTypes.pelem = []; _} -> Ok (Wire.List [])
  | OpamParserTypes.List { OpamParserTypes.pelem = l; _} ->
    let is_pair = function
      | { OpamParserTypes.pelem = OpamParserTypes.List { OpamParserTypes.pelem =
           [{ OpamParserTypes.pelem = OpamParserTypes.Ident _; _} ; _]; _}; _} -> true
      | _ -> false
    in
    if List.for_all is_pair l then begin
      List.fold_left (fun m xs ->
          m >>= fun m ->
          match xs.OpamParserTypes.pelem with
            OpamParserTypes.List { OpamParserTypes.pelem =
                [{ OpamParserTypes.pelem =  OpamParserTypes.Ident (k); _} ; v ]; _} ->
            (decode_s v >>= fun v -> Ok (M.add (String.trim k) v m))
          | _ -> Error "can not happen")
        (Ok M.empty) l >>= fun map ->
      Ok (Wire.Map map)
    end else
      List.fold_left (fun xs s ->
          xs >>= fun xs ->
          decode_s s >>= fun x ->
          Ok (x :: xs))
          (Ok []) l >>= fun xs ->
      Ok (Wire.List (List.rev xs))
  | OpamParserTypes.Int i -> Ok (Wire.Smallint i)
  | OpamParserTypes.Group { OpamParserTypes.pelem =
       [{ OpamParserTypes.pelem = OpamParserTypes.Logop (op, a, b); _}]; _} ->
    decode_s a >>= fun a ->
    decode_s b >>= fun b ->
    begin match op.OpamParserTypes.pelem with
      | `And -> Ok (Wire.And (a, b))
      | `Or -> Ok (Wire.Or (a, b))
    end
  | OpamParserTypes.Logop (op, a, b) ->
    decode_s a >>= fun a ->
    decode_s b >>= fun b ->
    begin match op.OpamParserTypes.pelem with
      | `And -> Ok (Wire.And (a, b))
      | `Or -> Ok (Wire.Or (a, b))
    end
  | OpamParserTypes.Group { OpamParserTypes.pelem = [a ; f]; _} ->
    decode_s a >>= fun a ->
    decode_s f >>= fun f ->
    Ok (Wire.Pair (a, f))
  | _ -> Error "unexpected thing while decoding"

let decode data =
  (try Ok (OpamParser.FullPos.string data "noname") with
     Parsing.Parse_error -> Error "parse error") >>= fun file ->
  let items = file.OpamParserTypes.file_contents in
  List.fold_left (fun acc v ->
      acc >>= fun acc ->
      match v.OpamParserTypes.pelem with
      | OpamParserTypes.Section _ -> Error "unexpected section"
      | OpamParserTypes.Variable (k, v) ->
        decode_s v >>= fun v ->
        Ok (M.add k.OpamParserTypes.pelem v acc))
    (Ok M.empty) items
