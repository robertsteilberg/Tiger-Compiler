signature SEMANT =
sig
  type venv 
  type tenv
  type expty
  type exp

  val transProg: exp -> unit
  val transExp: venv * tenv * exp -> expty
  (* type venv = Env.enventry Symbol.table
  type tenv = Types.ty Symbol.table
  type expty = {exp: Translate.exp, ty: Types.ty}

  val transDec: venv * tenv * Absyn.dec -> {venv: venv, tenv: tenv}
  val transVar: venv * tenv * Absyn.var -> expty
  val transTy:         tenv * Absyn.ty  -> Types.ty *)
end

structure Semant : SEMANT =
struct
  structure A = Absyn
  structure T = Types
  structure S = Symbol
  structure E = Env
  type venv = Env.enventry Symbol.table
  type tenv = Types.ty Symbol.table
  type expty = {exp: Translate.exp, ty: Types.ty}
  type exp = A.exp

  fun tyEq (t1: expty, t2: expty): bool = t1 = t2
  fun tyNeq (t1: expty, t2: expty): bool = t1 <> t2

  fun checkInt ({exp=X, ty=Y}, pos) = if Y = Types.INT then ()
                                      else ErrorMsg.error pos "Expecting INT."
  
  fun intOper ({left=lexp, oper=operation, right=rexp, pos=p}, f) = case operation of
                A.PlusOp => (checkInt(f lexp, p); checkInt(f rexp, p); {exp=(), ty=Types.INT})
              | A.MinusOp => (checkInt(f lexp, p); checkInt(f rexp, p); {exp=(), ty=Types.INT})
              | A.TimesOp => (checkInt(f lexp, p); checkInt(f rexp, p); {exp=(), ty=Types.INT})
              | A.DivideOp => (checkInt(f lexp, p); checkInt(f rexp, p); {exp=(), ty=Types.INT})
              | A.EqOp => (checkInt(f lexp, p); checkInt(f rexp, p); {exp=(), ty=Types.INT})
              | A.NeqOp => (checkInt(f lexp, p); checkInt(f rexp, p); {exp=(), ty=Types.INT})
              | A.LtOp => (checkInt(f lexp, p); checkInt(f rexp, p); {exp=(), ty=Types.INT})
              | A.LeOp => (checkInt(f lexp, p); checkInt(f rexp, p); {exp=(), ty=Types.INT})
              | A.GtOp => (checkInt(f lexp, p); checkInt(f rexp, p); {exp=(), ty=Types.INT})
              | A.GeOp => (checkInt(f lexp, p); checkInt(f rexp, p); {exp=(), ty=Types.INT})

  fun checkIfExp (ty, expectedTy, p) =
    case expectedTy of
         {exp=(), ty=T.UNIT} => if tyEq(ty, {exp=(), ty=T.UNIT}) then {exp=(), ty=T.UNIT}
                   else (ErrorMsg.error p "thenExp returns values."; {exp=(),
                   ty=T.UNIT})
       | ty2 => if tyEq(ty, ty2) then ty (* TODO *)
                   else (ErrorMsg.error p "thenExp returns different types from\
                   \elseExp."; {exp=(), ty=T.UNIT})

  fun transExp(venv, tenv, exp) =
    let fun trexp exp =
      case exp of
          A.OpExp(x) => intOper (x, trexp) (*TODO fix string/array comparison*)
        | A.IntExp(num) => {exp=(), ty=Types.INT}
        | A.StringExp((s,p)) => {exp=(), ty=Types.STRING}
        | A.IfExp({test=cond, then'=thenExp, else'=elseExp, pos=p}) =>
            (case elseExp of (*TODO return value*)
                  NONE => (checkInt(trexp cond, p);
                  checkIfExp(trexp thenExp, {exp=(), ty=T.UNIT}, p))
                | SOME v => (checkInt(trexp cond, p);
                  checkIfExp(trexp thenExp, trexp v, p)))
        | A.SeqExp(x) => if List.length x = 0 then {exp=(), ty=T.UNIT}
                         else trexp (case List.last (x) of (v, pos) => v)
        | A.WhileExp{test=exp, body=exp2, pos=p} =>
            (checkInt(trexp exp, p);
            if tyNeq(trexp exp2, {exp=(), ty=T.UNIT})
            then ErrorMsg.error p "While produces values"
            else ();
            {exp=(), ty=T.UNIT})
        | A.LetExp{decs, body, pos} =>
            let val {venv=venv', tenv=tenv'} = foldl transDec {venv=venv, tenv=tenv} decs
            in
              transExp (venv', tenv', body)
            end
        | _ => (ErrorMsg.error 0 "Does not match any exp" ; {exp=(), ty=T.UNIT}) (* redundant? *)
    in
      trexp exp
    end
  and transDec(A.VarDec{name, escape=False, typ=NONE, init, pos}, {venv, tenv}) =
      let val {exp, ty} = transExp (venv, tenv, init)
      in
        {venv=S.enter(venv, name, E.VarEntry{ty=ty}), tenv=tenv}
      end


  fun transProg exp =
    let val venv = Env.base_venv
        val tenv = Env.base_tenv
    in
      (transExp(venv, tenv, exp) ;())
    end

end
