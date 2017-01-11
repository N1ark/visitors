open PPrint

(* -------------------------------------------------------------------------- *)

(* A block with indentation. *)

let indentation = 2

let block opening contents closing =
  group (opening ^^ nest indentation (contents) ^^ closing)

(* -------------------------------------------------------------------------- *)

(* Parentheses with indentation. *)

(* We allow breaking a parenthesized thing into several lines by leaving the
   opening and closing parentheses alone on a line and indenting the content. *)

let parens d =
  block
    lparen
    (break 0 ^^ d)
    (break 0 ^^ rparen)

(* -------------------------------------------------------------------------- *)

(* Lambda-calculus application. *)

let app d1 d2 =
  (* The following definition would reject a large argument on a line of
     its own, indented: *)
  (* group (d1 ^^ nest indentation (break 1 ^^ d2)) *)
  (* However, that would be redundant with the fact that large arguments
     are usually parenthesized, and we already break lines and indent
     within the parentheses. So, the following suffices: *)
  group (d1 ^^ space ^^ d2)

(* -------------------------------------------------------------------------- *)

(* Running a buffer printer in a fresh buffer, and sending the result to an
   output channel. *)

let run (oc : out_channel) (print : Buffer.t -> 'a -> unit) (x : 'a) =
  let b = Buffer.create 1024 in
  print b x;
  Buffer.output_buffer oc b

(* -------------------------------------------------------------------------- *)

(* Printing a document into an output channel, with fixed parameters. *)

let output (oc : out_channel) (d : document) =
  run oc (PPrintEngine.ToBuffer.pretty 0.9 80) d
