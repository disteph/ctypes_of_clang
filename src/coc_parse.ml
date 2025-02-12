open Dolog
  
module L = Log.Make(struct let section = "parse" end)

module Make(Clang : Coc_clang.S) = struct
  open Coc_enums
  open Clang

  module R = CXChildVisitResult
  module K = CXCursorKind
  module T = Coc_enums.CXTypeKind

  module CHash = Hashtbl.Make(struct
      type t = cursor
      let equal = Cursor.equal
      let hash = Cursor.hash
  end)

  exception Unhandled_composite_member
  exception Global_not_found of string
  exception Invalid_composite_kind
  exception Unsupported_type of string
  exception Fixme of string
  exception Expecting_composite

  type global = 
    | GComp of { loc : Loc.t; name : name; kind : kind; clayout : clayout }
    | GEnum of { loc : Loc.t; name : name }
    | GTypedef of { loc : Loc.t; name : name; typ : typ }
    | GVar of { loc : Loc.t; name : name; typ : typ; is_const : bool }
    | GFunc of { loc : Loc.t; name : name; typ : typ }
    | GBuiltin of { name : string; typ : typ }
    
  and kind = Struct | Union

  and name = string * int

  and clayout = { size : int; align : int}

  and typ = 
    | TVoid
    | TBase of string
    | TNamed of string * bool
    | TGlobal of global 
    | TArray of typ * int
    | TPtr of typ 
    | TFuncPtr of { ret : typ; args : typ list; variadic : bool }
    | TFuncProto of { ret : typ; args : typ list; variadic : bool }
    | TEnum of { global : global; items : (string * int64) list; kind : typ }
    | TComp of { global : global; members : member list }

  and member =
    | Field of {name:string; typ:typ; offset:int}
    | Bitfield of {name:string; typ:typ; width:int; offset:int}

  let name_of_global = function
    | GComp {name} 
    | GEnum {name} 
    | GTypedef {name} 
    | GVar {name} 
    | GFunc {name} -> fst name
    | GBuiltin {name} -> name

  let loc_of_global = function
    | GComp {loc} 
    | GEnum {loc} 
    | GTypedef {loc} 
    | GVar {loc} 
    | GFunc {loc} -> loc 
    | GBuiltin _ -> failwith "loc_of_global"

  let string_of_loc l = Printf.sprintf "%s:%i:%i" l.Loc.file l.Loc.line l.Loc.col
  let sloc = string_of_loc

  let string_of_kind = function Union -> "union" | Struct -> "struct"

  let rec string_of_global =
    let open Printf in
    function
    | GComp { loc; name=(name,_); kind } -> 
      sprintf "%s %s [%s]" (string_of_kind kind) name (string_of_loc loc)
    | GEnum { loc; name=(name,_) } ->
      sprintf "enum %s [%s]" name (string_of_loc loc)
    | GTypedef { loc; name=(name,_); typ } ->
      sprintf "typedef %s : %s [%s]" name (string_of_typ typ)  (string_of_loc loc)
    | GVar { loc; name=(name,_); typ } ->
      sprintf "var %s : %s [%s]" name (string_of_typ typ) (string_of_loc loc)
    | GFunc { loc; name=(name,_); typ } ->
      sprintf "fun %s : %s [%s]" name (string_of_typ typ) (string_of_loc loc)
    | GBuiltin { name; typ } ->
      sprintf "builtin %s : %s" name (string_of_typ typ) 

  and string_of_typ = function
    | TVoid -> "void"
    | TBase s -> s
    | TNamed(s,_) -> s
    | TGlobal g -> name_of_global g
    | TArray(typ,size) -> string_of_typ typ ^ "[" ^ string_of_int size ^ "]"
    | TPtr typ -> string_of_typ typ ^ "*"
    | TFuncPtr {ret; args} | TFuncProto {ret; args} -> 
      string_of_typ ret ^ " (*)(" ^
        (String.concat ", " (List.map string_of_typ args)) ^ ")"
    | TEnum {global} -> "enum " ^ name_of_global global
    | TComp {global} -> "struct/union " ^ name_of_global global

  module TypeMap = Map.Make(struct
    type t = global
    let compare = compare
  end)

  type ctx = 
    {
      decls : (cursor * global) list;
      globals : global list;
      builtins : (global * string) list;
      comp_members_map : member list TypeMap.t;
      enum_items_map : ((string * int64) list * typ) TypeMap.t;
      id : unit -> int;
    }

  module BT = struct
    let schar = TBase("schar")
    let char = TBase("char")
    let uchar = TBase("uchar")
    let ushort = TBase("ushort")
    let uint = TBase("uint")
    let ulong = TBase("ulong")
    let ullong = TBase("ullong")
    let short = TBase("short")
    let int = TBase("sint")
    let long = TBase("long")
    let llong = TBase("llong")
    let float = TBase("float")
    let double = TBase("double")
    let ldouble = TBase("ldouble")
  end

  let rec conv_typ ctx typ cursor = 
    let kind = Type.kind typ in
    match kind with
    | T.Void | T.Invalid -> TVoid
    | T.SChar -> BT.schar
    | T.Char_S -> BT.char
    | T.UChar -> BT.uchar
    | T.Char_U -> BT.char
    | T.UShort -> BT.ushort
    | T.UInt -> BT.uint
    | T.ULong -> BT.ulong
    | T.ULongLong -> BT.ullong
    | T.Short -> BT.short
    | T.Int -> BT.int
    | T.Long -> BT.long
    | T.LongLong -> BT.llong
    | T.Float -> BT.float
    | T.Double -> BT.double
    | T.Bool -> BT.char 
    | T.LongDouble -> BT.ldouble

    | T.Complex -> begin
      match Type.kind @@ Type.elem_type typ with
      | T.Float -> TBase "complex32"
      | T.Double -> TBase "complex64"
      | T.LongDouble -> TBase "complexld"
      | _ as k -> raise (Unsupported_type ("complex: " ^ T.to_string k))
    end
  
    | T.FunctionProto | T.FunctionNoProto -> 
      let ret, args, variadic = conv_func_sig ctx typ cursor in
      L.info "TFuncProto";
      TFuncProto{ret;args;variadic}

    | T.Pointer -> conv_ptr_typ ctx (Type.pointee_type typ) cursor

    | T.Record | T.Unexposed | T.Enum | T.Typedef -> conv_decl_typ ctx (Type.declaration typ) 

    | T.DependentSizedArray | T.IncompleteArray ->
      TArray(conv_typ ctx (Type.array_elem_type typ) cursor, 0)

    | T.ConstantArray -> 
      TArray(conv_typ ctx (Type.array_elem_type typ) cursor, Type.array_size typ)

    (* VariableArray, Vector, Int128, UInt128 *)
    (* Bool, WChar, LongDouble *)
    | _ as k -> raise (Unsupported_type (T.to_string k))

  and conv_decl_typ ctx cursor = 
    let get_global () = 
      let cursor = Cursor.canonical cursor in
      try global_of_cursor ctx cursor 
      with e -> L.warn "conv_decl_typ [%s]" (sloc @@ Loc.location @@ Cursor.location cursor); 
                raise e 
    in
    match Cursor.kind cursor with
    | K.StructDecl | K.UnionDecl -> 
      let global = get_global () in
      TComp{global; members=try TypeMap.find global ctx.comp_members_map with Not_found -> []}
    | K.EnumDecl ->
      let global = get_global () in
      let items, kind = 
        try TypeMap.find global ctx.enum_items_map 
        with Not_found -> [], default_enum_type
      in
      TEnum{global; items; kind}
    | K.TypedefDecl ->
      TGlobal(get_global ())
    | _ as k -> 
      L.warn "conv_decl_typ %s" (K.to_string k);
      TVoid

  and default_enum_type = TBase "int"

  and conv_ptr_typ ctx typ cursor = 
    let kind = Type.kind typ in
    match kind with
    | T.Unexposed | T.FunctionProto | T.FunctionNoProto ->
      let ret = Type.ret_type typ in
      let decl = Type.declaration typ in
      L.info "conv_ptr_typ: %s %s %s" 
                      (T.to_string kind) 
                      (T.to_string (Type.kind ret)) 
                      (K.to_string (Cursor.kind decl));
      if Type.kind ret <> T.Invalid then
        let ret, args, variadic = conv_func_sig ctx typ cursor in
        L.info "TFuncPtr";
        TFuncPtr{ret;args;variadic}
      else if Cursor.kind decl <> K.NoDeclFound then
        TPtr(conv_decl_typ ctx (Cursor.canonical decl))
      else if Cursor.kind cursor = K.VarDecl then
        conv_typ ctx (Type.canonical_type typ) cursor
      else
        TPtr(TVoid)
    | _ -> TPtr (conv_typ ctx typ cursor)

  and conv_func_sig ctx typ cursor =
    let args = 
      List.map (fun c -> (*Cursor.spelling c,*) conv_typ ctx (Cursor.cur_type c) c) @@
        match Cursor.kind cursor with
        | K.FunctionDecl -> Array.to_list @@ Cursor.args cursor 
        | _ ->
          List.rev @@ Cursor.visit cursor 
            (fun c _ l -> 
              match Cursor.kind c with
              | K.ParmDecl -> R.Continue, c::l
              | _ -> R.Continue, l) []
    in
    let ret = conv_typ ctx (Type.ret_type typ) cursor in
    ret, args, Type.is_variadic typ 

  and builtin ~p (g,d) = 
    let mk (name,_) ct = 
      Some(GBuiltin{name; typ=TNamed(d,ct)}) 
    in
    match g with
    | GComp{loc;name;kind=Struct} when p loc name K.StructDecl -> mk name true
    | GComp{loc;name;kind=Union} when p loc name K.UnionDecl -> mk name true
    | GEnum{loc;name} when p loc name K.EnumDecl -> mk name false
    | GTypedef{loc;name} when p loc name K.TypedefDecl -> mk name false
    | GFunc{loc;name} when p loc name K.FunctionDecl -> mk name false
    | GVar {loc;name} when p loc name K.VarDecl -> mk name false
    | _ -> None

  and builtin_of_cursor ctx c = 
    let g = 
      let cursor_name = Cursor.spelling c in
      let cursor_kind = Cursor.kind c in
      let cursor_loc = Loc.location @@ Cursor.location c in
      let check loc (name,_) kind = loc=cursor_loc && name=cursor_name && kind=cursor_kind in
      let rec g = function
        | [] -> None
        | h :: t -> (match builtin ~p:check h with None -> g t | _ as x -> x)
      in
      g 
    in
    if ctx.builtins = [] then None else g ctx.builtins

  (* find global declaration from cursor - first look at builtins *)
  and global_of_cursor ctx c = 
    let rec f = function [] -> raise (Global_not_found (Cursor.spelling c))
                       | (c',g)::t when Cursor.equal c c' -> g 
                       | _ :: t -> f t 
    in
    match builtin_of_cursor ctx c with
    | None -> f ctx.decls
    | Some(g) -> g

  let to_kind = function K.StructDecl -> Struct | K.UnionDecl -> Union 
                       | _ -> raise Invalid_composite_kind

  let declare ~ctx ~global ~cnn_cursor ~cursor = 
    if Cursor.equal cursor cnn_cursor then 
      { ctx with decls = (cursor, global) :: ctx.decls }, global, true
    else 
      ctx, global_of_cursor ctx cnn_cursor, false

  let add_composite_members ctx global members = 
    if members = [] then ctx, false
    else { ctx with comp_members_map = TypeMap.add global members ctx.comp_members_map}, true

  let add_enum_items ctx global items typ = 
    if items = [] then ctx
    else { ctx with enum_items_map = TypeMap.add global (items,typ) ctx.enum_items_map} 

  let add_global ctx primary defines global =
    if primary then { ctx with globals = global :: ctx.globals } 
    else if defines then
      (* filter out old defn *)
      { ctx with globals = global :: (List.filter ((<>) global) ctx.globals) }
    else ctx

  let get_clayout cursor = 
    let typ = Cursor.cur_type cursor in
    { size = Type.size typ; align = Type.align typ }

  let rec visit_composite cursor _ (ctx, members, prefix) = 

    let name = Cursor.spelling cursor in
    let loc = Loc.location @@ Cursor.location cursor in
    let bitfield_width = Cursor.bit_width cursor in
    let skip_not_found f a = try f a with Global_not_found _ -> R.Continue, (ctx,members,prefix) in

    let field_decl = function
      | None ->
        let typ = Cursor.cur_type cursor in
        let typ = conv_typ ctx typ cursor in
        let offset = Cursor.field_offset cursor in
        L.info "field %s '%s' [%i] [%s]" (string_of_typ typ) name offset (sloc loc);
        R.Continue, (ctx, Field{name; typ; offset}::members, prefix)
      | Some width ->
        let typ = Cursor.cur_type cursor in
        let typ = conv_typ ctx typ cursor in
        let offset = Cursor.field_offset cursor in
        L.info "bitfield %s:%i '%s' [%i] [%s]" (string_of_typ typ) width name offset (sloc loc);
        R.Continue, (ctx, Bitfield{name; typ; width; offset}::members, prefix)
    in

    let comp_decl kind = 
      let kind = to_kind kind in
      let cnn_cursor = Cursor.canonical cursor in
      let cnn_loc = Loc.location @@ Cursor.location cnn_cursor in
      L.info "nested composite '%s' [%s] [%s]" name (sloc loc) (sloc cnn_loc);
      (* declare nested global *)
      let name = name, ctx.id() in
      let clayout = get_clayout cursor in
      let ctx, global, primary = declare ~ctx ~global:(GComp{loc;name;kind;clayout}) 
        ~cnn_cursor ~cursor in
      (* check for members *)
      let ctx, defines = visit_nested_composite ctx global cursor name in
      let ctx = add_global ctx primary defines global in
      R.Continue, (ctx, members, prefix)
    in

    let enum_decl () = 
      let cnn_cursor = Cursor.canonical cursor in
      let cnn_loc = Loc.location @@ Cursor.location cnn_cursor in
      L.info "nested enum '%s' [%s] [%s]" name (sloc loc) (sloc cnn_loc);
      let name = name, ctx.id() in
      let ctx, global, primary = declare ~ctx ~global:(GEnum{loc;name}) ~cnn_cursor ~cursor in
      (* check for members *)
      let ctx = visit_enum ctx global cursor name in
      let ctx = add_global ctx primary false global in
      R.Continue, (ctx, members, prefix)
    in

    match Cursor.kind cursor, bitfield_width with

    (* field - need to detect nested composites/enums *)
    | K.FieldDecl, w -> skip_not_found field_decl w

    (* nested composite declaration *)
    | (K.StructDecl | K.UnionDecl) as kind, _ -> skip_not_found comp_decl kind

    (* nested enumeration *)
    | K.EnumDecl, _ -> skip_not_found enum_decl ()

    | _ as k, _ -> 
      L.warn "unhandled composite member type '%s'" (K.to_string k);
      (*raise Unhandled_composite_member*)
      R.Continue, (ctx, members, prefix)

  and visit_nested_composite ctx global cursor prefix = 
    let ctx, members, _ = Cursor.visit cursor visit_composite (ctx,[],prefix) in
    add_composite_members ctx global (List.rev members)

  and visit_enum ctx global cursor name =  
    let items = 
      Cursor.visit cursor 
        (fun cursor _ items ->
           match Cursor.kind cursor with
           | K.EnumConstantDecl ->
             let name = Cursor.spelling cursor in
             let item = Cursor.enum_val cursor in
             R.Continue, ((name,item)::items)
           | _ ->
             R.Continue, items)
        []
    in
    add_enum_items ctx global (List.rev items) 
      (conv_typ ctx (Cursor.enum_type cursor) cursor)

  let visit_top tunit cursor parent ctx = 

    let name = Cursor.spelling cursor in
    let loc = Loc.location @@ Cursor.location cursor in
    let cnn_cursor = Cursor.canonical cursor in
    let cnn_loc = Loc.location @@ Cursor.location cnn_cursor in
    let skip_not_found f a = 
      try f a 
      with Global_not_found _ -> (*L.warn "skipped";*) R.Continue, ctx 
    in

    let comp_decl kind = 
      let kind = to_kind kind in
      L.info "comp '%s' [%s]->[%s]" name (sloc loc) (sloc cnn_loc);
      (* declare the (top-level) global *)
      let name = name, ctx.id() in
      let clayout = get_clayout cursor in
      let ctx, global, primary = declare ~ctx ~global:(GComp{loc;name;kind;clayout}) 
        ~cnn_cursor ~cursor in
      (* check for members *)
      let ctx, defines = visit_nested_composite ctx global cursor name in
      let ctx = add_global ctx primary defines global in
      R.Continue, ctx
    in
       
    let enum_decl () = 
      L.info "enum '%s' [%s]->[%s]" name (sloc loc) (sloc cnn_loc);
      (* declare the (top-level) global *)
      let name = name, ctx.id() in
      let ctx, global, primary = declare ~ctx ~global:(GEnum{loc;name}) ~cnn_cursor ~cursor in
      (* check for members *)
      let ctx = visit_enum ctx global cursor name in
      let ctx = add_global ctx primary false global in
      R.Continue, ctx
    in

    let function_decl () = 
      let open CXLinkageKind in
      match Cursor.linkage cursor with
      | External | UniqueExternal ->
        L.info "TFuncPtr '%s' [%s]->[%s]" name (sloc loc) (sloc cnn_loc);
        let typ = Cursor.cur_type cursor in
        let typ = 
          let ret, args, variadic = conv_func_sig ctx typ cursor in
          TFuncPtr{ret;args;variadic}
        in
        let name = name, ctx.id() in
        let global = GFunc{loc;name;typ} in
        let ctx, _, _ = declare ~ctx ~global ~cnn_cursor:cursor ~cursor:cursor in
        let ctx = add_global ctx true false global in
        R.Continue, ctx
      | _ -> 
        L.info "static func '%s' [%s]->[%s]" name (sloc loc) (sloc cnn_loc);
        R.Continue, ctx
    in

    let var_decl () = 
      let open CXLinkageKind in
      match Cursor.linkage cursor with
      | External | UniqueExternal ->
        L.info "var '%s' [%s]->[%s]" name (sloc loc) (sloc cnn_loc);
        let typ = Cursor.cur_type cursor in
        let is_const = Type.is_const typ in
        let typ = conv_typ ctx typ cursor in
        let name = name, ctx.id() in
        let global = GVar{loc;name;typ;is_const} in
        let ctx, _, _ = declare ~ctx ~global ~cnn_cursor:cursor ~cursor in
        let ctx = add_global ctx true false global in
        R.Continue, ctx
      | _ ->
        L.info "static var '%s' [%s]->[%s]" name (sloc loc) (sloc cnn_loc);
        R.Continue, ctx
    in

    let typedef_decl () = 
      let under_typ = Cursor.typedef_type cursor in
      let under_typ = 
        match Type.kind under_typ with
        | T.Unexposed -> Type.canonical_type under_typ
        | _ -> under_typ
      in
      let typ = conv_typ ctx under_typ cursor in
      L.info "typedef '%s' = %s [%s]" name (string_of_typ typ) (sloc loc);
      let name = name, ctx.id() in
      let global = GTypedef{loc;name;typ} in
      let ctx, _, _ = declare ~ctx ~global ~cnn_cursor:cursor ~cursor in
      let ctx = add_global ctx true false global in
      R.Continue, ctx
    in

    match Cursor.kind cursor with
    | K.UnexposedDecl -> 
      L.warn "unexposed declaration [%s]" (sloc loc);
      R.Recurse, ctx

    | K.StructDecl | K.UnionDecl as kind -> skip_not_found comp_decl kind
   
    | K.EnumDecl -> skip_not_found enum_decl ()

    | K.FunctionDecl -> skip_not_found function_decl ()

    | K.VarDecl -> skip_not_found var_decl ()

    | K.TypedefDecl -> skip_not_found typedef_decl ()

    | _ as kind -> 
      L.warn "unknown cursor kind '%s'" (K.to_string kind);
      R.Continue, ctx

  let run ?log ?pedantic ?unsaved ~builtins args = 
    let ctx = 
      let id = let x = ref 0 in (fun () -> incr x; !x-1) in
      { decls=[]; 
        globals=[];
        builtins;
        comp_members_map=TypeMap.empty; 
        enum_items_map=TypeMap.empty;
        id }
    in
    run ?log ?pedantic ?unsaved ~args 
      (fun tu ctx -> 
        let ctx = Cursor.visit (TU.cursor tu) (visit_top tu) ctx in
        {ctx with decls=List.rev ctx.decls; globals=List.rev ctx.globals}) ctx

end


