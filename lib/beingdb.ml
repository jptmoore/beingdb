(** BeingDB: Logic-based knowledge store with Git and Pack backends.

    Re-exports the portable runtime ({!Beingdb_runtime}), the native pack
    adapter ({!Beingdb_pack_unix}) and the authoring/server/CLI modules
    under one namespace. [Query_engine] and [Query_environment] are
    bound to the native {!Pack_backend} here for backward compatibility. *)

module Version = Version
module Decimal = Decimal
module Calendar = Calendar
module Value = Value
module Lexer = Lexer
module Fact = Fact
module Predicate_declaration = Predicate_declaration
module Manifest = Manifest
module Query_ast = Query_ast
module Clause_parser = Clause_parser
module Query_connectivity = Query_connectivity
module Query_planner = Query_planner
module Runtime_store = Runtime_store
module Pack_layout = Pack_layout
module Memory_store = Memory_store
module Git_backend = Git_backend
module Pack_backend = Pack_backend
module Parse_predicate = Parse_predicate
module Parse_declaration = Parse_declaration
module Query_parser = Query_parser

module Query_engine = struct
  include Query_engine
  include Db.Engine
end

module Query_validation = Query_validation
module Server_config = Server_config

module Query_environment = struct
  include Query_environment
  include Db.Environment
end

module Predicate_suggest = Predicate_suggest
module Surface_ast = Surface_ast
module Dsl_parser = Dsl_parser
module Core_query = Core_query
module Validation_error = Validation_error
module Dsl_lower = Dsl_lower
module Explain_plan = Explain_plan
module Db = Db
module Model = Model
module Controller = Controller
module Api = Api
module Repl_support = Repl_support
module Cli_clone = Cli_clone
module Cli_pull = Cli_pull
module Cli_import = Cli_import
module Cli_compile = Cli_compile
module Cli_serve = Cli_serve
module Cli_repl = Cli_repl
