Require Import CoqCompile.Lambda.
Require Import CoqCompile.CpsK.
Require Import CoqCompile.CpsKUtil.
Require Import ExtLib.Core.RelDec.
Require Import ExtLib.Structures.Monads.
Require Import ExtLib.Structures.Maps.
Require Import ExtLib.Structures.Reducible.
Require Import List Bool ZArith String.

Set Implicit Arguments.
Set Strict Implicit.

Section cps_convert.
  Import Lambda CPSK.
  
  (** Partition pattern matching arms into three classes -- (1) those that are matching on 
     nullary constructors, (2) those matching on nary constructors for n > 0, (3) a default
     pattern that matches anything.  Used in match compilation below. *)
  Fixpoint partition' v (arms:list (Lambda.pattern * exp)) 
                        (constants:list (CpsCommon.pattern * exp))
                        (pointers:list (CpsCommon.pattern * exp)) :=
     match arms with 
       | nil => (rev constants, rev pointers, None)
       | (Lambda.Con_p c nil, e)::rest => partition' v rest ((CpsCommon.Con_p c,e)::constants) pointers
       | (Lambda.Con_p c xs, e)::rest => 
         partition' v rest constants ((CpsCommon.Con_p c,bind_proj v xs 1 e)::pointers)
       | (Lambda.Var_p x,e)::rest => (rev constants, rev pointers, Some (Let_e (Op_d x v) e))
     end.

  Definition partition v arms := partition' v arms nil nil.
  
  Section monadic.
    Variable map_var : Type -> Type.
    Context {DMap_var : DMap var map_var}.

    Variable m : Type -> Type.
    Context {Monad_m : Monad m}.
    Context {State_m : MonadState positive m}.
    Context {Reader_m : MonadReader (map_var op) m}.
    Import MonadNotation.
    Local Open Scope monad_scope.
    Local Open Scope string_scope.
    
  (** Generate a fresh variable **)
  Definition freshVar (s:option string) : m var := 
    n <- modify Psucc ;;
    ret (Env.mkVar s n).

  (** Generate a fresh variable **)
  Definition freshCont (s:string) : m cont := 
    n <- modify Psucc ;;
    ret (K s n).

  Definition withVar {T} (x : var) (v : var) : m T -> m T :=
    local (Maps.add x (Var_o v)).

  Definition freshFor (v : var) : m var :=
    n <- modify Psucc ;;
    match v with 
      | Anon_v _ => ret (Anon_v n)
      | Named_v s p => 
        ret (Named_v s (Some n))
    end.

  Definition is_eta (e : exp) (vs : list var) : option cont :=
    match e with
      | AppK_e k es => 
        if eq_dec (map Var_o vs) es then Some k else None
      | _ => None
    end.


  (** Convert a [Lambda.exp] into a CPS [exp].  The meta-level continuation [k] is used
      to build the "rest of the expression".  We work in the state monad so we can generate
      fresh variables.  In general, functions are changed to take an extra argument which
      is used as the object-level continuation.  We "return" a value [v] by invoking this
      continuation on [v]. 

      We also must lower Lambda's [Match_e] into CPS's simple Switch.  We are assuming 
      nullary constructors are represented as "small integers" that can be distinguished 
      from pointers, and that nary constructors are represented as pointers to tuples that 
      contain the constructor value in the first field, and the arguments to the 
      constructors in successive fields.  So for instance, [Cons hd tl] will turn into:
      [mkTuple_p [Cons, hd, tl]].  

      To do a pattern match on [v], we first test to see if [v] is a pointer.  If not,
      then we then use a [Switch_e] to dispatch to the appropriate nullary constructor case.
      If [v] is a pointer, then we extract the construtor tag from the tuple that v
      references.  We then [Switch_e] on that tag to the appropriate nary constructor
      case.  The cases then extract the other values from the tuple and bind them to
      the appropriate pattern variables.  
  *)
  Fixpoint cps (e:Lambda.exp) (k:op -> m exp) : m exp := 
    match e with 
      | Lambda.Var_e x => 
        x' <- asks (Maps.lookup x) ;;
        match x' with
          | None => k (Var_o x)
          | Some o => k o
        end
      | Lambda.Con_e c nil => k (Con_o c)
      | Lambda.App_e e1 e2 => 
        cps e1 (fun v1 => 
          cps e2 (fun v2 => 
            a <- freshVar (Some "a") ;; 
            e <- k (Var_o a) ;;
            match is_eta e (a :: nil) with
              | None => 
                f <- freshCont "f" ;; 
                ret (LetK_e ((f, a::nil, e) :: nil) (App_e v1 (f::nil) (v2::nil)))
              | Some c => ret (App_e v1 (c::nil) (v2::nil))
            end
          ))
      | Lambda.Con_e c es => 
        (fix cps_es (es:list Lambda.exp) (vs:list op)(k:list op -> m exp) : m exp := 
          match es with 
            | nil => k (rev vs)
            | e::es => cps e (fun v => cps_es es (v::vs) k)
          end) es nil
        (fun vs => 
          x <- freshVar (Some "x") ;;
          e <- k (Var_o x) ;;
          ret (Let_e (Prim_d x MkTuple_p ((Con_o c)::vs)) e))
      | Lambda.Let_e x e1 e2 => 
        cps e1 (fun v1 =>
          x' <- freshFor x ;;
          e2' <- withVar x x' (cps e2 k) ; 
          ret (Let_e (Op_d x' v1) e2'))
      | Lambda.Lam_e x e => 
        x' <- freshFor x ;;
        f <- freshVar (Some "f") ;;
        c <- freshCont "K" ;; 
        e' <- withVar x x' (cps e (fun v => ret (AppK_e c (v::nil)))) ; 
        e0 <- k (Var_o f) ; 
        ret (Let_e (Fn_d f (c::nil) (x'::nil) e') e0)
      | Lambda.Letrec_e fs e => 
        fs' <- mapM (fun fn => 
          match fn with 
            | (f,(x,e)) => 
              c <- freshCont "c" ;;
              x' <- freshFor x ;;
              e' <- withVar x x' (cps e (fun v => ret (AppK_e c (v::nil)))) ;;
              ret (Fn_d f (c::nil) (x'::nil) e')
          end) fs ; 
        e0 <- cps e k ; 
        ret (Letrec_e fs' e0)
      | Lambda.Match_e e arms => 
        cps e (fun v => 
          x <- freshVar (Some "x") ;; 
          e0 <- k (Var_o x) ;;
          c <- match is_eta e0 (x :: nil) with
                 | None => 
                   c <- freshCont "c" ;;
                   ret (c, fun m => LetK_e ((c, (x::nil), e0) :: nil) m)
                 | Some k =>
                   ret (k, fun m => m)
               end ;;
          let '(c,kont) := c in
          arms' <- mapM (fun p_e => 
            e' <- cps (snd (p_e)) (fun v => ret (AppK_e c (v::nil))) ;;
            ret (fst p_e, e')) arms ;;
          is_ptr <- freshVar (Some "isptr") ;;
          tag <- freshVar (Some "tag") ;; 
          let '(constant_arms, pointer_arms, def) := partition v arms' in
          m <- ret (Let_e (Prim_d is_ptr Ptr_p (v::nil))
                     (Switch_e (Var_o is_ptr)
                       ((CpsCommon.Con_p "False"%string, switch_e v constant_arms def)::
                         (CpsCommon.Con_p "True"%string, 
                           (Let_e (Prim_d tag Proj_p ((Int_o 0)::v::nil))
                             (switch_e (Var_o tag) pointer_arms def)))::nil) None)) ;;
          ret (kont m))
    end.

  End monadic.

  Import MonadNotation.
  Local Open Scope monad_scope.

  Require Import CoqCompile.CpsKIO.
  Require Import ExtLib.Data.Map.FMapAList.
  Require Import ExtLib.Data.Monads.StateMonad.
  Require Import ExtLib.Data.Monads.ReaderMonad.

  Definition CPS_pure (e:Lambda.exp) : exp := 
    let cmd : readerT (alist var op) (state positive) exp := 
      let w := InitWorld_o in
      cps e (map_var := alist var) (fun x => ret (Halt_e x w))
    in evalState (runReaderT cmd empty) 1%positive.

  Definition CPS_io (e:Lambda.exp) : exp :=
    let cmd : readerT (alist var op) (state positive) exp := 
      let w := InitWorld_o in
      cps e (map_var := alist var) (fun x => ret (IO.runIO x)) in
    let result := evalState (runReaderT cmd empty) 1%positive in
    IO.wrapIO (wrapVar "io_bind") 
              (wrapVar "io_ret")
              (wrapVar "io_printChar")
              (wrapVar "io_printCharF")
              result.

End cps_convert.
