(** Detects a query whose positive pattern clauses form more than one
    connected component (an unconstrained Cartesian product). See the
    .ml for the exact connectivity rules. Returns [Error groups] where
    each element of [groups] is one disconnected component, rendered as
    the clause strings it contains. *)
val check_query : Query_ast.query -> (unit, string list list) result
