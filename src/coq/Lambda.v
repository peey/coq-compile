Require Import String.
Require Import List.
Require Import ExtLib.Structures.Monads.
Require Import ExtLib.Data.Monads.StateMonad.
Require Import ExtLib.Data.Monads.OptionMonad.
Require Import ExtLib.Data.Strings.
Require Import ExtLib.Core.RelDec.
Require Import CoqCompile.Env.

Set Implicit Arguments.
Set Strict Implicit.

Module Lambda.
  (** data constructors, such as "True", "False", "Nil", "::", "0", "S", etc. *)
  Definition constructor := string.

  (** environments -- naively as an association list *)
  Definition env_t A := list (var * A).

  Import MonadNotation.
  Open Local Scope monad_scope.

  Fixpoint lookup {A} (env: env_t A) (x:var) : option A :=
    match env with
      | nil => None
      | (y,v)::env' => if eq_dec x y then ret v else lookup env' x
    end.

  (** Lambda has only very basic patterns (no nesting).  So we can only write
      matches such as:

         match e with
         | C1 x1 x2 ... xn => e1
         | C2 y1 y2 ... yn => e2
         | ...
         | z => e

       We assume, or rather, Coq will guarantee, that the patterns are exhaustive
       and non-overlapping. *)
  Inductive pattern : Type :=
  | Con_p : constructor -> list var -> pattern
  | Var_p : var -> pattern.

  (** Expressions in Lambda include variables, functions (lambda-expressions over
      one variable), function applications, a basic sequential "let", a data
      constructor applied to arguments, a match expression, or a letrec.  The
      letrec binds a list of variables f1,...,fn to function definitions
      (fun x1 => e1) ... (fun xn => en) within the scope of some expression "e".
  *)
  Inductive exp : Type :=
  | Var_e : var -> exp
  | Lam_e : var -> exp -> exp
  | App_e : exp -> exp -> exp
  | Let_e : var -> exp -> exp -> exp
  | Con_e : constructor -> list exp -> exp
  | Match_e : exp -> list (pattern * exp) -> exp
  | Letrec_e : env_t (var * exp) -> exp -> exp.

  Section Printing.
    Require Import ExtLib.Programming.Show.
    Import ShowNotation.
    Local Open Scope string_scope.
    Local Open Scope show_scope.

    Require Import ExtLib.Data.Lists.
    
    Global Instance Show_pat : Show pattern :=
    { show x :=
      match x with
        | Con_p c vs => c << " " << sepBy_f show " " vs
        | Var_p v => show v
      end }.

    Fixpoint show_exp (e : exp) : showM :=
      match e with
        | Var_e v => show v
        | Lam_e v e => "(lambda (" << show v << ") " << show_exp e << ")"
        | App_e f e => "(" << show_exp f << " " << show_exp e << ")"
        | Let_e v e b =>
          "(let ((" << show v << " " << show_exp e << ")) " << 
          indent "     " (Char.chr_newline << show_exp b) << ")"
        | Con_e c le => "(" << c << " " << sepBy " " (map show_exp le) << ")"
        | Match_e e pe =>
          "(match " << show_exp e << 
          indent "   " (Char.chr_newline << 
                        sepBy Char.chr_newline (map (fun pe => 
                          let '(p,e) := pe in
                          "((" << show p << ") " << show_exp e << ")") pe)) << ")"
        | Letrec_e ds e => empty
      end%string.
    
    Global Instance Show_lambda : Show exp :=
    { show := show_exp }.  

  End Printing.

End Lambda.

