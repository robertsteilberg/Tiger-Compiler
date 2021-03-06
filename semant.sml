structure A = Absyn
structure T = Types
structure S = Symbol
structure E = Env
structure ERR = ErrorMsg

signature SEMANT =
sig
  type venv
  type tenv
  type expty
  type exp

  val transProg: exp -> unit
  val transExp: venv * tenv * exp -> expty
  val duplicatedDec: S.symbol list -> bool
end

structure Semant : SEMANT =
struct
  type venv = Env.enventry Symbol.table
  type tenv = Types.ty Symbol.table
  type expty = {exp: Translate.exp, ty: Types.ty}
  type exp = A.exp

  val err_rep = {exp=(),ty=T.BOTTOM}
  val error = ErrorMsg.error

  val loopCount = ref 0

  fun tyEq (t1:T.ty, t2:T.ty, pos:int): bool =
    case (t1, t2) of
         (T.RECORD(u1), T.RECORD(u2)) => (#2 u1) = (#2 u2)
       | (T.NIL,T.RECORD(_)) => true
       | (T.RECORD(_),T.NIL) => true
       | (T.RECORD(u1), _) => false
       | (_, T.RECORD(u1)) => false
       | (T.STRING, T.STRING) => true
       | (T.INT, T.INT) => true
       | (T.UNIT, T.UNIT) => true
       | (T.ARRAY(t1, u1), T.ARRAY(t2, u2)) => u1 = u2
       | (T.NIL, T.NIL) => false (* TODO *)
       | (T.NAME(n1), T.NAME(n2)) => n1 = n2
       | (T.BOTTOM, _) => true
       | (_, T.BOTTOM) => true
       | (T.NAME(_, typeOptRef), t2) => (case !typeOptRef of
                                             NONE => false
                                           | SOME t => tyEq(t, t2, pos))
       | (t1, T.NAME(_, typeOptRef)) => (case !typeOptRef of
                                             NONE => false
                                           | SOME t => tyEq(t1, t, pos))
       | (_, _) => false

  fun isSubtype(t1: T.ty, t2: T.ty) =
    (* Whether t1 is a subtype of t2 *)
    case (t1, t2) of
         (T.NIL, T.RECORD(_)) => true
       | (_, _) => false

  fun mismatchErr(typeName, pos, expected, got) =
    (error pos ("type mismatch in" ^ typeName ^ ": expected " ^ T.toString(expected) ^ " but got " ^ T.toString(got));
    err_rep)

  fun tyEqOrIsSubtype(t1: T.ty, t2: T.ty, pos:int) =
    (* true if t1 is a subtype of t2 or t1 is of same type with t2 *)
    isSubtype(t1, t2) orelse tyEq(t1, t2, pos)

  fun tyNeq (t1: T.ty, t2: T.ty, pos:int): bool = not (tyEq(t1, t2, pos))

  fun isInt (ty:T.ty, pos) = tyEq(ty,T.INT,pos)

  fun duplicatedDec [] = false
    | duplicatedDec (x::xs) = List.exists (fn newV => newV = x) xs
                              orelse duplicatedDec xs

  fun recordTyGenerator (tyList: A.field list, tenvRef: tenv ref) : T.ty =
    let
      fun lookUpTy {name, escape, typ, pos} = case S.look(!tenvRef, typ) of
                       SOME v => (name, v)
                     | NONE => (error 0 ("Cannot find: " ^ S.name(typ));
                                (name, T.BOTTOM))
    in
      T.RECORD((fn () => map lookUpTy tyList, ref ()))
    end

  fun tyCheckArrayExp (arrSym, tenv: tenv, typeSize: expty, typeInit: expty, pos) =
    let
      val elementType: T.ty =
        case S.look(tenv, arrSym) of
             SOME (T.ARRAY(t)) => #1 t
           | SOME otherType => ("error: " ^ S.name(arrSym) ^ " is not an array"; T.BOTTOM)
           | NONE => (error pos ("cannot find type: " ^ S.name(arrSym)); T.BOTTOM)
        val arrType = S.look(tenv, arrSym)
        val isIndexInt = tyEq(#ty typeSize, T.INT, pos)
        val defaultValueRightType = tyEq(elementType,  #ty typeInit, pos)
    in
      (case (isIndexInt, defaultValueRightType, arrType) of
             (true, true, SOME v) => {exp=(), ty=v}
          | (false, _, _) => (error pos "ArrayIndexTypeError";
                              {exp=(), ty=T.BOTTOM})
          | (_, false, _) => (mismatchErr("Array", pos, #ty typeInit, elementType);
                              {exp=(), ty=T.BOTTOM})
          | (_, _, NONE) => (error pos "Cannot find type of the array";
                              {exp=(), ty=T.BOTTOM}))
    end

  fun containsTy (fieldTy: A.symbol * A.pos, allTypes: tenv * A.symbol list): bool =
    let
      fun eqSymbol (item1: A.symbol) (item2: A.symbol) = item1 = item2
      val (tenv, newTypes) = allTypes
      val (sym, pos) = fieldTy
      val foundInNewTypes = case List.find (eqSymbol sym) newTypes of
                               NONE => false
                             | SOME v => true
      val foundInTENV = case S.look(tenv, sym) of
                             SOME v => true
                           | NONE => false
    in
      foundInNewTypes orelse foundInTENV
    end

  fun tyCheckRecordTy(fields, allTypes) =
    let
      fun checkEachField allTypes ({name, escape, typ, pos}, allCorrect:bool): bool =
        let
          val typeFound = containsTy((typ, pos), allTypes)
        in
          allCorrect andalso typeFound
        end
    in
      foldl (checkEachField allTypes) true fields
    end

  fun filterAndPrint f [] = []
    | filterAndPrint f (x::xs:{name: A.symbol, ty: A.ty, pos: A.pos} list) =
      if f(x) then x::(filterAndPrint f xs)
      else (
      error (#pos x) ("TypeDecError in for type:" ^ S.name (#name x));
      filterAndPrint f xs
      )

  fun tyCheckTypeDec(tenvRef, tylist: {name: A.symbol, ty: A.ty, pos: A.pos} list) =
    let
      val newTypes = map (fn r => #name r) tylist
      val allTypes = (!tenvRef, newTypes)
      fun isLegal allTypes {name, ty, pos} =
        let
        in
          (case ty of
                A.NameTy(nameTy) => containsTy(nameTy, allTypes)
              | A.RecordTy(recordTy) => tyCheckRecordTy(recordTy, allTypes)
              | A.ArrayTy(arrTy) => containsTy(arrTy, allTypes)
          )
        end
      val legalTypes = filterAndPrint (isLegal allTypes) tylist
    in
      case tylist = legalTypes of
           true => tylist (* stop updating; return the value *)
         | false => tyCheckTypeDec(tenvRef, legalTypes)
    end

  fun updateTenv(tenvRef: tenv ref, legalTylist):tenv =
    (* This function add legalTylist to tenv
    *
    * After passing tylist to tyCheckTypeDec, we gain legalTylist where
    * we are ready to add these legal types to tenv.
    * *)
    let fun helper tenvRef ({name, ty, pos}) =
      (case ty of
          A.NameTy(nameTy) => (tenvRef := S.enter(!tenvRef,
                                      name,
                                      T.NAME((#1 nameTy), ref (S.look(!tenvRef, (#1
                                      nameTy))))))
        | A.ArrayTy(arrTy) => (tenvRef := S.enter(!tenvRef,
                                      name,
                                      T.ARRAY(valOf(S.look(!tenvRef, #1 arrTy)),
                                      (ref ()))))
        | A.RecordTy(recordTy) => (tenvRef := S.enter(!tenvRef,
                                          name,
                                          recordTyGenerator(recordTy, tenvRef))))
    in
      (map (helper tenvRef) legalTylist; !tenvRef)
    end


  fun checkOp (expLeft:expty, expRight:expty, oper: A.oper, pos: int) =
        let
          fun compareErr(t1, t2) = (error pos
            ("type mismatch: cannot compare " ^ t1 ^ " with " ^ T.toString(t2));
            err_rep)
          fun illegalOpErr(oper, t2) = (error pos
            ("illegal operation: cannot perform " ^ oper ^ " on " ^ T.toString(t2)); err_rep)
          val tyLeft = (#ty expLeft)
          val tyRight = (#ty expRight)

          fun checkArithOp() =
            if not (isInt(tyLeft,pos))
            then illegalOpErr("+-/*", tyLeft)
            else if not (isInt(tyRight,pos))
            then illegalOpErr("+-/*", tyLeft)
            else {exp=(), ty=T.INT}

          fun checkCompOp() =
            case tyLeft of
              T.INT => if tyEq(T.INT, tyRight, pos)
                       then {exp=(), ty=T.INT}
                       else (compareErr("int", tyRight); err_rep)
            | T.STRING => if tyEq(T.STRING, tyRight, pos)
                          then {exp=(), ty=T.INT}
                          else compareErr("string", tyRight)
            | _ => (error pos ("type mismatch: cannot check comparison with " ^ T.toString(tyLeft));
                    err_rep)

          fun checkEqOp() =
            case tyLeft of
              T.INT => if tyEq(T.INT, tyRight, pos)
                       then {exp=(), ty=T.INT}
                       else (error pos ("type mismatch: cannot compare int with " ^ T.toString(tyRight));
                             err_rep)
            | T.STRING => if tyEq(T.STRING, tyRight, pos)
                          then {exp=(), ty=T.INT}
                          else (error pos ("type mismatch: cannot compare string with " ^ T.toString(tyRight));
                                err_rep)
            | T.ARRAY(ty,u) => if tyEq(T.ARRAY(ty,u), tyRight, pos)
                               then {exp=(), ty=T.INT}
                               else ((case tyRight of
                                         T.ARRAY(_,_) => error pos ("error: cannot compare arrays of different types")
                                       | t => error pos ("error: cannot compare array with " ^ T.toString(t)));
                                     err_rep)
            | T.RECORD(fields,u) => if tyEq(T.RECORD(fields,u), tyRight, pos)
                                    then {exp=(), ty=T.INT}
                                    else ((case tyRight of
                                              T.RECORD(_,_) => error pos ("error: cannot compare two different record types")
                                            | t => error pos ("error: cannot compare record with " ^ T.toString(t)));
                                          err_rep)
            | _ => (error pos ("error: cannot check equality with " ^ T.toString(tyLeft));
                    err_rep)
        in
          case oper of
            A.PlusOp => (checkArithOp())
          | A.MinusOp => (checkArithOp())
          | A.TimesOp => (checkArithOp())
          | A.DivideOp => (checkArithOp())
          | A.LtOp => (checkCompOp())
          | A.LeOp => (checkCompOp())
          | A.GtOp => (checkCompOp())
          | A.GeOp => (checkCompOp())
          | A.EqOp => (checkEqOp())
          | A.NeqOp => (checkEqOp())
        end

    fun getHeader tenv {name=nameFun, params, result, body, pos}: S.symbol *
      E.enventry *bool =
      let
        fun foldHelper ({name=nameVar, escape, typ, pos}, ans): T.ty list =
          case ans of
               [T.BOTTOM] => [T.BOTTOM]
             | tyList => (case S.look(tenv, typ) of
                             NONE => (error pos ("cannot find " ^ S.name(typ) ^
                             " in the header of " ^ S.name(nameFun)); [T.BOTTOM])
                           | SOME v => v::tyList)
        val formals = foldl foldHelper [] params
        val returnType = case result of
                            NONE => T.UNIT
                          | SOME (sym, pos) =>
                             (case S.look(tenv, sym) of
                                  SOME t => t
                                | NONE => (error pos ("cannot find the return type " ^ S.name(sym)); T.BOTTOM))
        val badHeader = case (formals, returnType) of
                             (_, T.BOTTOM) => true
                           | ([T.BOTTOM], _) => true
                           | _ => false
      in
        (nameFun, E.FunEntry{formals=formals, result=returnType}, badHeader)
      end

    fun addHeaders(headerList, venv): venv * bool =
      let fun helper(header, (venv, broken)) =
            case (header, broken) of
                 ((_, _, true), _) => (venv, true)
               |(_, true) => (venv, true)
               | ((name, funEntry, false), false) =>
                   (S.enter(venv, name, funEntry), false)
      in
        foldl helper (venv, false) headerList
      end

  fun transExp(venv, tenv: tenv, exp) =
    let
      fun trexp exp =
        case exp of
            A.VarExp(var) => trvar(var)
          | A.NilExp => {exp=(), ty=T.NIL}
          | A.IntExp(num) => {exp=(), ty=Types.INT}
          | A.StringExp((str,pos)) => {exp=(), ty=Types.STRING}
          | A.CallExp({func,args,pos}) =>
              (case S.look(venv,func) of
                SOME(E.FunEntry({formals,result})) =>
                    let
                      val numFormals = length(formals)
                      val numArgs = length(args)
                      fun tyEqList(l1:T.ty list, l2:T.ty list) =
                        if List.null(l1)
                        then {exp=(),ty=result}
                        else (case tyEq((hd l1), (hd l2), pos) of
                               false => (mismatchErr("function param", pos, (hd l1), (hd l2));
                                         {exp=(), ty=T.BOTTOM})
                             | true => tyEqList((tl l1), (tl l2)))
                    in
                      if numFormals <> numArgs
                      then (error pos ("error: " ^ Int.toString(numFormals) ^ " args needed but only " ^ Int.toString(numArgs) ^ " provided");
                            {exp=(), ty=T.BOTTOM})
                      else tyEqList(map #ty (map trexp args), formals)
                    end
               | _ => (error pos ("error: function " ^ S.name(func) ^ " not defined");
                       {exp=(), ty=T.BOTTOM}))
          | A.OpExp({left,oper,right,pos}) => checkOp(trexp(left),trexp(right),oper,pos)
          | A.RecordExp{fields,typ,pos} =>
              let
                val fieldTypes = map (fn (sym, exp, pos) => (sym, #ty (transExp(venv, tenv, exp)), pos)) fields
                fun checkFields(x::xs: (S.symbol*T.ty*int) list, y::ys: (S.symbol*T.ty) list, recFunc, unique) =
                      if S.name(#1 x) = S.name(#1 y)
                      then if tyEqOrIsSubtype(#2 x, #2 y, pos)
                           then checkFields(xs, ys, recFunc, unique)
                           else (error pos ("field type mismatch: expected " ^ T.toString (#2 y) ^ " but got " ^ T.toString (#2 x)); err_rep)
                      else (error pos ("field name mismatch: expected " ^ S.name(#1 y) ^ " but got " ^ S.name(#1 x)); err_rep)
                  | checkFields([], [], recFunc, unique) = {exp=(), ty=T.RECORD(recFunc,unique)}
                  | checkFields(_,_,_,_) = err_rep
              in
                case S.look(tenv, typ) of
                    SOME v => (case v of
                                  T.RECORD (r, u) => checkFields(fieldTypes, r(), r, u)
                                | _ => (error pos ("type mismatch: expected record but got " ^ T.toString v); err_rep))
                  | NONE => (error pos ("error: record of type " ^ S.name typ ^ " not found");
                             err_rep)
              end
          | A.IfExp({test,then',else',pos}) =>
              let
                val {exp=testExp,ty=testTy} = trexp(test)
                val {exp=thenExp,ty=thenTy} = trexp(then')
              in
                case else' of
                  NONE => if not (isInt(testTy,pos))
                          then (error pos ("type mismatch: test expression must be int, not " ^ T.toString(testTy));
                               err_rep)
                          else if tyEq(thenTy,T.UNIT,pos)
                          then {exp=(),ty=T.UNIT}
                          else (error pos ("error: then expression must return unit, not " ^ T.toString(thenTy));
                                err_rep)
                | SOME (e) =>
                    let
                      val {exp=elseExp,ty=elseTy} = trexp(e)
                    in
                      if not (isInt(testTy,pos))
                      then (error pos ("type mismatch: test expression must be int, not " ^ T.toString(testTy));
                           err_rep)
                      else if tyEq(thenTy,elseTy,pos)
                      then {exp=(),ty=T.UNIT}
                      else (error pos ("type mismatch: " ^ T.toString(thenTy) ^ " and " ^ T.toString(elseTy));
                            err_rep)
                    end
              end
          | A.SeqExp(exps) => (map (fn (exp,_) => (trexp exp)) (rev (tl (rev exps)));
                              if List.null(exps) then {exp=(), ty=T.UNIT}
                              else trexp (case List.last(exps) of (expr, pos) => expr))
          | A.AssignExp({var,exp,pos}) =>
              let
                val varType = #ty (trvar(var))
                val expType = #ty (trexp(exp))
              in
                if tyEqOrIsSubtype(expType, varType, pos)
                then {exp=(),ty=T.UNIT}
                else (error pos ("type mismatch: cannot assign " ^ T.toString(expType) ^ " to var of " ^ T.toString(varType));
                      err_rep)
              end

          | A.WhileExp({test,body,pos}) =>
              (loopCount := !loopCount + 1;
              let
                 val {exp=testExp,ty=testTy} = trexp(test)
                 val {exp=bodyExp,ty=bodyTy} = trexp(body)
              in
                if not (isInt(testTy,pos))
                then (error pos ("type mismatch: test expression must be int, not " ^ T.toString(testTy));
                      err_rep)
                else if tyEq(bodyTy,T.UNIT,pos)
                then (loopCount := !loopCount - 1; {exp=(),ty=T.UNIT})
                else (error pos ("error: while body must eval to unit, not " ^ T.toString(bodyTy));
                      err_rep)
              end)
          | A.ForExp({var,escape,lo,hi,body,pos}) =>
            (loopCount := !loopCount + 1;
            let
              val loTy = #ty (trexp(lo))
              val hiTy = #ty (trexp(hi))
              val {venv=venv', tenv=_} = transDec(A.VarDec({name=var,typ=SOME(Symbol.symbol "int",pos),init=lo,pos=pos,escape=escape}),{tenv=tenv,venv=venv})
              val bodyTy = #ty (transExp(venv', tenv, body))
            in
              if not (isInt(loTy,pos))
              then (error pos ("error: for loop var type must be int, not " ^ T.toString(loTy));
                    err_rep)
              else if not (isInt(hiTy,pos))
              then (error pos ("error: for limit var type must be int, not " ^ T.toString(hiTy));
                    err_rep)
              else if not (tyEq(bodyTy,T.UNIT,pos))
              then (error pos ("error: for body must eval to unit, not " ^ T.toString(bodyTy));
                    err_rep)
              else (loopCount := !loopCount - 1; {exp=(),ty=T.UNIT})
            end)
          | A.BreakExp(pos) => if !loopCount = 0
                             then (error pos ("error: illegal break"); err_rep)
                             else {exp=(),ty=T.UNIT}
          | A.LetExp({decs,body,pos}) =>
              let val {venv=venv', tenv=tenv'} = foldl transDec {venv=venv, tenv=tenv} decs
              in
                transExp (venv', tenv', body)
              end
          | A.ArrayExp{typ, size, init, pos} =>
              let
                val {exp=_,ty=sizeType} = trexp size
                val {exp=_,ty=initType} = trexp init
                val (arrayTy,unique) =
                  case S.look(tenv, typ) of
                       SOME (T.ARRAY(t,u)) => (t,u)
                     | SOME(x) => (error pos ("type mismatch: expected array but got " ^ T.toString(x)); (T.BOTTOM, ref ()))
                     | NONE => (error pos ("type mismatch: no such array type found "); (T.BOTTOM, ref ()))
                  val indexIsInt = tyEq(sizeType, T.INT, pos)
                  val initTypeCorrect = tyEq(arrayTy, initType, pos)
              in
                  if indexIsInt
                  then if initTypeCorrect
                       then {exp=(),ty=Types.ARRAY(arrayTy,unique)}
                       else mismatchErr ("array initialization value", pos, arrayTy, initType)
                  else mismatchErr ("array size", pos, T.INT, sizeType)
              end
        and trvar (A.SimpleVar(varname,pos)) =
          (case Symbol.look (venv, varname) of
                NONE => (error pos ("undefined variable " ^ Symbol.name varname);
                {exp=(), ty=T.BOTTOM})
              | SOME (Env.VarEntry {ty}) => {exp=(), ty=ty}
              | SOME _ => (error pos ("expected var but got fun");
                          {exp=(), ty=T.BOTTOM}))
          | trvar (A.SubscriptVar(var,indexExp,pos)) = (* var is the array, exp is the index *)
              let
                val {exp,ty} = trvar(var)
              in
                case ty of
                  T.ARRAY(t,_) =>(
                    let
                      val {exp=subExp,ty=subTy} = trexp(indexExp)
                    in
                      if tyEq(subTy, T.INT, pos)
                      then {exp=(),ty=t}
                      else (error pos
                            ("error: array can only be indexed with int, but found " ^
                             T.toString(subTy));
                             {exp=(),ty=T.BOTTOM})
                    end)
                | otherTy => (error pos ("type mismatch: replace " ^
                T.toString(otherTy) ^ " with array"); {exp=(),ty=T.BOTTOM})
              end
          | trvar (A.FieldVar(var,fieldname,pos)) = (* var is the record *)
              let
                val {exp,ty} = trvar(var)
              in
                case ty of
                  T.RECORD(fieldlist,_) =>
                    (case List.find (fn field => (#1 field) = fieldname) (fieldlist()) of
                      NONE => (error pos ("error: field " ^ S.name(fieldname) ^ " not found");
                              {exp=(), ty=T.BOTTOM})
                    | SOME(field) => {exp=(), ty=(#2 field)})
                | ty => (error pos ("error: expected record but got " ^ T.toString(ty));
                        {exp=(), ty=T.BOTTOM})
              end
    in
      trexp exp
    end

  and transDec

  (A.VarDec{name, escape=ref True, typ=NONE, init, pos}, {venv, tenv}) =
    (case init of
              A.NilExp => (error pos "NIL is not allowed without specifying types in variable declarations";
            {venv=venv, tenv=tenv})
            | otherExp => let val {exp, ty} = transExp (venv, tenv, otherExp)
                          in {venv=S.enter(venv, name, E.VarEntry{ty=ty}), tenv=tenv}
                          end)
    | transDec(A.VarDec{name, escape=ref True, typ=SOME (symbol,p), init, pos},
        {venv, tenv}) =
          let val {exp, ty=tyInit} = transExp (venv, tenv, init)
              val isSameTy = case S.look(tenv, symbol) of
                                NONE => (error pos ("cannot find the type:"
                                ^ S.name(symbol)); false)
                              | SOME t => tyEqOrIsSubtype(tyInit, t, pos)
          in
            (if isSameTy
             then {venv=S.enter(venv, name, E.VarEntry{ty=valOf(S.look(tenv, symbol))}), tenv=tenv}
             else (error pos ("tycon mistach"); {venv=venv, tenv=tenv}))
          end




   | transDec(A.TypeDec(tylist), {venv, tenv}) =
      let
        val containDup = duplicatedDec(map (fn r => #name r) tylist)
      in
        case containDup of
             true => (error (#pos (hd tylist)) "error: duplicated type definition";
                     map (fn r => print (S.name(#name r) ^ "\n")) tylist;
                   {venv=venv, tenv=tenv})
           | false => {venv=venv, tenv=updateTenv(ref tenv, tyCheckTypeDec(ref tenv, tylist))}
      end
   | transDec(A.FunctionDec(fundecList), {venv, tenv}) =
       checkFunctionDec(fundecList, {venv=venv, tenv=tenv})
  and checkFunctionDec(fundecList, {venv, tenv}) =
    let
      val headerList = map (getHeader tenv) fundecList
      val (venv', badHeader) = addHeaders(headerList, venv)
    in
      case badHeader of
           true => (error (#pos (hd fundecList)) "error in function header";
           {venv=venv, tenv=tenv})
         | false => (case checkEachFundec(fundecList, {venv=venv', tenv=tenv}, headerList) of
                        true => {venv=venv', tenv=tenv}
                      | false => (error (#pos (hd fundecList)) "function declaration return type is incorrect";{venv=venv, tenv=tenv} ))
    end
   and checkEachFundec(fundecList: A.fundec list,
                       {venv, tenv},
                       headerList: (Symbol.symbol * Env.enventry * bool) list): bool =
    let
      fun checkFundec {venv: venv, tenv: tenv} ((fundec, header), false) = false
        | checkFundec {venv: venv, tenv: tenv} ((fundec, header), true) =
            let
              fun addVar(fieldList): venv =
                 let fun helper ({name, escape, typ, pos}, table) =
                   S.enter(table, name, E.VarEntry{ty=valOf(S.look(tenv, typ))})
                 in
                   foldl helper venv fieldList
                 end
              val {name, params, result, body, pos} = fundec
              val (nameFun, E.FunEntry{formals, result=expectedType}, badHeader) = header
              val venvNew = addVar params
              val t =  transExp(venvNew, tenv, body)
            in
               case tyEq(#ty t, expectedType, pos) of
                    true => true
                  | false => (mismatchErr("function parameter", pos, #ty t, expectedType);
                              false)
            end
    in
      foldl (checkFundec {venv=venv, tenv=tenv}) true (ListPair.zip(fundecList, headerList))
    end

  fun transProg exp =
    let val venv = Env.base_venv
        val tenv = Env.base_tenv
    in
      (transExp(venv, tenv, exp) ;())
    end

end
