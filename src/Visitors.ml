open List
open Longident
open Location
open Asttypes
open Parsetree
open Ast_helper
open Ast_convenience
open Ppx_deriving
open VisitorsAnalysis
open VisitorsGeneration

(* -------------------------------------------------------------------------- *)

(* General infrastructure. *)

let plugin =
  "visitors"

(* No options are supported. *)

let parse_options options =
  options |> iter (fun (name, expr) ->
    match name with
    | _ ->
       raise_errorf
         ~loc:expr.pexp_loc
         "%s does not support option %s"
         plugin
         name
  )

(* -------------------------------------------------------------------------- *)

(* Public naming conventions. *)

(* We generate three classes: a [visitor] base class and two subclasses, [iter]
   and [map]. *)

let cvisitor : classe =
  "visitor"

let citer : classe =
  "iter"

let cmap : classe =
  "map"

(* For every type constructor [tycon], there is a visitor method, also called
   a descending method, as it is invoked when going down into the tree. *)

let tycon_visitor_method (tycon : Longident.t) : methode =
  (* We support qualified names, and use the last part of the name as the name
     of the visitor method. A qualified name is probably a nonlocal type, that
     is, not part of the current set of type declarations. *)
  last tycon
  (* TEMPORARY nice-looking convention, but can cause a conflict
     if a tycon or datacon name begins with "build_" or "match_" *)

(* For every data constructor [datacon], there is a descending visitor method,
   which is invoked on the way down, when this data constructor is discovered. *)

let datacon_descending_method (datacon : datacon) : methode =
  "match_" ^ datacon

(* For every data constructor [datacon], there is also an ascending visitor
   method, which is invoked on the way up, after children have been processed,
   in order to finish the processing of this node. In the base class, this
   ascending method is virtual. In the class [iter], it is defined to return a
   unit value. In the class [map], it is defined to reconstruct a new tree
   node using [datacon]. *)

let datacon_ascending_method (datacon : datacon) : methode =
  "build_" ^ datacon

(* For every record type constructor [tycon], there is an ascending visitor
   method. (See above description.) *)

let record_ascending_method (tycon : tycon) : methode =
  "build_" ^ tycon

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
   recursive calls. The type variable [ty_env] denotes its type. *)

let env : variable =
  "env"

let ty_env : core_type =
  Typ.var "env"

let penv : pattern =
  Pat.constraint_ (pvar env) ty_env

(* The variables [component i] denote tuple components. *)

let component (i : int) : variable =
  Printf.sprintf "c%d" i

let components (xs : _ list) : variable list =
  mapi (fun i _ -> component i) xs

(* The variable [thing tycon] denotes a record of type [tycon]. *)

let thing (tycon : tycon) : variable =
  Printf.sprintf "_%s" tycon

(* The variables [field label] denote record fields. *)

let field (label : label) : variable =
  Printf.sprintf "f%s" label

let fields (labels : label list) : variable list =
  map field labels

(* The variables [result i] denote results of recursive calls. *)

let result (i : int) : variable =
  Printf.sprintf "r%d" i

let results (xs : _ list) : variable list =
  mapi (fun i _ -> result i) xs

(* -------------------------------------------------------------------------- *)

(* Per-run global state. *)

module Run (Current : sig val decls : type_declaration list end) = struct

(* As we generate several classes at the same time, we maintain, for each
   generated class, a list of methods that we generate as we go. The following
   line brings [generate] and [dump] into scope. *)

include ClassFieldStore(struct end)

(* -------------------------------------------------------------------------- *)

(* [hook m xs e] constructs a call of the form [self#m xs], and (as a side
   effect) generates a method [method m xs = e]. The free variables of the
   expression [e] must be (a subset of) [xs]. *)

(* Thus, by default, the expression [hook m xs e] behaves in the same way
   as the expression [e]. But a hook, named [m], allows this default to be
   overridden. *)

let hook (m : string) (xs : string list) (e : expression) : expression =
  (* Generate a method in the class [visitor]. We note that the formal
     parameters [xs] don't need a type annotation: because this method has a
     call site, its type can be inferred. *)
  generate cvisitor (concrete_method m (lambdas xs e));
  (* Construct a method call. *)
  send self m (evars xs)