Module LambdaSemantics.
  Import Lambda MonadNotation.
  Open Local Scope monad_scope.
  (** Here, we model evaluation of expressions to give a "formal" definition
      of the meaning of programs.  Because [exp] includes the potential for
      diverging programs, we can't directly write the semantics as a Coq
      total function.  However, we can construct a predicate (relation)
      as a partial function between expressions and values. *)

  (** A value is the result of evaluating an expression.  A value is
      either a data constructor applied to values (e.g., "true", or "true::nil"),
      or a closure.  We have two kinds of closures, one corresponding to
      non-recursive functions, and one corresponding to recursive functions.
      In both cases, the closure captures the environment (a mapping from
      variables to values) along with the function definition.  To model
      recursion, we have to "unwind" the recursive definitions.  To avoid
      needing infinite (co-inductive) terms, we do this lazily at the
      site of application.  So the [Fix_v] form of closure specifies
      an environment, a set of mutually-recursive functions (as in a letrec)
      and a particular function name [f] from the set of recursively
      defined functions.  That is, [Fix_v env [(f1,(x1,e1)),...,(fn,(xn,en))] fi]
      is morally equivalent to [letrec f1 x1 = e1 ... fn xn = en in fi]. *)
  Inductive value : Type :=
  | Con_v : constructor -> list value -> value
  | Closure_v : env_t value -> var -> exp -> value
  | Fix_v : env_t value -> env_t (var * exp) -> var -> value.

  Fixpoint zip {A B} (xs:list A) (ys:list B) : option (list (A * B)) :=
    match xs, ys with
      | nil, nil => ret nil
      | x::xs, y::ys => t <- (zip xs ys) ;; ret ((x,y)::t)
      | _, _ => None
    end.

  Fixpoint eval_n (n:nat) (env:env_t value) (e:exp) : option value :=
    match n with
      | 0 => None
      | S n =>
        match e with
          | Var_e x => lookup env x
          | Lam_e x e => ret (Closure_v env x e)
          | App_e e1 e2 =>
            v1 <- eval_n n env e1 ;;
            v2 <- eval_n n env e2 ;;
            match v1 with
              | Closure_v env x e => eval_n n ((x,v2)::env) e
              | Fix_v env fs f =>
                let env' :=
                  List.map
                  (fun (p:var * (var * exp)) =>
                    let (f,_) := p in (f,Fix_v env fs f)) fs
                in
                match lookup fs f return option value with
                  | None => mzero
                  | Some (x,e) => eval_n n ((x,v2)::env' ++ env) e
                end
              | _ => mzero
            end
          | Con_e c es =>
            (fix map_eval_n (xs:list exp) (k:list value -> option value) : option value :=
              match xs with
                | nil => k nil
                | e::es => v <- eval_n n env e ;; map_eval_n es (fun vs => k (v::vs))
              end)
            es (fun vs => ret (Con_v c vs))
          | Let_e x e1 e2 =>
            v1 <- eval_n n env e1 ;; eval_n n ((x,v1)::env) e2
          | Letrec_e fs e =>
            let env' :=
              List.map
              (fun (p:var * (var * exp)) => let (f,_) := p in (f,Fix_v env fs f)) fs in
              eval_n n (env' ++ env) e
          | Match_e e arms =>
            v <- eval_n n env e ;;
            match v with
              | Con_v c vs =>
                (fix find_arm (arms:list (pattern * exp)) :=
                  match arms with
                    | nil => None
                    | ((Var_p x),e)::arms => eval_n n ((x,v)::env) e
                    | ((Con_p c' xs),e)::arms =>
                      if string_dec c c' then
                        env' <- zip xs vs ;; eval_n n (env' ++ env) e
                      else find_arm arms
                  end) arms
              | _ => None
            end
        end
    end.

  Definition evals (env:env_t value) (e:exp) (v:value) : Prop :=
    exists n, eval_n n env e = Some v.

End LambdaSemantics.


Module LambdaNotation.
  Require ExtLib.Data.Strings.
  Import Lambda MonadNotation.
  Local Open Scope string_scope.
  Local Open Scope monad_scope.
  Require Import BinPos.

  Definition Exp := state positive exp.

  Definition fresh (x:option string) : state positive var :=
    n <- get ;;
    put (Psucc n) ;;
    ret (mkVar x n).

  Definition gen (E : Exp) : exp :=
    fst (runState E 1%positive).
  Definition FN (f : Exp -> Exp) : Exp :=
    x <- fresh (Some "x") ;; e <- f (ret (Var_e x)) ;; ret (Lam_e x e).
  Notation "\ x => e" := (FN (fun x => e)) (at level 80).
  Definition APP (E1 E2:Exp) : Exp := e1 <- E1 ;; e2 <- E2 ;; ret (App_e e1 e2).
  Notation "E1 @ E2" := (APP E1 E2) (left associativity, at level 69).
  Definition LET (E1:Exp) (f:Exp -> Exp) : Exp :=
    x <- fresh (Some "x") ;; e1 <- E1 ;; e2 <- f (ret (Var_e x)) ;; ret (Let_e x e1 e2).
  Notation "'def' x := E1 'in' E2" := (LET E1 (fun x => E2))
    (right associativity, at level 75, E2 at next level).
  Definition LETREC (f:Exp -> Exp -> Exp) (E:Exp -> Exp) : Exp :=
    fname <- fresh (Some "f") ;; x <- fresh (Some "x") ;;
    fbody <- f (ret (Var_e fname)) (ret (Var_e x)) ;;
    e <- E (ret (Var_e fname)) ;;
    ret (Letrec_e ((fname,(x,fbody))::nil) e).
  Notation "'defrec' f [ x ] := E1 'in' E2" := (LETREC (fun f x => E1) (fun f => E2))
    (right associativity, at level 75, E2 at next level).
  Definition true_c : Exp := ret (Con_e "True" nil).
  Definition false_c : Exp := ret (Con_e "False" nil).
  Definition Z_c : Exp := ret (Con_e "0" nil).
  Definition S_c (E:Exp) : Exp := e <- E ;; ret (Con_e "S" (e::nil)).
  Definition IF_e (E1 E2 E3:Exp) : Exp :=
    e1 <- E1 ;; e2 <- E2 ;; e3 <- E3 ;;
    ret (Match_e e1 ((Con_p "True" nil, e2)::(Con_p "False" nil, e3)::nil)).
  Notation "'If' E1 'then' E2 'else' E3" := (IF_e E1 E2 E3)
    (right associativity, at level 72, E3 at next level).
  Notation "'nat_match' E 'with' 'Z' => E1 | 'S' [ x2 ] => E2" :=
    (e <- E ;; e1 <- E1 ;; n <- fresh (Some "n") ;; e2 <- (fun x2 => E2) (ret (Var_e n)) ;;
      ret (Match_e e ((Con_p "0" nil, e1) :: (Con_p "S" (n::nil), e2) :: nil)))
    (at level 72, e2 at next level).
  Definition PAIR_e (E1 E2:Exp) : Exp :=
    e1 <- E1 ;; e2 <- E2 ;; ret (Con_e "pair" (e1::e2::nil)).
  Notation "[[ e1 , e2 ]]" := (PAIR_e e1 e2).
  Definition fst' (E1:Exp) : Exp :=
    e1 <- E1 ;; a <- fresh (Some "a") ;; b <- fresh (Some "b") ;;
    ret (Match_e e1 ((Con_p "pair" (a::b::nil), Var_e a)::nil)).
  Definition snd' (E1:Exp) : Exp :=
    e1 <- E1 ;; a <- fresh (Some "a") ;; b <- fresh (Some "b") ;;
    ret (Match_e e1 ((Con_p "pair" (a::b::nil), Var_e b)::nil)).

  Definition e1 := def y := S_c Z_c in S_c y.
  Definition e2 := \ x => def x := S_c x in S_c x.
  Definition e3 := \ f => \ x => f @ x.
  Definition e4 := defrec f[x] := f @ x in f @ Z_c.
  Definition e5 := (\ x => If x then Z_c else S_c Z_c) @ false_c.
  Definition e6 := nat_match S_c (S_c Z_c) with Z => Z_c | S [y] => y.
  Definition e7 :=
    defrec plus[n] := (\m => nat_match n with Z => m | S[p] => plus @ p @ (S_c m))
    in plus.
  Definition four := S_c (S_c (S_c (S_c Z_c))).
  Definition two := S_c (S_c Z_c).
  Definition p := [[ two , four ]].
  Definition two' := fst' two.
  Definition e8 :=
    def compose := \f => \g => \x => g @ (f @ x) in
    def inc := \x => S_c x in
    defrec plus[n] :=
      nat_match n with
         Z => \m => m
       | S[p] => compose @ (plus @ p) @ inc
    in plus @ two.

   (* Eval compute in LambdaSemantics.eval_n 20 nil (gen (e8 @ two)). *)

End LambdaNotation.

