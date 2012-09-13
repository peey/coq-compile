Require Import Lambda.
Require Import String List.
Require Import ExtLib.Monad.Monad.
Require Import ExtLib.Monad.OptionMonad ExtLib.Monad.StateMonad ExtLib.Monad.ContMonad.
Require Import ExtLib.Monad.Folds.
Require Import ExtLib.Data.Strings.
Require Import ExtLib.Decidables.Decidable.

Set Implicit Arguments.
Set Strict Implicit.

Module CPS.
  Definition var := Lambda.var.
  Definition constructor := Lambda.constructor.
  Definition pattern := Lambda.pattern.
  Definition env_t := Lambda.env_t.

  Inductive op : Type := 
  | Var_o : var -> op
  | Con_o : constructor -> op.

  Inductive exp : Type := 
  | App_e : op -> list op -> exp
  | Let_e : var -> constructor -> list op -> exp -> exp
  | Match_e : op -> list (pattern * exp) -> exp
  | Letrec_e : env_t (list var * exp) -> exp -> exp.

  Definition K (Ans : Type) := contT Ans (state nat).

  Hint Transparent K : typeclass_instances.

  Local Open Scope string_scope.
  Import MonadNotation.

  (** Get a fresh temporary variable **)
  Definition freshTemp {Ans} (x:string) : K Ans var :=
    n <- lift (LambdaNotation.fresh x) ;
    ret ("$" ++ n).

  (** apply [f] before returning the result of [k] **)
  Definition plug (f : exp -> exp) (x : op) : K exp op :=
    mapContT (liftM f) (ret x).

  Notation "f [[ x ]]" := (plug f x) 
    (at level 84).

  Definition LetLam_e (f:var) (xs: list var) (e:exp) (e':exp) : exp := 
    Letrec_e ((f,(xs,e))::nil) e'.

  Definition match_eta (x:var) (e:exp) := 
    match e with 
      | App_e op1 ((Var_o y)::nil) => 
        if rel_dec y x then Some op1 else None
      | _ => None
    end.

  Definition App_k (v1 v2:op) : K exp op :=
    a <- freshTemp "a" ; 
    f <- freshTemp "f" ; 
    mapContT (fun c =>
      e <- c ;
      ret match match_eta a e with
            | None => LetLam_e f (a::nil) e (App_e v1 (v2::(Var_o f)::nil))
            | Some op => App_e v1 (v2::op::nil)
          end) (ret (Var_o a)).

  (** run to an exp, the [e] making it call the continuation [c] when done **)
  Definition run (e:K exp op) (c : var) : state nat exp :=
    runContT e (fun v => ret (App_e (Var_o c) (v::nil))).

  Fixpoint cps (e:Lambda.exp) : K exp op :=
    match e with 
      | Lambda.Var_e x => ret (Var_o x)
      | Lambda.Con_e c nil => ret (Con_o c)
      | Lambda.App_e e1 e2 => 
        v1 <- cps e1 ; v2 <- cps e2 ; App_k v1 v2
      | Lambda.Con_e c es => 
        ops <- mapM cps es ;
        x <- freshTemp "x" ; 
        (Let_e x c ops [[ Var_o x ]])
      | Lambda.Let_e x e1 e2 => 
        v1 <- cps e1 ;
        mapContT (fun c2 => 
          e2' <- c2 ;
          ret (Match_e v1 ((Lambda.Var_p x, e2')::nil))) (cps e2)
      | Lambda.Lam_e x e => 
        f <- freshTemp "f" ; 
        c <- freshTemp "c" ;
        e' <- lift (run (cps e) c) ;
        (LetLam_e f (x::c::nil) e' [[ Var_o f ]])
      | Lambda.Letrec_e fs e => 
        fs' <- mapM (fun fn => 
                      match fn with 
                        | (f,(x,e)) => 
                          c <- freshTemp "c" ; 
                          e' <- lift (run (cps e) c) ;
                          ret (f,(x::c::nil,e'))
                      end) fs ;
        v <- cps e ; 
        (Letrec_e fs' [[ v ]])
      | Lambda.Match_e e arms =>  
        v <- cps e ; 
        c <- freshTemp "c" ; 
        x <- freshTemp "x" ;
        arms' <- lift (mapM (fun p_e => 
                              e' <- run (cps (snd p_e)) c ; 
                              ret (fst p_e, e')) arms) ;
        mapContT (fun cc : state nat exp => 
                    z <- cc ; 
                    ret (LetLam_e c (x :: nil) z (Match_e v arms'))) (ret (Var_o x))
    end.
  
  Definition CPS (e:Lambda.exp) : exp := 
    evalState (runContT (cps e) (fun v => ret (App_e (Var_o "halt") (v::nil)))) 0.

  (** Pretty Printing CPS terms *)
  Definition op2string (v:op) : string := 
    match v with 
      | Var_o x => x
      | Con_o c => c
    end.

  Fixpoint spaces (n:nat) : string := 
    match n with
      | 0 => ""
      | S n => " " ++ (spaces n)
    end.

  Definition indent_by : nat := 2.

  Definition emit (s:string) : state (list string) unit := 
    sofar <- get ; 
    put (s::sofar).

  Fixpoint indent (n:nat) : state (list string) unit := 
    match n with 
      | 0 => ret tt
      | S n => emit " ";; indent n
    end.

  Fixpoint emit_list{A}(f:A->string)(vs:list A) : state (list string) unit := 
    match vs with 
      | nil => ret tt
      | v::nil => emit (f v) 
      | v::vs => emit (f v) ;; emit "," ;; emit_list f vs
    end.

  Definition emitpat(p:pattern) : state (list string) unit := 
    match p with 
      | Lambda.Var_p x => emit x
      | Lambda.Con_p c nil => emit c
      | Lambda.Con_p c xs => 
        emit c ;; emit "(" ;; emit_list (fun x => x) xs ;; emit ")"
    end.

  Section ITER.
    Context {S A:Type}.
    Variable f : A -> state S unit.

    Fixpoint iter (xs:list A) : state S unit := 
    match xs with 
      | nil => ret tt
      | h::t => f h ;; iter t
    end.
  End ITER.

  Definition newline : string := (String (Ascii.ascii_of_nat 10) EmptyString).

  Fixpoint emitcps(n:nat)(e:exp) : state (list string) unit := 
    indent n ;;
    match e with 
      | App_e v vs => 
        emit (op2string v) ;;
        emit "(" ;; emit_list op2string vs ;; emit ")" ;; emit newline 
      | Let_e x c vs e => 
        emit "let " ;; emit x ;; emit " = " ;; 
        emit c ;; emit "(" ;; emit_list op2string vs ;; emit ") in" ;; emit newline ;;
        emitcps (n + 2) e
      | Match_e v arms => 
        emit "match " ;; emit (op2string v) ;; emit " with" ;; emit newline ;;
        iter (fun (arm : pattern * exp) => 
          let (p,e) := arm in 
            indent n ;; emit "| ";; emitpat p ;; emit " => ";; emit newline ;; emitcps (2+n) e
        ) arms ;; 
        indent n ;; emit "end" ;; emit newline
      | Letrec_e fns e => 
        emit "letrec " ;; 
        iter (fun fn => 
          match fn with 
            | (f,(xs,e)) => 
              emit f ;; emit "(" ;; emit_list (fun x => x) xs ;; emit ") = " ;; emit newline ;;
              emitcps (n+8) e
          end) fns ;;
        indent n ;; emit "in " ;; emit newline ;; emitcps (n+2) e
    end.

  Definition cps2string(e:exp) := 
    newline ++ List.fold_left (fun x y => y ++ x) (snd (runState (emitcps 0 e) nil)) "".
        
  Eval compute in cps2string (CPS (LambdaNotation.gen LambdaNotation.e8)).

End CPS.
