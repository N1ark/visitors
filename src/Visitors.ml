open VisitorsList
open VisitorsString
open Longident
open Location
open List
let sprintf = Printf.sprintf
open Asttypes
open Parsetree
open Ast_helper
open Ast_convenience
open Ppx_deriving
open VisitorsAnalysis
open VisitorsGeneration

let plugin =
  "visitors"

(* -------------------------------------------------------------------------- *)

(* We can generate two classes, [iter] and [map]. They are mostly identical,
   and differ only in the code that is executed after the recursive calls. In
   [iter], this code does nothing; in [map], it reconstructs a data
   structure. *)

type variety =
  | Iter
  | Map

(* -------------------------------------------------------------------------- *)

(* Option processing. *)

(* The option [arity], accompanied with an integer parameter, allows setting
   the arity at which we generate code. *)

let arity =
  ref 0 (* dummy *)

(* The option [freeze], accompanied with a list of type variables, indicates
   which parameters of the type definition should be treated as nonlocal types. *)

let freeze =
  ref [] (* dummy *)

(* The option [irregular = true] suppresses the regularity check and allows a
   local parameterized type to be instantiated; e.g., the definition of ['a t]
   can then refer to [int t]. However, in most situations, this will lead to
   ill-typed generated code. The generated code should be well-typed if [t] is
   always instantiated in the same manner, e.g., if there are references to
   [int t] but not to other instances of [t]. *)

let irregular =
  ref false (* dummy *)

(* The option [name] specifies the name of the generated class. It is NOT
   optional. *)

let name =
  ref "" (* dummy *)

(* The option [nonlocal], accompanied with a list of module names, allows
   setting the modules that are searched for nonlocal functions, such as
   [List.iter]. The modules that appear first in the list are searched
   last. *)

let nonlocal : Longident.t list ref =
  ref [] (* dummy *)

(* The option [variety] indicates what kind of visitor we are generating.
   We support two kinds: [iter] and [map]. *)

let variety : variety option ref =
  ref None (* dummy *)

let variety_string =
  ref "" (* TEMPORARY moche *)

let parse_variety loc (s : string) =
  variety_string := s;
  try
    if prefix "map" s then
      let s = remainder "map" s in
      let i = if s = "" then 1 else int_of_string s in
      if i <= 0 then failwith "negative integer";
      Map, i
      (* TEMPORARY should allow positive integer only *)
    else if prefix "iter" s then
      let s = remainder "iter" s in
      let i = if s = "" then 1 else int_of_string s in
      if i <= 0 then failwith "negative integer";
      Iter, i
    else
      failwith "unexpected prefix"
  with
  | Failure _ ->
      raise_errorf ~loc "%s: invalid variety.\n\
                         A valid variety is iter, map, iter2, map2, etc." plugin

let parse_options loc options =
  let bool = Arg.get_expr ~deriver:plugin Arg.bool
  and string = Arg.get_expr ~deriver:plugin Arg.string
  and strings = Arg.get_expr ~deriver:plugin (Arg.list Arg.string) in
  (* The default values are specified here. *)
  arity := 1;
  freeze := [];
  irregular := false;
  name := "";
  nonlocal := [ Lident "VisitorsRuntime" ];
  variety := None;
  (* Analysis. *)
  iter (fun (o, e) ->
    let loc = e.pexp_loc in
    match o with
    | "freeze" ->
         freeze := strings e
    | "irregular" ->
        irregular := bool e
    | "name" ->
        name := string e;
        if String.length !name = 0 || String.uncapitalize_ascii !name <> !name then
          (* TEMPORARY should implement [is_valid_ocaml_class_name] properly *)
          raise_errorf ~loc "%s: %s must be a valid class name." plugin o
    | "nonlocal" ->
        (* TEMPORARY should check that every string in the list is a valid module name *)
        (* Always open [VisitorsRuntime], but allow it to be shadowed by
           user-specified modules. *)
        nonlocal := map Longident.parse ("VisitorsRuntime" :: strings e)
    | "variety" ->
        let v, a = parse_variety loc (string e) in
        variety := Some v;
        arity := a;
    | _ ->
        raise_errorf ~loc "%s: option %s is not supported." plugin o
  ) options;
  (* The parameter [name] is not optional. *)
  if String.length !name = 0 then
    raise_errorf ~loc "%s: please specify the name of the generated class.\n\
                       e.g. [@@deriving visitors { name = \"traverse\" }]" plugin;
  (* The parameter [variety] is not optional. *)
  if !variety = None then
    raise_errorf ~loc "%s: please specify the variety of the generated class.\n\
                       e.g. [@@deriving visitors { variety = \"iter\" }]" plugin

(* -------------------------------------------------------------------------- *)

(* We support parameterized type declarations, we require them to be regular.
   That is, for instance, if a type ['a term] is being defined, then every
   use of [_ term] in the definition should be ['a term]; it cannot be, say,
   [int term] or [('a * 'a) term]. *)

(* To enforce this, we check that, in every use of a local type constructor,
   the actual type parameters coincide with the formal type parameters. *)

let check_regularity loc tycon (formals : tyvar list) (actuals : core_type list) =
  (* Check that the numbers of parameters match. *)
  if length formals <> length actuals then
    raise_errorf ~loc
      "%s: the type constructor %s expects %s,\n\
       but is applied to %s."
      plugin tycon
      (number (length formals) "type parameter")
      (number (length actuals) "type parameter");
  (* Check that the parameters match. *)
  if not !irregular && not (
    fold_left2 (fun ok formal actual ->
      ok && actual.ptyp_desc = Ptyp_var formal
    ) true formals actuals
  ) then
    raise_errorf ~loc "%s: the type constructor %s is irregular." plugin tycon

(* -------------------------------------------------------------------------- *)

(* Per-run global state. *)

module Run (X : sig

  (* The type declarations that we are processing. *)
  val decls: type_declaration list

  (* The name of the generated class. *)
  val current: classe

  (* The arity of the generated code, e.g., 1 if one wishes to generate [iter]
     and [map], 2 if one wishes to generate [iter2] and [map2], and so on. *)
  val arity: int

  (* The variety of visitor that we wish to generate (see the definition of
     the type [variety] above). *)
  val variety: variety

end) = struct

let is_local =
  is_local X.decls

let current =
  X.current

let arity =
  X.arity

let choose e1 e2 =
  match X.variety with
  | Iter -> e1
  | Map  -> e2

let is_frozen (tv : tyvar) =
  List.mem tv !freeze (* TEMPORARY clean up *)

(* As we generate several classes at the same time, we maintain, for each
   generated class, a list of methods that we generate as we go. The following
   line brings [generate] and [dump] into scope. *)

include ClassFieldStore(struct end)

(* -------------------------------------------------------------------------- *)

(* Public naming conventions. *)

(* For every type constructor [tycon], there is a visitor method, also called
   a descending method, as it is invoked when going down into the tree. *)

let tycon_visitor_method (tycon : Longident.t) : methode =
  (* We support qualified names, and, in that case, use the last part of the
     qualified name to obtain the name of the visitor method. A qualified name
     is probably a nonlocal type, that is, not part of the current set of type
     declarations. *)
  (* I would like to use [last tycon] directly as the name of the method, but
     that could (in theory) create a conflict with the names of other methods.
     In order to guarantee the absence of conflicts, we must use a nonempty
     prefix. *)
  "visit_" ^ last tycon

(* Type variables are treated as nonlocal type constructors, so they also have
   a descending method. We include a quote in the method name so as to ensure
   the absence of collisions. *)

let tyvar_visitor_method (tv : tyvar) : methode =
  "visit_'" ^ tv

(* For every data constructor [datacon], there is a descending visitor method,
   which is invoked on the way down, when this data constructor is discovered. *)

let datacon_descending_method (datacon : datacon) : methode =
  "visit_" ^ datacon

(* At arity 2, for every sum type constructor [tycon] which has at least two
   data constructors, there is a failure method, which is invoked when the
   left-hand and right-hand arguments do not exhibit the same tags. *)

let failure_method (tycon : tycon) : methode =
  "fail_" ^ tycon

(* For every nonlocal type constructor [tycon], we need a visitor function.
   E.g., if we are generating a class [map], then for the type constructor
   [list], we need [List.map]. Note that this is not an absolute name: its
   interpretation depends on which modules have been opened. This can be
   influenced by the user via the option [nonlocal]. *)

let nonlocal_tycon_module (tycon : Longident.t) : Longident.t =
  match tycon with
  | Lident tycon ->
      (* Turn [list] into [List]. *)
      Lident (String.capitalize_ascii tycon)
  | Ldot (path, "t") ->
      (* Turn [Foo.t] into [Foo]. *)
      path
  | Ldot (path, tycon) ->
      (* Turn [Foo.list] into [Foo.List]. *)
      Ldot (path, String.capitalize_ascii tycon)
  | Lapply _ ->
      assert false

let nonlocal_tycon_function (tycon : Longident.t) : Longident.t =
  (* For [list], we need [List.map]. *)
  Ldot (nonlocal_tycon_module tycon, !variety_string)

(* -------------------------------------------------------------------------- *)

(* Private naming conventions. *)

(* These conventions must be set up so as to avoid collisions within each name
   space separately: e.g., variables, methods, type variables, and so on. *)

(* In a class, the variable [self] refers to self.
   The type variable [ty_self] denotes its type. *)

let self : variable =
  "self"

let ty_self : core_type =
  Typ.var "self"

let pself : pattern =
  Pat.constraint_ (pvar self) ty_self

(* The variable [env] refers to the environment that is carried down into
   recursive calls. *)

let env : variable =
  "env"

(* We sometimes need two (or more) copies of a variable: one copy for each
   index [j] ranging in the interval [0..arity). *)

let copy (j : int) (x : string) : string =
  assert (0 <= j && j < arity);
  if arity = 1 then
    (* No alteration required. *)
    x
  else
    sprintf "%s_%d" x j

(* The variables [component i j] denote tuple components. The index [i]
   ranges over tuple components; the index [j] ranges in [0..arity). *)

let component (i : int) (j : int) : variable =
  copy j (sprintf "c%d" i)

let components (i : int) : variable list =
  map (component i) (interval 0 arity)

let componentss (xs : _ list) : variable list list =
  mapi (fun i _ -> components i) xs

(* The variable [thing tycon j] denotes a value of type [tycon]. *)

let thing (tycon : tycon) (j : int) : variable =
  copy j (sprintf "this_%s" tycon)

let things (tycon : tycon) : variable list =
  map (thing tycon) (interval 0 arity)

(* The variables [field label j] denote record fields. *)

let field (label : label) (j : int) : variable =
  copy j (sprintf "f%s" label)

let fields (label : label) : variable list =
  map (field label) (interval 0 arity)

let fieldss (labels : label list) : variable list list =
  map fields labels

(* The variables [result i] denote results of recursive calls. *)

let result (i : int) : variable =
  sprintf "r%d" i

let results (xs : _ list) : variable list =
  mapi (fun i _ -> result i) xs

(* -------------------------------------------------------------------------- *)

(* [hook m xs e] constructs a call of the form [self#m xs], and (as a side
   effect) generates a method [method m xs = e]. The free variables of the
   expression [e] must be (a subset of) [xs]. *)

(* Thus, by default, the expression [hook m xs e] behaves in the same way
   as the expression [e]. But a hook, named [m], allows this default to be
   overridden. *)

let hook (m : string) (xs : string list) (e : expression) : expression =
  (* Generate a method. The formal parameters [xs] don't need a type
     annotation: because this method has a call site, its type can be
     inferred. *)
  generate current (concrete_method m (lambdas xs e));
  (* Construct a method call. *)
  send self m (evars xs)

(* -------------------------------------------------------------------------- *)

(* [visit_type env_in_scope ty] builds a small expression that represents the
   visiting code associated with the OCaml type [ty]. For instance, if [ty] is
   a local type constructor, this could be a call to the visitor method
   associated with this type constructor. *)

(* This expression may refer to the variable [self]. *)

(* If [env_in_scope] is true, then this expression may refer to the variable
   [env]. If [env_in_scope] is false, then this expression should denote a
   function of [env]. The use of [env_in_scope] complicates things slightly,
   but allows us to avoid the production of certain eta-redexes. *)

let rec visit_type (env_in_scope : bool) (ty : core_type) : expression =
  match env_in_scope, ty with

  (* A type constructor [tycon] applied to type parameters [tys]. We handle
     the case where [env_in_scope] is false, so we construct a function of
     [env]. *)
  | false,
    { ptyp_desc = Ptyp_constr ({ txt = (tycon : Longident.t); _ }, tys); _ } ->
      begin match is_local tycon with
      | Some formals ->
          (* [tycon] is a local type constructor, whose formal type parameters
             are [formals]. *)
          (* Check that [tys] and [formals] coincide. If they do not, we cannot
             handle this type declaration. *)
          check_regularity ty.ptyp_loc (last tycon) formals tys;
          (* Return the visitor method associated with [tycon]. Contrary to
             the nonlocal case (below), this method must not be applied to the
             visitor functions associated with [tys]. *)
          send self
            (tycon_visitor_method tycon)
            []
      | None ->
          (* [tycon] is a nonlocal type constructor. Invoke the (user-supplied)
             external function associated with it. This function is typically
             polymorphic, so multiple call sites do not pollute one another.
             This function must be applied to the visitor functions associated
             with [tys]. *)
          (* The search for this external function (by the compiler) is influenced
             by the [open] directives that we place at the beginning of the generated
             code. *)
          app
            (eident (nonlocal_tycon_function tycon))
            (map (visit_type false) tys)
      end

  (* A type variable [tv] is normally handled by a virtual method visitor.
     However, if this type variable has been marked as [frozen] by the user,
     then it is treated as if it were a nonlocal type by the same name. *)
  | false,
    { ptyp_desc = Ptyp_var tv; _ } ->
      if is_frozen tv then
        visit_type
          env_in_scope
          { ty with ptyp_desc = Ptyp_constr (mknoloc (Lident tv), []) }
      else begin
        generate current (virtual_method (tyvar_visitor_method tv));
        send self
          (tyvar_visitor_method tv)
          []
        end

  (* A tuple type. We handle the case where [env_in_scope] is true, as it
     is easier. *)
  | true,
    { ptyp_desc = Ptyp_tuple tys; _ } ->
      (* Construct a function that takes [arity] tuples as arugments. *)
      (* See [constructor_declaration] for comments. *)
      let xss = componentss tys in
      let rs = results xss in
      plambdas
        (ptuples (transpose arity (pvarss xss)))
        (letn rs (visit_types tys (evarss xss))
          (choose
            (unit())
            (tuple (evars rs))
          )
        )

  (* If [env_in_scope] does not have the desired value, wrap a recursive call
     within an application or abstraction. At most one recursive call takes
     place, so we never produce an eta-redex. *)
  | true, { ptyp_desc = (Ptyp_constr _ | Ptyp_var _); _ } ->
     app (visit_type false ty) [evar env]
  | false, { ptyp_desc = (Ptyp_tuple _); _ } ->
     lambda env (visit_type true ty)

  (* An unsupported construct. *)
  | _, _ ->
      let loc = ty.ptyp_loc in
      raise_errorf ~loc "%s: cannot deal with the type %s." plugin
        (string_of_core_type ty)

and visit_types tys (ess : expression list list) : expression list =
  (* The matrix [ess] is indexed first by component, then by index [j].
     Thus, to each type [ty], corresponds a row [es] of expressions,
     whose length is [arity]. *)
  assert (is_matrix (length tys) arity ess);
  map2 (fun ty es ->
    app (visit_type true ty) es
  ) tys ess

(* -------------------------------------------------------------------------- *)

(* [constructor_declaration] turns a constructor declaration (as found in a
   declaration of a sum type) into a case, that is, a branch in the case
   analysis construct that forms the body of the visitor method for this sum
   type. At the same time, it generates several auxiliary method declarations
   and definitions. *)

let constructor_declaration (cd : constructor_declaration) : case =

  (* This is either a traditional data constructor, whose components are
     anonymous, or a data constructor whose components form an ``inline
     record''. This is a new feature of OCaml 4.03. *)

  (* In order to treat these two cases uniformly, we extract the following
     information.
     [xss]      the names under which the components are known.
                this matrix has [length tys] rows -- one per component --
                and [arity] columns.
     [tys]      the types of the components.
     [pss]      the patterns that bind [xss], on the way down.
                this matrix has [arity] rows.
                it has [length tys] columns in the case of tuples,
                and 1 column in the case of inline records.
     [build]    the expressions that rebuild a data constructor, on the way up.
  *)

  let xss, tys, pss, (build : variable list -> expression list) =
  match cd.pcd_args with
    (* A traditional data constructor. *)
    | Pcstr_tuple tys ->
        let xss = componentss tys in
        let pss = transpose arity (pvarss xss) in
        xss, tys, pss, evars
    (* An ``inline record'' data constructor. *)
    | Pcstr_record lds ->
        let labels, tys = ld_labels lds, ld_tys lds in
        let xss = fieldss labels in
        let pss = transpose arity (pvarss xss) in
        xss, tys,
        map (fun ps -> [precord ~closed:Closed (combine labels ps)]) pss,
        fun rs -> [record (combine labels (evars rs))]
  in
  assert (is_matrix (length tys) arity xss);
  assert (length pss = arity);

  (* Get the name of this data constructor. *)
  let datacon = cd.pcd_name.txt in
  (* Create new names [rs] for the results of the recursive calls of visitor
     methods. *)
  let rs = results xss in

  (* Construct a case for this data constructor in the visitor method
     associated with this sum type. This case analyzes a tuple of width
     [arity]. After binding the components [xss], we call the descending
     method associated with this data constructor, with arguments [env] and
     [xss]. This method binds the variables [rs] to the results of the
     recursive calls to visitor methods, then (in the class [iter]) returns a
     unit value or (in the class [map]) reconstructs a tree node. *)
  Exp.case
    (ptuple (map (pconstr datacon) pss))
    (hook (datacon_descending_method datacon) (env :: flatten xss)
       (letn
          rs (visit_types tys (evarss xss))
          (choose
            (unit())
            (constr datacon (build rs))
          )
       )
    )

(* -------------------------------------------------------------------------- *)

(* [visit_decl decl] constructs an expression that represents the visiting
   code associated with the type declaration [decl]. In other words, it is
   the body of the visitor method associated with [decl]. *)

let visit_decl (decl : type_declaration) : expression =

  (* Bind the values to a vector of variables [xs]. *)
  let tycon = decl.ptype_name.txt in
  let xs = things tycon in
  assert (length xs = arity);

  match decl.ptype_kind, decl.ptype_manifest with

  (* A type abbreviation. *)
  | Ptype_abstract, Some ty ->
      visit_type true ty

  (* A record type. *)
  | Ptype_record (lds : label_declaration list), _ ->
      let labels, tys = ld_labels lds, ld_tys lds in
      (* See [constructor_declaration] for comments. *)
      lambdas xs (
        let rs = results labels in
        letn rs (visit_types tys (accesses xs labels))
          (choose
            (unit())
            (record (combine labels (evars rs)))
          )
      )

  (* A sum type. *)
  | Ptype_variant (cds : constructor_declaration list), _ ->
      (* Generate one case per data constructor. Place these cases in a
         [match] construct, which itself is placed in a function body. *)
      (* If [arity] is greater than 1 and if there is more than one data
         constructor, then generate also a default case. In this default
         case, invoke the failure method, which raises an exception. The
         failure method receives [env] and [xs] as arguments. *)
      let default() : case =
        Exp.case
          (ptuple (pvars xs))
          (hook (failure_method tycon) (env :: xs)
            (* This method ignores its arguments, which can cause warnings. *)
            (efail (tycon_visitor_method (Lident tycon)))
          )
      in
      let complete (cs : case list) : case list =
        if arity = 1 || length cs <= 1 then cs else cs @ [ default() ]
      in
      lambdas xs (
        Exp.match_
          (tuple (evars xs))
          (complete (map constructor_declaration cds))
      )

  (* Unsupported constructs. *)
  | Ptype_abstract, None ->
      let loc = decl.ptype_loc in
      raise_errorf ~loc "%s: cannot deal with abstract types." plugin

  | Ptype_open, _ ->
      let loc = decl.ptype_loc in
      raise_errorf ~loc "%s: cannot deal with open types." plugin

(* -------------------------------------------------------------------------- *)

(* [type_decl decl] generates the main visitor method associated with the type
   declaration [decl], as well as the necessary auxiliary methods. *)

let type_decl (decl : type_declaration) : unit =
  generate current (
    concrete_method
      (tycon_visitor_method (Lident decl.ptype_name.txt))
      (plambda (pvar env) (visit_decl decl))
  )

end

(* -------------------------------------------------------------------------- *)

(* [type_decls decls] produces a list of structure items (that is, toplevel
   definitions) associated with the type declarations [decls]. *)

(* Our classes are parameterized over the type variable ['env]. They are also
   parameterized over the type variable ['self], with a constraint that this
   is the type of [self]. This trick allows us to omit the types of the
   virtual methods, even if these types include type variables. *)

(* TEMPORARY move [parse_options] down here and avoid needless global state *)

let type_decls ~options ~path:_ (decls : type_declaration list) : structure =
  assert (decls <> []);
  let loc = (VisitorsList.last decls).ptype_loc in (* an approximation *)
  parse_options loc options;
  let module R = Run(struct
    let decls = decls
    let variety = match !variety with None -> assert false | Some v -> v
    let arity = !arity
    let current = !name
  end) in
  let open R in
  (* Analyze the type definitions, and populate our classes with methods. *)
  iter type_decl decls;
  (* In the generated code, disable certain warnings, so that the user sees
     no warnings, even if she explicitly enables them. We disable warnings
     26, 27 (unused variables) and 4 (fragile pattern matching; a feature
     intentionally exploited by [iter2] and [map2]). *)
  [ with_warnings "-4-26-27" (
    (* Surround the generated code with floating attributes, which can be
       used as markers to find and review the generated code. We use this
       mechanism to show the generated code in the documentation. *)
    floating "VISITORS.BEGIN" [] ::
    (* Open the module [VisitorsRuntime], as well as all modules specified
       by the user via the [nonlocal] option. In theory it would be preferable
       to use a tight [let open] declaration around every reference to an
       external function. However, the generated code looks nicer if we use
       a single series of [open] declarations at the beginning. These [open]
       declarations have local scope because [with_warnings] creates a local
       module using [include struct ... end]. *)
    stropen !nonlocal @
    (* Produce a class definition. *)
    class1 [ ty_self, Invariant ] current pself (dump current) ::
    floating "VISITORS.END" [] ::
    []
  )]

(* -------------------------------------------------------------------------- *)

(* Register our plugin with [ppx_deriving]. *)

let () =
  register (create plugin ~type_decl_str:type_decls ())
