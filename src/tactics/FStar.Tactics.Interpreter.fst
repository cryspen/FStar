﻿(*
   Copyright 2008-2016 Microsoft Research

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*)

module FStar.Tactics.Interpreter

(* Most of the tactic running logic is here. V1.Interpreter calls
into this module for all of that. *)

open FStar
open FStar.Compiler
open FStar.Compiler.Effect
open FStar.Compiler.List
open FStar.Compiler.Range
open FStar.Compiler.Util
open FStar.Syntax.Syntax
open FStar.Syntax.Embeddings
open FStar.TypeChecker.Common
open FStar.TypeChecker.Env
open FStar.Tactics.Result
open FStar.Tactics.Types
open FStar.Tactics.Printing
open FStar.Tactics.Monad
open FStar.Tactics.V2.Basic
open FStar.Tactics.CtrlRewrite
open FStar.Tactics.Native
open FStar.Tactics.Common
open FStar.Class.Show
open FStar.Class.Monad

module BU      = FStar.Compiler.Util
module Cfg     = FStar.TypeChecker.Cfg
module E       = FStar.Tactics.Embedding
module Env     = FStar.TypeChecker.Env
module Err     = FStar.Errors
module IFuns   = FStar.Tactics.InterpFuns
module NBE     = FStar.TypeChecker.NBE
module NBET    = FStar.TypeChecker.NBETerm
module N       = FStar.TypeChecker.Normalize
module NRE     = FStar.Reflection.V2.NBEEmbeddings
module PC      = FStar.Parser.Const
module PO      = FStar.TypeChecker.Primops
module Print   = FStar.Syntax.Print
module RE      = FStar.Reflection.V2.Embeddings
module S       = FStar.Syntax.Syntax
module SS      = FStar.Syntax.Subst
module TcComm  = FStar.TypeChecker.Common
module TcRel   = FStar.TypeChecker.Rel
module TcTerm  = FStar.TypeChecker.TcTerm
module U       = FStar.Syntax.Util

