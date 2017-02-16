open Conex_utils
open Conex_resource

open Rresult

module V = Conex_nocrypto.NC_V
module C = Conex.Make(Logs)(V)
module SIGN = Conex_nocrypto.NC_S

let str_to_msg = function
  | Ok x -> Ok x
  | Error s -> Error (`Msg s)

let msg_to_cmdliner = function
  | Ok () -> `Ok ()
  | Error (`Msg m) -> `Error (false, m)

let now = match Uint.of_float (Unix.time ()) with
  | None -> invalid_arg "cannot convert now to unsigned integer"
  | Some x -> x

let setup_log style_renderer level =
  Fmt_tty.setup_std_outputs ?style_renderer ();
  Logs.set_level level;
  Logs.set_reporter (Logs_fmt.reporter ~dst:Format.std_formatter ())

let find_basedir_id path id =
  Conex_unix_private_key.find_ids () >>= fun ids ->
  match path, id, ids with
  | _, _, [] -> Error "no private key found, use init"
  | None, None, [id, basedir] -> Ok (id, basedir)
  | None, None, _ -> Error "multiple private keys found, use --repo/--id"
  | None, Some id, ids ->
    (match List.filter (fun (id', _) -> id_equal id id') ids with
     | [id, basedir] -> Ok (id, basedir)
     | [] -> Error "no private key found for repo and id"
     | _ -> Error "multiple private keys found")
  | Some p, id, ids ->
    let id = match id with None -> (fun _ -> true) | Some x -> (fun y -> id_equal x y) in
    match List.filter (fun (id', dir) -> String.compare p dir = 0 && id id') ids with
    | [id, basedir] -> Ok (id, basedir)
    | [] -> Error "no private key found for repo and id"
    | _ -> Error "multiple private keys found"

let init_repo ?quorum dry basedir =
  Conex_unix_provider.(if dry then fs_ro_provider basedir else fs_provider basedir) >>= fun io ->
  Ok (Conex_repository.repository ?quorum V.digest (), io)

let help _ _ _ _ man_format cmds = function
  | None -> `Help (`Pager, None)
  | Some t when List.mem t cmds -> `Help (man_format, Some t)
  | Some _ -> List.iter print_endline cmds; `Ok ()

let w pp a = Logs.warn (fun m -> m "%a" pp a)
let warn_e pp = R.ignore_error ~use:(w pp)

module IO = Conex_io

let verify _ path quorum strict id anchors =
  msg_to_cmdliner @@ str_to_msg
    (find_basedir_id path id >>= fun (_id, basedir) ->
     init_repo ?quorum true basedir >>= fun (r, io) ->
     Logs.info (fun m -> m "%a" Conex_io.pp io) ;
     let valid =
       let v = Conex_opts.convert_anchors anchors in
       if S.is_empty v then
         (Logs.info (fun m -> m "treating all on disk janitors as trusted") ;
          (fun _ _ -> true))
       else
         (fun _ (_, dg) -> S.mem dg v)
     in
     C.verify_janitors ~valid io r >>= fun r ->
     C.verify_ids io r >>= fun repo ->
     IO.packages io >>= fun packages ->
     foldS (C.verify_package strict io) repo packages >>= fun _ ->
     Ok ())

let to_st_txt ppf = function
  | Ok _ -> Fmt.(pf ppf "%a" (styled `Green string) "approved")
  | Error e -> Fmt.(pf ppf "%a" (styled `Red Conex_repository.pp_error) e)

let status _ path quorum id no_rec package =
  msg_to_cmdliner
    (str_to_msg
       (match path, id with
        | Some p, Some id -> Ok (p, id)
        | None, Some id ->
          (match find_basedir_id None None with
           | Ok (_, basedir) -> Ok (id, basedir)
           | Error e -> Error e)
        | Some p, None ->
          (match find_basedir_id None None with
           | Ok (id, _) -> Ok (id, p)
           | Error e -> Error e)
        | None, None -> find_basedir_id None None) >>= fun (id, basedir) ->
     str_to_msg (init_repo ?quorum true basedir) >>= fun (r, io) ->
     Logs.info (fun m -> m "%a" Conex_io.pp io) ;
     str_to_msg (C.verify_janitors ~valid:(fun _ _ -> true) io r) >>= fun r ->
     (match IO.read_id io id with
      | Ok (`Author idx) ->
        let r, style, txt = match C.verify_id io r id with
          | Ok r -> r, `Green, "verified"
          | Error e -> r, `Red, "verification error: " ^ e
        in
        Logs.app (fun m -> m "author %a %s (created %s) %a %d resources, %d queued"
                     Fmt.(styled `Bold pp_id) idx.Author.name
                     (Header.counter idx.Author.counter idx.Author.wraps)
                     (Header.timestamp idx.Author.created)
                     Fmt.(styled style string) txt
                     (List.length idx.Author.resources)
                     (List.length idx.Author.queued) ) ;
        List.iter (fun ((t, _, c) as key, _) ->
            let bits = match SIGN.bits key with
              | Error e -> Logs.err (fun m -> m "error while decoding key %s" e) ; 0
              | Ok bits -> bits
            in
            let kid = V.keyid id key in
            Logs.app (fun m -> m "%d bit %s key created %s %a, %a"
                         bits (Key.alg_to_string t) (Uint.decimal c)
                         to_st_txt (Conex_repository.validate_key r id key)
                         Digest.pp kid))
          idx.Author.keys ;
        List.iter (fun a ->
            Logs.app (fun m -> m "account %a %a"
                         Author.pp_account a
                         to_st_txt (Conex_repository.validate_account r idx a)))
          idx.Author.accounts ;
        List.iteri (fun i r -> Logs.app (fun m -> m "queue %d: %a@ " i Author.pp_r r))
          idx.Author.queued ;
        str_to_msg (IO.ids io) >>= fun ids ->
        let teams =
          S.fold (fun id' teams ->
              R.ignore_error
                ~use:(fun e -> w IO.pp_r_err e ; teams)
                (IO.read_id io id' >>| function
                  | `Team t when S.mem id t.Team.members -> t :: teams
                  | `Team _ | `Author _ -> teams))
            ids []
        in
        let me = List.fold_left
            (fun acc t -> if no_rec then acc else S.add t.Team.name acc)
            (S.singleton id) teams
        in
        let members = List.fold_left S.union S.empty (List.map (fun t -> t.Team.members) teams) in
        let r =
          S.fold (fun id repo ->
              R.ignore_error
                ~use:(fun e -> Logs.warn (fun m -> m "ignoring id %s error %s" id e) ; repo)
                (C.verify_id io repo id))
            members r
        in
        List.iter (fun t ->
            Logs.app (fun m -> m "team %a (%d members) %a"
                         Fmt.(styled `Bold pp_id) t.Team.name (S.cardinal t.Team.members)
                         to_st_txt (Conex_repository.validate_team r t)))
          teams ;
        Ok (r, me, teams)
      | Ok (`Team t) ->
        let r, mems =
          S.fold (fun id (repo, res) ->
              match C.verify_id io repo id with
              | Ok repo -> (repo, (id, Ok ()) :: res)
              | Error e -> (repo, (id, Error e) :: res))
            t.Team.members (r, [])
        in
        Logs.app (fun m -> m "team %a (%d members) %a"
                     Fmt.(styled `Bold pp_id) t.Team.name (S.cardinal t.Team.members)
                     to_st_txt (Conex_repository.validate_team r t)) ;
        List.iter (fun (id, res) ->
            let idx = match IO.read_author io id with
              | Ok idx -> idx | Error _ -> Author.t Uint.zero id
            in
            let pp ppf = function
              | Ok () -> Fmt.(pf ppf "%a" (styled `Green string) "approved")
              | Error e -> Fmt.(pf ppf "%a" (styled `Red string) e)
            in
            Logs.app (fun m -> m "member %a %a %d resources %d keys"
                         pp_id id pp res (List.length idx.Author.resources) (List.length idx.Author.keys)))
          mems ;
        Ok (r, S.singleton id, [t])
      | Error e ->
        Logs.err (fun m -> m "couldn't read id %s: %a" id Conex_io.pp_r_err e) ;
        Ok (r, S.singleton id, [])) >>= fun (r, me, teams) ->
     (* load all ids (well, all team members!) *)
     let r = List.fold_left Conex_repository.add_team r teams in
     (* find_all_packages and print info about our ones (filtered by name) *)
     str_to_msg (IO.packages io) >>= fun packages ->
     let packages, _release =
       let prefix, rel =
         match Conex_opam_repository_layout.authorisation_of_package package with
         | None -> package, (fun _ -> true)
         | Some pn -> pn, (fun name -> name_equal name package)
       in
       S.filter (String.is_prefix ~prefix) packages, rel
     in
     let _repo =
       S.fold (fun name r ->
           match IO.read_authorisation io name with
           | Error _ -> Logs.err (fun m -> m "missing authorisation for %a" pp_name name) ; r
           | Ok auth when S.cardinal (S.inter auth.Authorisation.authorised me) = 0 ->
             r
           | Ok auth ->
             let r = match C.verify_ids ~ids:auth.Authorisation.authorised io r with
               | Error _ -> r
               | Ok r -> r
             in
             let on_disk = match IO.compute_package io Uint.zero name with
               | Ok od -> Some od
               | Error e -> Logs.err (fun m -> m "couldn't compute package %s: %s" name e) ; None
             in
             (match IO.read_package io name with
              | Error e ->
                Logs.app (fun m -> m "package %a authorisation %a"
                             pp_name name
                             to_st_txt (Conex_repository.validate_authorisation r auth)) ;
                Logs.err (fun m -> m "%a" IO.pp_r_err e)
               | Ok pkg ->
                 Logs.app (fun m -> m "package %a authorisation %a package index %a"
                              pp_name name
                              to_st_txt (Conex_repository.validate_authorisation r auth)
                              to_st_txt (Conex_repository.validate_package r ?on_disk auth pkg)) ;
                 (* now all the releases *)
                 (match on_disk with
                  | None -> Logs.app (fun m -> m "no releases")
                  | Some pkg ->
                    S.iter (fun release -> match IO.read_release io release with
                        | Error e -> Logs.err (fun m -> m "couldn't read release %s: %a" release IO.pp_r_err e)
                        | Ok rel ->
                          let on_disk =
                            match IO.compute_release V.raw_digest io Uint.zero release with
                            | Ok rel -> Some rel
                            | Error e -> Logs.err (fun m -> m "couldn't compute release %s: %a" release IO.pp_cc_err e) ; None
                          in
                          Logs.app (fun m -> m "release %s: %a" release to_st_txt
                                       (Conex_repository.validate_release r ?on_disk auth pkg rel)))
                      pkg.Package.releases));
             r)
         packages r
     in
     Ok ())

