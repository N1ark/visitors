type expr =
  | EConst of int
  | EAdd of expr * expr