(* [hooks m xs e1 e2] constructs a call of the form [self#m xs], and (as a side
   effect) generates a virtual method named [m] in the class [visitor]. It also
   generates an implementation [method m xs = e1] in the subclass [iter] and an
   implementation [method m xs = e2] in the subclass [map]. The free variables
   of the expressions [e1] and [e2] must be (a subset of) [xs]. *)

let hooks (m : string) (xs : variable list)
          (e1 : expression) (e2 : expression) : expression =
  (* Generate a declaration of [m] as a virtual method in the class [visitor].
     We note that it does not need a type annotation: because we have used the
     trick of parameterizing the class over its ['self] type, no annotations
     at all are needed. *)
  generate cvisitor (virtual_method m);
  (* Define this method in the subclass [iter]. *)
  (* An ad hoc detail: we assume that [e1] does not use its arguments [xs],
     so, in order to avoid OCaml's warning about unused variables, we replace
     them with wildcard patterns. *)
  generate citer (concrete_method m (plambdas (wildcards xs) e1));
  (* Define this method in the subclass [map]. *)
  generate cmap (concrete_method m (lambdas xs e2));
  (* Construct a method call. *)
  send self m (evars xs)

(* -------------------------------------------------------------------------- *)

(* [visit_type ty] builds a small expression that represents the visiting code
   associated with the OCaml type [ty]. For instance, if [ty] is a local type
   constructor, this could be a call to the visitor method associated with
   this type constructor. The expression constructed by [visit_type ty] may
   refer to the variables [self] and [env]. *)

let rec visit_type (ty : core_type) : expression =
  match ty with

  (* A type constructor [tycon] applied to type parameters [tys]. *)
  | { ptyp_desc = Ptyp_constr ({ txt = (tycon : Longident.t); _ }, tys); _ } ->
     (* Check if this is a local type constructor. If not, declare a virtual
        method for it. We rely on the fact that it is permitted for a virtual
        method to be declared several times. *)
      if not (is_local Current.decls tycon) then
        generate cvisitor (virtual_method (tycon_visitor_method tycon));
      (* Return the visitor method associated with [tycon]. It must be applied
         to the visitor functions associated with [tys] and to the environment
         [env]. *)
      send self
        (tycon_visitor_method tycon)
        (map lambda_env_visit_type tys @ [evar env])

  (* A tuple type. *)
  | { ptyp_desc = Ptyp_tuple tys; _ } ->
      (* Construct a function. In the case of tuples, as opposed to data
         constructors, we do not call an ascending method, as we would need
         one method name per tuple type, and that would be messy. Instead, we
         make the most general choice of ascending computation, which is to
         rebuild a tuple on the way up. Fortunately, this should always be
         well-typed, I believe. We do not need a descending method either
         because there is no case analysis. *)
      let xs = components tys in
      let es = visit_types tys (evars xs) in
      plambda (ptuple (pvars xs)) (tuple es)

  (* An unsupported construct. *)
  | { ptyp_loc; _ } ->
      raise_errorf
        ~loc:ptyp_loc
        "%s cannot be derived for %s"
        plugin
        (string_of_core_type ty)

and lambda_env_visit_type ty =
  lambda env (visit_type ty)

and visit_types tys es =
  map2 app1 (map visit_type tys) es

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
     [xs]       the names under which the components are known.
     [tys]      the types of the components
     [ps]       the patterns that bind [xs], on the way down
     [build]    the expressions that rebuild a data constructor, on the way up
  *)

  let xs, tys, ps, (build : variable list -> expression list) =
  match cd.pcd_args with
    (* A traditional data constructor. *)
    | Pcstr_tuple tys ->
        let xs = components tys in
        xs, tys, pvars xs, evars
    (* An ``inline record'' data constructor. *)
    | Pcstr_record lds ->
        let labels, tys = ld_labels lds, ld_tys lds in
        let xs = fields labels in
        xs, tys,
        [precord ~closed:Closed (combine labels (pvars xs))],
        fun rs -> [record (combine labels (evars rs))]
  in

  (* Get the name of this data constructor. *)
  let datacon = cd.pcd_name.txt in
  (* Create new names [rs] for the results of the recursive calls of visitor
     methods on the components [xs]. *)
  let rs = results xs in

  (* Construct a case for this data constructor in the visitor method
     associated with this sum type. After binding the components [xs], we call
     the descending method associated with this data constructor, with
     arguments [env] and [xs]. This method is implemented in the [visitor]
     class. It binds the variables [rs] to the results of the recursive calls
     to visitor methods, then calls the ascending method associated with this
     data constructor, with arguments [rs]. This method is declared in the
     [visitor] class and implemented in the subclasses [iter] and [map]. In
     the subclass [iter], it always returns a unit value. In the subclass
     [map], it reconstructs a tree node. *)
  Exp.case
    (pconstr datacon ps)
    (hook (datacon_descending_method datacon) (env :: xs)
       (letn
          rs (visit_types tys (evars xs))
          (hooks (datacon_ascending_method datacon) rs
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
  match decl.ptype_kind, decl.ptype_manifest with

  (* A type abbreviation. *)
  | Ptype_abstract, Some ty ->
      visit_type ty

  (* A record type. *)
  | Ptype_record (lds : label_declaration list), _ ->
      let labels, tys = ld_labels lds, ld_tys lds in
      (* Bind the record to a variable [x]. *)
      let tycon = decl.ptype_name.txt in
      let x = thing tycon in
      (* See [constructor_declaration] for comments. *)
      lambda x (
        let rs = results labels in
        letn rs (visit_types tys (accesses x labels))
          (hooks (record_ascending_method tycon) rs
            (unit())
            (record (combine labels (evars rs)))
          )
      )

  (* A sum type. *)
  | Ptype_variant (cds : constructor_declaration list), _ ->
      (* Generate one case per constructor, and place them in a function
         body, whose formal parameter is anonymous. *)
      Exp.function_ (map constructor_declaration cds)

  (* An unsupported construct. *)
  | _ ->
      raise_errorf
        ~loc:decl.ptype_loc
        "%s cannot be derived for this sort of type"
        plugin

(* -------------------------------------------------------------------------- *)

(* [type_decl decl] generates a class field (e.g., a method) associated with
   the type declaration [decl]. *)

let type_decl (decl : type_declaration) : unit =
  (* Produce a single method definition, whose name is based on this type
     declaration. *)
  generate cvisitor (
    concrete_method
      (tycon_visitor_method (Lident decl.ptype_name.txt))
      (plambda penv (visit_decl decl))
  )

end

(* -------------------------------------------------------------------------- *)

(* [type_decls decls] produces structure items (that is, toplevel definitions)
   associated with the type declarations [decls]. *)

let type_decls ~options ~path:_ (decls : type_declaration list) : structure =
  parse_options options;
  (* Analyze the type definitions. *)
  let module R = Run(struct let decls = decls end) in
  R.generate citer (Cf.inherit_ Fresh (Cl.constr (mknoloc (Lident cvisitor)) [ ty_self; ty_env ]) None);
  R.generate cmap (Cf.inherit_ Fresh (Cl.constr (mknoloc (Lident cvisitor)) [ ty_self; ty_env ]) None);
  iter R.type_decl decls;
  (* Produce class definitions. Our classes are parameterized over the type
     variable ['env]. They are also parameterized over the type variable
     ['self], with a constraint that this is the type of [self]. This trick
     allows us to omit the declaration of the types of the virtual methods,
     even if these types include type variables. *)
  let params = [
    ty_self, Invariant;
    ty_env, Invariant;
  ] in
  [
    class1 params cvisitor pself (R.dump cvisitor);
    class1 params citer pself (R.dump citer);
    class1 params cmap pself (R.dump cmap);
  ]

(* -------------------------------------------------------------------------- *)

(* We do not allow deriving any code on the fly, outside of a type declaration.
   Indeed, that would not make any sense: we need to generate a class and have
   a [self] parameter. *)

let no_core_type ty =
  raise_errorf
    ~loc:ty.ptyp_loc
    "%s cannot be used on the fly"
    plugin

(* -------------------------------------------------------------------------- *)

(* Register our plugin with [ppx_deriving]. *)

let () =
  register (
      create
        plugin
        ~core_type:no_core_type
        ~type_decl_str:type_decls
        ()
    )
