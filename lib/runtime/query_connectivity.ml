(** Query_connectivity: detects a query whose positive (non-negated)
    pattern clauses form more than one connected component -- i.e. would
    execute as an unconstrained Cartesian product between two otherwise
    unrelated pattern groups, such as:

    {v
      find Person, Organisation
      where
        person(Person)
        organisation(Organisation)
    v}

    Two top-level clauses are considered connected when they share a
    variable, share an identical literal constant, or are both
    referenced by a single comparison/between clause that spans them.
    [Optional]/[Alternatives]/[Not_exists] groups are each treated as one
    node at the level they appear, keyed by every variable used anywhere
    inside them (so a group is connected to the rest of the query via
    any variable it shares with an outer clause); each such group's own
    body (and, for [Alternatives], each branch independently) is in turn
    checked for internal connectivity, recursively.

    Deliberately does *not* treat repeated use of the same predicate as
    an error -- self-joins and multi-hop chains (e.g. [parent(A, B),
    parent(B, C)]) are ordinary, connected queries. *)

module Union_find = struct
  let create n = Array.init n (fun i -> i)

  let rec find t i =
    if t.(i) = i then i
    else (
      let root = find t t.(i) in
      t.(i) <- root;
      root)

  let union t a b =
    let ra = find t a and rb = find t b in
    if ra <> rb then t.(ra) <- rb
end

type node = { clause : Query_ast.clause; variables : string list; constants : Value.t list }

let node_of_clause (c : Query_ast.clause) : node option =
  match c with
  | Query_ast.Pattern { arguments; _ } ->
      let variables = List.filter_map (function Query_ast.Variable v -> Some v | _ -> None) arguments in
      let constants = List.filter_map (function Query_ast.Literal v -> Some v | _ -> None) arguments in
      Some { clause = c; variables; constants }
  | Query_ast.Optional group -> Some { clause = c; variables = Query_ast.extract_variables group; constants = [] }
  | Query_ast.Not_exists group -> Some { clause = c; variables = Query_ast.extract_variables group; constants = [] }
  | Query_ast.Alternatives branches -> Some { clause = c; variables = Query_ast.extract_variables (List.concat branches); constants = [] }
  | Query_ast.Compare _ | Query_ast.Between _ -> None

(** Every variable referenced by a top-level [Compare]/[Between] clause
    (comparisons don't produce nodes of their own, but they do connect
    whichever nodes bind the variables they reference). *)
let comparison_variable_groups (clauses : Query_ast.clause list) =
  List.filter_map
    (function
      | Query_ast.Compare { left; right; _ } -> Some (Query_ast.variables_of_term left @ Query_ast.variables_of_term right)
      | Query_ast.Between { value; lower; upper } ->
          Some (Query_ast.variables_of_term value @ Query_ast.variables_of_term lower @ Query_ast.variables_of_term upper)
      | Query_ast.Pattern _ | Query_ast.Optional _ | Query_ast.Alternatives _ | Query_ast.Not_exists _ -> None)
    clauses

(** Connectivity check over a single (non-nested) clause list: 0 or 1
    data-producing node is trivially connected; otherwise every node
    must end up in the same union-find component. *)
let check_flat (clauses : Query_ast.clause list) : (unit, string list list) result =
  let nodes = Array.of_list (List.filter_map node_of_clause clauses) in
  let n = Array.length nodes in
  if n <= 1 then Ok ()
  else begin
    let uf = Union_find.create n in
    for i = 0 to n - 1 do
      for j = i + 1 to n - 1 do
        let shares_variable = List.exists (fun v -> List.mem v nodes.(j).variables) nodes.(i).variables in
        let shares_constant = List.exists (fun v -> List.exists (Value.equal v) nodes.(j).constants) nodes.(i).constants in
        if shares_variable || shares_constant then Union_find.union uf i j
      done
    done;
    List.iter
      (fun vars ->
        let connected_indices = ref [] in
        Array.iteri (fun i node -> if List.exists (fun v -> List.mem v node.variables) vars then connected_indices := i :: !connected_indices) nodes;
        match !connected_indices with
        | [] | [ _ ] -> ()
        | first :: rest -> List.iter (fun i -> Union_find.union uf first i) rest)
      (comparison_variable_groups clauses);
    let roots = List.init n (fun i -> Union_find.find uf i) |> List.sort_uniq compare in
    if List.length roots <= 1 then Ok ()
    else
      let groups =
        List.map
          (fun root ->
            nodes |> Array.to_list
            |> List.filteri (fun i _ -> Union_find.find uf i = root)
            |> List.map (fun node -> Query_ast.clause_to_string node.clause))
          roots
      in
      Error groups
  end

(** Full connectivity check, recursing into nested groups: the top-level
    clause list, each [Optional]/[Not_exists] group's own body, and each
    [Alternatives] branch independently. Returns the first disconnected
    component found. *)
let rec check (clauses : Query_ast.clause list) : (unit, string list list) result =
  match check_flat clauses with
  | Error _ as e -> e
  | Ok () ->
      let rec go = function
        | [] -> Ok ()
        | (Query_ast.Optional group | Query_ast.Not_exists group) :: rest -> (
            match check group with Error _ as e -> e | Ok () -> go rest)
        | Query_ast.Alternatives branches :: rest -> (
            match List.fold_left (fun acc branch -> match acc with Error _ as e -> e | Ok () -> check branch) (Ok ()) branches with
            | Error _ as e -> e
            | Ok () -> go rest)
        | (Query_ast.Pattern _ | Query_ast.Compare _ | Query_ast.Between _) :: rest -> go rest
      in
      go clauses

let check_query (query : Query_ast.query) = check query.clauses