let add_r idx name typ data =
  let counter = Author.next_id idx in
  let digest = V.digest data in
  let res = Author.r counter name typ digest in
  Logs.info (fun m -> m "added %a to change queue" Author.pp_r res) ;
  Author.add_resource idx res

let init _ dry path id email =
  msg_to_cmdliner
    (match id, path with
     | None, _ -> Error (`Msg "please provide '--id'")
     | _, None -> Error (`Msg "please provide '--repo'")
     | Some id, Some path ->
       Nocrypto_entropy_unix.initialize () ;
       str_to_msg (init_repo ~quorum:0 dry path) >>= fun (_, io) ->
       Logs.info (fun m -> m "%a" Conex_io.pp io) ;
       (match IO.read_id io id with
        | Ok (`Team _) -> Error (`Msg ("team " ^ id ^ " exists"))
        | Ok (`Author idx) when List.length idx.Author.keys > 0 ->
          Error (`Msg ("key " ^ id ^ " exists and includes a public key"))
        | Ok (`Author k) ->
          Logs.info (fun m -> m "adding keys to %a" Author.pp k) ;
          Ok k
        | Error err ->
          Logs.info (fun m -> m "error reading author %s %a, creating a fresh one"
                         id Conex_io.pp_r_err err) ;
          Ok (Author.t now id)) >>= fun idx ->
       (match Conex_unix_private_key.read io id with
        | Ok priv ->
          let created = match priv with `Priv (_, _, c) -> c in
          Logs.info (fun m -> m "using existing private key %s (created %s)" id (Header.timestamp created)) ;
          Ok priv
        | Error _ ->
          let p = SIGN.generate now () in
          (if dry then
             str_to_msg (Conex_unix_private_key.write io id p) >>| fun () ->
             Logs.info (fun m -> m "generated and wrote private key %s" id) ;
           else
             Ok ()) >>| fun () ->
          p) >>= fun priv ->
       str_to_msg (SIGN.pub_of_priv priv) >>= fun public ->
       let accounts =
         List.sort_uniq Author.compare_account
           (`GitHub id :: List.map (fun e -> `Email e) email @ idx.Author.accounts)
       and counter = idx.Author.counter
       and wraps = idx.Author.wraps
       and queued = idx.Author.queued
       and resources = idx.Author.resources
       and created = idx.Author.created
       in
       let idx = Author.t ~accounts ~counter ~wraps ~resources ~queued created id in
       let idx = add_r idx id `Key (Key.wire id public) in
       let idx =
         List.fold_left (fun idx a -> add_r idx id `Account (Author.wire_account id a))
           idx accounts
       in
       str_to_msg (SIGN.sign now idx priv) >>= fun idx ->
       str_to_msg (IO.write_author io idx) >>= fun () ->
       Logs.info (fun m -> m "wrote %a" Author.pp idx) ;
       R.error_to_msg ~pp_error:Conex_crypto.pp_verification_error (V.verify idx) >>| fun () ->
       Logs.app (fun m -> m "Created keypair.  Please 'git add id/%s', and submit a PR.  Join teams and claim your packages." id))

