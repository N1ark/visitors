open List

(* [last xs] returns the last element of the nonempty list [xs]. *)

let rec last1 x xs =
  match xs with
  | [] ->
      x
  | x :: xs ->
      last1 x xs

let last xs =
  match xs with
  | [] ->
      assert false
  | x :: xs ->
      last1 x xs

(* [interval i j] constructs a list representation of the semi-open interval
   [i..j). *)

let rec interval i j : int list =
  if i < j then
    i :: interval (i + 1) j
  else
    []

(* [init i j f] constructs a list of the values [f i] up to [f (j - 1)]. *)

let init i j (f : int -> 'a) : 'a list =
  map f (interval i j)

(* [is_matrix m n xss] checks that [xss] is an [m]-by-[n] matrix, represented
   as a list of lists. *)

let is_matrix m n (xss : _ list list) =
  length xss = m && for_all (fun xs -> length xs = n) xss

(* [transpose n xss] transposes a matrix, represented as a list of lists.
   The parameter [n] is the width of the matrix, and is really useful only
   in the case where the matrix has zero height, in which case [transpose]
   constructs a matrix of height [n] and zero width. *)

let transpose (n : int) (xss : 'a list list) : 'a list list =
  let m = length xss in
  assert (is_matrix m n xss);
  (* Convert [xss] to an array, for speed. *)
  let xss : 'a array array =
    Array.(map of_list (of_list xss))
  in
  (* We have an [m]-by-[n] matrix, and construct an [n]-by-[m] matrix. *)
  init 0 n (fun j ->
    init 0 m (fun i ->
      xss.(i).(j)
    )
  )

(* [uniq cmp xs] assumes that the list [xs] is sorted according to the
   ordering [cmp] and returns the list [xs] deprived of any duplicate
   elements. *)

let rec uniq1 cmp x ys =
  match ys with
  | [] ->
      []
  | y :: ys ->
      if cmp x y = 0 then
        uniq1 compare x ys
      else
        y :: uniq1 cmp y ys

let uniq cmp xs =
  match xs with
  | [] ->
      []
  | x :: xs ->
      x :: uniq1 cmp x xs

(* [weed cmp xs] returns the list [xs] deprived of any duplicate elements. *)

let weed cmp xs =
  uniq cmp (List.sort cmp xs)
