(* Nat Mote
 *
 * Copyright (C) 2019-2022 r2c
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file LICENSE.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * LICENSE for more details.
 *)

open Common
open AST_generic
module MV = Metavariable

let logger = Logging.get_logger [ __MODULE__ ]

(******************************************************************************)
(* Handles AST printing for the purposes of autofix.
 *
 * The main printing logic happens elsewhere. This module's main purpose is to
 * extend the existing AST printers so that they can avoid printing AST nodes
 * which are lifted unchanged from either the target file (via metavariable
 * bindings) or the fix pattern in the rule. This serves two purposes:
 * - It lets us synthesize autofixes without having to implement printing for
 *   all of the AST nodes in the fixed AST.
 * - It lets us make minimal changes to target files by carrying over
 *   formatting, comments, etc. from the original code.
 *)
(******************************************************************************)

(* This lets us avoid the polymorphic hash function and polymorphic equality,
 * which will take into account extraneous information such as e_range, leading
 * to failed lookups. *)
module ASTTable = Hashtbl.Make (struct
  type t = AST_generic.any

  let equal = AST_generic.equal_any
  let hash = AST_generic.hash_any
end)

type ast_node_source =
  (* Indicates that a node came from the target file via a metavar binding *)
  | Target
  (* Indicates that a node came from the fix pattern *)
  | FixPattern

(* So that we can print by lifting the original source for unchanged AST nodes,
 * this indicates whether a given AST node came from the target file (via
 * metavariable bindings) or from the rule's fix pattern. Nodes that do not
 * appear in this table came from neither. *)
type ast_node_table = ast_node_source ASTTable.t

module PythonPrinter = Hybrid_print.Make (struct
  class printer = Ugly_print_AST.python_printer
end)

let get_printer lang external_printer : Ugly_print_AST.printer_t option =
  match lang with
  | Lang.Python -> Some (new PythonPrinter.printer external_printer)
  | _ ->
      logger#info "Failed to render autofix: no printer available for %s"
        (Lang.to_string lang);
      None

let original_source_of_ast source any =
  let* start, end_ = Visitor_AST.range_of_any_opt any in
  let starti = start.Parse_info.charpos in
  let _, _, endi = Parse_info.get_token_end_info end_ in
  let len = endi - starti in
  let str = String.sub source starti len in
  Some str

(* Add each metavariable value to the lookup table so that it can be identified
 * during printing *)
let add_metavars (tbl : ast_node_table) metavars =
  List.iter
    (fun (_, mval) ->
      let any = MV.mvalue_to_any mval in
      ASTTable.replace tbl any Target;
      (* For each metavariable binding that is a list of things, we need to
       * iterate through and add each item in the list to the table as well.
       *
       * For example, if `$...BAR` is bound to the separate arguments `1` and
       * `2`, in the example below, then the complete argument list `(1, 2)`
       * would never appear in the resulting AST that we attempt to print.
       * Despite that, we would like to reuse the original text for `1` and `2`.
       *
       * foo($...BAR, 5) -> foo(1, 2, 5)
       *
       * We don't need to recurse any deeper, because individual list items are
       * the smallest components of a metavariable value that will be lifted
       * into the resulting AST.
       * *)
      match mval with
      | MV.Args args ->
          List.iter (fun arg -> ASTTable.replace tbl (Ar arg) Target) args
      (* TODO iterate through other metavariable values that are lists *)
      | _ -> ())
    metavars

(* Add each AST node from the fix pattern AST to the lookup table so that it can
 * be identified during printing.
 *
 * We add all nodes here, regardless of whether they made it intact into the
 * fixed pattern AST. Despite this, we will only use the original text for nodes
 * that have made it into the fixed pattern AST unchanged. If a node was
 * modified, e.g. if it contained a metavariable that was replaced, that node
 * will not be equal to the original node when we look it up during printing,
 * and therefore we won't get a hashtbl hit, and so we won't use the text for
 * the original node.
 * *)
let add_fix_pattern_ast_nodes (tbl : ast_node_table) ast =
  let visitor =
    Visitor_AST.(
      mk_visitor
        {
          default_visitor with
          kargument =
            (fun (k, _) arg ->
              ASTTable.replace tbl (Ar arg) FixPattern;
              k arg)
            (* TODO visit every node that is part of AST_generic.any *);
        })
  in
  visitor ast

let make_external_printer ~metavars ~target_contents ~fix_pattern_ast
    ~fix_pattern : AST_generic.any -> Immutable_buffer.t option =
  let tbl : ast_node_table = ASTTable.create 8 in
  add_metavars tbl metavars;
  add_fix_pattern_ast_nodes tbl fix_pattern_ast;
  fun any ->
    let* node = ASTTable.find_opt tbl any in
    let* str =
      match node with
      | Target -> original_source_of_ast (Lazy.force target_contents) any
      | FixPattern -> original_source_of_ast fix_pattern any
    in
    Some (Immutable_buffer.of_string str)

(******************************************************************************)
(* Entry Point *)
(******************************************************************************)

let print_ast ~lang ~metavars ~target_contents ~fix_pattern_ast ~fix_pattern
    fixed_ast =
  let external_printer =
    make_external_printer ~metavars ~target_contents ~fix_pattern_ast
      ~fix_pattern
  in
  let* printer = get_printer lang external_printer in
  match printer#print_any fixed_ast with
  | Some print_result -> Some (Immutable_buffer.to_string print_result)
  | None ->
      logger#info "Failed to render autofix: could not print AST";
      None