let find_idx io name =
  let use e =
    w IO.pp_r_err e ;
    let idx = Author.t now name in
    Logs.info (fun m -> m "fresh %a" Author.pp idx) ;
    idx
  in
  R.ignore_error ~use
    (IO.read_author io name >>| fun idx ->
     Logs.debug (fun m -> m "read %a" Author.pp idx) ;
     idx)

let sign _ dry path id =
  msg_to_cmdliner
    (str_to_msg (find_basedir_id path id) >>= fun (id, basedir) ->
     str_to_msg (init_repo dry basedir) >>= fun (_r, io) ->
     R.error_to_msg ~pp_error:Conex_unix_private_key.pp_err
       (Conex_unix_private_key.read io id) >>= fun priv ->
     Logs.info (fun m -> m "using private key %s" id) ;
     let idx = find_idx io id in
     match idx.Author.queued with
     | [] -> Logs.app (fun m -> m "nothing changed") ; Ok ()
     | els ->
       List.iter (fun r ->
           Logs.app (fun m -> m "adding %a" Author.pp_r r))
         els ;
       (* XXX: PROMPT HERE *)
       Nocrypto_entropy_unix.initialize () ;
       str_to_msg (SIGN.sign now idx priv) >>= fun idx ->
       Logs.info (fun m -> m "signed author %a" Author.pp idx) ;
       str_to_msg (IO.write_author io idx) >>| fun () ->
       Logs.app (fun m -> m "wrote %s to disk" id))

