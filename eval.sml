structure Eval = struct 

(* Exceptions for object-language control transfer. *)
exception ContinueException of (Ast.IDENT option)
exception BreakException of (Ast.IDENT option)
exception TailCallException of (unit -> Mach.VAL)
exception ThrowException of Mach.VAL
exception ReturnException of Mach.VAL
exception SemanticException of Ast.USTRING
		   
fun newName (i:Ast.IDENT) (attrs:Ast.ATTRIBUTES) =
    case attrs of 
	Ast.Attributes {ns=n, ...} => {ns=n, id=i}

                 
fun setPropertyValue (obj:Mach.OBJ) (n:Mach.NAME) (p:Mach.PROP) =
    case obj of 
	Mach.Obj ob => Mach.addBinding (#bindings ob) n p


fun extendScope (p:Mach.SCOPE) (t:Mach.SCOPE_TAG) (ob:Mach.OBJ) = 
    Mach.Scope { parent=(SOME p), tag=t, obj=ob }


fun evalExpr (scope:Mach.SCOPE) (expr:Ast.EXPR) =
    case expr of
	Ast.LexicalRef { ident } =>
        evalRefExpr scope NONE ident
      | Ast.ObjectRef { base, ident } =>
        evalRefExpr scope (SOME (evalExpr scope base)) ident
      | Ast.LetExpr {defs, body} => 
	evalLetExpr scope defs body

      | Ast.TrinaryExpr (Ast.Cond, aexpr, bexpr, cexpr) => 
	evalCondExpr scope aexpr bexpr cexpr

      | Ast.BinaryExpr (bop, aexpr, bexpr) => 
	evalBinaryOp scope bop aexpr bexpr

      | Ast.CallExpr {func, actuals} => 
	evalCallExpr 
	    (evalExpr scope func) 
	    (map (evalExpr scope) actuals)

      | _ => 
	raise (Mach.UnimplementedException "unhandled expression type")

and evalCallExpr (v:Mach.VAL) (args:Mach.VAL list) =
    let 
	val func = 
	    case v of
		Mach.Reference r => Mach.deref r
	      | _ => v
	val thisObj = 
	    case v of
		Mach.Reference (Mach.Ref {base, ...}) => base
	      | _ => Mach.globalObject
    in
	case func of 
	    Mach.Function (Mach.Fun f) => f thisObj args
	  | _ => raise (SemanticException "calling non-function type")
    end

and assignValue (base:Mach.OBJ) (name:Mach.NAME) (v:Mach.VAL) = 
    (case base of 
	 Mach.Obj {bindings,...} => 
	 if Mach.hasBinding bindings name
	 then 
	     let 
		 val existingProp = Mach.getBinding bindings name
		 val newProp = { ty = (#ty existingProp), 
				 value = v, 
				 dontDelete = (#dontDelete existingProp), 
				 dontEnum = (#dontEnum existingProp),
				 readOnly = (#readOnly existingProp) }
	     in
		 if (#readOnly existingProp)
		 then raise (SemanticException "assigning to read-only property")
		 else ();
		 (* FIXME: insert typecheck here *)
		 Mach.delBinding bindings name;
		 Mach.addBinding bindings name newProp
	     end
	 else
	     let 
		 val prop = { ty = Ast.SpecialType Ast.Any,
			      value = v,
			      dontDelete = false,
			      dontEnum = false,
			      readOnly = false }
	     in
		 Mach.addBinding bindings name prop
	     end; v)
	    
and evalBinaryOp (scope:Mach.SCOPE) (bop:Ast.BINOP) (aexpr:Ast.EXPR) (bexpr:Ast.EXPR) =
    let
	fun rval x = case x of 
                         (Mach.Reference (Mach.Ref {base=Mach.Obj {bindings,...}, name})) => 
                         (#value (Mach.getBinding bindings name))
                       | _ => x
	fun lval x = case x of 
			 Mach.Reference r => r
		       | _ => raise (SemanticException "assigning to non-lvalue")				    
	fun toNum x = Mach.toNum (rval x)
	fun toString x = Mach.toString (rval x)
	fun evalBop bop' a b =
	    let 
		fun assignWith bop'' = evalBop Ast.Assign a (evalBop bop'' a b)
	    in
		case bop' of 
		    Ast.Assign => (case lval a of 
				       Mach.Ref {base, name} => 
				       assignValue base name (rval b))
		  | Ast.AssignPlus => assignWith Ast.Plus
		  | Ast.AssignMinus => assignWith Ast.Minus
		  | Ast.AssignTimes => assignWith Ast.Times
		  | Ast.AssignDivide => assignWith Ast.Divide
		  | Ast.AssignRemainder => assignWith Ast.Remainder
		  | Ast.AssignLeftShift => assignWith Ast.LeftShift
		  | Ast.AssignRightShift => assignWith Ast.RightShift
		  | Ast.AssignRightShiftUnsigned => assignWith Ast.RightShiftUnsigned
		  | Ast.AssignBitwiseAnd => assignWith Ast.BitwiseAnd
		  | Ast.AssignBitwiseOr => assignWith Ast.BitwiseOr
		  | Ast.AssignBitwiseXor => assignWith Ast.BitwiseXor
		  | Ast.AssignLogicalAnd => assignWith Ast.LogicalAnd
		  | Ast.AssignLogicalOr => assignWith Ast.LogicalOr
		  | Ast.AssignLogicalXor => assignWith Ast.LogicalXor

		  | Ast.Plus => 
		    (case (a,b) of 
			 (Mach.Num na, Mach.Num nb) => Mach.Num (na + nb)
		       | (_,_) => Mach.Str ((toString a) ^ (toString b)))
		  | Ast.Minus => Mach.Num ((toNum a) - (toNum b))
		  | Ast.Times => Mach.Num ((toNum a) * (toNum b))
		  | Ast.Divide => Mach.Num((toNum a) / (toNum b))
		  | _ => raise (Mach.UnimplementedException "unhandled binary operator type")
	    end
    in
	evalBop bop (evalExpr scope aexpr) (evalExpr scope bexpr)
    end


and evalCondExpr (scope:Mach.SCOPE) (cond:Ast.EXPR) (consequent:Ast.EXPR) (alternative:Ast.EXPR) = 
    let 
        val v = evalExpr scope cond
        val b = Mach.toBoolean v
    in
	if b 
	then evalExpr scope consequent
	else evalExpr scope alternative
    end
    

and evalRefExpr (scope:Mach.SCOPE) (b:Mach.VAL option) (r:Ast.IDENT_EXPR) =
    case r of 
	Ast.Identifier { ident, openNamespaces } =>
	let 	    
	    val multiname : Mach.MULTINAME = { nss=(!openNamespaces), id=ident }
	    val refOpt = (case b of 
			      SOME (Mach.Object ob) => resolveOnObjAndPrototypes ob multiname
			    | NONE => resolveOnScopeChain scope multiname
			    | _ => raise (SemanticException "ref expression on non-object value"))
	in
	    case refOpt of 
		NONE => raise Mach.MultiReferenceException multiname
	      | SOME r => r
	end
      | _ => raise (Mach.UnimplementedException "unimplemented identifier expression form")
		   
and evalLetExpr (scope:Mach.SCOPE) (defs:Ast.VAR_BINDING list) (body:Ast.EXPR) = 
    let 
	val obj = Mach.newObject NONE
        val newScope = extendScope scope Mach.Let obj
    in
        List.app (addBinding obj scope) defs;
        evalExpr newScope body
    end
    
and addBinding (obj:Mach.OBJ) (scope:Mach.SCOPE) (defn:Ast.VAR_BINDING) =
    case defn of 
	(Ast.Binding { kind, init, attrs, pattern, ty }) =>
	case pattern of 
	    Ast.IdentifierPattern name => 
	    let 
		val n = newName name attrs
		val ro = case kind of 
			     Ast.Const => true
			   | Ast.LetConst => true
			   | _ => false
		val t = case ty of
			    NONE => Ast.SpecialType Ast.Any
			  | SOME e => e
		val v = case init of 
			    NONE => Mach.Undef
			  | SOME e => evalExpr scope e
		val prop = { ty = t, 
			     value = v, 
			     dontDelete = true,
			     dontEnum = true,
			     readOnly = ro } 
	    in
		setPropertyValue obj n prop
	    end
	  | _ => raise (Mach.UnimplementedException "unhandled binding form")
          
and resolveOnScopeChain (scope:Mach.SCOPE) (mname:Mach.MULTINAME) =     
    case scope of 
	Mach.Scope { parent, obj, ... } => 
	case resolveOnObjAndPrototypes obj mname of
	    NONE => (case parent of 
			 SOME p => resolveOnScopeChain p mname
		       | NONE => NONE)
	  | result => result
    
and resolveOnObjAndPrototypes (obj:Mach.OBJ) (mname:Mach.MULTINAME) = 
    case obj of 
	Mach.Obj ob => 
	case resolveOnObj obj mname of 
	    NONE => 
	    let 
		val proto = !(#prototype ob)
	    in
		case proto of 
		    NONE => NONE
                  | SOME p => resolveOnObjAndPrototypes p mname
	    end
	  | result => result

and resolveOnObj (obj:Mach.OBJ) (mname:Mach.MULTINAME) =    
    case obj of 
	Mach.Obj ob => 
	let     
	    val id = (#id mname)
	    fun tryName [] = NONE
	      | tryName (x::xs) = 
		let 
		    val n = {ns=x, id=id} 
		in
		    if Mach.hasBinding (#bindings ob) n
		    then SOME (Mach.Reference (Mach.Ref { base = obj, name = n }))
		    else tryName xs
		end
	in
	    tryName (#nss mname)
	end

and evalTailCallExpr scope e = 
    raise (TailCallException (fn _ => evalExpr scope e))

and evalNonTailCallExpr scope e = 
    evalExpr scope e
    handle TailCallException thunk => thunk ()
         | ReturnException v => v

fun labelEq stmtLabel exnLabel = 
    case (stmtLabel, exnLabel) of
	(SOME sl, SOME el) => sl = el
      | (NONE, SOME _) => false
      | (_, NONE) => true
		     
fun evalStmts (scope:Mach.SCOPE) (stmts:Ast.STMT list) = 
    (map (evalStmt scope) stmts; Mach.Undef)
		       
and evalStmt scope (stmt:Ast.STMT) = 
    case stmt of 
	Ast.ExprStmt e => evalExpr scope e
      | Ast.IfStmt i => evalIfStmt scope i
      | Ast.WhileStmt w => evalWhileStmt scope w
      | Ast.ReturnStmt r => evalReturnStmt scope r
      | Ast.BreakStmt lbl => evalBreakStmt scope lbl
      | Ast.ContinueStmt lbl => evalContinueStmt scope lbl
      | Ast.ThrowStmt t => evalThrowStmt scope t
      | Ast.LabeledStmt (lab, s) => evalLabelStmt scope lab s
      | Ast.BlockStmt b => evalBlock scope b
      | _ => raise Mach.UnimplementedException "Unimplemented statement type"

and evalDefns (scope:Mach.SCOPE) (ds:Ast.DEFN list) = 
    (map (evalDefn scope) ds; Mach.Undef)

and evalDefn (scope:Mach.SCOPE) (d:Ast.DEFN) = 
    case d of 
	Ast.FunctionDefn f => evalFuncDefn scope f    
      | _ => raise Mach.UnimplementedException "Unimplemented definition type"

and evalFuncDefn (scope:Mach.SCOPE) (f:Ast.FUNC) = 

    (* Our goal here is to convert the definition AST of the function
     * into an SML function that invokes the interpreter on the
     * function's body with a new scope. The new scope should be the
     * lexical scope of the definition augmented with bindings connecting
     * all the formals to their corresponding actuals, and a final binding
     * for the name 'this', bound to the dynamic value provided from the
     * function call site. 
     *)

    let 
	fun getType tyOpt = (case tyOpt of 
				 SOME t => t
			       | NONE => Ast.SpecialType Ast.Any)
	val func = case f of Ast.Func f' => f'
	fun funcClosure (thisObj:Mach.OBJ) (args:Mach.VAL list) = 
	    let
		val (varObj:Mach.OBJ) = Mach.newObject NONE 
		val (varScope:Mach.SCOPE) = Mach.Scope { tag = Mach.VarActivation,
							 obj = varObj,
							 parent = SOME scope }
		fun bindArgs [] [] = ()
		  (* FIXME: vastly more complex arg-binding rules actually apply. *)
		  | bindArgs [] (b::bz) = raise SemanticException "Too few actuals"
		  | bindArgs (a::az) [] = raise SemanticException "Too many actuals"
		  | bindArgs (a::az) ((Ast.Binding {ty, pattern, attrs, ...})::bz) = 
		    let 
			val formalTy = getType ty
			(* FIXME: insert typecheck here *)
			val formalName = (case (pattern, attrs) of 
					      (Ast.IdentifierPattern id,
					       Ast.Attributes attrs) => { id=id, ns=(#ns attrs) }
					    | _ => raise (Mach.UnimplementedException "Unsupported formal type"))
			val argProp = { ty = formalTy,
					value = a,
					dontDelete = true,
					dontEnum = true,
					readOnly = true }
		    in
			setPropertyValue varObj formalName argProp;
			bindArgs az bz
		    end
		    
		val thisProp = { ty = Ast.SpecialType Ast.Any,
				 value = Mach.Object thisObj,
				 dontDelete = true,
				 dontEnum = true,
				 readOnly = true }
	    in
		bindArgs args (#formals func);
		setPropertyValue varObj {id="this", ns=Ast.Private} thisProp;
		evalBlock varScope (#body func)
	    end
	val funcProp = { ty = (getType (#ty func)),
			 value = Mach.Function (Mach.Fun funcClosure),
			 dontDelete = true,
			 dontEnum = false,
			 readOnly = false }
	val funcAttrs = case (#attrs func) of Ast.Attributes a => a
	val funcName = {id=(#name func), ns=(#ns funcAttrs)}
	val scopeObj = case scope of Mach.Scope {obj, ...} => obj
    in
	setPropertyValue scopeObj funcName funcProp
    end
	
and evalBlock scope (Ast.Block{pragmas,defns,stmts}) = 
    (evalDefns scope defns;
     evalStmts scope stmts)

and evalIfStmt scope { cnd,thn,els } = 
    let 
        val v = evalExpr scope cnd 
        val b = Mach.toBoolean v
    in
        if b 
        then evalStmt scope thn
        else evalStmt scope els
    end
    
and evalLabelStmt scope lab s = 
    evalStmt scope s
    handle BreakException exnLabel 
	   => if labelEq (SOME lab) exnLabel
              then Mach.Undef 
              else raise BreakException exnLabel
			 
and evalWhileStmt scope { cond, body, contLabel } = 
    let
        fun loop (accum:Mach.VAL option)
          = let 
              val v = evalExpr scope cond
              val b = Mach.toBoolean v
          in
              if not b 
              then 
                  let
                      val curr = (SOME (evalStmt scope body)
                                  handle ContinueException exnLabel => 
					 if labelEq contLabel exnLabel
					 then NONE
					 else raise ContinueException exnLabel)
                      val next = (case curr 
                                   of NONE => accum
                                    | x => x)
                  in
                      loop next
                  end
              else
                  accum
          end
    in
        case loop NONE of
            NONE => Mach.Undef
	  | SOME v => v
    end
    
and evalReturnStmt scope e
  = raise (ReturnException (evalExpr scope e))
	  
and evalThrowStmt scope e
  = raise (ThrowException (evalExpr scope e))
	  
and evalBreakStmt scope lbl
  = raise (BreakException lbl)
	  
and evalContinueStmt scope lbl
  = raise (ContinueException lbl)
	  
end
