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

open FStar.Compiler.Effect
open FStar.Compiler.Range
open FStar.Syntax.Syntax
open FStar.Syntax.Embeddings
open FStar.Tactics.Types
module Env = FStar.TypeChecker.Env

val run_tactic_on_ps :
    range -> (* position on the tactic call *)
    range -> (* position for the goal *)
    bool ->  (* whether this call is in the "background", like resolve_implicits *)
    embedding 'a ->
    'a ->
    embedding 'b ->
    term ->        (* a term representing an `'a -> tac 'b` *)
    bool ->        (* true if the tactic term is already typechecked *)
    proofstate ->  (* proofstate *)
    list goal * 'b (* goals and return value *)

val primitive_steps : unit -> list FStar.TypeChecker.Primops.primitive_step

val report_implicits : range -> FStar.TypeChecker.Rel.tagged_implicits -> unit

(* Called by Main *)
val register_tactic_primitive_step : FStar.TypeChecker.Primops.primitive_step -> unit

(* For debugging only *)
val tacdbg : ref bool

open FStar.Tactics.Monad
module NBET = FStar.TypeChecker.NBETerm
val e_tactic_thunk (er : embedding 'r) : embedding (tac 'r)
val e_tactic_nbe_thunk (er : NBET.embedding 'r) : NBET.embedding (tac 'r)
val e_tactic_1 (ea : embedding 'a) (er : embedding 'r) : embedding ('a -> tac 'r)
val e_tactic_nbe_1 (ea : NBET.embedding 'a) (er : NBET.embedding 'r) : NBET.embedding ('a -> tac 'r)
