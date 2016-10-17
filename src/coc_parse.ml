open Coc_enums

let rev_ok = function
  | Ok l -> Ok (List.rev l)
  | Error e -> Error e

module Make(Clang : Coc_clang.S) = struct
  open Clang

  open CXChildVisitResult
  open CXCursorKind
  module C = Coc_enums.CXTypeKind 

  exception Coc_parse_unreachable
  let unreachable () = raise Coc_parse_unreachable

  exception Coc_parse_unsupported of string
  let unsupported str = raise (Coc_parse_unsupported str)

  module CHash = Hashtbl.Make(struct
      type t = Clang.cursor
      let equal = Clang.Cursor.equal
      let hash = Clang.Cursor.hash
  end)

  type ctx = 
    {
      mutable name : global CHash.t;
      mutable globals : global list;
    }

  (*and options = 
    {
    }*)

  and global = 
    | GType of type_info
    | GComp of comp_info
    | GCompDecl of comp_info
    | GEnum of enum_info
    | GEnumDecl of enum_info
    | GVar of var_info
    | GFunc of var_info
    | GOther

  and func_sig = 
    {
      fs_ret : typ;
      fs_args : (string * typ) list;
      fs_variadic : bool;
    }

  and typ = 
    | TVoid
    | TInt of ikind
    | TFloat of fkind
    | TPtr of typ * bool 
    | TArray of typ * int64
    | TFuncProto of func_sig
    | TFuncPtr of func_sig
    | TNamed of type_info
    | TComp of comp_info
    | TEnum of enum_info

  and ikind = 
    | IBool
    | ISChar
    | IUChar
    | IShort
    | IUShort
    | IInt
    | IUInt
    | ILong
    | IULong
    | ILongLong
    | IULongLong
    | IWChar

  and fkind = 
    | FFloat
    | FDouble
  
  and comp_member = 
    | Field of field_info
    | Comp of comp_info
    | Enum of enum_info
    | CompField of comp_info * field_info
    | EnumField of enum_info * field_info

  and comp_kind = 
    | Struct
    | Union
    
  and comp_info = 
    {
      ci_kind : comp_kind;
      ci_name : string;
      ci_members : comp_member list;
    }

  and field_info = 
    {
      fi_name : string;
      fi_typ : typ;
      (*fi_bitfields : (string * int) list option;*)
    }

  and enum_info = 
    {
      ei_name : string;
      ei_items : enum_item list;
      ei_kind : ikind;
    }

  and enum_item = 
    {
      eit_name : string;
      eit_val : int64;
    }

  and type_info =
    {
      ti_name : string;
      ti_typ : typ;
    }

  and var_info = 
    {
      vi_name : string;
      vi_typ : typ;
      vi_val : int64 option;
      vi_is_const : bool;
    }

  let rec conv_ty ctx typ cursor = 
    let kind = Type.kind typ in
    match kind with
    
    (* base int and float types *)
    | C.Void | C.Invalid -> TVoid
    | C.Bool -> TInt(IBool)
    | C.SChar | C.Char_S -> TInt(ISChar)
    | C.UChar | C.Char_U -> TInt(IUChar)
    | C.UShort -> TInt(IUShort)
    | C.UInt -> TInt(IUInt)
    | C.ULong -> TInt(IULong)
    | C.ULongLong -> TInt(IULongLong)
    | C.Short -> TInt(IShort)
    | C.Int -> TInt(IInt)
    | C.Long -> TInt(ILong)
    | C.LongLong -> TInt(ILongLong)
    | C.WChar -> TInt(IWChar)
    | C.Float -> TFloat(FFloat)
    | C.Double | C.LongDouble -> TFloat(FDouble)
    | C.Pointer -> conv_ptr_ty ctx (Type.pointee_type typ) cursor
    | C.VariableArray -> unreachable()
    | C.DependentSizedArray | C.IncompleteArray ->
      TArray(conv_ty ctx (Type.elem_type typ) cursor, 0L)
    | C.FunctionProto | C.FunctionNoProto ->
      let fsig = mk_fn_sig ctx typ cursor in
      TFuncProto(fsig)
    | C.Record | C.Typedef | C.Unexposed | C.Enum -> 
      conv_decl_ty ctx (Type.declaration typ)
    | C.ConstantArray -> 
      TArray(conv_ty ctx (Type.elem_type typ) cursor, Type.array_size typ)
    | C.Vector | C.Int128 | C.UInt128 ->
      unsupported "128-bit integers and/or vectors are not supported"
    | _ -> unsupported (Type.name typ)

  and conv_ptr_ty ctx typ cursor = 
    let is_const = Type.is_const typ in
    match Type.kind typ with
    | C.Unexposed | C.FunctionProto | C.FunctionNoProto ->
      let ret = Type.ret_type typ in
      let decl = Type.declaration typ in
      if Type.kind ret = C.Invalid then 
        TFuncPtr(mk_fn_sig ctx typ cursor)
      else if Cursor.kind decl = NoDeclFound then
        TPtr(conv_decl_ty ctx decl, is_const)
      else if Cursor.kind cursor = VarDecl then
        conv_ty ctx (Type.canonical_type typ) cursor
      else
        TPtr(TVoid, is_const)

    | _ -> TPtr(conv_ty ctx typ cursor, is_const)

  and mk_fn_sig ctx typ cursor = 
    let args = 
      List.map (fun c -> Cursor.spelling c, conv_ty ctx (Cursor.cur_type c) c) @@
        match Cursor.kind cursor with
        | FunctionDecl -> Array.to_list @@ Cursor.args cursor 
        | _ ->
          List.rev @@ Cursor.visit cursor 
            (fun c _ l -> 
              match Cursor.kind c with
              | ParmDecl -> Continue, c::l
              | _ -> Continue, l) []
    in
    let ret = conv_ty ctx (Type.ret_type typ) cursor in
    {
      fs_args = args;
      fs_ret = ret;
      fs_variadic = Type.is_variadic typ;
    }

  and conv_decl_ty ctx cursor = 
    match Cursor.kind cursor with
    | StructDecl | UnionDecl -> 
        let decl = decl_name ctx cursor in
        let ci = compinfo decl in
        TComp(ci)
    | EnumDecl -> 
        let decl = decl_name ctx cursor in
        let ei = enuminfo decl in
        TEnum(ei)
    | TypedefDecl ->
        let decl = decl_name ctx cursor in
        let ti = typeinfo decl in
        TNamed(ti) 
    | _ -> TVoid

  and compinfo = function
    | GComp(c) | GCompDecl(c) -> c
    | _ -> failwith "compinfo"
  
  and enuminfo = function
    | GEnum(e) | GEnumDecl(e) -> e
    | _ -> failwith "enuminfo"
  
  and typeinfo = function
    | GType(t) -> t
    | _ -> failwith "typeinfo"

  and varinfo = function
    | GVar(v) | GFunc(v) -> v
    | _ -> failwith "varinfo"

  and opaque_decl ctx decl = 
    let name = decl_name ctx decl in
    ctx.globals <- name :: ctx.globals

  and fwd_decl : type a. ctx -> Clang.cursor -> (ctx -> a -> a) -> a -> a = fun ctx cursor f a -> 
    let def = Cursor.definition cursor in
    if Cursor.equal def cursor then f ctx a
    else 
      match Cursor.kind def with
      | NoDeclFound | InvalidFile -> opaque_decl ctx cursor; a
      | _ -> a

  and opaque_ty ctx typ = 
    match Type.kind typ with
    | C.Record | C.Enum -> begin
      let decl = Type.declaration typ in
      let def = Cursor.definition decl in
      match Cursor.kind def with
      | NoDeclFound | InvalidFile -> opaque_decl ctx decl
      | _ -> ()
      end
    | _ -> ()

  and decl_name ctx cursor = 
    let cursor = Cursor.canonical cursor in
    match CHash.find ctx.name cursor with
    | e -> e
    | exception Not_found ->
      let spelling = Cursor.spelling cursor in
      let global = 
        match Cursor.kind cursor with
        | StructDecl -> GCompDecl {ci_name=spelling; ci_kind=Struct; ci_members=[]}
        | UnionDecl -> GCompDecl {ci_name=spelling; ci_kind=Union; ci_members=[]}
        | EnumDecl ->
          let ei_kind = 
            match Type.kind @@ Cursor.enum_type cursor with
            | C.SChar | C.Char_S -> ISChar
            | C.UChar | C.Char_U -> IUChar
            | C.UShort -> IUShort | C.UInt -> IUInt
            | C.ULong -> IULong | C.ULongLong -> IULongLong
            | C.Short -> IShort | C.Int -> IInt
            | C.Long -> ILong | C.LongLong -> ILongLong
            | _ -> IInt
          in
          GEnumDecl { ei_name=spelling; ei_kind; ei_items=[] }
        | TypedefDecl ->
          GType { ti_name=spelling; ti_typ=TVoid }
        | VarDecl ->
          GVar { vi_name=spelling; vi_typ=TVoid; vi_val=None; vi_is_const=false }
        | FunctionDecl ->
          GFunc { vi_name=spelling; vi_typ=TVoid; vi_val=None; vi_is_const=false }
        | _ -> GOther
      in
      CHash.add ctx.name cursor global;
      global

  and visit_enum cursor items =
    Cursor.visit cursor 
      (fun cursor _ items ->
        match Cursor.kind cursor with
        | EnumConstantDecl -> 
          Continue, 
            ({ eit_name=Cursor.spelling cursor; eit_val=Cursor.enum_val cursor }) :: items
        | _ -> 
          Continue, items)
      items
  
  and visit_composite cursor ctx members = 

    let rec inner_composite = function
      | TComp(ty) -> Some(ty)
      | TPtr(ty,_) | TArray(ty,_) -> inner_composite ty
      | _ -> None
    in

    let rec inner_enumeration = function
      | TEnum(ty) -> Some(ty)
      | TPtr(ty,_) | TArray(ty,_) -> inner_enumeration ty
      | _ -> None
    in
    
    let members = 
      match Cursor.kind cursor with
      | FieldDecl -> begin
        (* XXX bitfield stuff XXX *)
        let name = Cursor.spelling cursor in
        let typ = conv_ty ctx (Cursor.cur_type cursor) cursor in
        let field = { fi_name=name; fi_typ=typ } in
        match inner_composite typ, inner_enumeration typ, members with
        | Some(c), None, ((Comp(h))::t) when h=c -> 
          (CompField(h, field)) :: t
        | None, Some(e), ((Enum(h))::t) when h=e -> 
          (EnumField(h, field)) :: t
        | _ -> 
          (Field field) :: members
      end
      | StructDecl | UnionDecl ->
        let visit ctx members =
          let decl = decl_name ctx cursor in
          let ci = compinfo decl in
          let ci_members = 
            Cursor.visit cursor (fun c _ m -> visit_composite c ctx m) ci.ci_members 
          in
          (Comp { ci with ci_members }) :: members
        in
        fwd_decl ctx cursor visit members
      | EnumDecl ->
        let visit ctx members = 
          let decl = decl_name ctx cursor in
          let ei = enuminfo decl in
          let ei_items = visit_enum cursor ei.ei_items in
          Enum { ei with ei_items } :: members
        in
        fwd_decl ctx cursor visit members
      
      | _ ->
        (* XXX warn - unhandled *)
        members
    in

    Continue, members

  (*and visit_literal cursor unt = (* XXX TODO *) *)

  and visit_top ctx tunit cursor _ () = 
    match Cursor.kind cursor with
    | UnexposedDecl -> Recurse, ()
    
    | StructDecl | UnionDecl ->
      let visit ctx () = 
        let decl = decl_name ctx cursor in
        let ci = compinfo decl in
        let ci_members = 
          Cursor.visit cursor (fun c _ m -> visit_composite c ctx m) ci.ci_members
        in
        ctx.globals <- (GComp { ci with ci_members }) :: ctx.globals
      in
      Continue, fwd_decl ctx cursor visit ()

    | EnumDecl ->
      let visit ctx () = 
        let decl = decl_name ctx cursor in
        let ei = enuminfo decl in
        let ei_items = visit_enum cursor ei.ei_items in
        ctx.globals <- (GEnum { ei with ei_items }) :: ctx.globals 
      in
      Continue, fwd_decl ctx cursor visit ()

    | FunctionDecl ->
      let linkage = Cursor.linkage cursor in
      if linkage <> CXLinkageKind.External && linkage <> CXLinkageKind.UniqueExternal then
        Continue, ()
      else
        let vi = varinfo @@ decl_name ctx cursor in
        let typ = Cursor.cur_type cursor in
        let vi_typ = TFuncPtr(mk_fn_sig ctx typ cursor) in
        ctx.globals <- (GFunc { vi with vi_typ }) :: ctx.globals;
        Continue, ()

    (* | VarDecl -> *)

    | TypedefDecl ->
      let under_typ = Cursor.typedef_type cursor in
      let under_typ = 
        match Type.kind under_typ with
        | C.Unexposed -> Type.canonical_type under_typ
        | _ -> under_typ
      in
      let typ = conv_ty ctx (Cursor.cur_type cursor) cursor in
      let ti = typeinfo @@ decl_name ctx cursor in
      ctx.globals <- (GType { ti with ti_typ=typ }) :: ctx.globals;
      opaque_ty ctx under_typ;
      Continue, ()

    (* | MacroDefinition *)

    | _ -> Continue, ()

end


