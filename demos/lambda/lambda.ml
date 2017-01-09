open Abstraction

type ('fn, 'bn) term =
  | TVar of 'fn
  | TLambda of ('bn, ('fn, 'bn) term) abstraction
  | TApp of ('fn, 'bn) term * ('fn, 'bn) term
  [@@deriving
    visitors { name = "iter"; variety = "iter"; nonlocal = ["Atom2Unit"]; freeze=["bn"] },
    visitors { name = "map"; variety = "map"; nonlocal = ["Atom2DeBruijn"]; freeze=["bn"] },
    visitors { name = "import"; variety = "map"; nonlocal = ["String2Atom"]; freeze=["bn"] }
  ]

(* Nominal. *)

type raw_term =
  (string, string) term

type nominal_term =
  (Atom.t, Atom.t) term

type db_term =
  (int, unit) term

let fa (t : nominal_term) : Atom.Set.t =
  let o = object
    inherit [_] iter
    inherit Atom2Unit.fa
  end in
  o # visit_term Atom2Unit.empty t;
  o # accu

let nominal2debruijn (t : nominal_term) : db_term =
  let o = object
    inherit [_] map
    inherit Atom2DeBruijn.map
  end in
  o # visit_term Atom2DeBruijn.empty t

let import (t : raw_term) : nominal_term =
  let o = object
    inherit [_] import
    inherit String2Atom.map
  end in
  o # visit_term String2Atom.empty t

let x = Atom.freshh "x"

let identity =
  TLambda (x, TVar x)

let y =
  TVar (Atom.freshh "y")

let idy =
  TApp (identity, y)

let () =
  print_endline "fa(\\x.x):";
  print_endline (Atom.Set.print (fa identity));
  print_endline "fa(y):";
  print_endline (Atom.Set.print (fa y));
  print_endline "fa((\\x.x) y):";
  print_endline (Atom.Set.print (fa idy))

(*

class ['self] subst (sigma : name -> name) = object (self : 'self)
  (* TEMPORARY incorrect if [sigma x] is in [env]! need freshening *)
  method visit_name env x =
    if Atom.Set.mem x env then x else sigma x
  method visit_binder term env (x, t) =
    let env = Atom.Set.add x env in
    x, term env t
end

let subst (sigma : name -> name) (t : term) : term =
  let subst = object
    inherit [_] map
    inherit [_] subst sigma
  end in
  let env = Atom.Set.empty in
  subst#visit_term env t

(* TEMPORARY need a term printer, too *)


let () =
  print (fa (subst (function "x" -> "z" | x -> x) idy))
 *)
