module Term = struct

  open Abstraction

  type ('fn, 'bn) term =
    | TVar of 'fn
    | TLambda of ('bn, ('fn, 'bn) term) abstraction
    | TApp of ('fn, 'bn) term * ('fn, 'bn) term
    [@@deriving
      visitors { name = "size"; variety = "reduce"; path = ["Size"]; freeze = ["bn"; "fn"]; monoid = "Monoid.Sum" },
      visitors { name = "Atom2Unit"; variety = "iter"; path = ["Atom2Unit"]; freeze = ["bn"; "fn"]; final = true },
      visitors { name = "Atom2DeBruijn"; variety = "map"; path = ["Atom2DeBruijn"]; freeze = ["bn"; "fn"]; final = true },
      visitors { name = "String2Atom"; variety = "map"; path = ["String2Atom"]; freeze = ["bn"; "fn"]; final = true },
      visitors { name = "Atom2String"; variety = "map"; path = ["Atom2String"]; freeze = ["bn"; "fn"]; final = true },
      visitors { name = "Atom2Atom"; variety = "map"; path = ["Atom2Atom"]; freeze = ["bn"; "fn"]; final = true },
      visitors { name = "Copy"; variety = "map"; path = ["Copy"]; freeze = ["bn"; "fn"]; final = true }
    ]

end

type raw_term =
  (string, string) Term.term

type nominal_term =
  (Atom.t, Atom.t) Term.term

type db_term =
  (int, unit) Term.term

let size (t : (_, _) Term.term) : int =
  let o = object
    inherit [_] Term.size as super
    method! visit_term env t =
      (* Every node counts 1 towards the size. *)
      1 + super#visit_term env t
  end in
  o # visit_term () t

let fa (t : nominal_term) : Atom.Set.t =
  let accu = ref Atom.Set.empty in
  Term.Atom2Unit.visit_term (Abstraction.Atom2Unit.empty accu) t;
  !accu

let atom2debruijn (t : nominal_term) : db_term =
  Term.Atom2DeBruijn.visit_term Abstraction.Atom2DeBruijn.empty t

let string2atom (t : raw_term) : nominal_term =
  Term.String2Atom.visit_term Abstraction.String2Atom.empty t

let atom2string (t : nominal_term) : raw_term =
  Term.Atom2String.visit_term Abstraction.Atom2String.empty t

let subst (sigma : Atom.subst) (t : nominal_term) : nominal_term =
  Term.Atom2Atom.visit_term sigma t

let copy (t : nominal_term) : nominal_term =
  Term.Copy.visit_term Abstraction.Copy.empty t

open Term

let x = Atom.freshh "x"

let identity =
  TLambda (x, TVar x)

let y =
  TVar (Atom.freshh "y")

let idy =
  TApp (identity, y)

open Printf

let () =
  print_endline "fa(\\x.x):";
  print_endline (Atom.Set.print (fa identity));
  print_endline "fa(y):";
  print_endline (Atom.Set.print (fa y));
  print_endline "fa((\\x.x) y):";
  print_endline (Atom.Set.print (fa idy));
  print_endline "size(\\x.x):";
  printf  "%d\n" (size identity);
  print_endline "size((\\x.x) y):";
  printf  "%d\n" (size idy)


(* TODO:

capture-avoiding substitution with freshening (nominal w/o GUH)
substitution of terms for variables (must copy term when grafting)
linear substitution of term for variable (w/o copying; check linearity at runtime?)
alpha-equivalence test (nominal)
test x \in fv(t) (nominal)
entering a binder (and testing for global uniqueness)
simultaneous opening? (nominal)
efficient printing (conversion from nominal back to raw) with pre-computation of fa
well-formedness checking (just traversing the term and checking for global uniqueness)
-- test for global uniqueness everywhere an environment is extended

implement a term printer

 *)
