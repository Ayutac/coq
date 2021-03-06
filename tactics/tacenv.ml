(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2012     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

open Util
open Genarg
open Pp
open Names
open Tacexpr

(** Tactic notations (TacAlias) *)

type alias = KerName.t

let alias_map = Summary.ref ~name:"tactic-alias"
  (KNmap.empty : glob_tactic_expr KNmap.t)

let register_alias key tac =
  alias_map := KNmap.add key tac !alias_map

let interp_alias key =
  try KNmap.find key !alias_map
  with Not_found -> Errors.anomaly (str "Unknown tactic alias: " ++ KerName.print key)

(** ML tactic extensions (TacML) *)

type ml_tactic =
  typed_generic_argument list -> Geninterp.interp_sign -> unit Proofview.tactic

module MLName =
struct
  type t = ml_tactic_name
  let compare tac1 tac2 =
    let c = String.compare tac1.mltac_tactic tac2.mltac_tactic in
    if c = 0 then String.compare tac1.mltac_plugin tac2.mltac_plugin
    else c
end

module MLTacMap = Map.Make(MLName)

let pr_tacname t =
  t.mltac_plugin ^ "::" ^ t.mltac_tactic

let tac_tab = ref MLTacMap.empty

let register_ml_tactic ?(overwrite = false) s (t : ml_tactic) =
  let () =
    if MLTacMap.mem s !tac_tab then
      if overwrite then
        let () = tac_tab := MLTacMap.remove s !tac_tab in
        msg_warning (str ("Overwriting definition of tactic " ^ pr_tacname s))
      else
        Errors.anomaly (str ("Cannot redeclare tactic " ^ pr_tacname s ^ "."))
  in
  tac_tab := MLTacMap.add s t !tac_tab

let interp_ml_tactic s =
  try
    MLTacMap.find s !tac_tab
  with Not_found ->
    Errors.errorlabstrm ""
      (str "The tactic " ++ str (pr_tacname s) ++ str " is not installed.")

let () =
  let assert_installed opn = let _ = interp_ml_tactic opn in () in
  Hook.set Tacintern.assert_tactic_installed_hook assert_installed

(** Coq tactic definitions. *)

(* Table of "pervasives" macros tactics (e.g. auto, simpl, etc.) *)


let initial_atomic =
  let open Locus in
  let open Misctypes in
  let open Genredexpr in
  let dloc = Loc.ghost in
  let nocl = {onhyps=Some[];concl_occs=AllOccurrences} in
  let fold accu (s, t) =
    let body = TacAtom (dloc, t) in
    Id.Map.add (Id.of_string s) body accu
  in
  let ans = List.fold_left fold Id.Map.empty
      [ "red", TacReduce(Red false,nocl);
        "hnf", TacReduce(Hnf,nocl);
        "simpl", TacReduce(Simpl None,nocl);
        "compute", TacReduce(Cbv Redops.all_flags,nocl);
        "intro", TacIntroMove(None,MoveLast);
        "intros", TacIntroPattern [];
        "cofix", TacCofix None;
        "trivial", TacTrivial (Off,[],None);
        "auto", TacAuto(Off,None,[],None);
      ]
  in
  let fold accu (s, t) = Id.Map.add (Id.of_string s) t accu in
  List.fold_left fold ans
      [ "idtac",TacId [];
        "fail", TacFail(ArgArg 0,[]);
        "fresh", TacArg(dloc,TacFreshId [])
      ]

let atomic_mactab = Summary.ref ~name:"atomic_tactics" initial_atomic

let register_atomic_ltac id tac =
  atomic_mactab := Id.Map.add id tac !atomic_mactab

let interp_atomic_ltac id = Id.Map.find id !atomic_mactab

let is_primitive_ltac_ident id =
  try
    match Pcoq.parse_string Pcoq.Tactic.tactic id with
     | Tacexpr.TacArg _ -> false
     | _ -> true (* most probably TacAtom, i.e. a primitive tactic ident *)
  with e when Errors.noncritical e -> true (* prim tactics with args, e.g. "apply" *)

let is_atomic_kn kn =
  let (_,_,l) = repr_kn kn in
  (Id.Map.mem (Label.to_id l) !atomic_mactab)
  || (is_primitive_ltac_ident (Label.to_string l))

(***************************************************************************)
(* Tactic registration *)

(* Summary and Object declaration *)

open Nametab
open Libnames
open Libobject

let mactab =
  Summary.ref (KNmap.empty : glob_tactic_expr KNmap.t)
    ~name:"tactic-definition"

let interp_ltac r = KNmap.find r !mactab

(* Declaration of the TAC-DEFINITION object *)
let add (kn,td) = mactab := KNmap.add kn td !mactab
let replace (kn,td) = mactab := KNmap.add kn td !mactab

type tacdef_kind =
  | NewTac of Id.t
  | UpdateTac of Nametab.ltac_constant

let load_md i ((sp,kn),(local,defs)) =
  let dp,_ = repr_path sp in
  let mp,dir,_ = repr_kn kn in
  let (id, t) = defs in
    match id with
      | NewTac id ->
          let sp = make_path dp id in
          let kn = Names.make_kn mp dir (Label.of_id id) in
            Nametab.push_tactic (Until i) sp kn;
            add (kn,t)
      | UpdateTac kn -> replace (kn,t)

let open_md i ((sp,kn),(local,defs)) =
  let dp,_ = repr_path sp in
  let mp,dir,_ = repr_kn kn in
  let (id, t) = defs in
    match id with
        NewTac id ->
          let sp = make_path dp id in
          let kn = Names.make_kn mp dir (Label.of_id id) in
            Nametab.push_tactic (Exactly i) sp kn
      | UpdateTac kn -> ()

let cache_md x = load_md 1 x

let subst_kind subst id =
  match id with
    | NewTac _ -> id
    | UpdateTac kn -> UpdateTac (Mod_subst.subst_kn subst kn)

let subst_md (subst,(local,defs)) =
  (local,
   let (id, t) = defs in
     (subst_kind subst id,Tacsubst.subst_tactic subst t))

let classify_md (local,defs as o) =
  if local then Dispose else Substitute o

let inMD : bool * (tacdef_kind * glob_tactic_expr) -> obj =
  declare_object {(default_object "TAC-DEFINITION") with
     cache_function  = cache_md;
     load_function   = load_md;
     open_function   = open_md;
     subst_function = subst_md;
     classify_function = classify_md}

(* Adds a definition for tactics in the table *)
let make_absolute_name ident repl =
  let loc = loc_of_reference ident in
  if repl then
    let kn =
      try Nametab.locate_tactic (snd (qualid_of_reference ident))
      with Not_found ->
        Errors.user_err_loc (loc, "",
                    str "There is no Ltac named " ++ pr_reference ident ++ str ".")
    in
    UpdateTac kn
  else
    let id = Constrexpr_ops.coerce_reference_to_id ident in
    let kn = Lib.make_kn id in
    let () = if KNmap.mem kn !mactab then
      Errors.user_err_loc (loc, "",
        str "There is already an Ltac named " ++ pr_reference ident ++ str".")
    in
    let () = if is_atomic_kn kn then
      msg_warning (str "The Ltac name " ++ pr_reference ident ++
        str " may be unusable because of a conflict with a notation.")
    in
    NewTac id

let register_ltac local isrec tacl =
  let map (ident, local, body) =
    let name = make_absolute_name ident local in
    (name, body)
  in
  let rfun = List.map map tacl in
  let ltacrecvars =
    let fold accu (op, _) = match op with
    | UpdateTac _ -> accu
    | NewTac id -> Id.Map.add id (Lib.make_kn id) accu
    in
    if isrec then List.fold_left fold Id.Map.empty rfun
    else Id.Map.empty
  in
  let ist = { (Tacintern.make_empty_glob_sign ()) with Genintern.ltacrecvars; } in
  let map (name, body) =
    let body = Flags.with_option Tacintern.strict_check (Tacintern.intern_tactic_or_tacarg ist) body in
    (name, body)
  in
  let defs = List.map map rfun in
  let iter def = match def with
  | NewTac id, _ ->
    let _ = Lib.add_leaf id (inMD (local, def)) in
    Flags.if_verbose msg_info (Nameops.pr_id id ++ str " is defined")
  | UpdateTac kn, _ ->
    let _ = Lib.add_anonymous_leaf (inMD (local, def)) in
    let name = Nametab.shortest_qualid_of_tactic kn in
    Flags.if_verbose msg_info (Libnames.pr_qualid name ++ str " is redefined")
  in
  List.iter iter defs

let () =
  Hook.set Tacintern.interp_ltac_hook interp_ltac;
  Hook.set Tacintern.interp_atomic_ltac_hook interp_atomic_ltac
