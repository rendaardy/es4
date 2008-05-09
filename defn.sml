(* -*- mode: sml; mode: font-lock; tab-width: 4; insert-tabs-mode: nil; indent-tabs-mode: nil -*- *)
(*
 * The following licensing terms and conditions apply and must be
 * accepted in order to use the Reference Implementation:
 *
 *    1. This Reference Implementation is made available to all
 * interested persons on the same terms as Ecma makes available its
 * standards and technical reports, as set forth at
 * http://www.ecma-international.org/publications/.
 *
 *    2. All liability and responsibility for any use of this Reference
 * Implementation rests with the user, and not with any of the parties
 * who contribute to, or who own or hold any copyright in, this Reference
 * Implementation.
 *
 *    3. THIS REFERENCE IMPLEMENTATION IS PROVIDED BY THE COPYRIGHT
 * HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
 * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
 * OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN
 * IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * End of Terms and Conditions
 *
 * Copyright (c) 2007 Adobe Systems Inc., The Mozilla Foundation, Opera
 * Software ASA, and others.
 *)

structure Defn = struct

(* Local tracing machinery *)

val doTrace = ref false
val doTraceSummary = ref false
fun log ss = LogErr.log ("[defn] " :: ss)
fun error ss = LogErr.defnError ss
fun trace ss = if (!doTrace) then log ss else ()
fun trace2 (s, us) = if (!doTrace) then log [s, (Ustring.toAscii us)] else ()

fun fmtName n = if (!doTrace) then LogErr.name n else ""
fun fmtNs n = if (!doTrace) then LogErr.namespace n else ""

(* 
 * We use a globally unique numbering of type variables, assigned once when
 * we walk the AST during definition. They are inserted in any ribs formed
 * under a type binder. This includes the activation rib of any type-parametric
 * function, the instance rib of any type-parametric interface or class, and
 * -- depending on how we resolve the interaction of type parameters and 
 * class objects -- possibly the class rib of any type-parametric class.
 * 
 * We do not insetrt them anywhere in type terms, because those have no ribs.
 *)

val typeVarCounter = ref 0
fun mkTypeVarFixture _ = 
    (typeVarCounter := (!typeVarCounter) + 1;
     Ast.TypeVarFixture (!typeVarCounter))

fun mkParamRib (idents:Ast.IDENTIFIER list)
  : Ast.RIB = 
    map (fn id => (Ast.PropName (Name.public id), (mkTypeVarFixture()))) idents

(*
 * The goal of the definition phase is to put together the ribs
 * of the program, as well as insert class, function and interface
 * objects into the global object.

    To be specific, the definition phase completes the following tasks:
    - fold type expressions
    - translate defnitions to rib + initialisers
    - check for conflicting fixtures
    - hoist rib
    - inherit super classes and interfaces
    - evaluate pragmas
    - capture open namespaces in unqualified identifiers

    TODO
    - fold types
    - inheritance checks
 *)


datatype LABEL_KIND =
          IterationLabel
        | SwitchLabel
        | StatementLabel


type LABEL = (Ast.IDENTIFIER * LABEL_KIND)


(* 
 * 
 * The type ENV carrise *two* lists of RIBs, outer and inner. The
 * outer ribs are those including and containing the current hoisting
 * scope. The inner ribs are any lexical scopes defined *inside* the
 * current hoisting scope.
 * 
 * Any time you add a hoisted definition to an environment, you are
 * extending the head of the outerRibs. Any time you add a non-hoisted
 * definition to an environment, you are extending the head of the
 * innerRibs.
 * 
 * The concatenation of the inner and outer ribs is the full ribs,
 * which is the combined RIBs you should use to look up any bindings
 * in.
 *)

type ENV =
     { innerRibs: Ast.RIB list,
       outerRibs: Ast.RIB list,
       tempOffset: int,
       openNamespaces: Ast.NAMESPACE list list,
       labels: LABEL list,
       defaultNamespace: Ast.NAMESPACE,
       program: Fixture.PROGRAM,
       func: Ast.FUNC option }    

    
val (initRib:Ast.RIB) = 
	[ 
	 (* This is the new name that non-backward-compatibly pollutes the ES3 unqualified global. *)
	 (Ast.PropName Name.public_ES4, Ast.NamespaceFixture Name.ES4NS),
	 
	 (* These are the namespaces in ES4 that have spec-defined, normative roles and meanings. *)
	 (Ast.PropName Name.ES4_public, Ast.NamespaceFixture Name.publicNS),
     (Ast.PropName Name.ES4_meta, Ast.NamespaceFixture Name.metaNS),
     (Ast.PropName Name.ES4_intrinsic, Ast.NamespaceFixture Name.intrinsicNS),

	 (* 
	  * These are a namespaces that *would* be defined in the standard library except that we 
	  * define a bunch of native methods in them, and therefore wish to have access to them here.
	  * In theory we could back off and look it up once the interpreter boots. They're just here
	  * to be convenient.
	  *)
	 (Ast.PropName Name.ES4_helper, Ast.NamespaceFixture Name.helperNS),
	 (Ast.PropName Name.ES4_informative, Ast.NamespaceFixture Name.informativeNS),


	 (* 
	  * These are namespaces that *could* be defined in the boot process, but that code is 
	  * sufficiently tangly and order-sensitive that it's much easier to define them here. 
	  *)
	 (Ast.PropName Name.ES4_Unicode, Ast.NamespaceFixture Name.UnicodeNS),
	 (Ast.PropName Name.ES4_RegExpInternals, Ast.NamespaceFixture Name.RegExpInternalsNS)
	]


fun getFullRibs (env:ENV)
    : Ast.RIBS = 
    let
        val { innerRibs, outerRibs, ... } = env
    in
        innerRibs @ outerRibs
    end


fun dumpEnv (e:ENV) : unit =
    if (!doTrace) 
    then 
        let 
            val ribs = getFullRibs e
        in
            List.app Fixture.printRib ribs
        end
    else ()


fun makeTy (e:ENV) 
           (tyExpr:Ast.TYPE) 
    : Ast.TYPE = 
    (* 
     * FIXME: controversial? This attempts to normalize each type term the first 
     * time we see it. We ignore type errors since it's not technically
     * our job to try this here; if someone wants early typechecking they can
     * use the verifier.
     *)        
    Type.normalize (getFullRibs e) tyExpr
    handle LogErr.TypeError _ => tyExpr


fun inl f (a, b) = (f a, b)

fun isInstanceInit (s:Ast.STATEMENT)
    : bool =
    let
    in case s of
           Ast.InitStmt {kind,static,prototype,...} =>
           not ((kind=Ast.LetVar) orelse (kind=Ast.LetConst) orelse
                prototype orelse static)
         | _ => false
    end

	
(*
    Since we are in the definition phase the open namespaces have not been
    captured yet, so capture them before evaluating an unqualified namespace
    expression
*)


fun addNamespace (ns:Ast.NAMESPACE) 
                 (opennss:Ast.NAMESPACE list) =
    if List.exists (fn x => ns = x) opennss
    (* FIXME: should be an error to open namspaces redundantly *)
    then (trace ["skipping namespace ",fmtNs ns]; opennss)   
    else (trace ["adding namespace ", fmtNs ns]; ns :: opennss)


(*
    NAME_EXPRESSION and NAMESPACE_EXPRESSION
 *)

fun defNamespaceExpr (env:ENV)
                     (nse:Ast.NAMESPACE_EXPRESSION)
    : Ast.NAMESPACE_EXPRESSION = 
    case nse of 
        Ast.Namespace ns => Ast.Namespace ns
      | Ast.NamespaceName ne => Ast.NamespaceName (defNameExpr env ne)
                                
