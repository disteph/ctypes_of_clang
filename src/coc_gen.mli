module Make(Clang : Coc_clang.S) : sig 

  module Cparse : module type of Coc_parse.Make(Clang)

  module Attrs : sig
    type t  
    val get : (string Asttypes.loc * Parsetree.payload) list -> t 
  end

  module G : Map.S with type key = Cparse.global

  type t = 
    {
      loc : Location.t;
      attrs : Attrs.t;
      mangle : string -> string;
      global_to_binding : string G.t;
      builtins : Cparse.global list;
      comp_members_map : Cparse.member list Cparse.TypeMap.t;
      enum_items_map : ((string * int64) list * Cparse.typ) Cparse.TypeMap.t;
      gendecl : Clang.Loc.t -> string -> bool;
      gentype : Clang.Loc.t -> string -> bool;
    }

  val gen_ccode : ctx:t -> code:string -> 
    (string * Parsetree.expression) list

  val ccode : ctx:t -> code:string -> 
    Parsetree.structure_item list

  val register : unit -> unit

end