let solve (#a:Type) {| ev : a |} : Tot a = ev
let tacdbg = BU.mk_ref false

let embed {|embedding 'a|} r (x:'a) norm_cb = embed x r None norm_cb
let unembed {|embedding 'a|} a norm_cb : option 'a = unembed a norm_cb

let native_tactics_steps () =
  let step_from_native_step (s: native_primitive_step) : PO.primitive_step =
    { name                         = s.name
    ; arity                        = s.arity
    ; univ_arity                   = 0 // Zoe : We might need to change that
    ; auto_reflect                 = Some (s.arity - 1)
    ; strong_reduction_ok          = s.strong_reduction_ok
    ; requires_binder_substitution = false // GM: Don't think we care about pretty-printing on native
    ; renorm_after                 = false
    ; interpretation               = s.tactic
    ; interpretation_nbe           = fun _cb _us -> NBET.dummy_interp s.name
    }
  in
  List.map step_from_native_step (FStar.Tactics.Native.list_all ())

(* This reference keeps all of the tactic primitives. *)
let __primitive_steps_ref : ref (list PO.primitive_step) =
  BU.mk_ref []

let primitive_steps () : list PO.primitive_step =
    (native_tactics_steps ())
    @ (!__primitive_steps_ref)

let register_tactic_primitive_step (s : PO.primitive_step) : unit =
  __primitive_steps_ref := s :: !__primitive_steps_ref

(* This function attempts to reconstruct the reduction head of a
stuck tactic term, to provide a better error message for the user. *)
let rec t_head_of (t : term) : term =
    match (SS.compress t).n with
    | Tm_app _ ->
      (* If the head is a ctor, or an uninterpreted fv, do not shrink
         further. Otherwise we will get failures saying that 'Success'
         or 'dump' got stuck, which is not helpful. *)
      let h, args = U.head_and_args_full t in
      let h = U.unmeta h in
      begin match (SS.compress h).n with
      | Tm_uinst _
      | Tm_fvar _
      | Tm_bvar _ // should not occur
      | Tm_name _
      | Tm_constant _ -> t
      | _ -> t_head_of h
      end
    | Tm_match {scrutinee=t}
    | Tm_ascribed {tm=t}
    | Tm_meta {tm=t} -> t_head_of t
    | _ -> t

let unembed_tactic_0 (eb:embedding 'b) (embedded_tac_b:term) (ncb:norm_cb) : tac 'b =
    let! proof_state = get in
    let rng = embedded_tac_b.pos in

    (* First, reify it from Tac a into __tac a *)
    let embedded_tac_b = U.mk_reify embedded_tac_b (Some PC.effect_TAC_lid) in

    let tm = S.mk_Tm_app embedded_tac_b
                         [S.as_arg (embed rng proof_state ncb)]
                          rng in


    // Why not HNF? While we don't care about strong reduction we need more than head
    // normal form due to primitive steps. Consider `norm (steps 2)`: we need to normalize
    // `steps 2` before caling norm, or it will fail to unembed the set of steps. Further,
    // at this moment at least, the normalizer will not call into any step of arity > 1.
    let steps = [Env.Weak;
                 Env.Reify;
                 Env.UnfoldUntil delta_constant; Env.UnfoldTac;
                 Env.Primops; Env.Unascribe] in

    // Maybe use NBE if the user asked for it
    let norm_f = if Options.tactics_nbe ()
                 then NBE.normalize
                 else N.normalize_with_primitive_steps
    in
    (* if proof_state.tac_verb_dbg then *)
    (*     BU.print1 "Starting normalizer with %s\n" (show tm); *)
    let result = norm_f (primitive_steps ()) steps proof_state.main_context tm in
    (* if proof_state.tac_verb_dbg then *)
    (*     BU.print1 "Reduced tactic: got %s\n" (show result); *)

    let res = unembed result ncb in

    match res with
    | Some (Success (b, ps)) ->
      set ps;!
      return b

    | Some (Failed (e, ps)) ->
      set ps;!
      traise e

    | None ->
        (* The tactic got stuck, try to provide a helpful error message. *)
        let h_result = t_head_of result in
        let open FStar.Pprint in
        let maybe_admit_tip : document =
          (* Use the monadic visitor to check whether the reduced head
          contains an admit, which is a common error *)
          let r : option term =
            Syntax.VisitM.visitM_term (fun t ->
              match t.n with
              | Tm_fvar fv when fv_eq_lid fv PC.admit_lid -> None
              | _ -> Some t) h_result
          in
          if None? r
          then doc_of_string "The term contains an `admit`, which will not reduce. Did you mean `tadmit()`?"
          else empty
        in
        FStar.Errors.Raise.(error_doc (Fatal_TacticGotStuck,
          [str "Tactic got stuck!";
           str "Reduction stopped at: " ^^ ttd h_result;
           maybe_admit_tip]) proof_state.main_context.range)

let unembed_tactic_nbe_0 (eb:NBET.embedding 'b) (cb:NBET.nbe_cbs) (embedded_tac_b:NBET.t) : tac 'b =
    let! proof_state = get in

    (* Applying is normalizing!!! *)
    let result = NBET.iapp_cb cb embedded_tac_b [NBET.as_arg (NBET.embed E.e_proofstate_nbe cb proof_state)] in
    let res = NBET.unembed (E.e_result_nbe eb) cb result in

    match res with
    | Some (Success (b, ps)) ->
      set ps;!
      return b

    | Some (Failed (e, ps)) ->
      set ps;!
      traise e

    | None ->
        FStar.Errors.Raise.(
          error_doc (Fatal_TacticGotStuck,
            [str "Tactic got stuck (in NBE)!";
             text "Please file a bug report with a minimal reproduction of this issue.";
             str "Result = " ^^ str (NBET.t_to_string result)]) proof_state.main_context.range
        )

let unembed_tactic_1 (ea:embedding 'a) (er:embedding 'r) (f:term) (ncb:norm_cb) : 'a -> tac 'r =
    fun x ->
      let rng = FStar.Compiler.Range.dummyRange  in
      let x_tm = embed rng x ncb in
      let app = S.mk_Tm_app f [as_arg x_tm] rng in
      unembed_tactic_0 er app ncb

let unembed_tactic_nbe_1 (ea:NBET.embedding 'a) (er:NBET.embedding 'r) (cb:NBET.nbe_cbs) (f:NBET.t) : 'a -> tac 'r =
    fun x ->
      let x_tm = NBET.embed ea cb x in
      let app = NBET.iapp_cb cb f [NBET.as_arg x_tm] in
      unembed_tactic_nbe_0 er cb app

let e_tactic_thunk (er : embedding 'r) : embedding (tac 'r)
    =
    mk_emb (fun _ _ _ _ -> failwith "Impossible: embedding tactic (thunk)?")
           (fun t cb -> Some (unembed_tactic_1 e_unit er t cb ()))
           (FStar.Syntax.Embeddings.term_as_fv S.t_unit)

let e_tactic_nbe_thunk (er : NBET.embedding 'r) : NBET.embedding (tac 'r)
    =
    NBET.mk_emb
           (fun cb _ -> failwith "Impossible: NBE embedding tactic (thunk)?")
           (fun cb t -> Some (unembed_tactic_nbe_1 NBET.e_unit er cb t ()))
           (fun () -> NBET.mk_t (NBET.Constant NBET.Unit))
           (emb_typ_of unit)

let e_tactic_1 (ea : embedding 'a) (er : embedding 'r) : embedding ('a -> tac 'r)
    =
    mk_emb (fun _ _ _ _ -> failwith "Impossible: embedding tactic (1)?")
           (fun t cb -> Some (unembed_tactic_1 ea er t cb))
           (FStar.Syntax.Embeddings.term_as_fv S.t_unit)

let e_tactic_nbe_1 (ea : NBET.embedding 'a) (er : NBET.embedding 'r) : NBET.embedding ('a -> tac 'r)
    =
    NBET.mk_emb
           (fun cb _ -> failwith "Impossible: NBE embedding tactic (1)?")
           (fun cb t -> Some (unembed_tactic_nbe_1 ea er cb t))
           (fun () -> NBET.mk_t (NBET.Constant NBET.Unit))
           (emb_typ_of unit)

let unembed_tactic_1_alt (ea:embedding 'a) (er:embedding 'r) (f:term) (ncb:norm_cb) : option ('a -> tac 'r) =
    Some (fun x ->
      let rng = FStar.Compiler.Range.dummyRange  in
      let x_tm = embed rng x ncb in
      let app = S.mk_Tm_app f [as_arg x_tm] rng in
      unembed_tactic_0 er app ncb)

let e_tactic_1_alt (ea: embedding 'a) (er:embedding 'r): embedding ('a -> (proofstate -> __result 'r)) =
    let em = (fun _ _ _ _ -> failwith "Impossible: embedding tactic (1)?") in
    let un (t0: term) (n: norm_cb): option ('a -> (proofstate -> __result 'r)) =
        match unembed_tactic_1_alt ea er t0 n with
        | Some f -> Some (fun x -> run (f x))
        | None -> None
    in
    mk_emb em un (FStar.Syntax.Embeddings.term_as_fv t_unit)

let report_implicits rng (is : TcRel.tagged_implicits) : unit =
  is |> List.iter
    (fun (imp, tag) ->
      match tag with
      | TcRel.Implicit_unresolved
      | TcRel.Implicit_checking_defers_univ_constraint ->
        Errors.log_issue rng
                (Err.Error_UninstantiatedUnificationVarInTactic,
                 BU.format3 ("Tactic left uninstantiated unification variable %s of type %s (reason = \"%s\")")
                             (show imp.imp_uvar.ctx_uvar_head)
                             (show (U.ctx_uvar_typ imp.imp_uvar))
                             imp.imp_reason)
      | TcRel.Implicit_has_typing_guard (tm, ty) ->
        Errors.log_issue rng
                (Err.Error_UninstantiatedUnificationVarInTactic,
                 BU.format4 ("Tactic solved goal %s of type %s to %s : %s, but it has a non-trivial typing guard. Use gather_or_solve_explicit_guards_for_resolved_goals to inspect and prove these goals")
                             (show imp.imp_uvar.ctx_uvar_head)
                             (show (U.ctx_uvar_typ imp.imp_uvar))
                             (show tm)
                             (show ty)));
  Err.stop_if_err ()

let run_tactic_on_ps'
  (rng_call : Range.range)
  (rng_goal : Range.range)
  (background : bool)
  (e_arg : embedding 'a)
  (arg : 'a)
  (e_res : embedding 'b)
  (tactic:term)
  (tactic_already_typed:bool)
  (ps:proofstate)
  : list goal // remaining goals
  * 'b // return value
  =
    let ps = { ps with main_context = { ps.main_context with intactics = true } } in
    let ps = { ps with main_context = { ps.main_context with range = rng_goal } } in
    let env = ps.main_context in
    if !tacdbg then
        BU.print2 "Typechecking tactic: (%s) (already_typed: %s) {\n"
          (show tactic)
          (show tactic_already_typed);

    (* Do NOT use the returned tactic, the typechecker is not idempotent and
     * will mess up the monadic lifts. We're just making sure it's well-typed
     * so it won't get stuck. c.f #1307 *)
    let g =
      if tactic_already_typed
      then Env.trivial_guard
      else let _, _, g = TcTerm.tc_tactic (type_of e_arg) (type_of e_res) env tactic in
           g in

    if !tacdbg then
        BU.print_string "}\n";

    TcRel.force_trivial_guard env g;
    Err.stop_if_err ();
    let tau = unembed_tactic_1 e_arg e_res tactic FStar.Syntax.Embeddings.id_norm_cb in

    (* if !tacdbg then *)
    (*     BU.print1 "Running tactic with goal = (%s) {\n" (show typ); *)
    let res =
      Profiling.profile
        (fun () -> run_safe (tau arg) ps)
        (Some (Ident.string_of_lid (Env.current_module ps.main_context)))
        "FStar.Tactics.Interpreter.run_safe"
    in
    if !tacdbg then
        BU.print_string "}\n";

    match res with
    | Success (ret, ps) ->
        if !tacdbg then
            do_dump_proofstate ps "at the finish line";

        (* if !tacdbg || Options.tactics_info () then *)
        (*     BU.print1 "Tactic generated proofterm %s\n" (show w); *)
        let remaining_smt_goals = ps.goals@ps.smt_goals in
        List.iter
          (fun g ->
            FStar.Tactics.V2.Basic.mark_goal_implicit_already_checked g;//all of these will be fed to SMT anyway
            if is_irrelevant g
            then (
              if !tacdbg then BU.print1 "Assigning irrelevant goal %s\n" (show (goal_witness g));
              if TcRel.teq_nosmt_force (goal_env g) (goal_witness g) U.exp_unit
              then ()
              else failwith (BU.format1 "Irrelevant tactic witness does not unify with (): %s"
                                                           (show (goal_witness g)))
            ))
          remaining_smt_goals;

        // Check that all implicits were instantiated
        Errors.with_ctx "While checking implicits left by a tactic" (fun () ->
          if !tacdbg then
              BU.print1 "About to check tactic implicits: %s\n" (FStar.Common.string_of_list
                                                                      (fun imp -> show imp.imp_uvar)
                                                                      ps.all_implicits);

          let g = {Env.trivial_guard with TcComm.implicits=ps.all_implicits} in
          let g = TcRel.solve_deferred_constraints env g in
          if !tacdbg then
              BU.print2 "Checked %s implicits (1): %s\n"
                          (show (List.length ps.all_implicits))
                          (show ps.all_implicits);
          let tagged_implicits = TcRel.resolve_implicits_tac env g in
          if !tacdbg then
              BU.print2 "Checked %s implicits (2): %s\n"
                          (show (List.length ps.all_implicits))
                          (show ps.all_implicits);
          report_implicits rng_goal tagged_implicits
        );

        (remaining_smt_goals, ret)

    (* Catch normal errors to add a "Tactic failed" at the top. *)
    | Failed (Errors.Error (code, msg, rng, ctx), ps) ->
      let msg = FStar.Pprint.doc_of_string "Tactic failed" :: msg in
      raise (Errors.Error (code, msg, rng, ctx))

    | Failed (Errors.Err (code, msg, ctx), ps) ->
      let msg = FStar.Pprint.doc_of_string "Tactic failed" :: msg in
      raise (Errors.Err (code, msg, ctx))

    (* Any other error, including exceptions being raised by the metaprograms. *)
    | Failed (e, ps) ->
        do_dump_proofstate ps "at the time of failure";
        let texn_to_string e =
            match e with
            | TacticFailure s ->
                "\"" ^ s ^ "\""
            | EExn t ->
                "Uncaught exception: " ^ (show t)
            | e ->
                raise e
        in
        let rng =
          if background
          then match ps.goals with
               | g::_ -> g.goal_ctx_uvar.ctx_uvar_range
               | _ -> rng_call
          else ps.entry_range
        in
        let open FStar.Pprint in
        Err.raise_error_doc (Err.Fatal_UserTacticFailure,
                            [doc_of_string "Tactic failed";
                             doc_of_string (texn_to_string e);
                            ])
                          rng

let run_tactic_on_ps
          (rng_call : Range.range)
          (rng_goal : Range.range)
          (background : bool)
          (e_arg : embedding 'a)
          (arg : 'a)
          (e_res : embedding 'b)
          (tactic:term)
          (tactic_already_typed:bool)
          (ps:proofstate) =
    Profiling.profile
      (fun () -> run_tactic_on_ps' rng_call rng_goal background e_arg arg e_res tactic tactic_already_typed ps)
      (Some (Ident.string_of_lid (Env.current_module ps.main_context)))
      "FStar.Tactics.Interpreter.run_tactic_on_ps"