and defNameExpr (env:ENV)
                (ne:Ast.NAME_EXPRESSION)
    : Ast.NAME_EXPRESSION =
    let
        val openNamespaces = (#openNamespaces env)
        (* FIXME: this is a kludge; in the future the goal is to do a first pass
         * and *collect* all the global names defined in a compilation unit, then 
         * run the definer with that collected set. For now we just work with the 
         * rootRib "up to this point in the file", which serves to disambiguate
         * the same *most* of the time. Sometimes it's a bit too constrictive. 
         * Spec it with the set of all names declared, of course.
         *)
        fun getName ((Ast.PropName pn),_) = SOME pn
          | getName _ = NONE
        val globalNames = List.mapPartial getName (List.last (#outerRibs env))
    in
        case ne of
            Ast.UnqualifiedName { identifier, ... } =>
            Ast.UnqualifiedName { identifier=identifier,
                                  openNamespaces=openNamespaces,
                                  globalNames=globalNames }
            
          | Ast.QualifiedName { namespace, identifier } =>
            Ast.QualifiedName { namespace = defNamespaceExpr env namespace,
                                identifier = identifier }

          | Ast.ResolvedName name => 
            Ast.ResolvedName name
    end
    
fun resolve (env:ENV)
            (nameExpr:Ast.NAME_EXPRESSION)
    : (Ast.RIBS * Ast.NAME * Ast.FIXTURE) =
    Fixture.resolveNameExpr (getFullRibs env) (defNameExpr env nameExpr)

fun resolveNsExprToNamespace (env:ENV)
                             (nse:Ast.NAMESPACE_EXPRESSION) 
    : Ast.NAMESPACE = 
    Fixture.resolveNamespaceExpr (getFullRibs env) (defNamespaceExpr env nse)

fun resolveNsExprOptToNamespace (env: ENV)
                                (nso:Ast.NAMESPACE_EXPRESSION option)
    : Ast.NAMESPACE =
    case nso of
        NONE => (#defaultNamespace env)
      | SOME nse => resolveNsExprToNamespace env nse
                    
(*
    Create a new context initialised with the provided rib and
    inherited environment
*)

fun enterFragment (env:ENV)
                  (frag:Ast.FRAGMENT)
    : ENV =     
    let
        val { innerRibs, outerRibs, tempOffset, openNamespaces, 
              labels, defaultNamespace, program, func } = env                                           
    
        val (newProgram, newDefaultNs, newOpenNss) = 
            (program, defaultNamespace, openNamespaces)
    in
        { innerRibs = innerRibs, 
          outerRibs = outerRibs,
          tempOffset = tempOffset,
          openNamespaces = newOpenNss,
          labels = labels,
          defaultNamespace = newDefaultNs,
          program = newProgram,
          func = func }
    end

    
fun extendEnvironment (env:ENV)
                      (rib:Ast.RIB)
                      (hoistingPoint:bool)
    : ENV =
    let
        val { innerRibs, outerRibs, tempOffset, openNamespaces, 
              labels, 
              defaultNamespace, program, func } = env
        val (newInnerRibs, newOuterRibs) = if hoistingPoint
                                           then ([], rib :: (innerRibs @ outerRibs))
                                           else (rib :: innerRibs, outerRibs)
    in
        { innerRibs = newInnerRibs,
          outerRibs = newOuterRibs,
          tempOffset = tempOffset,
          openNamespaces = openNamespaces,
          labels = labels,
          defaultNamespace = defaultNamespace,
          program = program,
          func = func }
    end


fun mergeRibs (program:Fixture.PROGRAM)
              (oldRib:Ast.RIB)
              (additions:Ast.RIB)
    : Ast.RIB = 
    Fixture.mergeRibs (Type.matches program []) oldRib additions    
(* FIXME: calls some pretty-hairy type code - needed? *)


fun headAndTailOfRibs (ribs:Ast.RIB list)
    : (Ast.RIB * Ast.RIB list) = 
    case ribs of 
        [] => ([],[])
      | (x::xs) => (x, xs)


fun addToInnerRib (env:ENV)
                  (additions:Ast.RIB)
    : ENV =
    let 
        val { innerRibs, outerRibs, tempOffset, openNamespaces, 
              labels, 
              defaultNamespace, program, func } = env
        val (innerRib, rest) = headAndTailOfRibs innerRibs
        val newInnerRib = mergeRibs (#program env) innerRib additions
        val newInnerRibs = newInnerRib :: rest
    in
        { innerRibs = newInnerRibs, 
          outerRibs = outerRibs,
          tempOffset = tempOffset,
          openNamespaces = openNamespaces,
          labels = labels,
          defaultNamespace = defaultNamespace,
          program = program,
          func = func }
    end


fun addToOuterRib (env:ENV)
                  (additions:Ast.RIB)
    : ENV =
    let 
        val { innerRibs, outerRibs, tempOffset, openNamespaces, 
              labels, 
              defaultNamespace, program, func } = env
        val (outerRib, rest) = headAndTailOfRibs outerRibs
        val newOuterRib = mergeRibs (#program env) outerRib additions
        val newOuterRibs = newOuterRib :: rest
    in
        { innerRibs = innerRibs, 
          outerRibs = newOuterRibs,
          tempOffset = tempOffset,
          openNamespaces = openNamespaces,
          labels = labels,
          defaultNamespace = defaultNamespace,
          program = program,
          func = func }
    end


fun updateTempOffset (env:ENV) (newTempOffset:int)
    : ENV =
    let
        val { innerRibs, outerRibs, tempOffset, openNamespaces, 
              labels, defaultNamespace, program, func } = env
    in
        { innerRibs = innerRibs, 
          outerRibs = outerRibs,
          tempOffset = newTempOffset,
          openNamespaces = openNamespaces,
          labels = labels,
          defaultNamespace = defaultNamespace,
          program = program,
          func = func }
    end


fun enterClass (env:ENV) 
			   (privateNS:Ast.NAMESPACE)
			   (protectedNS:Ast.NAMESPACE)
			   (parentProtectedNSs:Ast.NAMESPACE list)
    : (ENV * Ast.RIB) =
    let
 		val localNamespaceRib = [ (Ast.PropName (Name.private privateNS), 
								   Ast.NamespaceFixture privateNS),
								  (Ast.PropName (Name.protected privateNS), 
								   Ast.NamespaceFixture protectedNS) ]
		val env = extendEnvironment env localNamespaceRib true
        val { innerRibs, outerRibs, tempOffset, openNamespaces, 
              labels, defaultNamespace, program, func } = env
		val openNamespaces = ([privateNS, protectedNS] @ parentProtectedNSs) :: openNamespaces
	in
		({ innerRibs = innerRibs, 
           outerRibs = outerRibs,
           tempOffset = tempOffset,
           openNamespaces = openNamespaces,
           labels = labels,
           defaultNamespace = defaultNamespace,
           program = program,
           func = func }, localNamespaceRib )
	end


fun enterFuncBody (env:ENV) (newFunc:Ast.FUNC)
    : ENV = 
    let
        val { innerRibs, outerRibs, tempOffset, openNamespaces, 
              labels, 
              defaultNamespace, program, func } = env    
    in
        { innerRibs = innerRibs, 
          outerRibs = outerRibs,
          tempOffset = tempOffset,
          openNamespaces = openNamespaces,
          labels = labels,
          defaultNamespace = defaultNamespace,
          program = program,
          func = SOME newFunc }
    end


fun dumpLabels (labels : LABEL list) = 
    trace ["labels ", concat (map (fn (id,_) => (Ustring.toAscii id) ^ " ") labels)]

(*
    Add a label to the current environment context. Report an error
    if there is a duplicate. Labels on switch and iteration statements
    have special meaning. They get lifted into the switch or iteration
    statement so the correct continuation value can be returned in case
    of break, and the correct control flow produced in case of continue.
    Also, the definition phase must distinguish between ordinary statement
    labels and iteration and switch labels to validate continue statements.
*)

fun addLabel ((label:LABEL),(env:ENV))
    : ENV =
        let
            val { innerRibs, outerRibs, tempOffset, openNamespaces, 
                  labels, defaultNamespace, program, func } = env
            val (labelId,labelKnd) = label
        in
            dumpLabels labels;
            if List.exists (fn ((id,knd):LABEL) =>
                               not (id = Ustring.empty) andalso  (* ignore empty labels *)
                               id = labelId andalso              (* compare ids *)
                               knd = labelKnd) labels            (* and kinds *)
            then LogErr.defnError ["duplicate label ", Ustring.toAscii labelId]
            else ();
            { innerRibs = innerRibs, 
              outerRibs = outerRibs,
              tempOffset = tempOffset,
              openNamespaces = openNamespaces,
              labels = label::labels,
              defaultNamespace = defaultNamespace,
              program = program,
              func = func }
        end


fun addLabels (env:ENV) (labels:LABEL list)
    : ENV =
    List.foldl addLabel env labels 

(*
    CLASS_DEFN

    The class definer analyzes the class definition into two blocks,
    a class block that implements the class object and an instance
    block that implements the instance objects.

    ClassFixture = {
        extends = ...
        implements = ...
        cblk = {
            fxtrs = ...  (* static rib *)
            inits = ...  (* static inits,  empty? static props are inited by statements *)
            body = ...   (* static initialiser *)
        }
        iblk = { ... }
    }

    The steps taken are:
    - analyze class body into instance and class blocks
    - resolve extends and implements and do inheritance
    - return a fixture binding for the class
*)

and defClass (env: ENV)
             (cdef: Ast.CLASS_DEFN)
    : (Ast.RIB * Ast.CLASS_DEFN) =
    let
        val class = analyzeClassBody env cdef
        val class = resolveClassInheritance env cdef class
        val Ast.Cls {name,...} = class
    in
        ([(Ast.PropName name, Ast.ClassFixture class)],cdef)
    end

(*
    Defining an interface

    - unpack the interface definition
    - construct the interface name
    - resolve super interfaces
    - define current interface definitions
    - inherit base rib
    - construct instance type
    - construct interface
    - return interface fixture
*)

and defInterface (env: ENV)
                 (idef: Ast.INTERFACE_DEFN)
    : (Ast.RIB * Ast.INTERFACE_DEFN) =
    let
        val { ident, ns, nonnullable, params, extends, instanceDefns } = idef

        (* Make the interface name *)
        val name = {id = ident, ns = resolveNsExprOptToNamespace env ns} 

        (* Resolve base interface's super interfaces and rib *)
        val (superInterfaces:Ast.TYPE list, inheritedRib:Ast.RIB) = resolveInterfaces env extends

        val prog = (#program env)

(*        val groundSuperInterfaceExprs = map (Type.groundExpr o (makeTy env) o (fn t => Type.normalize (getFullRibs env) t)) superInterfaces *)
        val groundSuperInterfaceExprs = map (makeTy env) superInterfaces

        val instanceEnv = extendEnvironment env [] true
        val (typeParamRib:Ast.RIB) = mkParamRib params
        val instanceEnv = addToInnerRib instanceEnv typeParamRib

        (* Define the current rib *)
        val (unhoisted,instanceRib,_) = defDefns instanceEnv instanceDefns

        (* Inherit rib and check overrides *)
        val instanceRib:Ast.RIB = inheritRib NONE inheritedRib instanceRib

        (* Make the instance type and interface fixture *)
        val instanceType:Ast.TYPE = 
            makeTy env (Ast.InstanceType 
                            { name=name,
                              nonnullable=nonnullable,
                              typeParams=params,
                              typeArgs=[],
                              superTypes=groundSuperInterfaceExprs,
                              ty=Ast.AnyType,  (* FIXME needs synthetic record type *)
                              dynamic=false}) (* interfaces are never dynamic *)
                        
        val iface:Ast.IFACE = 
            Ast.Iface { name=name, 
                        typeParams=params,
                        nonnullable=nonnullable, 
                        extends=superInterfaces, 
                        instanceRib=instanceRib,
                        instanceType=instanceType }
    in
        ([(Ast.PropName name, Ast.InterfaceFixture iface)],idef)
    end

(*
    inheritRib

    Steps:

    -

    Errors:

    - override by non-override fixture
    - override of final fixture
    - interface fixture not implemented

    Notes:

    don't check type compatibility yet; we don't know the value of type
    expressions until verify time. In standard mode we need to do a
    light weight verification to ensure that overrides are type compatible
    before a class is loaded.
*)

(*
   Given two fixtures, one base and other derived, check to see if
   the derived fixture can override the base fixture. Specifically,
   check that:

       - the base fixture is not 'final'
       - the derived fixture is 'override'
       - they have same number of parameters
       - they both have the return type void or neither has the return type void
       - what else?

       - FIXME: perhaps we ought to permit overriding fixtures with
         parametric types; we used to but the problem is more complex with general 
         lambda types. Currently disabled.

   Type compatibility of parameter and return types is done by the evaluator
   (or verifier in strict mode) and not here because type annotations can have
   forward references
*)

and canOverride (fb:Ast.FIXTURE) (fd:Ast.FIXTURE)
    : bool =
    let (*
        fun isVoid ty = 
            case ty of 
                Ast.VoidType => true
              | _ => false
          *)           
        val isCompatible = case (fb,fd) of
                (Ast.MethodFixture
                     {ty=Ast.FunctionType {params=pb, 
                                           result=rtb, 
                                           minArgs=mb,
                                           ...}, 
                      func=Ast.Func 
                               {fsig=Ast.FunctionSignature 
                                         {defaults=db, 
                                          ...}, 
                                ...},
                      ...},
                 Ast.MethodFixture
                     {ty=Ast.FunctionType {params=pd, 
                                           result=rtd, 
                                           minArgs=md,
                                           ...}, 
                      func=Ast.Func 
                               {fsig=Ast.FunctionSignature 
                                          {defaults=dd, 
                                           ...}, 
                                ...},
                      ...}) =>
                    let
                        val _ = trace ["mb ",Int.toString mb, " md ",Int.toString md,"\n"]
                        val _ = trace ["length pb ",Int.toString (length pb),
                                       " length pd ",Int.toString (length pd),"\n"]
                        val _ = trace ["length db ",Int.toString (length db),
                                       " length dd ",Int.toString (length dd),"\n"]
                    in
                        true
                        (*
                        ((isVoid rtb) andalso (isVoid rtd))
                        orelse
                        ((not (isVoid rtb)) andalso (not (isVoid rtd)))
                         *)
                    (* FIXME: check compatibility of return types? *)
                    end
                    
              | _ => false
        val _ = trace ["isCompatible = ",Bool.toString isCompatible]

    in case (fb,fd) of
        (Ast.MethodFixture {final,func,...}, 
         Ast.MethodFixture {override,...}) =>
        (((not final) andalso override) orelse (AstQuery.funcIsAbstract func))
        andalso isCompatible

      (* FIXME: what are the rules for getter/setter overriding?
         1/base fixture is not final
         2/derived fixture is override
         3/getter is compatible
         4/setter is compatible
      *)
      | (Ast.VirtualValFixture vb,
         Ast.VirtualValFixture vd) =>
            let
                val _ = trace ["checking override of VirtualValFixture"]
            in
               true
            end
      | _ => LogErr.unimplError ["checkOverride"]
    end

and inheritRib (privateNS:Ast.NAMESPACE option)
			   (base:Ast.RIB)
               (derived:Ast.RIB)
    : Ast.RIB =
    let

        (*
           Recurse through the rib of a base class to see if the
           given fixture binding is allowed. if so, then add it
           return the updated rib

           TODO: check for name conflicts:

                Any name can be overridden by any other name with the same
                identifier and a namespace that is at least as visible. Visibility
                is an attribute of the builtin namespaces: private, protected,
                internal and public. These are related by:

                    private < protected
                    protected < public
                    private < internal
                    internal < public

                where < means less visible

                Note that protected and internal are overlapping namespaces and
                therefore it is an error to attempt to override a name in one
                with a name in another.

            It is an error for there to be a derived fixture with a name that is:

               - less visible than a base fixture
               - as visible or more visible than a base fixture but not overriding it
                 (this case is caught by the override check below)
        *)

        fun inheritFixture (n:Ast.FIXTURE_NAME, fb:Ast.FIXTURE)
            : Ast.RIB =
            let
                fun targetFixture _ = if (Fixture.hasFixture derived n)
                                      then SOME (Fixture.getFixture derived n)
                                      else NONE
				val canInherit = 
					case (n, privateNS) of 
						(* NB: you can -- and must -- *inherit* the private fixtures,
						 * in the sense that other inherited fixtures may refer to them 
						 * as helpers. What you *can't* inherit is the binding for the
						 * name "private". Nor can you *see* any of the inherited privates,
						 * since you have no access to the base private namespace.
						 *)
						(Ast.PropName name, SOME pns) => not (name = (Name.private pns))
					  | (Ast.PropName _, _) => true
					  | (Ast.TempName _, _) => error ["inheriting temp fixture"]
            in
				if canInherit
				then case targetFixture () of
                         NONE => (n,fb)::derived    (* not in the derived class, so inherit it *)
					   | SOME fd =>
                         case (canOverride fb fd) of
                             true => derived  (* return current fixtures *)
						   | _ => LogErr.defnError ["illegal override of ", LogErr.fname n]
				else derived
            end

    in case base of
        [] => derived (* done *)
      | first::follows => inheritRib privateNS follows (inheritFixture first)
    end

(*
    implementFixtures

    Steps:

    -

    Errors:

    - interface fixture not implemented

*)

and implementFixtures (base:Ast.RIB)
                      (derived:Ast.RIB)
    : unit =
    let
        (*
        *)

        fun implementFixture ((n,fb):(Ast.FIXTURE_NAME * Ast.FIXTURE))
            : Ast.RIB =
            let
                fun targetFixture _ = if (Fixture.hasFixture derived n)
                                      then SOME (Fixture.getFixture derived n)
                                      else NONE
            in
                case targetFixture () of
                    NONE => LogErr.defnError ["unimplemented interface method ", LogErr.fname n]
                  | SOME fd =>
                        case (canOverride fb fd) of
                            true => derived  (* return current fixtures *)
                          | _ => LogErr.defnError ["illegal implementation of ", LogErr.fname n]
            end

    in case base of
        [] => () (* done *)
      | first::follows => implementFixtures follows (implementFixture first)
    end

(*
    resolveClassInheritance

    Inherit instance fixtures from the base class. Check fixtures against
    interface fixtures
*)

and resolveClassInheritance (env:ENV)
                 ({extends,implements,...}: Ast.CLASS_DEFN)
                 (Ast.Cls {name, privateNS, protectedNS, parentProtectedNSs, 
						   typeParams, nonnullable, dynamic, classRib, 
						   instanceRib, instanceInits, constructor, classType, 
						   instanceType,...}:Ast.CLS)
    : Ast.CLS =
    let
        val _ = trace ["analyzing inheritance for ", fmtName name]

        val (extendsTy:Ast.TYPE option, 
             instanceRib0:Ast.RIB) = resolveExtends env instanceRib extends name

        val (implementsTys:Ast.TYPE list, 
             instanceRib1:Ast.RIB) = resolveImplements env instanceRib0 implements


        val instanceType = 
            let
                val it = AstQuery.needInstanceType instanceType
                val superTypes:Ast.TYPE list = 
                    case extendsTy of 
                        NONE => implementsTys
                      | SOME ty => ty :: implementsTys
                val prog = (#program env)
(*                val superTypes = map (Type.groundExpr o (makeTy env) o (fn t => Type.normalize (getFullRibs env) t)) superTypes *)
                val superTypes = map (makeTy env) superTypes
                val te = Ast.InstanceType { name = (#name it),
                                            typeParams = (#typeParams it),
                                            typeArgs = (#typeArgs it),
                                            nonnullable = (#nonnullable it),
                                            superTypes = superTypes,
                                            ty = (#ty it),
                                            dynamic = (#dynamic it)}
            in
                case typeParams of 
                    [] => te
(*FIXME
                  | params => Ast.LamType { params = params, 
                                            body = te }
  *)
          end
                
    in
        Ast.Cls {name=name,
				 privateNS=privateNS,
				 protectedNS=protectedNS,
				 parentProtectedNSs=parentProtectedNSs,
                 typeParams=typeParams,
                 nonnullable=nonnullable,
                 dynamic=dynamic,
                 extends=extendsTy,
                 implements=implementsTys,
                 classRib=classRib,
                 instanceRib=instanceRib1,
                 instanceInits=instanceInits,
                 constructor=constructor,
                 classType=classType,
                 instanceType=instanceType}
    end

(*
    Resolve the base class

    Steps
    - resolve base class reference to a class fixture and its name
    - inherit fixtures from the base class

    Errors
    - base class not found
    - inheritance cycle detected

*)


and resolveExtends (env:ENV)
                   (currInstanceRib:Ast.RIB)
                   (extends:Ast.TYPE option)
                   (currName:Ast.NAME) 
    : (Ast.TYPE option * Ast.RIB) =
    let
        val baseClassNameExpr:Ast.NAME_EXPRESSION option = 
            case extends of 
                NONE => if currName = Name.public_Object
                        then NONE
                        else SOME (Name.nameExprOf Name.public_Object)
              | SOME te => SOME (extractNameExprFromTypeName te)
    in
        case baseClassNameExpr of
            NONE => (NONE, currInstanceRib)
          | SOME bcm => 
            let
                val (_, 
                     baseClassName:Ast.NAME, 
                     baseClassFixture:Ast.FIXTURE) = 
                    resolve env bcm
            in
                (SOME (classInstanceType baseClassFixture),
                 inheritRib (SOME (classPrivateNS baseClassFixture))
							(classInstanceRib baseClassFixture) 
							currInstanceRib)
            end
    end

and resolveImplements (env: ENV)
                      (instanceRib: Ast.RIB)
                      (implements: Ast.TYPE list)
    : (Ast.TYPE list * Ast.RIB) =
    let
        val (superInterfaces, abstractRib) = resolveInterfaces env implements
        val _ = implementFixtures abstractRib instanceRib
    in
        (superInterfaces,instanceRib)
    end

(*
    Resolve each of the expressions in the 'implements' list to an interface
    fixture. check that each of the methods declared by each interface is
    implemented by the current set of instance ribs.

    Steps
    - resolve super interface references to interface fixtures
    - inherit ribs from the super interfaces

    Errors
    - super interface fixture not found

*)

and interfaceMethods (ifxtr:Ast.FIXTURE)
    : Ast.RIB =
    case ifxtr of
        Ast.InterfaceFixture (Ast.Iface {instanceRib,...}) => instanceRib
      |_ => LogErr.internalError ["interfaceMethods"]

and interfaceExtends (ifxtr:Ast.FIXTURE)
    : Ast.TYPE list =
    case ifxtr of
        Ast.InterfaceFixture (Ast.Iface {extends,...}) => extends
      |_ => LogErr.internalError ["interfaceExtends"]

and interfaceInstanceType (ifxtr:Ast.FIXTURE)
    : Ast.TYPE =
    case ifxtr of
        Ast.InterfaceFixture (Ast.Iface {instanceType,...}) => instanceType
      |_ => LogErr.internalError ["interfaceInstanceType"]

and classInstanceRib (cfxtr:Ast.FIXTURE)
    : Ast.RIB =
    case cfxtr of
        Ast.ClassFixture (Ast.Cls {instanceRib,...}) => instanceRib
      |_ => LogErr.internalError ["classInstanceRib"]

and classPrivateNS (cfxtr:Ast.FIXTURE)
    : Ast.NAMESPACE =
    case cfxtr of
        Ast.ClassFixture (Ast.Cls {privateNS,...}) => privateNS
      |_ => LogErr.internalError ["privateNS"]

and classInstanceType (cfxtr:Ast.FIXTURE)
    : Ast.TYPE =
    case cfxtr of
        Ast.ClassFixture (Ast.Cls {instanceType,...}) => instanceType
      |_ => LogErr.internalError ["classInstanceType"]

(*
    resolve a list of interface names to their super interfaces and
    method ribs

    interface I { function m() }
    interface J extends I { function n() }  // [I],[m]
    interface K extends J {}  // [I,J] [m,n]

*)

(* FIXME: for the time being we're only going to handle inheriting from 
 * TYPEs of a simple form: those which name a 0-parameter interface. 
 * Generalize later. 
 *)
and extractNameExprFromTypeName (Ast.TypeName (ne, _)) : Ast.NAME_EXPRESSION = ne
  | extractNameExprFromTypeName _ = 
    error ["can only presently handle inheriting from simple named interfaces"]

and resolveInterfaces (env: ENV)
                      (types: Ast.TYPE list)
    : (Ast.TYPE list * Ast.RIB) =
    case types of        
        [] => ([],[])
      | _ =>
        let
            val nameExprs:Ast.NAME_EXPRESSION list = map extractNameExprFromTypeName types
            fun resolveToFix ne = let val (_, _, fix) = resolve env ne in fix end
            val ifaces = map resolveToFix nameExprs
            val ifaceInstanceTypes:Ast.TYPE list = map interfaceInstanceType ifaces
            val superIfaceTypes:Ast.TYPE list = List.concat (map interfaceExtends ifaces)
            val methodRib:Ast.RIB = List.concat (map interfaceMethods ifaces)
        in
            (ifaceInstanceTypes @ superIfaceTypes, methodRib)
        end

(*
    analyzeClassBody

    The parser has already turned the class body into a block statement with init
    statements for setting the value of static and prototype fixtures. This class
    definition has a body whose only interesting statements left are init statements
    that set the value of instance vars.
*)

and analyzeClassBody (env:ENV)
                     (cdef:Ast.CLASS_DEFN)
    : Ast.CLS =
    let
        val {ns, privateNS, protectedNS, ident, 
			 nonnullable, dynamic, params, classDefns, instanceDefns, 
			 instanceStmts, ctorDefn,  ...} = cdef

        (*
         * Partition the class definition into a class block
         * and an instance block, and then define both blocks.
         *)

        val ns = resolveNsExprOptToNamespace env ns
        val name = {id=ident, ns=ns}
        val _ = trace ["defining class ", fmtName name]
        val (staticEnv, localNamespaceRib) = enterClass env privateNS protectedNS []
        val (unhoisted,classRib,classInits) = defDefns staticEnv classDefns
        val classRib = (mergeRibs (#program env) unhoisted classRib)
        val classRib = (mergeRibs (#program env) classRib localNamespaceRib)

        (* namespace and type definitions aren't normally hoisted *)

        val instanceEnv = extendEnvironment staticEnv [] true

        (* FIXME: there is some debate about whether type parameters live in the 
         * instance rib or the class rib. This needs to be resolved. 
         *)
        val (typeParamRib:Ast.RIB) = mkParamRib params
        val instanceEnv = addToInnerRib instanceEnv typeParamRib

        val (unhoisted,instanceRib,_) = defDefns instanceEnv instanceDefns
        val instanceEnv = addToInnerRib instanceEnv instanceRib

        val ctor:Ast.CTOR option =
            case ctorDefn of
                NONE => NONE
              | SOME c => SOME (defCtor instanceEnv c)

        val (instanceStmts,_) = defStmts staticEnv instanceStmts  (* no hoisted fixture produced *)
            
        (*
         * The parser separates variable definitions into defns and stmts. The only stmts
         * in this case will be InitStmts and what we really want is INITs so we translate
         * to to INITs here.
         *)

        fun initsFromStmt stmt =
            case stmt of
                Ast.ExprStmt (Ast.InitExpr (target,Ast.Head (temp_fxtrs,temp_inits),inits)) 
                => (temp_fxtrs,temp_inits@inits)
              | _ => LogErr.unimplError ["Defn.bindingsFromStmt"]

        val (fxtrs,inits) = ListPair.unzip(map initsFromStmt instanceStmts)
        val instanceInits = Ast.Head (List.concat fxtrs, List.concat inits)

        val instanceType = 
            makeTy env (Ast.InstanceType 
                            { name = name,
                              nonnullable = nonnullable,
                              typeParams = params,
                              typeArgs = [],
                              superTypes = [], (* set in resolveClassInheritence *)
                              ty = Ast.AnyType,  (* FIXME needs synthetic record type *)
                              dynamic = dynamic})
    in
        Ast.Cls { name=name,
				  privateNS = privateNS,
				  protectedNS = protectedNS,				  
				  parentProtectedNSs = [], (* set in resolveClassInheritence *)
                  typeParams = params,
                  nonnullable = nonnullable,
                  dynamic = dynamic,
                  extends = NONE,
                  implements = [],
                  classRib = classRib,
                  instanceRib = instanceRib,
                  instanceInits = instanceInits,
                  constructor = ctor,
                  classType = makeTy env (Ast.RecordType []),
                  instanceType = instanceType }
    end

(*
    BINDING

    During parsing, variable definitions are split into a var binding
    and optional init stmt. During the definition phase, the var binding
    is translated into a fixture and optional initialiser. The init stmt
    initalises the property value and its type

    var v : t = x

    A type annotation is an attribute of a fixture, evaluated
    before the fixture is used to create a property. Light weight
    implementations may evaluate type annotations when instantiating
    a block scope for the first time. This lazy evaluation of type
    annotations means that unresolved reference errors shall not
    be reported until runtime in standard mode.

    The definition above translates into the following psuedo
    code during the definition phase

    Block = {
        fxtrs = [ val {id='v'} ]
        inits = [ ref(v).type = t ]
        stmts = [ v = x to ref(v).type ]
    }

    The fxtrs and inits of a var definition might be hoisted
    out of their defining block. It is a definition error for
    a type annotation to resolve to a local, non-type fixture.
    This is to avoid changing the meaning of type annotations
    by hoisting

    Here's a problem case:

    function f()
    {
        type t = {i:I,s:S}

        {
            type t = {i:int,s:string}
            var v : t = {i:10,s:"hi"}
            function g() : t {} {}
        }
    }

    Without a definition error, the meaning of 't' changes
    after hoisting of 'v' and 'g'

*)

and defVar (env:ENV)
           (kind:Ast.VAR_DEFN_TAG)
           (ns:Ast.NAMESPACE)
           (var:Ast.BINDING)
    : (Ast.FIXTURE_NAME*Ast.FIXTURE) =

    case var of
        Ast.Binding { ident, ty } =>
        let
            val ty':Ast.TYPE = defTypeExpr env ty
            val writable' = case kind of
                                Ast.Const => false
                              | Ast.LetConst => false
                              | _ => true
            val offset = (#tempOffset env)
            val name' = fixtureNameFromPropIdent env (SOME ns) ident offset
        in
            (name', Ast.ValFixture {ty=ty',writable=writable'})
        end

(*
    (BINDING list * INIT_STEP list) -> (RIB * INITS)

     and INIT_STEP =   (* used to encode init of bindings *)
         InitStep of (BINDING_IDENTIFIER * EXPRESSION)
       | AssignStep of (EXPRESSION * EXPRESSION)

     and BINDING_IDENTIFIER =
         TempIdent of int
       | PropIdent of IDENTIFIER

    -->

     and INITS    = (FIXTURE_NAME * EXPRESSION) list

     and FIXTURE_NAME = TempName of int
                      | PropName of NAME

*)

and fixtureNameFromPropIdent (env:ENV) 
                             (ns:Ast.NAMESPACE option) 
                             (ident:Ast.BINDING_IDENTIFIER) 
                             (tempOffset:int)
    : Ast.FIXTURE_NAME =
    case ident of
        Ast.TempIdent n =>  Ast.TempName (n+tempOffset)
      | Ast.ParamIdent n => Ast.TempName n
      | Ast.PropIdent id =>
        let
        in case ns of
               SOME ns => Ast.PropName {ns=ns,id=id}
             | _ =>
               let
                   val nameExpr = defNameExpr env (Ast.UnqualifiedName {identifier=id, openNamespaces=[], globalNames=[]})
                   val (_, {ns,id}, _) = resolve env nameExpr
               in
                   Ast.PropName {ns=ns,id=id}
               end
        end

and defInitStep (env:ENV)
                (ns:Ast.NAMESPACE option)
                (step:Ast.INIT_STEP)
    : (Ast.FIXTURE_NAME * Ast.EXPRESSION) =
    let
    in case step of
        Ast.InitStep (ident,expr) =>
            let
                val tempOffset = (#tempOffset env)
                val name = fixtureNameFromPropIdent env ns ident tempOffset
                val expr = defExpr env expr
            in
                (name,expr)
            end
      | Ast.AssignStep (left,right) => (* resolve lhs to fixture name, and rhs to expr *)
            let
                (* FIXME: there is something wrong about AssignStep. Should be a NAME_EXPR LHS? Revisit. *)
                val name = case left of Ast.LexicalReference {name,...} => name
                                      | _ => error ["invalid lhs in InitStep"]
                val (_, {ns,id}, _) = resolve env name
            in
                (Ast.PropName {ns=ns,id=id}, defExpr env right)
            end
    end

and defBindings (env:ENV)
                (kind:Ast.VAR_DEFN_TAG)
                (ns:Ast.NAMESPACE)
                ((binds,inits):Ast.BINDINGS)
    : (Ast.RIB * Ast.INITS) =
    let
        val fxtrs:Ast.RIB = map (defVar env kind ns) binds
        val inits:Ast.INITS = map (defInitStep env (SOME ns)) inits
    in
        (fxtrs,inits)
    end

and defSettings (env:ENV)
                ((binds,inits):Ast.BINDINGS)
    : (Ast.RIB * Ast.INITS) =
    let
        val _ = trace [">> defSettings"]
        val fxtrs:Ast.RIB = map (defVar env Ast.Var Name.publicNS) binds
        val inits:Ast.INITS = map (defInitStep env NONE) inits   (* FIXME: lookup ident in open namespaces *)
        val _ = trace ["<< defSettings"]
    in
        (fxtrs,inits)
    end

(*
    FUNC_SIG

    A function signature defines the invocation interface of a callable
    object. One is translated into a list of value fixtures and a list
    of initialisers that implement the call sequence

    function f.<t,u,v>(x:t,y:u=10):v {...}

    Function = {
        fsig = ...  (* structural type *)
        rib
        inits
        block = {
            fxtrs = [ 't' -> TypeVal,
                      'call' -> Block {
                          fxtrs = [ val {id='x'}, val {id='y'} ]
                          inits = [ ref(x).type = t,x=args[0] to ref(x).type,
                                    y=(args.length<2?10:args[1]) to ref(y).type ]
                          body = [ ... ]}, ... ]
            inits = [ t=targ[0],... ]
            body = [ ]
        }
    }

    var c = o.f<A,B,C>(a,b)

    let g = o.f         bindThis
    let h = g.<A,B,C>   bindTypes
    let c = h(a,b)      callFunction

    paramBlock
    settingsBlock
    body
*)

and defFuncSig (env:ENV)
               (fsig:Ast.FUNC_SIG)
    : (Ast.RIB * Ast.INITS * Ast.EXPRESSION list * Ast.RIB * Ast.INITS * Ast.EXPRESSION list * Ast.TYPE) =

    case fsig of
        Ast.FunctionSignature { typeParams, params, paramTypes, defaults, ctorInits,
                                returnType, thisType, hasRest } =>
        let

(**** FIXME

            (* compute typeval fixtures (type parameters) *)
            fun mkTypeVarFixture x = (Ast.PropName {ns=Name.internalNS, id=x},
                                      Ast.TypeVarFixture)

            val typeParamFixtures = map mkTypeVarFixture typeParams
            val typeEnv = extendEnvironment env typeParamFixtures 0
****)

            val thisType:Ast.TYPE = 
                case thisType of 
                    NONE => Ast.AnyType
                  | SOME x => defTypeExpr env x

            fun isTempFixture (n:Ast.FIXTURE_NAME, _) : bool =
                case n of
                   Ast.TempName _ => true
                 | _ => false


            val (paramRib,paramInits) = defBindings env Ast.Var Name.publicNS params
            val ((settingsRib,settingsInits),superArgs) =
                    case ctorInits of
                        SOME (settings,args) => (defSettings env settings, defExprs env args)
                      | NONE => (([],[]),[])
            val settingsRib = List.filter isTempFixture settingsRib
        in
            (paramRib,
             paramInits,
             defaults,
             settingsRib,
             settingsInits,
             superArgs,
             thisType)
        end

(*
    FUNC

    The activation frame of a function is described by a BLOCK. The ribs
    are the parameters (type and ordinary) and (hoisted) vars. The optional
    arguments are implemented using the inits. The body of the function is
    contained in the statements list.

    In addition to the block a function is described by its type tag, which
    is a function type expression.

    func : FUNC = {
        type =
        body : BLOCK = {
            fxtrs
            inits
            stmts =
                [BlkStmt {
                    fxtrs
                    inits
                    stmts }
           ]
        }
    }

    Assemble the normal form of the fun

    analyzeFuncSig
    defBlock

    function f(x,y,z) { var i=10; let j=20 }

    {f=[x,y,z,i],i=[],
      s=[{f=[j],i=[],
        s=[i=10,j=20]}]}
*)
             
and defFunc (env:ENV) 
            (func:Ast.FUNC)
    : (Ast.HEAD * Ast.EXPRESSION list * Ast.FUNC) = (* (settings, superArgs, func) *)    
    let
        val _ = trace [">> defFunc"]
        val Ast.Func {name, fsig, block, ty, native, generator, loc, ...} = func
        fun findFuncType env e = 
            case e of 
           (*     Ast.LamType { params, body } => 
                findFuncType (extendEnvironment env (mkParamRib params) true) body 
            *)
                Ast.FunctionType fty => (env, fty)
              | _ => error ["unexpected primary type in function: ", LogErr.ty e]

        val newT = defTypeExpr env ty
        val (env, funcType) = findFuncType env newT                     
        val numParams = length (#params funcType)
        val env = updateTempOffset env numParams
        val (paramRib, paramInits, defaults, settingsRib, settingsInits, superArgs, thisType) = defFuncSig env fsig
        val defaults = defExprs env defaults
        val env = extendEnvironment env paramRib true
        val env = enterFuncBody env func
        val (blockOpt:Ast.BLOCK option, hoisted:Ast.RIB) = 
            case block of 
                NONE => (NONE, [])
              | SOME b => 
                let 
                    val (block:Ast.BLOCK, hoisted:Ast.RIB) = defBlock env b
                in
                    (SOME block, hoisted)
                end
        val _ = trace ["<< defFunc"]
    in
        (Ast.Head (settingsRib, settingsInits), superArgs,
         Ast.Func {name = name,
                   fsig = fsig,
                   block = blockOpt,
                   defaults = defaults,
                   ty = newT,
                   param = Ast.Head (mergeRibs (#program env) paramRib hoisted, 
                                     paramInits),
                   native=native,
                   generator=generator,
                   loc=loc})
    end

(*
    FUNC_DEFN

    A function can be bound or unbound, writable or not, have constrained or
    unconstrainted 'this'. In all cases however a function definition specifies
    the function's name, type, and implementation

    Edition 3 style functions are unbound, writable, and have an unconstratined
    'this'. The fixture that holds one is of type *, and it is initialized by
    an assignment expression in the preamble of the defining block.

*)

and defFuncDefn (env:ENV) 
                (f:Ast.FUNC_DEFN)
    : Ast.RIB =
    case (#func f) of
        Ast.Func { name, fsig, block, ty, native, ... } =>
        let
            val qualNs = resolveNsExprOptToNamespace env (#ns f)
            val newName = Ast.PropName { id = (#ident name), ns = qualNs }
            val (_, _, newFunc) = defFunc env (#func f)
            val Ast.Func { ty, ... } = newFunc

            val fixture =
                case (#kind name) of
                    Ast.Get =>
                    Ast.VirtualValFixture
                        { ty = AstQuery.resultTyOfFuncTy ty,
                          getter = SOME newFunc,
                          setter = NONE }
                  | Ast.Set =>
                    Ast.VirtualValFixture
                        { ty = AstQuery.singleParamTyOfFuncTy ty,
                          getter = NONE,
                          setter = SOME newFunc }
                  | Ast.Ordinary =>
                    let
                        val (ftype, isWritable) =
                            if (#kind f) = Ast.Var                            
                            then  
                                (* e3 style writeable function *)
                                (makeTy env (Ast.AnyType), true)  
                            else 
                                (* read only, method *)
                                (ty, false)
                    in
                        Ast.MethodFixture
                            { func = newFunc,
                              ty = ftype,
                              writable = isWritable,
                              final = (#final f),
                              override = (#override f)}
                    end
                  | Ast.Call =>
                    Ast.MethodFixture
                        { func = newFunc,
                          ty = ty,
                          writable = false,
                          final = true,
                          override = false}
                  | Ast.Has =>
                    Ast.MethodFixture
                        { func = newFunc,
                          ty = ty,
                          writable = false,
                          final = true,
                          override = false}
                  | Ast.Operator =>
                    LogErr.unimplError ["operator function not implemented"]
        in
            [(newName, fixture)]
        end

and defCtor (env:ENV) (ctor:Ast.CTOR)
    : Ast.CTOR =
    let
        val _ = trace [">> defCtor"]
        val _ = (trace ["environment: "]; dumpEnv env)                
        val Ast.Ctor {func,...} = ctor
        val (settings,superArgs,newFunc) = defFunc env func
        val _ = trace ["<< defCtor"]
    in
        Ast.Ctor {settings=settings, superArgs=superArgs, func=newFunc}
    end

(*
    PRAGMA list

    Some effects of pragmas are propagated to the expressions they modify via a
    Context value. Interpret each pragma and initialise a new env using the results
*)

and defPragmas (env:ENV)
               (pragmas:Ast.PRAGMA list)
    : (Ast.PRAGMA list * ENV * Ast.RIB) =
    let
        val program = ref (#program env)
        val innerRibs  = #innerRibs env
        val outerRibs  = #outerRibs env
        val defaultNamespace = ref (#defaultNamespace env)
        val opennss = ref []
        val rib = ref []
        val tempOffset = #tempOffset env

        fun modifiedEnv _ = 
            { innerRibs = innerRibs,
              outerRibs = outerRibs,
              tempOffset = tempOffset,
              openNamespaces = (case !opennss of
                                    [] => (#openNamespaces env)   (* if opennss is empty, don't concat *)
                                  | _  => !opennss :: (#openNamespaces env)),
              labels = (#labels env),
              defaultNamespace = !defaultNamespace,
              program = !program,
              func = (#func env) }

        fun defPragma x =
            case x of
                Ast.UseNamespace nse =>
                    let
                        val env = modifiedEnv()
                        val ns = resolveNsExprToNamespace env nse
                    in
                        opennss := addNamespace ns (!opennss);
                        Ast.UseNamespace (Ast.Namespace ns)
                    end
              | Ast.UseDefaultNamespace nse =>
                    let
                        val env = modifiedEnv()
                        val ns = resolveNsExprToNamespace env nse
                        val _ = trace ["use default namespace ", fmtNs ns]
                    in
                        defaultNamespace := ns;
                        Ast.UseDefaultNamespace (Ast.Namespace ns)
                    end

              | p => p

        val newPragmas = map defPragma pragmas                         
    in
        (newPragmas, modifiedEnv (), !rib)
    end


and defLiteral (env:ENV)
               (lit:Ast.LITERAL)
    : Ast.LITERAL =
    let
        val _ = trace [">> defLiteral"]
    in
        case lit of
            Ast.LiteralFunction func =>
            let
                val (_,_,func) = defFunc env func
            in
                Ast.LiteralFunction func
            end

          | Ast.LiteralArray {exprs, ty} =>
            Ast.LiteralArray {exprs = defExpr env exprs,
                              ty = case ty of
                                       NONE => NONE
                                     | SOME t => SOME (defTypeExpr env t) }
          | Ast.LiteralXML exprs =>
            Ast.LiteralXML (defExprs env exprs)

          | Ast.LiteralObject {expr, ty} =>
            Ast.LiteralObject {expr = List.map (fn { kind, name, init } =>
                                                   { kind = kind,
                                                     name = defNameExpr env name,
                                                     init = defExpr env init }) expr,
                               ty = case ty of
                                        NONE => NONE
                                      | SOME t => SOME (defTypeExpr env t) }

          | Ast.LiteralNamespace ns =>
            Ast.LiteralNamespace ns

          | _ => lit   (* FIXME: other cases to handle here *)
    end


and defExpr (env:ENV)
            (expr:Ast.EXPRESSION)
    : Ast.EXPRESSION =
    let
        fun sub e = defExpr env e
    in
        case expr of
            Ast.TernaryExpr (e1, e2, e3) =>
            Ast.TernaryExpr (sub e1, sub e2, sub e3)

          | Ast.BinaryExpr (b, e1, e2) =>
            Ast.BinaryExpr (b, sub e1, sub e2)

          | Ast.BinaryTypeExpr (b, e, ty) =>
            Ast.BinaryTypeExpr (b, sub e, defTypeExpr env ty)

          | Ast.UnaryExpr (u, e) =>
            Ast.UnaryExpr (u, sub e)

          | Ast.TypeExpr t =>
            Ast.TypeExpr (defTypeExpr env t)

          | Ast.ThisExpr k =>
            (case k of
                 SOME Ast.FunctionThis =>
                 (case (#func env) of
                      SOME (Ast.Func { name = { kind, ident }, ...}) => 
                      (case kind of
                           Ast.Get => error ["'this function' not allowed in getter"]
                         | Ast.Set => error ["'this function' not allowed in setter"]
                         | _ => Ast.ThisExpr k)
                    | _ => error ["'this function' not allowed in non-function context"])
               | _ => Ast.ThisExpr k)

          | Ast.YieldExpr eo =>
            (case eo of
                      NONE => Ast.YieldExpr NONE
                    | SOME e => Ast.YieldExpr (SOME (sub e)))

          | Ast.SuperExpr eo =>
            (case eo of
                      NONE => Ast.SuperExpr NONE
                    | SOME e => Ast.SuperExpr (SOME (sub e)))

          | Ast.LiteralExpr le =>
            Ast.LiteralExpr (defLiteral env le)

          | Ast.CallExpr {func, actuals} =>
            Ast.CallExpr {func = sub func,
                          actuals = map sub actuals }

          | Ast.ApplyTypeExpr { expr, actuals } =>
            Ast.ApplyTypeExpr { expr = sub expr,
                                actuals = map (defTypeExpr env) actuals }

          | Ast.LetExpr { defs, body,... } =>
            let
                val (f,i)   = defBindings env Ast.Var Name.publicNS defs
                val env     = extendEnvironment env f false
                val newBody = defExpr env body
            in
                Ast.LetExpr { defs = ([],[]),  (* defs, *)
                              body = newBody,
                              head = SOME (Ast.Head (f,i)) }
            end

          | Ast.NewExpr { obj, actuals } =>
            Ast.NewExpr { obj = sub obj,
                          actuals = map sub actuals }

          | Ast.ObjectNameReference { object, name, loc } =>
            (LogErr.setLoc loc;
             Ast.ObjectNameReference { object = sub object,
                                       name = defNameExpr env name,
                                       loc = loc })

          | Ast.ObjectIndexReference { object, index, loc } => 
            (LogErr.setLoc loc;
             Ast.ObjectIndexReference { object = sub object,
                                        index = sub index,
                                        loc = loc })

          | Ast.LexicalReference { name, loc } =>
            (LogErr.setLoc loc;
             Ast.LexicalReference { name = defNameExpr env name,
                                    loc = loc})
            
          | Ast.SetExpr (a, le, re) =>
            Ast.SetExpr (a, (sub le), (sub re))

          | Ast.GetTemp n =>
            let
                val tempOffset = (#tempOffset env)
            in
                Ast.GetTemp (n+tempOffset)
            end

          | Ast.GetParam n =>
            Ast.GetTemp n

          | Ast.ListExpr es =>
            Ast.ListExpr (map sub es)

          | Ast.InitExpr ie =>
            Ast.InitExpr ie
    end


and defExprs (env:ENV)
             (exprs:Ast.EXPRESSION list)
    : Ast.EXPRESSION list =
    let
        val es = map (defExpr env) exprs
    in
        es
    end

(*
    TYPE

*)

and defFuncTy (env:ENV)
              (ty:Ast.FUNCTION_TYPE)
    : Ast.FUNCTION_TYPE =
        let
            val {typeParams,params,result,thisType,hasRest,minArgs} = ty
            val params' = map (defTypeExpr env) params
            val thisType' = defTypeExpr env thisType
            val result' = Option.map (defTypeExpr env) result
        in
            {typeParams=typeParams,
             params=params',
             result=result',
             thisType=thisType',
             hasRest=hasRest,
             minArgs=minArgs}
        end


and defTypeExpr (env:ENV)
                (typeExpr:Ast.TYPE)
    : Ast.TYPE =
    case typeExpr of
        Ast.FunctionType t =>
        Ast.FunctionType (defFuncTy env t)
      | Ast.TypeName (n,nonce) =>
        Ast.TypeName ((defNameExpr env n), nonce)
      | Ast.UnionType tys =>
        Ast.UnionType (map (defTypeExpr env) tys)
      | Ast.ArrayType tys =>
        Ast.ArrayType (map (defTypeExpr env) tys)
      | Ast.RecordType tys =>
        Ast.RecordType (map (defFieldType env) tys)
      | Ast.NonNullType t =>
        Ast.NonNullType (defTypeExpr env t)
      | Ast.TypeIndexReferenceType (ty, n) =>
        Ast.TypeIndexReferenceType (defTypeExpr env ty, n)

      | Ast.TypeNameReferenceType (ty, ident) =>
        Ast.TypeNameReferenceType (defTypeExpr env ty, ident)

      | Ast.AppType ( base, args ) => 
        Ast.AppType ( defTypeExpr env base, map (defTypeExpr env) args )
(*
      | Ast.LamType { params, body } => 
        Ast.LamType { params = params,
                      body = defTypeExpr env body }
*)
      (* FIXME *)
      | t => t


and defFieldType (env:ENV)
              (ty:Ast.FIELD_TYPE)
    : Ast.FIELD_TYPE =
    let
        val {name,ty} = ty
        val ty = defTypeExpr env ty
    in
        {name=name,ty=ty}
    end


(*
    STATEMENT

    Define a statement and return the elaborated statement and a list
    of hoisted rib.
*)

and defStmt (env:ENV)
            (labelIds:Ast.IDENTIFIER list)
            (stmt:Ast.STATEMENT)
    : (Ast.STATEMENT * Ast.RIB) =
    let
        fun defForEnumStmt env (fe:Ast.FOR_ENUM_STATEMENT) =
            let
                fun defVarDefnOpt vd =
                    case vd of
                        SOME vd => defDefn env (Ast.VariableDefn vd)
                      | NONE => ([],[],[])
            in
            case fe of
                { isEach, obj, defn, labels, body, next, ... } =>
                let
                    val newObj =  defExpr env obj
                    val (ur1,hr1,i1) = defVarDefnOpt defn
                    val env = extendEnvironment env ur1 false
                    val (newBody,hoisted) = defStmt env [] body
                    val tempEnv = updateTempOffset env 1   (* alloc temp for iteration value *)
                    val (newNext,_) = defStmt tempEnv [] next
                in
                    (Ast.ForInStmt { isEach=isEach,
                                     obj = newObj,
                                     defn = defn,
                                     labels = Ustring.empty::labelIds,
                                     body = newBody,
                                     rib = SOME ur1,
                                     next = newNext },
                     mergeRibs (#program env) hr1 hoisted)
                end
            end

        fun makeIterationLabel id = (id,IterationLabel)
        fun makeStatementLabel id = (id,StatementLabel)
        fun makeSwitchLabel id = (id,SwitchLabel)

        fun defWhileStmt (env) (w:Ast.WHILE_STATEMENT) =
            case w of
                { cond, body, labels, rib } => (* FIXME: inits needed *)
                let
                    val newCond = defExpr env cond
                    val (newBody, hoisted) = defStmt env [] body
                in
                    ({ cond=newCond,
                       rib=NONE,
                       body=newBody,
                       labels=Ustring.empty::labelIds}, hoisted)
                end

        (*
            for ( var x = 10; x > 0; --x ) ...
            for ( x=10; x > 0; --x ) ...
        *)

        fun defForStmt env { defn, init, cond, update, labels, body, rib } =
            let
                fun defVarDefnOpt vd =
                    case vd of
                        SOME vd => defDefn env (Ast.VariableDefn vd)
                      | NONE => ([],[],[])
                val (ur,hr,_) = defVarDefnOpt defn
                val env = extendEnvironment env (mergeRibs (#program env) ur hr) false
                val (newInit,_) = defStmts env init
                val newCond = defExpr env cond
                val newUpdate = defExpr env update
                val (newBody, hoisted) = defStmt env [] body
            in
                trace ["<< reconstructForStmt"];
                ( Ast.ForStmt { defn = defn,
                                init = newInit,
                                cond = newCond,
                                update = newUpdate,
                                labels = Ustring.empty::labelIds,
                                body = newBody,
                                rib = SOME (ur) },
                  (mergeRibs (#program env) hr hoisted) )
            end

        fun reconstructCatch { bindings, rib, inits, block, ty } =
            let
                val ty:Ast.TYPE = defTypeExpr env ty
                val (r0,i0) = defBindings env Ast.Var Name.publicNS bindings
                val env = extendEnvironment env r0 false
                val (block:Ast.BLOCK, rib:Ast.RIB) = defBlock env block
            in
                ({ bindings = bindings,   (* FIXME: what about inits *)
                  block = block,
                  rib = SOME r0,
                  inits = SOME i0,
                  ty=ty }, rib)
            end

        fun defCase env { label, body, inits }
            : Ast.CASE * Ast.RIB =
            let
                val (body:Ast.BLOCK, hoisted) = defBlock env body
                val label =
                    case label of
                        NONE => NONE
                      | SOME e =>
                        let
                            val e' = defExpr env e
                        in
                            SOME e'
                        end
            in
                ({label = label,
                  inits = SOME [],
                  body = body},
                hoisted)
            end

        fun findClass (n:Ast.NAME) =
            let
                val (_,_,f) = resolve env (Name.nameExprOf n)
            in 
                case f of
                    Ast.ClassFixture cd => cd
                  | _ => LogErr.defnError ["reference to non-class fixture"]
            end
            
        fun reconstructClassBlock {ns, privateNS, protectedNS, 
								   ident:Ast.IDENTIFIER, block, name:Ast.NAME option } =
            let
                val _ = trace2 ("reconstructing class block for ", ident)
                val Ast.Block { pragmas, defns, head, body, loc } = block

                (* filter out instance initializers *)
                val (_,stmts) = List.partition isInstanceInit body

				(* 
				 * NB: Not able to see parent-protected NSs in class
				 * block, only local private and protected! 
				 *) 
				val (env, _) =
					enterClass env privateNS protectedNS []

                val namespace = resolveNsExprOptToNamespace env ns
                val name = {ns=namespace, id=ident}


                val (block,hoisted) = defBlock env (Ast.Block {pragmas=pragmas,
                                                               defns=defns,
                                                               head=head,
                                                               body=body,
                                                               loc=loc})
            in
                (Ast.ClassBlock { ns = ns,
								  privateNS = privateNS,
								  protectedNS = protectedNS,
                                  ident = ident,
                                  name = SOME name,
                                  block = block }, hoisted)
            end


        fun checkLabel labelIdOpt labelKnd =
            let
                val labelId = case labelIdOpt of NONE => Ustring.empty | SOME i => i
                val _ = trace2 ("checkLabel ",labelId)
                val { labels, ... } = env
            in
                dumpLabels labels;
                 if List.exists (fn (id,knd) =>
                                    id = labelId andalso    (* compare ids *)
                                    knd = labelKnd) labels  (* and kinds *)
                 then true
                 else false
            end

        fun checkBreakLabel (id:Ast.IDENTIFIER option) =
            (*
                A break with an empty label shall only occur in an iteration
                statement or switch statement. A break with a non-empty label
                shall only occur in a statement with that label as a member of
                its label set
            *)
            if case id of
                NONE => (checkLabel id SwitchLabel) orelse (checkLabel id IterationLabel)
              | _ => (checkLabel id StatementLabel)
            then ()
            else LogErr.defnError ["invalid break label"]

        fun checkContinueLabel (id:Ast.IDENTIFIER option) =
            (*
                A continue statement with an empty label shall only occur in
                an iteration statement. A continue statement with a non-empty
                label shall only occur in an iteration statement with that
                label as a member of its label set
            *)

            if checkLabel id IterationLabel
            then ()
            else LogErr.defnError ["invalid label in continue statement"]

    in
        case stmt of
            Ast.EmptyStmt =>
            (Ast.EmptyStmt,[])

          | Ast.ExprStmt es =>
            let
            in
                (Ast.ExprStmt (defExpr env es),[])
            end

          | Ast.InitStmt {ns, temps, inits, prototype, static, kind} =>
            let
                val ns0 = resolveNsExprOptToNamespace env ns

                val target = case (kind, prototype, static) of
                                 (_,true,_) => Ast.Prototype
                               | (_,_,true) => Ast.Hoisted
                               | (Ast.Var,_,_) => Ast.Hoisted
                               | (Ast.Const,_,_) => Ast.Hoisted
                               | _ => Ast.Local
                val temps = defBindings env kind ns0 temps  (* ISSUE: kind and ns are irrelevant *)
            in
                (Ast.ExprStmt (Ast.InitExpr (target, Ast.Head temps, (map (defInitStep env (SOME ns0)) inits))),[])
            end

          | Ast.ForInStmt fe =>
            let
                val env' = addLabels env (map makeIterationLabel labelIds)
                val env'' = addLabel ((makeIterationLabel Ustring.empty), env')
            in
                defForEnumStmt env'' fe
            end

          | Ast.ThrowStmt es =>
            (Ast.ThrowStmt (defExpr env es), [])

          | Ast.ReturnStmt es =>
            (Ast.ReturnStmt (defExpr env es), [])

          | Ast.BreakStmt i =>
            let
            in
                checkBreakLabel i;
                (Ast.BreakStmt i, [])
            end

          | Ast.ContinueStmt i =>
            let
            in
                checkContinueLabel i;
                (Ast.ContinueStmt i, [])
             end

          | Ast.BlockStmt b =>
            inl (Ast.BlockStmt) (defBlock env b)

          | Ast.ClassBlock cb =>
            reconstructClassBlock cb

          | Ast.LabeledStmt (id, s) =>
            let
                val env' = addLabel ((makeStatementLabel id), env)
                val (s',f') = defStmt env' (id::labelIds) s
            in
                (Ast.LabeledStmt (id,s'),f')
            end

          | Ast.LetStmt b =>
            inl (Ast.LetStmt) (defBlock env b)

          | Ast.WhileStmt w =>
            let
                val env' = addLabels env (map makeIterationLabel labelIds)
                val env'' = addLabel ((makeIterationLabel Ustring.empty), env')
            in
                inl (Ast.WhileStmt) (defWhileStmt env'' w)
            end

          | Ast.DoWhileStmt w =>
            let
                val env' = addLabels env (map makeIterationLabel labelIds);
                val env'' = addLabel ((makeIterationLabel Ustring.empty), env')
            in
                inl (Ast.DoWhileStmt) (defWhileStmt env'' w)
            end

          | Ast.ForStmt f =>
            let
                val env' = addLabels env (map makeIterationLabel labelIds);
                val env'' = addLabel ((makeIterationLabel Ustring.empty), env')
            in
                defForStmt env'' f
            end

          | Ast.IfStmt { cnd, thn, els } =>
            let
                val cnd = defExpr env cnd
                val (thn,thn_hoisted) = defStmt env [] thn
                val (els,els_hoisted) = defStmt env [] els
            in

                (Ast.IfStmt { cnd = cnd,
                              thn = thn,
                              els = els },
                 mergeRibs (#program env) thn_hoisted els_hoisted)
            end

          | Ast.WithStmt { obj, ty, body } =>
            let
                val (body,hoisted) = defStmt env [] body
            in
                (Ast.WithStmt { obj = (defExpr env obj),
                           ty = (defTypeExpr env ty),
                           body = body }, hoisted)
            end

          | Ast.TryStmt { block, catches, finally } =>
            let
                val (block,thoisted) = defBlock env block
                val (catches,choisted) = ListPair.unzip (map reconstructCatch catches)
                val (finally,fhoisted) = case finally of
                                   NONE =>
                                   (NONE,[])
                                 | SOME b =>
                                   let val (block,hoisted) = defBlock env b
                                   in (SOME block,hoisted) end
            in
                (Ast.TryStmt {block = block,
                              catches = catches,
                              finally = finally}, thoisted@(List.concat choisted)@fhoisted)
            end

          | Ast.SwitchStmt { cond, cases, ... } =>
            let
                val env' = addLabels env (map makeSwitchLabel labelIds);
                val env'' = addLabel ((makeSwitchLabel Ustring.empty), env')
                val (cases,hoisted) = ListPair.unzip (map (defCase env'') cases)
            in
                (Ast.SwitchStmt { cond = defExpr env cond,
                                  cases = cases,
                                  labels=Ustring.empty::labelIds}, List.concat hoisted)
            end

          | Ast.SwitchTypeStmt { cond, ty, cases } =>
            let
                val (cases,hoisted) = ListPair.unzip (map reconstructCatch cases)
            in
                (Ast.SwitchTypeStmt {cond = defExpr env cond,
                                     ty = defTypeExpr env ty,
                                     cases = cases}, List.concat hoisted)
            end
          | Ast.DXNStmt { expr } =>
            (Ast.DXNStmt { expr = defExpr env expr },[])
    end

and defStmts (env) (stmts:Ast.STATEMENT list)
    : (Ast.STATEMENT list * Ast.RIB) =
    case stmts of
        (stmt::stmts) =>
            let
                val (s1,f1):(Ast.STATEMENT*Ast.RIB) = defStmt env [] stmt

                (* Class definitions are embedded in the ClassBlock so we
                   need to update the environment in that case *)

                val env = addToOuterRib env f1
                val (s2, f2) = defStmts env stmts
            in
                (s1::s2,(mergeRibs (#program env) f1 f2))
            end
      | [] => ([],[])

(*
    NAMESPACE_DEFN

    Translate a namespace definition into a namespace fixture. Namespaces
    are not hoisted. The initialiser is resolved at this time and so must
    be a namespace expression, if it exists. 
*)

and defNamespaceDefn (env:ENV)
                 (nd:Ast.NAMESPACE_DEFN)
    : (Ast.RIB * Ast.NAMESPACE_DEFN) =
    case nd of
        { ident, ns, init } =>
        let
            val _ = trace [">> defNamespaceDefn"]
            val qualNs = resolveNsExprOptToNamespace env ns
            val initNs = case init of
                             NONE => Name.newOpaqueNS ()
                           | SOME nse => resolveNsExprToNamespace env nse
            val fixtureName = Ast.PropName { ns = qualNs, id = ident }
            val newNd = { ident = ident,
                          ns = SOME (Ast.Namespace qualNs),
                          init = SOME (Ast.Namespace initNs) }
        in
            ([(fixtureName, Ast.NamespaceFixture initNs)], newNd)
        end


and defType (env:ENV)
            (td:Ast.TYPE_DEFN)
    : Ast.RIB =
    let
        val { ident, ns, typeParams, init } = td
        val ns = resolveNsExprOptToNamespace env ns
        val n = { id=ident, ns=ns }
    in
        [(Ast.PropName n,
          Ast.TypeFixture (typeParams, defTypeExpr env init))]
    end

(*FIXME ##*)

(*
    DEFN

    Translate a definition into two ribs (hoisted and unhoisted) and a
    (possibly empty) list of initialisers.
*)


and defDefn (env:ENV)
            (defn:Ast.DEFN)
    : (Ast.RIB * Ast.RIB * Ast.INITS) = (* unhoisted, hoisted, inits *)
    case defn of
        Ast.VariableDefn { kind, ns, static, prototype, bindings } =>
            let
                val _ = trace ["defVar"]
                val ns = resolveNsExprOptToNamespace env ns
                val (fxtrs,inits) = defBindings env kind ns bindings
            in case kind of
              (* hoisted fxtrs *)
                Ast.Var => ([],fxtrs,inits)
              | Ast.Const => ([],fxtrs,inits)
              (* unhoisted fxtrs *)
              | Ast.LetVar => (fxtrs,[],inits)
              | Ast.LetConst => (fxtrs,[],inits)
            end
      | Ast.FunctionDefn fd =>
            let
                val {kind,...} = fd
                val fxtrs = defFuncDefn env fd
            in case kind of
              (* hoisted fxtrs *)
                Ast.Var => ([],fxtrs,[])
              | Ast.Const => ([],fxtrs,[])
              (* unhoisted fxtrs *)
              | Ast.LetVar => (fxtrs,[],[])
              | Ast.LetConst => (fxtrs,[],[])
            end
      | Ast.NamespaceDefn nd =>
            let
                val _ = trace ["defNamespaceDefn"]
                val (hoisted,def) = defNamespaceDefn env nd
            in
                ([],hoisted,[])
            end
      | Ast.ClassDefn cd =>
            let
                val _ = trace ["defClass"]
                (* FIXME: we use classes inside statements *)
                val (hoisted,def) = defClass env cd
            in
                ([],hoisted,[])
            end

      | Ast.InterfaceDefn cd =>
            let
                val (hoisted,def) = defInterface env cd
            in
                ([],hoisted,[])
            end

      | Ast.TypeDefn td =>
        let
            val unhoisted = defType env td
        in
            (unhoisted, [], [])
        end

      | _ => LogErr.unimplError ["defDefn"]

(*
    DEFN list

    Process each definition.
*)

and defDefns (env:ENV)
             (defns:Ast.DEFN list)
    : (Ast.RIB * Ast.RIB * Ast.INITS) = (* unhoisted, hoisted, inits *)
    let
        fun loop (env:ENV)
                 (defns:Ast.DEFN list)
                 (unhoisted:Ast.RIB)
                 (hoisted:Ast.RIB)
                 (inits:Ast.INITS)
            : (Ast.RIB * Ast.RIB * Ast.INITS) = (* unhoisted, hoisted, inits *)
            case defns of 
                [] => (unhoisted, hoisted, inits)
              | d::ds => 
                let
                    val { program, ... } = env
                    val (unhoisted', hoisted', inits') = defDefn env d
                    val env = addToOuterRib env hoisted'
                    val env = addToInnerRib env unhoisted'
                    val _ = trace(["defDefns: combining unhoisted ribs"]);                    
                    val combinedUnHoisted = mergeRibs program unhoisted unhoisted'
                    val _ = trace(["defDefns: combining hoisted ribs"]);        
                    val combinedHoisted = mergeRibs program hoisted hoisted'
                    val _ = trace(["defDefns: combining inits"])
                    val combinedInits = inits @ inits'
                in
                    loop env ds combinedUnHoisted combinedHoisted combinedInits
                end
        val _ = trace([">> defDefns"])
        val res = loop env defns [] [] []
        val _ = trace(["<< defDefns"])
    in
        res
    end    
        
(*
    BLOCK

    Initialise a Block's rib and initialisers fields. Pragmas and
    definitions are not used after this definition phase. Traverse the
    statements so that embedded blocks (e.g. block statements, let
    expressions) are initialised.

    Class blocks have an outer scope that contain the class (static)
    rib. When entering a class block, extend the environment with
    the class object and its base objects, in reverse order

*)

and defBlock (env:ENV)
             (b:Ast.BLOCK)
    : (Ast.BLOCK * Ast.RIB) =
    defBlockFull env b false

and defDecorativeBlock (env:ENV)
                       (b:Ast.BLOCK)
    : (Ast.BLOCK * Ast.RIB) = 
    defBlockFull env b true
    
and defBlockFull (env:ENV)
                 (b:Ast.BLOCK)
                 (decorative:bool)
    (* 
     * Returns the re-formed block *and* the rib of "escaping" defns:
     * if the block is decorative, that's everything; if the block is 
     * normal, it's only the hoists.
     *)
    : (Ast.BLOCK * Ast.RIB) =
    let
        val Ast.Block { pragmas, defns, body, loc, ... } = b
        val _ = LogErr.setLoc loc
        val env = if decorative 
                  then env
                  else extendEnvironment env [] false
        val (pragmas, env, unhoisted_pragma_fxtrs) = defPragmas env pragmas
        val (unhoisted_defn_fxtrs, hoisted_defn_fxtrs, inits) = defDefns env defns
        val unhoisted = mergeRibs (#program env) 
                                  unhoisted_defn_fxtrs 
                                  unhoisted_pragma_fxtrs
        val env = addToOuterRib env hoisted_defn_fxtrs
        val env = addToInnerRib env unhoisted
        val (body, hoisted_body_fxtrs) = defStmts env body
        val hoisted = mergeRibs (#program env) hoisted_defn_fxtrs hoisted_body_fxtrs
        val contained = if decorative
                        then []
                        else unhoisted
        val escaped = if decorative
                      then mergeRibs (#program env) hoisted unhoisted 
                      else hoisted
    in
        (Ast.Block { pragmas = pragmas,
                     defns = [],  (* clear definitions, we are done with them *)
                     body = body,
                     head = SOME (Ast.Head (contained, inits)),
                     loc = loc},
         escaped)
    end

(*
  FRAGMENT
*)                          


and defFragment (env:ENV) 
                (frag:Ast.FRAGMENT)
    : (Ast.FRAGMENT * Ast.RIB) =
    let
        val env = enterFragment env frag
    in
        case frag of 
			Ast.Anon blk => 
            let 
                val (blk, escaped) = defDecorativeBlock env blk
            in
                (Ast.Anon blk, escaped)
            end
    end

and mkTopEnv (prog:Fixture.PROGRAM) 
             (langEd:int)
    : ENV =
    { outerRibs = [Fixture.getRootRib prog],
      innerRibs = [],
      tempOffset = 0,
      openNamespaces = (if (langEd > 3)
                        then [[Name.ES4NS], [Name.publicNS ]]
                        else [[Name.publicNS]]),
      labels = [],
      defaultNamespace = Name.publicNS,
      program = prog,
      func = NONE }

and summarizeFragment (Ast.Anon (Ast.Block {head=(SOME (Ast.Head (rib, _))), ...})) =
    Fixture.printRib rib

and defTopFragment (prog:Fixture.PROGRAM)
                   (frag:Ast.FRAGMENT)
                   (langEd:int)
    : (Fixture.PROGRAM * Ast.FRAGMENT) =
    let
        val topEnv = mkTopEnv prog langEd
        val (frag, escaped) = defFragment topEnv frag
		val Ast.Anon (Ast.Block { pragmas, defns, head, body, loc }) = frag
		val newHead = case head of
						  SOME (Ast.Head (rib, inits)) => 
						  SOME (Ast.Head (mergeRibs prog rib escaped, inits))
						| NONE => 
						  SOME (Ast.Head (escaped, []))
    (* 
     * We stuff the escapees back inside the anon block. This is 
	 * ugly and needs a little refactoring. It used to be this way
	 * to handle packages, but is no longer necessary.
     *)
        val frag = Ast.Anon 
                       (Ast.Block { pragmas = pragmas,
                                    defns = [],                                                                       
                                    head = newHead,
                                    body = body,
                                    loc = loc })
        val prog = Fixture.extendRootRib prog escaped (Type.matches prog [])
    in
        trace ["fragment definition complete"];
        (if !doTraceSummary
         then summarizeFragment frag
         else ());
        (if !doTrace
         then Pretty.ppFragment frag
         else ());
        (prog, frag)
    end

end
