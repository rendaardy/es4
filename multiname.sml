(* -*- mode: sml; mode: font-lock; tab-width: 4; insert-tabs-mode: nil; indent-tabs-mode: nil -*- *)

(* The Multiname Algorithm *)

structure Multiname = struct

fun resolveMultiname (mname:Ast.MULTINAME)
		     (curr:'a)
		     (nameExists:(('a, Ast.NAME) -> bool))
		     (getParent:('a -> ('a option)))
    : (Ast.NAME * 'a) option =
    let     
        val _ = LogErr.trace ["resolving multiname ", LogErr.multiname mname]
        val id = (#id mname)
		 
        (* Try each namespace in the set and accumulate matches. *)
		 
        fun tryName (matches:Ast.NAME list) [] = matches
          | tryName (matches:Ast.NAME list) (x::xs) : Ast.NAME list =
            let 
                val n = { ns=x, id=id } 
                val _ = LogErr.trace ["trying name ", LogErr.name n]
            in
                if nameExists (curr, n)
                then tryName (n::matches) xs
                else tryName matches xs
            end
        (*
	 * Try each of the nested namespace sets in turn to see
         * if there is a match. Raise an exception if there is
         * more than one match. Continue up to "parent" 
         * if there are none 
	 *)
	    
        fun tryMultiname [] = NONE  
          | tryMultiname (x::xs:Ast.NAMESPACE list list) : Ast.NAME option = 
            let 
                val matches = tryName [] x
            in case matches of
                   n :: [] => SOME n
                 | [] => tryMultiname xs
                 | _  => LogErr.nameError ["ambiguous reference ", 
					   LogErr.multiname mname]
            end
    in
        case tryMultiname (#nss mname) of
            SOME n => SOME (n, curr)
          | NONE => 
	    (case getParent curr of
		 NONE => LogErr.nameError ["exhausted search for ", 
					   LogErr.multiname mname]
	       | SOME parent => resolveMultiname mname 
						 parent 
						 nameExists 
						 getParent)
    end
end

