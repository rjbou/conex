open Core

module S = Set.Make(String)

let apply_diff provider diff =
  let read path =
    if Diff.file diff = path_to_string path then
      match provider.Provider.read path with
      | Ok data -> Ok (Diff.apply (Some data) diff)
      | Error _ -> Ok (Diff.apply None diff)
    else
      provider.Provider.read path
  and file_type path =
    let pn = path_to_string path
    and name = Diff.file diff
    in
    if pn = name then
      Ok File
    else if Strhelper.is_prefix ~prefix:(pn ^ "/") name then
      Ok Directory
    else
      provider.Provider.file_type path
  and read_dir path =
    let name = List.rev (string_to_path (Diff.file diff))
    and path = List.rev path
    in
    (* XXX: unlikely to be correct... *)
    let data = match name with
      | fn::xs when xs = path -> Some (`File fn)
      | _ -> None
    in
    match provider.Provider.read_dir path, data with
      | Ok files, Some data -> Ok (data :: files)
      | Ok files, None -> Ok files
      | Error _, Some data -> Ok [data]
      | Error e, None -> Error e
  and write _ = invalid_arg "cannot write on a diff provider, is read-only!"
  and exists path =
    let pn = path_to_string path
    and name = Diff.file diff
    in
    if pn = name then
      true
    else
      provider.Provider.exists path
  and name = provider.Provider.name
  and description = "Patch provider"
  in
  { Provider.name ; description ; file_type ; read ; write ; read_dir ; exists }

let apply repo diff =
  let provider = Repository.provider repo in
  let new_provider = apply_diff provider diff in
  Repository.change_provider repo new_provider

type component =
  | Idx of identifier * Diff.diff
  | Id of identifier * Diff.diff
  | Authorisation of name * Diff.diff
  | Dir of name * name * Diff.diff list

let categorise diff =
  let p = string_to_path (Diff.file diff) in
  match Layout.(is_index p, is_key p, is_authorisation p, is_item p) with
  | Some id, None, None, None ->
    Printf.printf "found an index in diff %s\n" id;
    Idx (id, diff)
  | None, Some id, None, None ->
    Printf.printf "found an id in diff %s\n" id;
    Id (id, diff)
  | None, None, Some id, None ->
    Printf.printf "found an authorisation in diff %s\n" id;
    Authorisation (id, diff)
  | None, None, None, Some (d, p) ->
    Printf.printf "found a dir in diff %s %s\n" d p;
    Dir (d, p, [ diff ])
  | _ -> invalid_arg ("couldn't categorise " ^ (path_to_string p))

let diffs_to_components diffs =
  let pdir p v =
    function Dir (p', v', _) when p = p' && v = v' -> true | _ -> false
  in
  List.fold_left (fun acc diff ->
      match categorise diff with
      | Dir (p, v, d) as ele ->
        (match List.partition (pdir p v) acc with
         | [Dir (_, _, ds)], others -> Dir (p, v, d @ ds) :: others
         | [], others -> ele :: others
         | _, _ -> invalid_arg "unexpected thing here")
     | x -> x :: acc)
    [] diffs

(* verification goes repo -> update -> (repo, err) result *)
(*  what needs to be verified?
  - new key: idx exists?
  - deletion of key: idx gone?
*)
let verify repo _c = Ok repo (* = function
  | Idx (id, diff) ->
    let repo' = apply repo diff in
    begin match
        Repository.read_index repo id,
        Repository.read_index repo' id
      with
      | Ok idx, Ok idx' ->
        guard (idx.Index.counter < idx'.Index.counter) `CounterNotIncreased >>= fun () ->
        Repository.verify_index repo idx' >>= fun _ ->
        Ok (Repository.add_index repo' idx')
      | Error _, Ok idx' ->
        guard (idx'.Index.counter = 0L) `CounterNotZero >>= fun () ->
        guard (Layout.valid_keyid id) `InvalidId >>= fun () ->
        guard (Layout.unique_keyid (Repository.all_ids repo) id) `InvalidId >>= fun () ->
        Repository.verify_index repo idx' >>= fun _ ->
        Ok (Repository.add_index repo' idx')
      | _, Error e -> Error e
    end

  | Id (id, diff) ->
    let repo' = apply repo diff in
    begin match
        Repository.read_id repo id,
        Repository.read_id repo' id
      with
      | Ok (`Key k), Ok (`Key k') ->
        guard (k.Publickey.counter < k'.Publickey.counter) `CounterNotIncreased >>= fun () ->
        Repository.verify_key repo k' >>= fun _ ->
        Ok (Repository.add_key repo' k')
      | Error _, Ok (`Key k') ->
        guard (k'.Publickey.counter = 0L) `CounterNotZero >>= fun () ->
        guard (Layout.valid_keyid id) `InvalidId >>= fun () ->
        guard (Layout.unique_keyid (Repository.all_ids repo) id) `InvalidId >>= fun () ->
        Repository.verify_key repo k' >>= fun _ ->
        Ok (Repository.add_key repo' k')
      | Ok (`Team t), Ok (`Team t') ->
        guard (t.Team.counter < t'.Team.counter) `CounterNotIncreased >>= fun () ->
        Repository.verify_team repo t' >>= fun _ ->
        Ok (Repository.add_team repo' t')
      | Error _, Ok (`Team t') ->
        guard (t'.Team.counter = 0L) `CounterNotZero >>= fun () ->
        guard (Layout.valid_keyid id) `InvalidId >>= fun () ->
        guard (Layout.unique_keyid (Repository.all_ids repo) id) `InvalidId >>= fun () ->
        Repository.verify_team repo t' >>= fun _ ->
        Ok (Repository.add_team repo' t')
      | _, Error e -> Error e
      | _ -> Error `InvalidKeyTeam (* disallow team to key and vice versa *)
    end


  | Authorisation (name, diff) ->
    let repo' = apply repo diff in
    begin match
        Repository.read_authorisation repo name,
        Repository.read_authorisation repo' name
      with
      | Ok a, Ok a' ->
        guard (a.Authorisation.counter < a'.Authorisation.counter) `CounterNotIncreased >>= fun () ->
        Repository.verify_authorisation repo a' >>= fun _ ->
        Ok repo'
      | Error _, Ok a' ->
        guard (a'.Authorisation.counter = 0L) `CounterNotZero >>= fun () ->
        guard (Layout.valid_name name) `InvalidName >>= fun () ->
        guard (Layout.unique_data (Repository,all_authorisations repo) name) `InvalidName >>= fun () ->
        Repository.verify_authorisation repo a' >>= fun _ ->
        Ok repo'
      | _, Error e -> Error e
    end

  | Dir (p, v, diffs) ->
    let repo' = List.fold_left apply repo diffs in
    let cs_ok a r = match
        Repository.read_checksum repo v,
        Repository.read_checksum repo' v
      with
      | Ok cs, Ok cs' ->
        guard (cs.Checksum.counter < cs'.Checksum.counter) `CounterNotIncreased >>= fun () ->
        Repository.verify_checksum repo' a r cs' >>= fun _ ->
        Ok repo'
      | Error _, Ok cs' ->
        guard (cs'.Checksum.counter = 0L) `CounterNotZero >>= fun () ->
        Repository.verify_checksum repo' a r cs' >>= fun _ ->
        Ok repo'
      | Ok _, Error _ -> Ok repo'
    in
    begin match
        Repository.read_authorisation repo p,
        Repository.read_releases repo p,
        Repository.read_releases repo' p
      with
      | Ok a, Ok r, Ok r' ->
        guard (r.Releases.counter < r'.Releases.counter) `CounterNotIncreased >>= fun () ->
        Repository.verify_releases repo' a r' >>= fun _ ->
        cs_ok a r'
      | Ok a, Error _, Ok r' ->
        guard (r'.Releases.counter = 0L) `CounterNotZero >>= fun () ->
        Repository.verify_releases repo' a r' >>= fun _ ->
        cs_ok a r'
      | Error _, _, _ -> Error (`MissingAuthorisation p)
      | Ok _, _, Error e -> Error e
    end
    *)

let verify_patch repo patch =
  List.fold_left
    (fun res p -> match res with Ok r -> verify r p | Error e -> Error e)
    (Ok repo)
    (* TODO: compare (first key + index (in which sequence?), then authorisations, then dirs) *)
    (List.sort compare patch)

let verify_diff repo data =
  let diffs = Diff.to_diffs data in
  let comp = diffs_to_components diffs in
  verify_patch repo comp

