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

(*
 * This is the basic entry point for the ES4 reference evaluator.
 * Platform-specific wrappers for different SML implementations
 * may explicitly call the main function from custom entry points.
 *)

structure Main = struct

val interactive = ref true
val quiet = ref false
val langEd = ref 4
val progDir : string option ref = ref NONE

fun usage () =
    (List.app TextIO.print
              ["usage: es4 [-3|-4] [-b] [-h|-r|(-p|-d|-v|-e) file ...] [-Pn] [-Tmod] ...\n",
               "    -3            process input files in 3rd edition mode\n",
               "(*) -4            process input files in 4th edition mode\n",
               "    -b            boot standard library from scratch (ignore image file)\n",
               "    -bv           verify standard library",
               "    -q            quiet (suppress startup banner)\n",
               "\n",
               "    -h            display this help message and exit\n",
               "(*) -r            start the interactive read-eval-print loop\n",
               "    -p            run given files through parse phase and exit\n",
               "    -d            run given files through definition phase and exit\n",
               "    -v            run given files through verification phase and exit\n",
               "    -e            evaluate given files and exit\n",
               "\n",
               "(*) default\n",
               "\n",
               "    -Pn           turn on profiling for stack depth {n}\n",
               "    -Tmod         turn on tracing for module {mod}\n",
               "\n",
               "    mod:\n",
               "        lex       lexing\n",
               "        parse     parsing\n",
               "        name      name resolution\n",
               "        defn      definition phase\n",
               "        verify    verification phase\n",
               "        verified  show post-verification AST alone\n",
               "        eval      evaluator\n",
               "        construct object construction\n",
               "        mach      abstract machine operations\n",
               "        decimal   decimal arithmetic\n",
               "        native    native operations\n",
               "        boot      standard library boot sequence\n",
               "        ns        namespaces in traces\n",
               "        type      operations on types\n",
               "        stack     stack operations\n"])

fun findTraceOption (tname:string)
    : (bool ref) option =
    case tname of
        "lex" => SOME (Lexer.doTrace)
      | "parse" => SOME (Parser.doTrace)
      | "defn" => SOME (Defn.doTrace)
      | "defnsum" => SOME (Defn.doTraceSummary)
      | "verify" => SOME (Verify.doTrace) 
      | "verify_warn" => SOME (Verify.traceWarnings) 
      | "verified" => SOME (Verify.doTraceProg) 
      | "eval" => SOME (Eval.doTrace)
      | "mach" => SOME (Mach.doTrace)
      | "decimal" => SOME (DecimalParams.doTrace)
      | "native" => SOME (Native.doTrace)
      | "boot" => SOME (Boot.doTrace)
      | "type" => SOME (Type.doTrace)
      | "construct" => SOME (Eval.doTraceConstruct) 
      | "ns" => SOME (LogErr.doNamespaces) 
      | "stack" => SOME (Mach.traceStack) 
      (* FIXME: add "fixture" *)
      | _ => NONE

