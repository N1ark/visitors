open Printf
open TermAlt
(* open Toolbox TEMPORARY *)

(* Sample terms. *)

let x =
  Atom.freshh "x"

let y =
  Atom.freshh "y"

let id =
  TLambda (x, TVar x)

let delta_body =
  TApp (TVar x, TVar x)

let delta =
  TLambda (x, delta_body)

let omega =
  TApp (delta, copy delta)

let samples = [
    TVar y;
    id;
    TApp (id, TVar y);
    TApp (id, TVar x);
    TApp (id, copy id);
    delta;
    omega;
    import KitImport.empty (TLambda ("x", TVar "x"));
    import KitImport.empty (TLambda ("z", TLambda ("z", TVar "z")));
  ]

let closed_samples = [
    id;
    TApp (id, copy id);
    delta;
    omega;
    import KitImport.empty (TLambda ("z", TLambda ("z", TVar "z")));
  ]

let evaluate f =
  List.iter f samples

(* A non-hygienic term printer. This printer shows the real (internal) identity
   of atoms, using [Atom.show]. *)

let nhprint oc t =
  Print.term oc (show t)

(* A hygienic term printer. This printer uses [export]. *)

let hprint oc t =
  (* works for closed terms only, as of now *)
  Print.term oc (export KitExport.empty t)

let print_size t =
  printf "size(%a) = %d\n%!"
    nhprint t
    (size t)

let () =
  evaluate print_size

let print_copy t =
  printf "copy(%a) = %a\n%!"
    nhprint t
    nhprint (copy t)

let () =
  evaluate print_copy

let print_export t =
  printf "export(%a) = %a\n%!"
    nhprint t
    hprint t

let () =
  List.iter print_export closed_samples

let print_fa t =
  printf "fa(%a) = %a\n%!"
    nhprint t
    Atom.Set.print (fa t)

let () =
  evaluate print_fa

(* TEMPORARY
let print_fa' t =
  (* This uses the debugging term printer, not the hygienic term printer. *)
  (* Similarly, it uses the debugging printer for sets of atoms. *)
  printf "fa'(%a) = %a\n%!"
    nhprint t
    Atom.Set.print (fa' t)

let () =
  evaluate print_fa'

let print_substitute1 u x t =
  printf "substituting %a for %a in %a = ...\n  %a\n%!"
    nhprint u
    Atom.print x
    nhprint t
    nhprint (substitute1 u x t)

let () =
  print_substitute1 (TVar y) x (TVar x);
  print_substitute1 (TVar y) x (TVar y);
  print_substitute1 delta x delta_body;
  ()

let print_equiv t1 t2 =
  printf "equiv: %a ~ %a = %b\n%!"
    nhprint t1
    nhprint t2
    (equiv t1 t2)

let () =
  print_equiv id id;
  print_equiv id (TVar x);
  print_equiv (TVar x) (TVar y);
  print_equiv delta (copy delta);
  print_equiv omega (copy omega);
  print_equiv (TLambda (x, TVar x)) (TLambda (y, TVar y));
  print_equiv (TLambda (x, TVar x)) (TLambda (y, TVar x));
  ()

let print_wf t =
  printf "wf(%a) = %b\n%!"
    nhprint t
    (wf t)

let () =
  evaluate print_wf

 *)