let reset _ dry path id =
  msg_to_cmdliner
    (str_to_msg (find_basedir_id path id) >>= fun (id, basedir) ->
     str_to_msg (init_repo dry basedir) >>= fun (_r, io) ->
     let idx = find_idx io id in
     match idx.Author.queued with
     | [] -> Logs.app (fun m -> m "nothing changed") ; Ok ()
     | qs ->
       List.iter
         (fun r -> Logs.app (fun m -> m "dropping %a" Author.pp_r r))
         qs ;
       let idx = Author.reset idx in
       str_to_msg (IO.write_author io idx) >>| fun () ->
       Logs.app (fun m -> m "wrote %s to disk" id))

let find_auth io name =
  let use e =
    w IO.pp_r_err e ;
    let a = Authorisation.t now name in
    Logs.info (fun m -> m "fresh %a" Authorisation.pp a);
    a
  in
  R.ignore_error ~use
    (IO.read_authorisation io name >>| fun a ->
     Logs.debug (fun m -> m "read %a" Authorisation.pp a);
     a)

let auth _ dry path id remove members p =
  msg_to_cmdliner
    (if p = "" then Error (`Msg "missing package argument") else
     str_to_msg (find_basedir_id path id) >>= fun (id, basedir) ->
     str_to_msg (init_repo dry basedir) >>= fun (r, io) ->
     let auth = find_auth io p in
     let f = if remove then Authorisation.remove else Authorisation.add in
     let auth' = List.fold_left f auth members in
     let idx = find_idx io id in
     if not (Authorisation.equal auth auth') then begin
       let auth, overflow = Authorisation.prep auth' in
       if overflow then
         Logs.warn (fun m -> m "counter overflow in authorisation %s, needs approval" p) ;
       str_to_msg (IO.write_authorisation io auth) >>= fun () ->
       Logs.info (fun m -> m "wrote %a" Authorisation.pp auth) ;
       let idx = add_r idx p `Authorisation (Authorisation.wire auth) in
       str_to_msg (IO.write_author io idx) >>| fun () ->
       Logs.app (fun m -> m "modified authorisation and added resource to your list.")
     end else if not (Conex_repository.contains ~queued:true r idx p `Authorisation (Authorisation.wire auth)) then begin
       let idx = add_r idx p `Authorisation (Authorisation.wire auth) in
       str_to_msg (IO.write_author io idx) >>| fun () ->
       Logs.app (fun m -> m "added resource to your list.")
     end else begin
       Logs.app (fun m -> m "nothing changed.") ;
       Ok ()
     end)

let release _ dry path id remove p =
  msg_to_cmdliner
    (if p = "" then Error (`Msg "missing package argument") else
     str_to_msg (find_basedir_id path id) >>= fun (id, basedir) ->
     str_to_msg (init_repo dry basedir) >>= fun (r, io) ->
     (match Conex_opam_repository_layout.authorisation_of_package p with
      | Some n -> Ok (n, S.singleton p)
      | None -> str_to_msg (IO.releases io p) >>= fun rels -> Ok (p, rels))
     >>= fun (pn, releases) ->
     let auth = find_auth io pn in
     (* need to load team information *)
     let r =
       S.fold (fun id repo ->
           match IO.read_id io id with
           | Ok (`Author _) -> repo
           | Ok (`Team t) -> Conex_repository.add_team repo t
           | Error _ -> repo)
         auth.Authorisation.authorised r
     in
     if not (Conex_repository.authorised r auth id) then
       Logs.warn (fun m -> m "not authorised to modify package %s, PR will require approval" p) ;
     let rel =
       let use e =
         w IO.pp_r_err e ;
         Package.t now pn
       in
       R.ignore_error ~use
         (IO.read_package io pn >>| fun rel ->
          Logs.debug (fun m -> m "read %a" Package.pp rel) ;
          rel)
     in
     let f m t = if remove then Package.remove t m else Package.add t m in
     let rel' = S.fold f releases rel in
     let idx = find_idx io id in
     (if not (Package.equal rel rel') then begin
        let rel, overflow = Package.prep rel' in
        if overflow then
          Logs.warn (fun m -> m "counter overflow in releases %s, needs approval" pn) ;
        str_to_msg (IO.write_package io rel) >>| fun () ->
        Logs.info (fun m -> m "wrote %a" Package.pp rel) ;
        add_r idx pn `Package (Package.wire rel)
       end else if not (Conex_repository.contains ~queued:true r idx pn `Package (Package.wire rel')) then begin
        Ok (add_r idx pn `Package (Package.wire rel))
       end else Ok idx) >>= fun idx' ->
     let add_cs name acc =
       acc >>= fun idx ->
       let cs =
         let use e =
           w IO.pp_r_err e ;
           let c = Release.t now name [] in
           Logs.info (fun m -> m "fresh %a" Release.pp c);
           c
         in
         R.ignore_error ~use
           (IO.read_release io name >>| fun cs ->
            Logs.debug (fun m -> m "read %a" Release.pp cs) ;
            cs)
       in
       R.error_to_msg ~pp_error:IO.pp_cc_err
         (IO.compute_release V.raw_digest io now name) >>= fun cs' ->
       if not (Release.equal cs cs') then
         let cs' = Release.set_counter cs' cs'.Release.counter in
         let cs', overflow = Release.prep cs' in
         if overflow then Logs.warn (fun m -> m "counter overflow in checksum %s, needs approval" name) ;
         str_to_msg (IO.write_release io cs') >>| fun () ->
         Logs.info (fun m -> m "wrote %a" Release.pp cs') ;
         add_r idx name `Release (Release.wire cs')
       else if not (Conex_repository.contains ~queued:true r idx name `Release (Release.wire cs)) then
         Ok (add_r idx name `Release (Release.wire cs))
       else
         Ok idx
     in
     (if not remove then S.fold add_cs releases (Ok idx') else Ok idx') >>= fun idx' ->
     if not (Author.equal idx idx') then begin
       str_to_msg (IO.write_author io idx') >>| fun () ->
       Logs.info (fun m -> m "wrote %a" Author.pp idx') ;
       Logs.app (fun m -> m "released and added resources to your resource list.")
     end else
       Ok (Logs.app (fun m -> m "nothing happened")))

let team _ dry path id remove members tid =
  msg_to_cmdliner
    (if tid = "" then Error (`Msg "missing team argument") else
     str_to_msg (find_basedir_id path id) >>= fun (id, basedir) ->
     str_to_msg (init_repo dry basedir) >>= fun (r, io) ->
     let team =
       let use e =
         w IO.pp_r_err e ;
         let team = Team.t now tid in
         Logs.info (fun m -> m "fresh %a" Team.pp team) ;
         team
       in
       R.ignore_error ~use
         (IO.read_team io tid >>| fun team ->
          Logs.debug (fun m -> m "read %a" Team.pp team) ;
          team)
     in
     let f = if remove then Team.remove else Team.add in
     let team' = List.fold_left f team members in
     let idx = find_idx io id in
     if not (Team.equal team team') then begin
       let team, overflow = Team.prep team' in
       if overflow then
         Logs.warn (fun m -> m "counter overflow in team %s, needs approval" tid) ;
       str_to_msg (IO.write_team io team) >>= fun () ->
       Logs.info (fun m -> m "wrote %a" Team.pp team) ;
       let idx = add_r idx tid `Team (Team.wire team) in
       str_to_msg (IO.write_author io idx) >>| fun () ->
       Logs.app (fun m -> m "modified team and added resource to your resource list.")
     end else if not (Conex_repository.contains ~queued:true r idx tid `Team (Team.wire team)) then begin
       let idx = add_r idx tid `Team (Team.wire team) in
       str_to_msg (IO.write_author io idx) >>| fun () ->
       Logs.app (fun m -> m "added resource to your resource list.")
     end else begin
       Logs.app (fun m -> m "nothing changed.") ;
       Ok ()
     end)


open Cmdliner

let docs = Conex_opts.docs

let setup_log =
  Term.(const setup_log
        $ Fmt_cli.style_renderer ~docs ()
        $ Logs_cli.level ~docs ())

let help_secs = [
 `S "GENERAL";
 `P "Conex is a tool suite to manage and verify cryptographically signed data repositories.";
 `S "KEYS";
 `P "Public keys contain a unique identifier.  They are distributed with the repository itself.";
 `P "Your private keys are stored PEM-encoded in ~/.conex.  You can select which key to use by passing --id to conex.";
 `S "PACKAGE";
 `P "A package is an opam package, and can either be the package name or the package name and version number.";
 `S docs;
 `P "These options are common to all commands.";
 `S "SEE ALSO";
 `P "Use `$(mname) $(i,COMMAND) --help' for help on a single command.";
 `S "BUGS"; `P "Check bug reports at https://github.com/hannesm/conex.";]

let team_a =
  let doc = "Team" in
  Arg.(value & pos 0 Conex_opts.id_c "" & info [] ~docv:"TEAM" ~doc)

let noteam =
  let doc = "Do not transitively use teams" in
  Arg.(value & flag & info ["noteam"] ~docs ~doc)

let status_cmd =
  let doc = "information about yourself" in
  let man =
    [`S "DESCRIPTION";
     `P "Shows information about yourself."]
  in
  Term.(ret Conex_opts.(const status $ setup_log $ repo $ quorum $ id $ noteam $ package)),
  Term.info "status" ~doc ~man

let verify_cmd =
  let doc = "verification" in
  let man =
    [`S "DESCRIPTION";
     `P "Shows verification status."]
  in
  Term.(ret Conex_opts.(const verify $ setup_log $ repo $ quorum $ strict $ id $ anchors)),
  Term.info "verify" ~doc ~man

let authorisation_cmd =
  let doc = "modify authorisation of a package" in
  let man =
    [`S "DESCRIPTION";
     `P "Modifies authorisaton of a package."]
  in
  Term.(ret Conex_opts.(const auth $ setup_log $ dry $ repo $ id $ remove $ members $ package)),
  Term.info "authorisation" ~doc ~man

let release_cmd =
  let doc = "modify releases of a package" in
  let man =
    [`S "DESCRIPTION";
     `P "Modifies releases of a package."]
  in
  Term.(ret Conex_opts.(const release $ setup_log $ dry $ repo $ id $ remove $ package)),
  Term.info "release" ~doc ~man

let team_cmd =
  let doc = "modify members of a team" in
  let man =
    [`S "DESCRIPTION";
     `P "Modifies members of a team."]
  in
  Term.(ret Conex_opts.(const team $ setup_log $ dry $ repo $ id $ remove $ members $ team_a)),
  Term.info "team" ~doc ~man

let reset_cmd =
  let doc = "reset staged changes" in
  let man =
    [`S "DESCRIPTION";
     `P "Resets queued changes of your resource list."]
  in
  Term.(ret Conex_opts.(const reset $ setup_log $ dry $ repo $ id)),
  Term.info "reset" ~doc ~man

let sign_cmd =
  let doc = "sign staged changes" in
  let man =
    [`S "DESCRIPTION";
     `P "Cryptographically signs queued changes to your resource list."]
  in
  Term.(ret Conex_opts.(const sign $ setup_log $ dry $ repo $ id)),
  Term.info "sign" ~doc ~man

let init_cmd =
  let emails =
    let doc = "Pass set of email addresses" in
    Arg.(value & opt_all string [] & info ["email"] ~docs ~doc)
  in
  let doc = "initialise" in
  let man =
    [`S "DESCRIPTION";
     `P "Generates a private key and conex key entry."]
  in
  Term.(ret Conex_opts.(const init $ setup_log $ dry $ repo $ id $ emails)),
  Term.info "init" ~doc ~man

let help_cmd =
  let topic =
    let doc = "The topic to get help on. `topics' lists the topics." in
    Arg.(value & pos 0 (some string) None & info [] ~docv:"TOPIC" ~doc)
  in
  let doc = "display help about conex_author" in
  let man =
    [`S "DESCRIPTION";
     `P "Prints help about conex commands and subcommands"] @ help_secs
  in
  Term.(ret Conex_opts.(const help $ setup_log $ dry $ repo $ id $ Term.man_format $ Term.choice_names $ topic)),
  Term.info "help" ~doc ~man

let default_cmd =
  let doc = "cryptographically sign your released packages" in
  let man = help_secs in
  Term.(ret Conex_opts.(const help $ setup_log $ dry $ repo $ id $ Term.man_format $ Term.choice_names $ Term.pure None)),
  Term.info "conex_author" ~version:"%%VERSION_NUM%%" ~sdocs:docs ~doc ~man

let cmds = [ help_cmd ; status_cmd ;
             init_cmd ; sign_cmd ; reset_cmd ;
             verify_cmd ;
             authorisation_cmd ; team_cmd ; release_cmd ]

let () =
  match Term.eval_choice default_cmd cmds
  with `Ok () -> exit 0 | _ -> exit 1