fun consumeOption (opt:string) : bool =
    case explode opt of                                  
        ([#"-", #"3"]) => (langEd := 3; false)
      | ([#"-", #"4"]) => (langEd := 4; false)
      | ([#"-", #"I"]) => (interactive := false; false)
      | ([#"-", #"q"]) => (quiet := true; false)
      | (#"-" :: #"T" :: rest) => (case findTraceOption (String.implode rest) of
                                       SOME r => (r := true; false)
                                     | NONE => true)
      | ([#"-", #"b"]) => false
      | ([#"-", #"b", #"v"]) => (Boot.verifyBuiltins := true; false)
      (*
      | (#"-" :: #"P" :: rest) =>
        (case Int.fromString (String.implode rest) of
             NONE => false
           | SOME 0 => false
           | SOME n => (Eval.doProfile := SOME n; false))
       *)

      | _ => true

exception quitException
exception continueException of Ustring.SOURCE list
exception noboot

val exit = OS.Process.exit
val success = OS.Process.success
val failure = OS.Process.failure

(* FIXME: should use more portable OS.Process.exit *)
fun withEofHandler thunk =
    (thunk (); 0)
(*    handle LogErr.EofError => (print ("**ERROR* EofError: Unexpected end of file\n"); 1) *)

fun withHandlers thunk =
    (thunk (); 0)
    handle
    LogErr.LexError e    => (print ("**ERROR** LexError: " ^ e ^ "\n"); 1)
  | LogErr.ParseError e  => (print ("**ERROR** ParseError: " ^ e ^ "\n"); 1)
  | LogErr.NameError e   => (print ("**ERROR** NameError: " ^ e ^ "\n"); 1)
  | LogErr.TypeError e   => (print ("**ERROR** TypeError: " ^ e ^ "\n"); 1)
  | LogErr.FixtureError e => (print ("**ERROR** FixtureError: " ^ e ^ "\n"); 1)
  | LogErr.DefnError e   => (print ("**ERROR** DefnError: " ^ e ^ "\n"); 1)
  | LogErr.EvalError e   => (print ("**ERROR** EvalError: " ^ e ^ "\n"); 1)
  | LogErr.MachError e   => (print ("**ERROR** MachError: " ^ e ^ "\n"); 1)
  | LogErr.VerifyError e => (print ("**ERROR** VerifyError: " ^ e ^ "\n"); 1)
  | LogErr.HostError e   => (print ("**ERROR** HostError: " ^ e ^ "\n"); 1)
  | LogErr.AstError e    => (print ("**ERROR** AstError: " ^ e ^ "\n"); 1)
  | LogErr.UnimplError e => (print ("**ERROR** UnimplError: " ^ e ^ "\n"); 1)

datatype COMMAND =
    HelpCommand
  | ReplCommand
  | ParseCommand of string list
  | DefineCommand of string list
  | VerifyCommand of string list
  | EvalCommand of string list
  | ResetCommand

fun processOptions (argvRest:string list)
    : COMMAND =
    (case List.filter consumeOption argvRest of
         ("-h"::argvRest) => HelpCommand
       | ("-r"::argvRest) => ReplCommand
       | ("-p"::argvRest) => ParseCommand argvRest
       | ("-d"::argvRest) => DefineCommand argvRest
       | ("-v"::argvRest) => VerifyCommand argvRest
       | ("-e"::argvRest) => EvalCommand argvRest
       | ("-dump"::argvRest) => ResetCommand
       | _ => ReplCommand)

fun parse argvRest =
    (TextIO.print "parsing ... \n";
     List.map Parser.parseFile argvRest)

fun define rootFixtureMap argvRest =
    let
        val progs = parse argvRest
        fun f rootFixtureMap accum (prog::progs) = 
            let 
                val (rootFixtureMap', prog') = Defn.defProgram rootFixtureMap prog (!langEd)
            in
                f rootFixtureMap' (prog'::accum) progs
            end
          | f rootFixtureMap accum _ = (rootFixtureMap, List.rev accum)
    in
        TextIO.print "defining ... \n";
        f rootFixtureMap [] progs
    end

fun verify rootFixtureMap argvRest =
    let
        val (rootFixtureMap, progs) = define rootFixtureMap argvRest
        fun f rootFixtureMap accum (prog::progs) = 
            let 
                val prog' = Verify.verifyProgram rootFixtureMap true prog
            in
                f rootFixtureMap (prog'::accum) progs
            end
          | f rootFixtureMap accum _ = (rootFixtureMap, List.rev accum)
    in
        TextIO.print "verifying ... \n";
        f rootFixtureMap [] progs
    end

fun eval regs argvRest =
    let
        val (rootFixtureMap, progs) = verify (#rootFixtureMap regs) argvRest
        val regs = Eval.withRootFixtureMap regs rootFixtureMap
    in
        Mach.setLangEd regs (!langEd);
        Posix.Process.alarm (Time.fromReal 300.0);
	    TextIO.print "evaluating ... \n";
        withHandlers (fn () => map (Eval.evalProgram regs) progs)
    end

fun getProgDir() =
    let
        val name = CommandLine.name()
        val {dir, ...} = OS.Path.splitDirFile (CommandLine.name())
    in
        (* FIXME: total hack for telling whether we're running in the SML/NJ REPL *)
        if String.isSuffix "sml" name then
            OS.FileSys.getDir()
        else
            dir
    end

fun repl (regs:Mach.REGS)
         (dump:string -> bool)
         (readLine:string -> string option)
    : unit =
    let
        val regsCell = ref regs

        val doParse = ref true
        val doDefn = ref true
        val doEval = ref true
        val beStrict = ref false

        fun toggleRef (n:string) (r:bool ref) =
            (r := not (!r);
             print ("set " ^ n ^ " = " ^ (Bool.toString (!r)) ^ "\n"))

        fun doLine (accum:Ustring.SOURCE list) : unit =
            let
(*
                val _ = (case accum of
                             [] =>  if !interactive then print ">> " else print "<SMLREADY>\n"
                           | _ => ())
*)
                val line = case readLine (if !interactive then ">> " else "<SMLREADY>\n") of
                               NONE => raise quitException
                             | SOME s => s
                val toks = String.tokens Char.isSpace line
                fun help _ = (List.app print
                                       [
                                        ":quit          - quit repl\n",
                                        ":trace <T>     - toggle tracing of <T>\n",
                                        ":help          - this message\n",
                                        ":reboot        - reload the boot environment\n",
                                        ":parse         - toggle parse stage\n",
                                        ":defn          - toggle defn stage\n",
                                        ":strict        - toggle strict verification\n",
                                        ":eval          - toggle evaluation stage\n",
                                        ":profile <N>   - toggle profiling at depth <N>\n"
                                       ])
            in
                case toks of
                    [":quit"] => raise quitException
                  | [":3"] => (langEd := 3)
                  | [":4"] => (langEd := 4)
                  | [":q"] => raise quitException
                  | [":h"] => help ()
                  | [":help"] => help ()
                  | [":?"] => help ()
                  | ["?"] => help ()
                  | [":reboot"] => (regsCell := Boot.boot (valOf (!progDir)))
                  | [":parse"] => toggleRef "parse" doParse
                  | [":defn"] => toggleRef "defn" doDefn
                  | [":eval"] => toggleRef "eval" doEval
                  | [":strict"] => toggleRef "strict" beStrict
                  | [":trace", t] =>
                    (case findTraceOption t of
                         NONE =>
                         (print ("unknown trace option " ^ t ^ "\n"))
                       | SOME r => toggleRef ("trace option " ^ t) r)

                  | [":profile", n] =>
                    (case Int.fromString n of
                         NONE => Mach.setProfile (!regsCell) NONE
                       | SOME 0 => Mach.setProfile (!regsCell) NONE
                       | SOME n => Mach.setProfile (!regsCell) (SOME n))

                  | [] => ()
                  | _ =>
                    if not (!doParse) then () else
                    let
                        val lines = (Ustring.fromSource line) :: accum
                        val prog = Parser.parseLines (List.rev lines)
                            handle LogErr.EofError => raise continueException lines
			            fun tidyUp _ = 
				            let
				                val stk = Mach.stackOf (!regsCell)
				                val ss = Mach.stackString stk
				                val _ = Mach.resetStack (!regsCell)
				            in
				                print ("Uncaught exception at: " ^ ss ^ "\n")
				            end
                    in
                        if not (!doDefn) then () else
                        let
                            val (rootFixtureMap, prog) = Defn.defProgram (#rootFixtureMap (!regsCell)) prog (!langEd)
                            val prog = Verify.verifyProgram rootFixtureMap true prog
                        in
                            regsCell := Eval.withRootFixtureMap regs rootFixtureMap;
                            if not (!doEval) then () else
                            let
                                val regs = !regsCell
					            val _ = Mach.resetStack regs
                                val _ = Mach.setLangEd regs (!langEd)
                                val res = (Eval.evalProgram regs prog)
						            handle Eval.ThrowException v => (tidyUp (); v)
                            in
                                case res of
                                    Mach.UndefinedValue => ()
                                  | _ => 
						            print (Ustring.toAscii 
                                               (Eval.toUstring (!regsCell) res) ^ "\n")
						            handle Eval.ThrowException v => 
						                   (tidyUp();
							                print (Ustring.toAscii 
								                       (Eval.toUstring (!regsCell) v) ^ "\n")
							                handle Eval.ThrowException _ => 
							                       tidyUp() (* oh forget it... *))
                            end
                        end
                    end
            end

        fun runUntilQuit accum =
            runUntilQuit ((withHandlers (fn () => doLine accum); [])
                          handle continueException accum' => accum')
    in
        if (!quiet) then () else
            TextIO.print (Version.banner ^ "\n");
        (runUntilQuit [])
        handle quitException => print "bye\n"
    end

and main (dump:string -> bool)
         (readLine:string -> string option)
    : 'a =
    let
        fun resume (regs:Mach.REGS option) =
            let
                val dir = getProgDir()

                fun getRegs() = (case regs of
                                     NONE => (Boot.boot dir
                                              handle
                                              LogErr.LexError e => (print ("**BOOT ERROR** LexError: " ^ e ^ "\n"); raise noboot)
                                            | LogErr.ParseError e => (print ("**BOOT ERROR** ParseError: " ^ e ^ "\n"); raise noboot)
                                            | LogErr.NameError e => (print ("**BOOT ERROR** NameError: " ^ e ^ "\n"); raise noboot)
                                            | LogErr.TypeError e => (print ("**BOOT ERROR** TypeError: " ^ e ^ "\n"); raise noboot)
                                            | LogErr.FixtureError e => (print ("**BOOT ERROR** FixtureError: " ^ e ^ "\n"); raise noboot)
                                            | LogErr.DefnError e => (print ("**BOOT ERROR** DefnError: " ^ e ^ "\n"); raise noboot)
                                            | LogErr.EvalError e => (print ("**BOOT ERROR** EvalError: " ^ e ^ "\n"); raise noboot)
                                            | LogErr.MachError e => (print ("**BOOT ERROR** MachError: " ^ e ^ "\n"); raise noboot)
                                            | LogErr.VerifyError e => (print ("**BOOT ERROR** VerifyError: " ^ e ^ "\n"); raise noboot)
                                            | LogErr.HostError e => (print ("**BOOT ERROR** HostError: " ^ e ^ "\n"); raise noboot)
                                            | LogErr.AstError e => (print ("**BOOT ERROR** AstError: " ^ e ^ "\n"); raise noboot)
                                            | LogErr.UnimplError e => (print ("**BOOT ERROR** UnimplError: " ^ e ^ "\n"); raise noboot))
                                   | SOME regs => regs)
            in
                progDir := SOME dir;
                case processOptions (CommandLine.arguments()) of
                    HelpCommand => (usage (); success)
                  | ReplCommand => (repl (getRegs()) dump readLine; success)
                  | ParseCommand files => (parse files; success)
                  | DefineCommand files => (define (#rootFixtureMap (getRegs())) files; success)
                  | VerifyCommand files => (verify (#rootFixtureMap (getRegs())) files; success)
                  | EvalCommand files => (eval (getRegs()) files; success)
                  | ResetCommand =>
                    let
                        val _ = TextIO.print "Building image...\n"
                        val regs = Boot.boot dir
                    in
                        if dump (OS.Path.joinDirFile {dir = dir, file = "es4.image"}) then
                            resume (SOME regs)
                        else
                            success
                    end
            end
    in
        exit (withEofHandler
                  (fn () =>
                      withHandlers
                          (fn () =>
                              resume NONE)))
    end

end
