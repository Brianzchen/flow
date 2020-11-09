(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

exception Found of Jsdoc.t

let find comments =
  Base.Option.iter (Jsdoc.of_comments comments) ~f:(fun jsdoc -> raise (Found jsdoc))

let loc_of_object_key =
  let open Flow_ast.Expression.Object.Property in
  function
  | Identifier (loc, _)
  | Literal (loc, _)
  | Computed (_, Flow_ast.ComputedKey.{ expression = (loc, _); _ })
  | PrivateName (loc, _) ->
    loc

let comments_of_variance =
  let open Flow_ast.Variance in
  Base.Option.bind ~f:(fun (_, { comments; _ }) -> comments)

let comments_of_object_key =
  let open Flow_ast.Expression.Object.Property in
  function
  | Identifier (_, Flow_ast.Identifier.{ comments; _ })
  | Literal (_, Flow_ast.Literal.{ comments; _ })
  | Computed (_, Flow_ast.ComputedKey.{ comments; _ }) ->
    comments
  | PrivateName _ -> None

let loc_of_annotation_or_hint =
  let open Flow_ast.Type in
  function
  | Missing loc
  | Available (_, (loc, _)) ->
    loc

(* used to forward the comments on an export statement to the declaration
   contained in the export statement. That's why we don't bother with all
   cases; only statements that can appear in export declarations. *)
let replace_comments_of_statement ~comments =
  let open Flow_ast.Statement in
  Utils_js.map_snd (function
      | TypeAlias x -> TypeAlias TypeAlias.{ x with comments }
      | OpaqueType x -> OpaqueType OpaqueType.{ x with comments }
      | InterfaceDeclaration x -> InterfaceDeclaration Interface.{ x with comments }
      | VariableDeclaration x -> VariableDeclaration VariableDeclaration.{ x with comments }
      | ClassDeclaration x -> ClassDeclaration Flow_ast.Class.{ x with comments }
      | FunctionDeclaration x -> FunctionDeclaration Flow_ast.Function.{ x with comments }
      | EnumDeclaration x -> EnumDeclaration EnumDeclaration.{ x with comments }
      | other -> other)

class documentation_searcher (def_loc : Loc.t) =
  object (this)
    inherit [unit, Loc.t] Flow_ast_visitor.visitor ~init:() as super

    method is_target loc = Loc.equal def_loc loc

    method! variable_declaration stmt_loc decl =
      let open Flow_ast.Statement.VariableDeclaration in
      let { declarations; comments; _ } = decl in
      Base.List.iter declarations ~f:(function
          | ( _,
              Declarator.
                {
                  id = (_, Flow_ast.Pattern.(Identifier Identifier.{ name = (loc, _); annot; _ }));
                  _;
                } )
            when this#is_target loc || this#is_target (loc_of_annotation_or_hint annot) ->
            find comments
          | ( _,
              Declarator.
                { id = (_, Flow_ast.Pattern.(Identifier Identifier.{ name = (loc, _); _ })); _ } )
            when this#is_target loc ->
            find comments
          | (_, Declarator.{ init = Some (loc, _); _ }) when this#is_target loc -> find comments
          | _ -> ());
      super#variable_declaration stmt_loc decl

    method! class_ stmt_loc cls =
      let open Flow_ast.Class in
      let { id; comments; _ } = cls in
      Base.Option.iter id ~f:(fun (loc, _) -> if this#is_target loc then find comments);
      super#class_ stmt_loc cls

    method! function_ loc func =
      let open Flow_ast.Function in
      let { comments; id; sig_loc; _ } = func in
      if this#is_target loc || this#is_target sig_loc then find comments;
      Base.Option.iter id ~f:(fun (id_loc, _) -> if this#is_target id_loc then find comments);
      super#function_ loc func

    method! declare_variable stmt_loc decl =
      let open Flow_ast.Statement.DeclareVariable in
      let { id = (loc, _); comments; _ } = decl in
      if this#is_target loc then find comments;
      super#declare_variable stmt_loc decl

    method! declare_class stmt_loc decl =
      let open Flow_ast.Statement.DeclareClass in
      let { id = (loc, _); comments; _ } = decl in
      if this#is_target loc then find comments;
      super#declare_class stmt_loc decl

    method! declare_function stmt_loc decl =
      let open Flow_ast.Statement.DeclareFunction in
      let { id = (loc, _); comments; _ } = decl in
      if this#is_target loc then find comments;
      super#declare_function stmt_loc decl

    method! object_property_type prop_type =
      let open Flow_ast.Type.Object.Property in
      let (_, { key; value; comments; variance; _ }) = prop_type in
      let value_loc =
        match value with
        | Init (value_loc, _)
        | Get (_, Flow_ast.Type.Function.{ return = (value_loc, _); _ })
        | Set (value_loc, _) ->
          value_loc
      in
      if this#is_target (loc_of_object_key key) || this#is_target value_loc then begin
        find comments;
        find (comments_of_variance variance);
        find (comments_of_object_key key)
      end;
      super#object_property_type prop_type

    method! class_method method_loc meth =
      let open Flow_ast.Class.Method in
      let { key; comments; _ } = meth in
      if this#is_target (loc_of_object_key key) then begin
        find comments;
        find (comments_of_object_key key)
      end;
      super#class_method method_loc meth

    method! class_property prop_loc prop =
      let open Flow_ast.Class.Property in
      let { key; variance; comments; _ } = prop in
      if this#is_target (loc_of_object_key key) then begin
        find comments;
        find (comments_of_variance variance);
        find (comments_of_object_key key)
      end;
      super#class_property prop_loc prop

    method! object_property prop =
      let open Flow_ast.Expression.Object.Property in
      let (locs, comments) =
        match prop with
        | (_, Init { key; value = (value_loc, _); _ }) ->
          ([loc_of_object_key key; value_loc], [comments_of_object_key key])
        | (prop_loc, Method { key; value = (_, Flow_ast.Function.{ comments; _ }) }) ->
          ([prop_loc], [comments_of_object_key key; comments])
        | (_, Get { key; value = (_, Flow_ast.Function.{ return; _ }); comments }) ->
          ([loc_of_object_key key; loc_of_annotation_or_hint return], [comments])
        | (_, Set _) -> ([], [])
      in
      if List.exists this#is_target locs then List.iter find comments;
      super#object_property prop

    method! enum_declaration loc enum =
      let open Flow_ast.Statement.EnumDeclaration in
      let { comments; id = (id_loc, _); _ } = enum in
      if this#is_target loc || this#is_target id_loc then find comments;
      super#enum_declaration loc enum

    method! enum_defaulted_member member =
      let open Flow_ast.Statement.EnumDeclaration.DefaultedMember in
      let (loc, { id = (_, Flow_ast.Identifier.{ comments; _ }) }) = member in
      if this#is_target loc then find comments;
      member

    method enum_initialized_member
        : 'a. ('a, Loc.t) Flow_ast.Statement.EnumDeclaration.InitializedMember.t ->
          ('a, Loc.t) Flow_ast.Statement.EnumDeclaration.InitializedMember.t =
      fun member ->
        let open Flow_ast.Statement.EnumDeclaration.InitializedMember in
        let (loc, { id = (_, Flow_ast.Identifier.{ comments; _ }); _ }) = member in
        if this#is_target loc then find comments;
        member

    method! enum_boolean_member member = this#enum_initialized_member member

    method! enum_number_member member = this#enum_initialized_member member

    method! enum_string_member member = this#enum_initialized_member member

    method! export_named_declaration loc decl =
      let open Flow_ast.Statement.ExportNamedDeclaration in
      let { declaration; comments; _ } = decl in
      if this#is_target loc then find comments;
      Base.Option.iter
        declaration
        ~f:Utils_js.(replace_comments_of_statement ~comments %> this#statement %> ignore);
      super#export_named_declaration loc decl

    method! export_default_declaration loc decl =
      let open Flow_ast.Statement.ExportDefaultDeclaration in
      let { declaration; comments; _ } = decl in
      (let open Flow_ast.Expression in
      match declaration with
      | Declaration stmt ->
        stmt |> replace_comments_of_statement ~comments |> this#statement |> ignore
      | Expression (_, TypeCast TypeCast.{ annot = (_, (loc, _)); _ })
      | Expression (loc, _) ->
        if this#is_target loc then find comments);
      super#export_default_declaration loc decl

    method! type_alias loc type_alias =
      let open Flow_ast.Statement.TypeAlias in
      let { id = (id_loc, _); comments; _ } = type_alias in
      if this#is_target id_loc then find comments;
      super#type_alias loc type_alias

    method! interface loc interface =
      let open Flow_ast.Statement.Interface in
      let { id = (id_loc, _); comments; _ } = interface in
      if this#is_target id_loc then find comments;
      super#interface loc interface
  end

let search def_loc ast =
  let searcher = new documentation_searcher def_loc in
  try
    ignore (searcher#program ast);
    None
  with Found documentation -> Some documentation

module Remove_types = struct
  open Parsing_heaps_utils

  class type_remover ~(reader : Parsing_heaps.Reader.reader) =
    object
      inherit [ALoc.t, ALoc.t * Type.t, Loc.t, Loc.t] Flow_polymorphic_ast_mapper.mapper

      method on_loc_annot x = loc_of_aloc ~reader x

      method on_type_annot (x, _) = loc_of_aloc ~reader x
    end

  let f ~reader ~typed_ast = (new type_remover ~reader)#program typed_ast
end

let jsdoc_of_getdef_loc ?current_ast ~reader def_loc =
  let open Base.Option.Let_syntax in
  let%bind source = Loc.source def_loc in
  let current_ast_if_should_use =
    let%bind ((current_file_loc, _) as typed_ast) = current_ast in
    let%bind current_file_source =
      Loc.source (Parsing_heaps_utils.loc_of_aloc ~reader current_file_loc)
    in
    if source = current_file_source then
      Some (Remove_types.f ~reader ~typed_ast)
    else
      None
  in
  let%bind ast =
    match current_ast_if_should_use with
    | Some _ as some_ast -> some_ast
    | None -> Parsing_heaps.Reader.get_ast ~reader source
  in
  search def_loc ast

let documentation_of_jsdoc jsdoc =
  let documentation_of_unrecognized_tag (tag_name, tag_description) =
    let tag_name_documentation = Printf.sprintf "**@%s**" tag_name in
    match tag_description with
    | None -> tag_name_documentation
    | Some tag_description -> Printf.sprintf "%s %s" tag_name_documentation tag_description
  in
  let documentation_strings =
    Base.Option.fold
      (Jsdoc.description jsdoc)
      ~f:(fun unrecognized_tag_documentations description ->
        description :: unrecognized_tag_documentations)
      ~init:(Base.List.map ~f:documentation_of_unrecognized_tag (Jsdoc.unrecognized_tags jsdoc))
  in
  match documentation_strings with
  | [] -> None
  | _ -> Some (String.concat "\n\n" documentation_strings)
