Require Import Lambda Cps.
Require Import String List.
Require Import ExtLib.Monad.Monad.
Require Import ExtLib.Monad.OptionMonad ExtLib.Monad.StateMonad ExtLib.Monad.ContMonad.
Require Import ExtLib.Data.Strings.
Require Import ExtLib.Decidables.Decidable.

Set Implicit Arguments.
Set Strict Implicit.

(** In this module, we define a few simple reduction optimizations.
    We will ultimately want to break these out into separate modules,
    provide a number of regression tests, use better data structures,
    and fuse the passes as best we can.
*)

(** To do for the current code:
    - use a better finite map data structure for environments
    - fuse copy propagation with other transformations to make them linear time
    - fuse some of the optimizations together a la Jim & Appel?
    - add distinction between recursive & non-recursive functions
    - add distinction between continuations & user-level functions (and calls)?
    - make projection from constructors explicit?

   To do for future basic optimizations:
    - eta expansion elimination (for both functions and constructors)
    - common sub-expression elimination (CSE)
      - the interesting part of this is function calls in the CPS setting
    - splitting mutually recursive functions that aren't really recursive
      (strongly connected components), supporting better dead-code and 
      inline-once optimization.
    - general inlining for functions
    - partial redundancy elimination

   To do for loop optimizations:
    - loop invariant removal, including loop invariant arguments
    - interprocedural copy propagation, reduction, and CSE

   To do for general engineering:
    - break optimizations into separate files
    - better test/regression infrastructure
*)
Module Optimize.
  Import MonadNotation CPS.
  (** The optimizer (and much of the compiler) is going to want to use
      some sort of environment:  a finite map from variables to some type
      of information.  Here, I've just used association lists, but obviously,
      we need to rip this out, put it in a different module, and use
      something with good asymptotic behavior (i.e., a balanced tree.)

      Ultimately, we may want to use numbers to represent variables so
      that we can get efficient indexing...
  *)
  Definition initial_env {A} : env_t A := nil.

  Fixpoint update {A} (x:var) (c:A) (xs:env_t A) : env_t A :=
    match xs with
      | nil => (x,c)::nil
      | (y,k)::t => if eq_dec y x then (y,c)::t else (y,k)::(update x c t)
    end.

  Fixpoint lookup {A} (x:var) (xs:env_t A) : option A :=
    match xs with
      | nil => None
      | (y,c)::t => if eq_dec y x then Some c else lookup x t
    end.

  Definition extend {A} (xs:env_t A) (x:var) (v:A) : env_t A :=
    (x,v)::xs.

  Fixpoint substs {A} (xs:list var) (vs:list A) : env_t A :=
    match xs, vs with
      | x::xs, v::vs => extend (substs xs vs) x v
      | _, _ => initial_env
    end.

  (** Copy Propagation:  reduce all expressions of the form:

      match v with
      | x => e
      end

     into e[v/x].

     (Note that this is the only real way we have to encode: "let x = v in e")

     This assumes we don't capture variables.  There are at least two
     ways to deal with this problem:  ensure all variables are
     uniquely named so we don't have to worry about it;  alternatively,
     rename as we go.

     Or, we could use deBruijn indices but that introduces many problems
     later on.  For instance, we cannot use a global map from variable names
     to counts in the dead-code and inline passes below.  We would need
     some notion of "path" instead.
  *)
  Definition cprop_op (subst:env_t op) (v:op) : op :=
    match v with
      | Var_o x => match lookup x subst with | None => v | Some v' => v' end
      | _ => v
    end.

  Definition cprop_list (subst:env_t op) (vs:list op): list op :=
    List.map (cprop_op subst) vs.

  Fixpoint cprop (subst:env_t op) e : exp :=
    match e with
      | App_e v vs => App_e (cprop_op subst v) (cprop_list subst vs)
      | Let_e x c vs e => Let_e x c (cprop_list subst vs) (cprop subst e)
      | Match_e v ((Lambda.Var_p x,e)::nil) =>
        let v' := cprop_op subst v in cprop (extend subst x v') e
      | Match_e v arms =>
        Match_e (cprop_op subst v)
        (List.map (fun (arm:pattern*exp) => (fst arm, cprop subst (snd arm))) arms)
      | Letrec_e fs e =>
        Letrec_e
        (List.map (fun (fn:var*(list var*exp)) =>
          match fn with (f,(x,e)) => (f,(x,cprop subst e)) end) fs) (cprop subst e)
    end.

  Definition copyprop := cprop initial_env.

  Section TEST_COPYPROP.
    Import LambdaNotation.
    (* Eval compute in (cps2string (CPS (gen e1))). *)
    (* Eval compute in (cps2string (copyprop (CPS (gen e1)))). *)
  End TEST_COPYPROP.

  (** More match reduction:

     match C with | ... | C => e | ... end => e

     let x = C v1 ... vn in
     ...
     match x with | ... | C x1 ... xn => e | ... end => e[vi/xi]

     This also has the variable capture problem.  In addition, the way
     it's coded makes it hard to prove termination.  Finally, the right
     way to do this is to fuse together the copy propagation with the
     reductions.
     *)
  Fixpoint reduce (n:nat)(env:env_t (constructor * list op)) (e:exp) : exp :=
    match n with
      | 0 => e
      | S n =>
      (* specialize the match arm under the assumption that the
         pattern is now equal to x.  For instance, if we have:
         
         match x with 
         | Cons h t => ... match x with 
                           | Cons h1 t1 => e1
                           | Nil => e2
         | Nil => ... match x with 
                      | Cons h3 t3 => e3
                      | Nil => e4

         then we can reduce the inner matches if for each arm, we remember
         that (x = Cons h t) and (x = Nil) respectively. *)
        let reduce_arm := 
          fun (x:var) (arm:pattern*exp) => 
            (fst arm, 
            match (fst arm) with 
              | Lambda.Con_p c nil =>
                  (* in this branch, substitute Con_o c for x *)
                  reduce n env (cprop (substs (x::nil) ((Con_o c)::nil)) (snd arm))
                  (* in this branch, treat x as bound to (c vs) *)
              | Lambda.Con_p c xs => reduce n ((x,(c, (map Var_o xs)))::env) (snd arm)
              | Lambda.Var_p y => 
                  (* in this branch, substitute x for y *)
                  reduce n env (cprop (substs (y::nil) ((Var_o x)::nil)) (snd arm))
            end)
            in
          let find_arm :=
            fix find (c:constructor)(arms:list (pattern*exp)) : option (pattern*exp) :=
            match arms with
              | nil => None
              | (Lambda.Con_p c' xs,e)::rest =>
                if eq_dec c c' then Some (Lambda.Con_p c' xs,e) else find c rest
              | (Lambda.Var_p x,e)::rest => Some (Lambda.Var_p x,e)
            end in
            match e with
              | Match_e (Var_o x) arms =>
                match lookup x env with
                  (* earlier, we had Let_e x c vs, so we can reduce the match *)
                  | Some (c,vs) =>
                    match find_arm c arms with
                      | Some (Lambda.Con_p _ ys,ec) =>
                        reduce n env (cprop (substs ys vs) ec)
                      | Some (Lambda.Var_p y,ec) =>
                        reduce n env (cprop (substs (y::nil) ((Var_o x)::nil)) ec)
                      | _ => e
                    end
                  | None =>
                    (* we can't reduce this match, but we can reduce nested matches
                       on the same variable. *)
                    Match_e (Var_o x) (List.map (reduce_arm x) arms)
                end
              | Match_e (Con_o c) arms =>
                (* this is a special case for the nullary constructors *)
                match find_arm c arms with
                  | Some (Lambda.Con_p _ _,ec) => reduce n env ec
                  | _ => e
                end
              | Let_e x c vs e => Let_e x c vs (reduce n (extend env x (c,vs)) e)
              | Letrec_e fs e =>
                Letrec_e
                (List.map (fun fn =>
                  match fn with
                    | (f,(xs,e)) => (f,(xs,reduce n env e))
                  end) fs) (reduce n env e)
              | App_e v vs => App_e v vs
            end
    end.

  (** Calculate the number of uses of a variable (i.e., free occurrences) and
      return an environment mapping variables to counts.  *)
  Definition counts := env_t nat.

  Notation "e1 ;; e2" := (_ <- e1 ; e2) (at level 51, right associativity).

  Definition clear_count (x:var) : ST counts unit :=
    s <- get ; put (update x 0 s).

  Definition inc_count (x:var) : ST counts unit :=
    s <- get ;
    match lookup x s with
      | None => put (update x 1 s)
      | Some c => put (update x (1+c) s)
    end.

  Definition use_op (v:op) : ST counts unit :=
    match v with
      | Var_o x => inc_count x
      | Con_o _ => ret tt
    end.

  Definition use_pat (p:pattern) : ST counts unit :=
    match p with
      | Lambda.Con_p _ xs => iter clear_count xs
      | Lambda.Var_p x => clear_count x
    end.

  Fixpoint uses (e:exp) : ST counts unit :=
    match e with
      | App_e v vs => use_op v ;; iter use_op vs
      | Let_e x c vs e =>
        iter use_op vs ;; clear_count x ;; uses e
      | Match_e v arms =>
        use_op v ;;
        iter (fun (arm:pattern*exp) => use_pat (fst arm) ;; uses (snd arm)) arms
      | Letrec_e fs e =>
        iter (fun fn => match fn with
                          | (f,(xs,e)) => clear_count f ;; iter clear_count xs
                        end) fs ;;
        iter (fun fn => match fn with | (_,(_,e)) => uses e end) fs ;;
        uses e
    end.

  Definition calc_uses (e:exp) : counts := snd (runState (uses e) nil).

  Section DEADCODE.
    (** Assume we have usage counts for each variable -- this gets lambda
        abstracted outside the section for each function that uses this. *)
    Variable cs : counts.

    (** Determine whether a let-bound or letrec-bound variable is "dead"
       (has a use-count of zero) and if so, eliminate it.  Note that this
       will never get rid of a truly recursive function. *)
    Definition is_dead (fn : (var * (list var * exp))) :=
      match lookup (fst fn) cs with
        | Some 0 => true
        | _ => false
      end.

    (** Eliminate dead bindings -- i.e., that have a use-count of zero. *)
    Fixpoint dead(e:exp) : exp :=
      match e with
        | App_e _ _ => e
        | Let_e x c vs e' =>
          match lookup x cs with
            | Some 0 => dead e'
            | _ => Let_e x c vs (dead e')
          end
        | Match_e v arms =>
          Match_e v (List.map (fun arm => (fst arm, dead (snd arm))) arms)
        | Letrec_e fs e =>
          let fs' := List.map (fun fn => (fst fn, (fst (snd fn), dead (snd (snd fn))))) fs in
          let gs := filter (fun x => negb (is_dead x)) fs' in
            match gs with
              | nil => dead e
              | _ => Letrec_e gs (dead e)
            end
      end.

    (** Count the number of times a function is called *)
    Fixpoint calls (e:exp) : ST counts unit := 
      match e with 
        | App_e (Var_o x) _ => use_op (Var_o x)
        | App_e _ _ => ret tt
        | Let_e x c vs e => calls e
        | Match_e v arms => 
          iter (fun (arm:pattern*exp) => calls (snd arm)) arms
        | Letrec_e fs e => 
          iter (fun fn => clear_count (fst fn)) fs ;; 
          iter (fun fn => calls (snd (snd fn))) fs ;;
          calls e
      end.

    (** Assume we have calculated the numer of calls for each function in an environment. *)
    Variable num_calls : env_t nat.

    (** Claim:  A letrec function f can be safely inlined if it is called in exactly
        one spot, and there are no other uses of the function.  (Is this correct?
        Consider the case of a letrec with two functions f and g that call each
        other and there are no other calls.  Then there's no way to enter the loop!
        So f and g must be dead code.  If one of the functions (say f) has another call 
        site, then we can still safely inline g into f. *)
    Definition called_once (fn:var * (list var * exp)) : bool := 
      let (f,_) := fn in 
      match lookup f num_calls, lookup f cs with 
        | Some 1, Some 1 => true
        | _, _ => false
      end.

    (* Again, fusing the copy propagation with the inline1 pass would make
       this more efficient.  Note that inlining a function that is called
       at most once preserves the property that each variable is uniquely
       named.  So generalizing this to multiple uses requires a bit more
       work, as we must pick fresh variable names for each copy of a function
       that we inline. 
       *)
    Fixpoint inline1 (defs:env_t (list var * exp)) (e:exp) : exp :=
        match e with
          | App_e (Var_o f) vs =>
            match lookup f defs with
              | None => e
              | Some (xs,e') => cprop (substs xs vs) e'
            end
          | App_e _ _ => e
          | Let_e x c vs e => Let_e x c vs (inline1 defs e)
          | Match_e v arms =>
            Match_e v (map (fun arm => (fst arm, inline1 defs (snd arm))) arms)
          | Letrec_e fs e =>
            let defs' := (filter called_once fs) ++ defs in 
              let fs' := 
                filter (fun fn => negb (called_once fn)) 
                (map (fun fn => (fst fn, (fst (snd fn), inline1 defs' (snd (snd fn))))) fs) in
                match fs' with
                  | nil => (inline1 defs' e)
                  | fs' => Letrec_e fs' (inline1 defs' e)
                end
        end.

  End DEADCODE.

  Definition deadcode (e:exp) : exp :=
      dead (calc_uses e) e.

  Definition inline_once (e:exp) : exp :=
      inline1 (snd (runState (calls e) initial_env)) (calc_uses e) nil e.

  (** Our simple optimizer *)
  Definition optimize (fuel:nat) (e:exp) : exp :=
    inline_once (deadcode (reduce fuel initial_env (cprop initial_env e))).

  (** Note that some reductions may enable other reductions.  For instance,
      after inlining a function, we have opportunities to do more match
      reductions.  And after a match reduction, we may be able to inline
      a function.  So the way we've written this, we really should iterate
      the optimizer until there are no more reductions to perform.

      Note also that we are recalculating the usage counts for both deadcode
      and inline_once.  An alternative would be to try to keep the counts
      up to date.
  *)
(*
  Section TEST_OPTIMIZER.
    Import LambdaNotation.
    
    Eval compute in cps2string (reduce 100 initial_env (cprop initial_env (CPS (gen e8)))).
    Eval compute in cps2string (optimize 100 (CPS (gen e8))).
    Eval compute in (cps2string (CPS (gen e6))).
    Eval compute in (cps2string (optimize 100 (CPS (gen e6)))).

    Definition test_exp :=
      def f := \ x => S_c x in f @ Z_c.

    Eval compute in (cps2string (CPS (gen test_exp))).
    Eval compute in (cps2string (inline_once (cprop initial_env (CPS (gen test_exp))))).
    Eval compute in (cps2string (optimize 100 (CPS (gen test_exp)))).

    Definition next_test := 
      def f := \ x => x in Z_c.
    Eval compute in (cps2string (CPS (gen next_test))).
    Eval compute in (cps2string (deadcode (cprop initial_env (CPS (gen next_test))))).

    Require Import Parse.
    Import Parse. Import String.
    Definition other_test := 
      match 
      parse_exp ( "
        (lambda (x) 
          (match x 
              ((Z) (match x 
                    ((Z) `(Z))
                    ((S a) a)
                   ))
              ((S z) (match x
                      ((Z) `(Z))
                      ((S b) b)))))
      ")
      with 
        Some p => fst p | None => Lambda.Con_e "c"%string nil end.
     Eval compute in (cps2string (optimize 100 (CPS other_test))).
  End TEST_OPTIMIZER.
*)

End Optimize.
