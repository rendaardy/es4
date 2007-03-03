structure LogErr = struct

fun log ss = (List.app TextIO.print ss; TextIO.print "\n")

fun error ss = log ("**ERROR** " :: ss)

fun name (n:Ast.NAME) = 
    case (#ns n) of 
        Ast.Intrinsic=> "[namespace intrinsic]::" ^ (#id n) ^ " "
      | Ast.OperatorNamespace=> "[namespace operator]::" ^ (#id n) ^ " "
      | Ast.Private i=> "[namespace private " ^ i ^ "]::" ^ (#id n) ^ " "
      | Ast.Protected i=> "[namespace protected " ^ i ^ "]::" ^ (#id n) ^ " "
      | Ast.Public i => "[namespace public " ^ i ^ "]::" ^ (#id n) ^ " "
      | Ast.Internal i => "[namespace internal " ^ i ^ "]::" ^ (#id n) ^ " "
      | Ast.UserNamespace i => "[namespace user " ^ i ^ "]::" ^ (#id n) ^ " "

fun fname (n:Ast.FIXTURE_NAME) = 
    case n of 
	Ast.TempName n => "<temp " ^ (Int.toString n) ^ ">"			  
      | Ast.PropName n => name n

fun multiname (mn:Ast.MULTINAME) = 
    case (#nss mn) of 
	[] => (String.concat ["{multiname: NO NAMESPACE :: ", (#id mn), "}"])
      | _ => String.concat
		 (["{multiname: "] @ (map String.concat
		  (List.map (List.map (fn ns => name {ns = ns, id = (#id mn)})) (#nss mn)) @
		  ["}"]))
	     
exception LexError
exception ParseError
exception NameError
exception DefnError
exception EvalError
exception MachError
exception HostError
exception UnimplError

fun lexError ss = 
    (error ("lexError " :: ss); 
     raise LexError)

fun parseError ss = 
    (error ("parseError " :: ss); 
     raise ParseError)

fun nameError ss = 
    (error ("nameError " :: ss); 
     raise NameError)

fun defnError ss = 
    (error ("defnError " :: ss); 
     raise DefnError)

fun evalError ss = 
    (error ("evalError " :: ss); 
     raise EvalError)

fun machError ss = 
    (error ("machError " :: ss); 
     raise MachError)

fun hostError ss = 
    (error ("hostError " :: ss); 
     raise HostError)

fun unimplError ss = 
    (error ("unimplError " :: ss); 
     raise UnimplError)

fun internalError ss = 
    (error ("internalError " :: ss); 
     raise UnimplError)

end
