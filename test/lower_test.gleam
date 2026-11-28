import emit/moonbit
import filepath
import glance
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import index/symbol_table
import lower/desugar
import lower/ir
import lower/ir_util
import lower/mangle
import lower/pattern
import lower/tco
import lower/validate
import project/cmd
import project/prepass
import project/workspace
import simplifile

pub fn mangle_keywords_and_type_params_test() {
  assert mangle.is_reserved_keyword("match") == True
  assert mangle.is_reserved_keyword("loop") == True
  assert mangle.is_reserved_keyword("guard") == True
  assert mangle.is_reserved_keyword("struct") == True
  assert mangle.is_reserved_keyword("count") == False

  assert mangle.mangle_ident("match") == "match_"
  assert mangle.mangle_ident("loop") == "loop_"
  assert mangle.mangle_ident("guard") == "guard_"
  assert mangle.mangle_ident("module") == "module_"
  assert mangle.mangle_ident("extern") == "extern_"
  assert mangle.mangle_ident("declare") == "declare_"
  assert mangle.mangle_ident("dyn") == "dyn_"
  assert mangle.mangle_ident("lazy") == "lazy_"
  assert mangle.mangle_ident("ignore") == "ignore_"
  assert mangle.mangle_ident("println") == "println_"
  assert mangle.mangle_ident("match_") == "match__"
  assert mangle.mangle_ident("match__") == "match___"
  assert mangle.mangle_ident("normal_var") == "normal_var"
  assert mangle.mangle_ident("foo_") == "foo_"

  assert mangle.is_reserved_type_name("Error") == True
  assert mangle.is_reserved_type_name("Option") == True
  assert mangle.is_reserved_type_name("User") == False
  assert mangle.mangle_type_name("Error") == "Error_"
  assert mangle.mangle_type_name("Error_") == "Error__"
  assert mangle.mangle_type_name("User") == "User"
  assert mangle.mangle_type_name("User_") == "User_"

  assert mangle.mangle_type_param("item") == "Item"
  assert mangle.mangle_type_param("key_value") == "KeyValue"
  assert mangle.mangle_type_param("int") == "T_Int"
  assert mangle.mangle_type_param("string") == "T_String"
  assert mangle.mangle_type_param("t0") == "T_T0"
  assert mangle.mangle_type_param("t0") != mangle.type_var_id_to_name(0)
  assert mangle.mangle_type_param("_a") != mangle.mangle_type_param("a")
  assert mangle.type_var_id_to_name(2) == "T2"
}

// -----------------------------------------------------------------------------
// 7. Phase 2: Pattern lowering tests
// -----------------------------------------------------------------------------
pub fn pattern_lists_strings_and_shorthand_variants_test() {
  let src =
    "pub type User {\n"
    <> "  User(name: String, age: Int)\n"
    <> "}\n"
    <> "\n"
    <> "pub fn inspect_list(xs: List(Int)) -> Int {\n"
    <> "  case xs {\n"
    <> "    [] -> 0\n"
    <> "    [x] -> x\n"
    <> "    [x, y, ..rest] -> x + y\n"
    <> "  }\n"
    <> "}\n"
    <> "\n"
    <> "pub fn parse_cmd(s: String) -> String {\n"
    <> "  case s {\n"
    <> "    \"cmd:\" as p <> rest if rest != \"\" -> p <> rest\n"
    <> "    \"hi:\" <> rest -> rest\n"
    <> "    _ -> \"\"\n"
    <> "  }\n"
    <> "}\n"
    <> "\n"
    <> "pub fn match_user(u: User) -> String {\n"
    <> "  case u {\n"
    <> "    User(name:, ..) -> name\n"
    <> "  }\n"
    <> "}\n"

  let assert Ok(#(ast_mod, pre_res)) = prepass.parse_module("pat_mod", src)
  let table =
    symbol_table.index_project(
      "pat_pkg",
      [#("pat_mod", ast_mod, pre_res)],
      None,
      dict.new(),
    )
  let ir_mod = desugar.desugar_module(ast_mod, table, "pat_mod")

  // List pattern lowering: [], [x], [x, y, ..rest]
  let assert Ok(inspect_fn) =
    list.find(ir_mod.functions, fn(f) { f.name == "inspect_list" })
  let assert [ir.IrStmtExpr(ir.IrMatch(clauses: list_clauses, ..))] =
    inspect_fn.body
  let assert [c_empty, c_single, c_cons2] = list_clauses

  assert c_empty.patterns
    == [[ir.IrPatVariant(Some("gprelude"), None, "Nil", [], False)]]
  assert c_single.patterns
    == [
      [
        ir.IrPatVariant(
          Some("gprelude"),
          None,
          "Cons",
          [
            ir.IrPatArg(None, ir.IrPatVar("x")),
            ir.IrPatArg(
              None,
              ir.IrPatVariant(Some("gprelude"), None, "Nil", [], False),
            ),
          ],
          False,
        ),
      ],
    ]
  assert c_cons2.patterns
    == [
      [
        ir.IrPatVariant(
          Some("gprelude"),
          None,
          "Cons",
          [
            ir.IrPatArg(None, ir.IrPatVar("x")),
            ir.IrPatArg(
              None,
              ir.IrPatVariant(
                Some("gprelude"),
                None,
                "Cons",
                [
                  ir.IrPatArg(None, ir.IrPatVar("y")),
                  ir.IrPatArg(None, ir.IrPatVar("rest")),
                ],
                False,
              ),
            ),
          ],
          False,
        ),
      ],
    ]

  // String prefix pattern lowering with `as` prefix alias + user guard
  let assert Ok(parse_fn) =
    list.find(ir_mod.functions, fn(f) { f.name == "parse_cmd" })
  let assert [ir.IrStmtExpr(ir.IrMatch(clauses: str_clauses, ..))] =
    parse_fn.body
  let assert [c_cmd, c_hi, c_wild] = str_clauses

  assert c_cmd.patterns == [[ir.IrPatVar("__str_pfx_0")]]
  assert c_cmd.prefix_bindings
    == [
      #("p", ir.IrString("cmd:")),
      #(
        "rest",
        ir.IrCall(
          ir.IrModuleRef(Some("gprelude"), "gprelude", "string_drop_prefix"),
          [
            ir.IrCallArg(None, ir.IrVar("__str_pfx_0")),
            ir.IrCallArg(None, ir.IrString("cmd:")),
          ],
        ),
      ),
    ]
  // Guard has both synthetic has_prefix AND user guard wrapped with needed prefix bindings
  let assert Some(ir.IrBinOp(ir.IrAnd, has_pfx_call, ir.IrBlock(guard_block))) =
    c_cmd.guard
  assert has_pfx_call
    == ir.IrCall(
      ir.IrModuleRef(Some("gprelude"), "gprelude", "string_has_prefix"),
      [
        ir.IrCallArg(None, ir.IrVar("__str_pfx_0")),
        ir.IrCallArg(None, ir.IrString("cmd:")),
      ],
    )
  assert list.length(guard_block) == 2

  assert c_hi.patterns == [[ir.IrPatVar("__str_pfx_1")]]
  assert c_wild.patterns == [[ir.IrPatDiscard]]

  // Shorthand variant pattern: User(name:, ..)
  let assert Ok(user_fn) =
    list.find(ir_mod.functions, fn(f) { f.name == "match_user" })
  let assert [ir.IrStmtExpr(ir.IrMatch(clauses: [c_user], ..))] = user_fn.body
  assert c_user.patterns
    == [
      [
        ir.IrPatVariant(
          None,
          None,
          "User",
          [ir.IrPatArg(Some("name"), ir.IrPatVar("name"))],
          True,
        ),
      ],
    ]
  let _ = pattern.lower_pattern
  Nil
}

// -----------------------------------------------------------------------------
// 8. Phase 2: Desugar, Use, Pipes, Captures, Getters & Record Updates
// -----------------------------------------------------------------------------
pub fn desugar_use_chains_and_let_assert_test() {
  let src =
    "pub fn wrap(x: a, f: fn(a) -> b) -> b {\n"
    <> "  f(x)\n"
    <> "}\n"
    <> "\n"
    <> "pub fn bare(f: fn(Int) -> Int) -> Int {\n"
    <> "  f(10)\n"
    <> "}\n"
    <> "\n"
    <> "pub fn pipeline(res: Result(Int, String)) -> Int {\n"
    <> "  use #(a, b) <- wrap(#(1, 2))\n"
    <> "  use n <- bare\n"
    <> "  let assert Ok(v) = res as \"must be ok\"\n"
    <> "  a + b + n + v\n"
    <> "}\n"

  let assert Ok(#(ast_mod, pre_res)) = prepass.parse_module("use_mod", src)
  let table =
    symbol_table.index_project(
      "use_pkg",
      [#("use_mod", ast_mod, pre_res)],
      None,
      dict.new(),
    )
  let ir_mod = desugar.desugar_module(ast_mod, table, "use_mod")
  let assert Ok(pipe_fn) =
    list.find(ir_mod.functions, fn(f) { f.name == "pipeline" })

  // Outer `use #(a, b) <- wrap(#(1, 2))` becomes single call expr
  let assert [
    ir.IrStmtExpr(ir.IrCall(
      ir.IrVar("wrap"),
      [
        ir.IrCallArg(None, ir.IrTuple([ir.IrInt("1"), ir.IrInt("2")])),
        ir.IrCallArg(None, ir.IrFn(params: [outer_param], body: outer_body, ..)),
      ],
    )),
  ] = pipe_fn.body

  assert outer_param.name == "__use_arg_0"

  // Destructured tuple `let #(a, b) = __use_arg_0`, followed by `use n <- bare`
  let assert [
    ir.IrStmtLet(
      ir.IrPatTuple([ir.IrPatVar("a"), ir.IrPatVar("b")]),
      None,
      ir.IrVar("__use_arg_0"),
    ),
    ir.IrStmtExpr(ir.IrCall(
      ir.IrVar("bare"),
      [ir.IrCallArg(None, ir.IrFn(params: [inner_param], body: inner_body, ..))],
    )),
  ] = outer_body

  assert inner_param.name == "n"

  // Inside inner closure: `let assert Ok(v) = res` -> IrStmtGuard + final addition
  let assert [
    ir.IrStmtGuard(
      value: ir.IrVar("res"),
      pattern: ir.IrPatVariant(
        None,
        None,
        "Ok",
        [ir.IrPatArg(None, ir.IrPatVar("v"))],
        False,
      ),
      guard_condition: None,
      abort_message: Some(ir.IrString("must be ok")),
      post_bindings: [],
    ),
    ir.IrStmtExpr(ir.IrBinOp(ir.IrAddInt, _, ir.IrVar("v"))),
  ] = inner_body
}

pub fn desugar_pipes_captures_getters_and_record_updates_test() {
  let helper_src =
    "pub fn inc(x: Int) -> Int {\n"
    <> "  x + 1\n"
    <> "}\n"
    <> "\n"
    <> "pub type Account {\n"
    <> "  Admin(id: Int, name: String, level: Int)\n"
    <> "  Guest(id: Int, name: String)\n"
    <> "}\n"
    <> "\n"
    <> "pub type Box(a) {\n"
    <> "  Box(value: a, tag: String)\n"
    <> "}\n"
    <> "\n"
    <> "pub type Hook {\n"
    <> "  Hook(cb: fn(Int) -> Int)\n"
    <> "}\n"

  let main_src =
    "import app/helper\n"
    <> "import app/helper.{Admin, Box, Guest}\n"
    <> "\n"
    <> "pub fn add(a: Int, b: Int) -> Int { a + b }\n"
    <> "pub fn divide(numerator: Int, by denominator: Int) -> Int { numerator / denominator }\n"
    <> "pub fn greet(prefix p: String, name n: String) -> String { p <> n }\n"
    <> "pub fn make_adder(n: Int) -> fn(Int) -> Int { fn(x) { x + n } }\n"
    <> "\n"
    <> "pub fn test_pipes_and_captures(x: Int) -> Int {\n"
    <> "  let f1 = add(1, _)\n"
    <> "  let f2 = divide(by: _, 20)\n"
    <> "  let r1 = x |> helper.inc\n"
    <> "  let r2 = x |> add(10)\n"
    <> "  let r3 = x |> make_adder(5)\n"
    <> "  let r4 = x |> add(1, _)\n"
    <> "  f1(r1) + f2(2) + r2 + r3 + r4\n"
    <> "}\n"
    <> "\n"
    <> "pub fn test_labeled_pipe() -> String {\n"
    <> "  \"Alice\" |> greet(prefix: \"Hi, \")\n"
    <> "}\n"
    <> "\n"
    <> "pub fn test_getters_and_updates(acc: Account, box: Box(Int)) -> #(Int, Account, Box(Int), Int) {\n"
    <> "  let helper = box\n"
    <> "  let v = helper.value\n"
    <> "  let id = acc.id\n"
    <> "  let name = \"NewName\"\n"
    <> "  let acc2 = Admin(..acc, name:)\n"
    <> "  let box2 = Box(..box, value: 99)\n"
    <> "  #(id, acc2, box2, v)\n"
    <> "}\n"

  let assert Ok(#(helper_ast, helper_pre)) =
    prepass.parse_module("app/helper", helper_src)
  let assert Ok(#(main_ast, main_pre)) =
    prepass.parse_module("app/main", main_src)

  let table =
    symbol_table.index_project(
      "app",
      [
        #("app/helper", helper_ast, helper_pre),
        #("app/main", main_ast, main_pre),
      ],
      None,
      dict.new(),
    )

  let helper_ir = desugar.desugar_module(helper_ast, table, "app/helper")
  let main_ir = desugar.desugar_module(main_ast, table, "app/main")

  // Verify Uniform Enum derive flag & synthesized getters on helper_ir
  let assert Ok(acc_def) =
    list.find(helper_ir.types, fn(t) { t.name == "Account" })
  assert acc_def.derive_eq_debug_hash == True

  let assert Ok(hook_def) =
    list.find(helper_ir.types, fn(t) { t.name == "Hook" })
  assert hook_def.derive_eq_debug_hash == False

  let acc_getters =
    list.filter(helper_ir.getters, fn(g) { g.type_name == "Account" })
  assert list.map(acc_getters, fn(g) { g.field_name }) == ["id", "name"]

  let box_getters =
    list.filter(helper_ir.getters, fn(g) { g.type_name == "Box" })
  assert list.map(box_getters, fn(g) { #(g.field_name, g.type_params) })
    == [#("tag", ["A"]), #("value", ["A"])]

  // Verify captures & pipes
  let assert Ok(pipes_fn) =
    list.find(main_ir.functions, fn(f) { f.name == "test_pipes_and_captures" })
  let assert [
    // f1 = add(1, _)
    ir.IrStmtLet(
      ir.IrPatVar("f1"),
      None,
      ir.IrFn(
        params: [ir.IrFnParam("__capture_0", None)],
        body: [
          ir.IrStmtExpr(ir.IrCall(
            ir.IrVar("add"),
            [
              ir.IrCallArg(None, ir.IrInt("1")),
              ir.IrCallArg(None, ir.IrVar("__capture_0")),
            ],
          )),
        ],
        ..,
      ),
    ),
    // f2 = divide(by: _, 20)
    ir.IrStmtLet(
      ir.IrPatVar("f2"),
      None,
      ir.IrFn(
        params: [ir.IrFnParam("__capture_1", None)],
        body: [
          ir.IrStmtExpr(ir.IrCall(
            ir.IrVar("divide"),
            [
              ir.IrCallArg(Some("by"), ir.IrVar("__capture_1")),
              ir.IrCallArg(None, ir.IrInt("20")),
            ],
          )),
        ],
        ..,
      ),
    ),
    // r1 = x |> helper.inc
    ir.IrStmtLet(
      ir.IrPatVar("r1"),
      None,
      ir.IrCall(
        ir.IrModuleRef(Some("helper"), "app/helper", "inc"),
        [ir.IrCallArg(None, ir.IrVar("x"))],
      ),
    ),
    // r2 = x |> add(10)
    ir.IrStmtLet(
      ir.IrPatVar("r2"),
      None,
      ir.IrCall(
        ir.IrVar("add"),
        [ir.IrCallArg(None, ir.IrVar("x")), ir.IrCallArg(None, ir.IrInt("10"))],
      ),
    ),
    // r3 = x |> make_adder(5)  (saturated -> closure call)
    ir.IrStmtLet(
      ir.IrPatVar("r3"),
      None,
      ir.IrCall(
        ir.IrCall(ir.IrVar("make_adder"), [ir.IrCallArg(None, ir.IrInt("5"))]),
        [ir.IrCallArg(None, ir.IrVar("x"))],
      ),
    ),
    // r4 = x |> add(1, _)
    ir.IrStmtLet(
      ir.IrPatVar("r4"),
      None,
      ir.IrCall(
        ir.IrVar("add"),
        [ir.IrCallArg(None, ir.IrInt("1")), ir.IrCallArg(None, ir.IrVar("x"))],
      ),
    ),
    _,
  ] = pipes_fn.body

  // Verify labeled pipe slot resolution: "Alice" |> greet(prefix: "Hi, ")
  let assert Ok(greet_pipe_fn) =
    list.find(main_ir.functions, fn(f) { f.name == "test_labeled_pipe" })
  assert greet_pipe_fn.body
    == [
      ir.IrStmtExpr(
        ir.IrCall(ir.IrVar("greet"), [
          ir.IrCallArg(Some("name"), ir.IrString("Alice")),
          ir.IrCallArg(Some("prefix"), ir.IrString("Hi, ")),
        ]),
      ),
    ]

  // Verify local variable shadowing module alias (`let helper = box; helper.value` -> getter),
  // uniform getter (`acc.id`), and multi-variant vs single-variant record updates
  let assert Ok(upd_fn) =
    list.find(main_ir.functions, fn(f) { f.name == "test_getters_and_updates" })
  let assert [
    ir.IrStmtLet(ir.IrPatVar("helper"), None, ir.IrVar("box")),
    ir.IrStmtLet(
      ir.IrPatVar("v"),
      None,
      ir.IrGetterCall(ir.IrVar("helper"), "value"),
    ),
    ir.IrStmtLet(
      ir.IrPatVar("id"),
      None,
      ir.IrGetterCall(ir.IrVar("acc"), "id"),
    ),
    ir.IrStmtLet(ir.IrPatVar("name"), None, ir.IrString("NewName")),
    ir.IrStmtLet(
      ir.IrPatVar("acc2"),
      None,
      ir.IrMatch([ir.IrVar("acc")], [acc_match_arm, acc_abort_arm]),
    ),
    ir.IrStmtLet(
      ir.IrPatVar("box2"),
      None,
      ir.IrMatch([ir.IrVar("box")], [box_match_arm]),
    ),
    _,
  ] = upd_fn.body

  // Multi-variant record update has abort fallback and non-shadowing synthetic vars
  assert acc_abort_arm.patterns == [[ir.IrPatDiscard]]
  assert acc_abort_arm.body
    == ir.IrAbort(
      ir.PanicAbort,
      Some(ir.IrString("unreachable record update variant")),
    )
  let assert [
    [
      ir.IrPatVariant(
        Some("helper"),
        Some("app/helper"),
        "Admin",
        [
          ir.IrPatArg(Some("id"), ir.IrPatVar("__upd_2_id")),
          ir.IrPatArg(Some("name"), ir.IrPatDiscard),
          ir.IrPatArg(Some("level"), ir.IrPatVar("__upd_2_level")),
        ],
        False,
      ),
    ],
  ] = acc_match_arm.patterns
  assert acc_match_arm.body
    == ir.IrCall(ir.IrConstructor(Some("helper"), Some("app/helper"), "Admin"), [
      ir.IrCallArg(Some("id"), ir.IrVar("__upd_2_id")),
      ir.IrCallArg(Some("name"), ir.IrVar("name")),
      ir.IrCallArg(Some("level"), ir.IrVar("__upd_2_level")),
    ])

  // Single-variant record update is exhaustive (1 arm, no abort fallback)
  let assert [
    [
      ir.IrPatVariant(
        Some("helper"),
        Some("app/helper"),
        "Box",
        [
          ir.IrPatArg(Some("value"), ir.IrPatDiscard),
          ir.IrPatArg(Some("tag"), ir.IrPatVar("__upd_3_tag")),
        ],
        False,
      ),
    ],
  ] = box_match_arm.patterns
}

// -----------------------------------------------------------------------------
// 9. Phase 2: Functional `for` TCO tests
// -----------------------------------------------------------------------------
pub fn tco_functional_for_loop_lowering_test() {
  let src =
    "pub fn sum_loop(items: List(Int), acc: Int) -> Int {\n"
    <> "  case items {\n"
    <> "    [] -> acc\n"
    <> "    [x, ..rest] -> sum_loop(rest, acc + x)\n"
    <> "  }\n"
    <> "}\n"
    <> "\n"
    <> "pub fn count_labeled(count n: Int, acc total: Int, tag _tag: String) -> Int {\n"
    <> "  case n {\n"
    <> "    0 -> total\n"
    <> "    _ -> {\n"
    <> "      let next = n - 1\n"
    <> "      count_labeled(acc: total + n, count: next, tag: \"loop\")\n"
    <> "    }\n"
    <> "  }\n"
    <> "}\n"
    <> "\n"
    <> "pub fn map_naive(items: List(Int), f: fn(Int) -> Int) -> List(Int) {\n"
    <> "  case items {\n"
    <> "    [] -> []\n"
    <> "    [x, ..rest] -> [f(x), ..map_naive(rest, f)]\n"
    <> "  }\n"
    <> "}\n"

  let assert Ok(#(ast_mod, pre_res)) = prepass.parse_module("tco_mod", src)
  let table =
    symbol_table.index_project(
      "tco_pkg",
      [#("tco_mod", ast_mod, pre_res)],
      None,
      dict.new(),
    )
  let ir_mod =
    desugar.desugar_module(ast_mod, table, "tco_mod")
    |> tco.optimize_module

  // 1. Self-tail-recursive sum_loop -> IrForLoop with IrBreak & IrContinue
  let assert Ok(sum_fn) =
    list.find(ir_mod.functions, fn(f) { f.name == "sum_loop" })
  let assert [
    ir.IrStmtExpr(ir.IrForLoop(
      bindings: [#("items", ir.IrVar("items")), #("acc", ir.IrVar("acc"))],
      body: [ir.IrStmtExpr(ir.IrMatch(clauses: [arm_nil, arm_cons], ..))],
    )),
  ] = sum_fn.body

  assert arm_nil.body == ir.IrBreak(ir.IrVar("acc"))
  assert arm_cons.body
    == ir.IrContinue([
      ir.IrVar("rest"),
      ir.IrBinOp(ir.IrAddInt, ir.IrVar("acc"), ir.IrVar("x")),
    ])

  // 2. Labeled reordered call args + discarded param normalized to `__tco_unused_2`
  let assert Ok(cnt_fn) =
    list.find(ir_mod.functions, fn(f) { f.name == "count_labeled" })
  assert list.map(cnt_fn.params, fn(p) { p.name })
    == ["n", "total", "__tco_unused_2"]
  let assert [
    ir.IrStmtExpr(ir.IrForLoop(
      bindings: [
        #("n", ir.IrVar("n")),
        #("total", ir.IrVar("total")),
        #("__tco_unused_2", ir.IrVar("__tco_unused_2")),
      ],
      body: [ir.IrStmtExpr(ir.IrMatch(clauses: [arm_zero, arm_step], ..))],
    )),
  ] = cnt_fn.body

  assert arm_zero.body == ir.IrBreak(ir.IrVar("total"))
  let assert ir.IrBlock([
    ir.IrStmtLet(ir.IrPatVar("next"), None, _),
    ir.IrStmtExpr(ir.IrContinue([
      ir.IrVar("next"),
      ir.IrBinOp(ir.IrAddInt, ir.IrVar("total"), ir.IrVar("n")),
      ir.IrString("loop"),
    ])),
  ]) = arm_step.body

  // 3. Non-tail-recursive map_naive stays an ordinary function (no IrForLoop)
  let assert Ok(map_fn) =
    list.find(ir_mod.functions, fn(f) { f.name == "map_naive" })
  let assert [ir.IrStmtExpr(ir.IrMatch(..))] = map_fn.body
}

// -----------------------------------------------------------------------------
// 10. Phase 3: Prelude runtime sync, pkg_config, MoonBit emitter & Golden E2E
// -----------------------------------------------------------------------------
pub fn bit_array_tier2_lowering_and_emission_test() {
  let src =
    "pub fn is_empty(b: BitArray) -> Bool {\n"
    <> "  case b {\n"
    <> "    <<>> -> True\n"
    <> "    <<_:bits>> -> False\n"
    <> "  }\n"
    <> "}\n\n"
    <> "pub fn id_bits(b: BitArray) -> BitArray {\n"
    <> "  case b {\n"
    <> "    <<rest:bits>> -> rest\n"
    <> "  }\n"
    <> "}\n\n"
    <> "pub fn split_bits(b: BitArray) -> #(Int, Int) {\n"
    <> "  case b {\n"
    <> "    <<a:3, b:5>> -> #(a, b)\n"
    <> "    _ -> #(0, 0)\n"
    <> "  }\n"
    <> "}\n\n"
    <> "pub fn sized_frame(b: BitArray) -> #(BitArray, BitArray) {\n"
    <> "  case b {\n"
    <> "    <<len:8, payload:bytes-size(len), rest:bits>> -> #(payload, rest)\n"
    <> "    _ -> #(<<>>, <<>>)\n"
    <> "  }\n"
    <> "}\n\n"
    <> "pub fn arith_size(b: BitArray) -> Int {\n"
    <> "  case b {\n"
    <> "    <<n:4, v:size(n * 2 - 1)>> -> v\n"
    <> "    _ -> 0\n"
    <> "  }\n"
    <> "}\n\n"
    <> "pub fn endian_float_utf(b: BitArray) -> Int {\n"
    <> "  case b {\n"
    <> "    <<x:12-little-signed, _f:16-float-little>> -> x\n"
    <> "    <<\"GET \":utf8, rest:bits>> -> bit_len(rest)\n"
    <> "    <<cp:utf8_codepoint, _:bits>> -> {\n"
    <> "      let _ = cp\n"
    <> "      1\n"
    <> "    }\n"
    <> "    <<_:utf8, _:bits>> -> 2\n"
    <> "    _ -> 0\n"
    <> "  }\n"
    <> "}\n\n"
    <> "pub fn nested_and_aliases(b: BitArray) -> #(Int, BitArray) {\n"
    <> "  case b {\n"
    <> "    <<1:8, payload:bytes-size(1), rest:bits>> -> #(1, <<payload:bits, rest:bits>>)\n"
    <> "    <<a:4, b:4>> as header -> #(a + b, header)\n"
    <> "    _ -> #(0, <<>>)\n"
    <> "  }\n"
    <> "}\n\n"
    <> "pub fn guard_pruning(b: BitArray) -> BitArray {\n"
    <> "  case b {\n"
    <> "    <<byte, rest:bits>> if byte < 128 -> rest\n"
    <> "    _ -> <<>>\n"
    <> "  }\n"
    <> "}\n\n"
    <> "pub fn body_pruning(b: BitArray) -> Bool {\n"
    <> "  case b {\n"
    <> "    <<len:8, _:bytes-size(len)>> -> True\n"
    <> "    _ -> False\n"
    <> "  }\n"
    <> "}\n\n"
    <> "pub fn bit_len(b: BitArray) -> Int {\n"
    <> "  let _ = b\n"
    <> "  0\n"
    <> "}\n\n"
    <> "pub fn construct_all(n: Int, cp: UtfCodepoint, ba: BitArray) -> BitArray {\n"
    <> "  <<n:16-native, 1.5, \"hi\":utf16-little, \"yo\":utf32-big, cp:utf8_codepoint, cp:utf16_codepoint-little, cp:utf32_codepoint-big, ba:bits-size(4), ba:bits-size(1)-unit(8)>>\n"
    <> "}\n"

  let assert Ok(#(ast_mod, pre_res)) = prepass.parse_module("ba_unit", src)
  let table =
    symbol_table.index_project(
      "ba_pkg",
      [#("ba_unit", ast_mod, pre_res)],
      None,
      dict.new(),
    )
  let ir_mod =
    desugar.desugar_module(ast_mod, table, "ba_unit")
    |> tco.optimize_module

  // 1. <<>> and <<_:bits>>
  let assert Ok(fn_empty) =
    list.find(ir_mod.functions, fn(f) { f.name == "is_empty" })
  let assert [ir.IrStmtExpr(ir.IrMatch(clauses: [c_emp, c_any], ..))] =
    fn_empty.body
  assert c_emp.patterns == [[ir.IrPatBitString([])]]
  assert c_any.patterns == [[ir.IrPatDiscard]]
  assert c_any.guard == None
  assert c_any.prefix_bindings == []

  // 2. <<rest:bits>>
  let assert Ok(fn_id) =
    list.find(ir_mod.functions, fn(f) { f.name == "id_bits" })
  let assert [ir.IrStmtExpr(ir.IrMatch(clauses: [c_id], ..))] = fn_id.body
  assert c_id.patterns == [[ir.IrPatVar("rest")]]
  assert c_id.guard == None
  assert c_id.prefix_bindings == []

  // 3. <<byte, rest:bits>> if byte < 128 -> rest (guard has NO rest, body has NO byte)
  let assert Ok(fn_gp) =
    list.find(ir_mod.functions, fn(f) { f.name == "guard_pruning" })
  let assert [ir.IrStmtExpr(ir.IrMatch(clauses: [c_gp, _], ..))] = fn_gp.body
  assert list.map(c_gp.prefix_bindings, fn(b) { b.0 }) == ["rest"]
  let assert Some(ir.IrBinOp(ir.IrAnd, _, ir.IrBlock(gp_block))) = c_gp.guard
  assert list.any(gp_block, fn(st) {
    case st {
      ir.IrStmtLet(ir.IrPatVar("byte"), ..) -> True
      _ -> False
    }
  })
  assert !list.any(gp_block, fn(st) {
    case st {
      ir.IrStmtLet(ir.IrPatVar("rest"), ..) -> True
      _ -> False
    }
  })

  // 4. <<len:8, _:bytes-size(len)>> -> True (body prefix_bindings completely pruned)
  let assert Ok(fn_bp) =
    list.find(ir_mod.functions, fn(f) { f.name == "body_pruning" })
  let assert [ir.IrStmtExpr(ir.IrMatch(clauses: [c_bp, _], ..))] = fn_bp.body
  assert c_bp.prefix_bindings == []
  assert c_bp.guard != None

  // 5. Verify MoonBit codegen strings
  let #(mbt, _) = moonbit.emit_module(ir_mod)
  assert string.contains(mbt, "(n : Int64, cp : Char, ba : @gprelude.BitArray)")
  assert string.contains(mbt, "{ bit_length: 0L, .. } => true")
  assert string.contains(mbt, "@gprelude.bit_array_read_int(")
  assert string.contains(mbt, "12L, true, false")
  assert string.contains(mbt, "@gprelude.bit_array_read_float(")
  assert string.contains(mbt, "16L, false")
  assert string.contains(mbt, "@gprelude.bit_array_match_bits(")
  assert string.contains(mbt, "@gprelude.bit_array_read_utf8_codepoint(")
  assert string.contains(mbt, "@gprelude.BitArray::int_segment(n, 16L, false)")
  assert string.contains(
    mbt,
    "@gprelude.BitArray::float_segment(1.5, 64L, true)",
  )
  assert string.contains(
    mbt,
    "@gprelude.BitArray::from_utf16((\"hi\" : StringView), false)",
  )
  assert string.contains(
    mbt,
    "@gprelude.BitArray::from_utf32((\"yo\" : StringView), true)",
  )
  assert string.contains(mbt, "@gprelude.BitArray::utf8_codepoint_segment(cp)")
  assert string.contains(
    mbt,
    "@gprelude.BitArray::utf16_codepoint_segment(cp, false)",
  )
  assert string.contains(
    mbt,
    "@gprelude.BitArray::utf32_codepoint_segment(cp, true)",
  )
  assert string.contains(mbt, "@gprelude.BitArray::bits_segment(ba, 4L)")
  assert string.contains(mbt, "@gprelude.BitArray::bits_segment(ba, (1L * 8L))")
  Nil
}

pub fn validate_int_literals_unit_test() {
  assert validate.parse_gleam_int_literal("0") == Ok(0)
  assert validate.parse_gleam_int_literal("9_223_372_036_854_775_807")
    == Ok(validate.int64_max)
  assert validate.parse_gleam_int_literal("-9_223_372_036_854_775_808")
    == Ok(validate.int64_min)
  assert validate.parse_gleam_int_literal("0x7fff_ffff_ffff_ffff")
    == Ok(validate.int64_max)
  assert validate.parse_gleam_int_literal("-0x8000_0000_0000_0000")
    == Ok(validate.int64_min)
  assert validate.parse_gleam_int_literal("0o777777777777777777777")
    == Ok(validate.int64_max)
  assert validate.parse_gleam_int_literal("-0o1000000000000000000000")
    == Ok(validate.int64_min)

  let ok_src =
    "pub const c_min = -9_223_372_036_854_775_808\n"
    <> "pub const c_max = 9_223_372_036_854_775_807\n"
    <> "pub fn boundaries(x: Int) -> Int {\n"
    <> "  let _ = 0\n"
    <> "  let _ = 9223372036854775807\n"
    <> "  let _ = 9_223_372_036_854_775_807\n"
    <> "  let _ = -9223372036854775808\n"
    <> "  let _ = -9_223_372_036_854_775_808\n"
    <> "  let _ = 0x7fff_ffff_ffff_ffff\n"
    <> "  let _ = -0x8000_0000_0000_0000\n"
    <> "  let _ = 0o777777777777777777777\n"
    <> "  let _ = -0o1000000000000000000000\n"
    <> "  let _ = 0b111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111\n"
    <> "  let _ = -0b1000000000000000000000000000000000000000000000000000000000000000\n"
    <> "  case x {\n"
    <> "    -9223372036854775808 -> -1\n"
    <> "    9223372036854775807 -> 1\n"
    <> "    _ -> 0\n"
    <> "  }\n"
    <> "}\n"

  let assert Ok(#(ok_ast, ok_pre)) = prepass.parse_module("ok_mod", ok_src)
  let ok_table =
    symbol_table.index_project(
      "ok_pkg",
      [#("ok_mod", ok_ast, ok_pre)],
      None,
      dict.new(),
    )
  assert validate.validate_module_int_literals(ok_ast, ok_table, "ok_mod")
    == Ok(Nil)

  let bad_src =
    "pub const too_big = 9_223_372_036_854_775_808\n"
    <> "pub fn bad_cases(x: Int, b: BitArray) -> Int {\n"
    <> "  let _ = 9223372036854775808\n"
    <> "  let _ = -9223372036854775809\n"
    <> "  let _ = 0x8000_0000_0000_0000\n"
    <> "  let _ = -0x8000_0000_0000_0001\n"
    <> "  let _ = 0o1000000000000000000000\n"
    <> "  let _ = 0b1000000000000000000000000000000000000000000000000000000000000000\n"
    <> "  let _ = <<9223372036854775808:size(64)>>\n"
    <> "  let _ = <<x:size(9223372036854775808)>>\n"
    <> "  let _ = case b {\n"
    <> "    <<9223372036854775808:size(8)>> -> 1\n"
    <> "    <<y:size(9223372036854775808)>> -> y\n"
    <> "    _ -> 0\n"
    <> "  }\n"
    <> "  case x {\n"
    <> "    9223372036854775808 -> 1\n"
    <> "    _ -> 0\n"
    <> "  }\n"
    <> "}\n"

  let assert Ok(#(bad_ast, bad_pre)) = prepass.parse_module("mod", bad_src)
  let bad_table =
    symbol_table.index_project(
      "app",
      [#("mod", bad_ast, bad_pre)],
      None,
      dict.new(),
    )
  let assert Error(err) =
    validate.validate_module_int_literals(bad_ast, bad_table, "mod")

  let expected_fragments = [
    "src/mod.gleam:1:21: Integer literal `9_223_372_036_854_775_808`",
    "src/mod.gleam:3:11: Integer literal `9223372036854775808`",
    "src/mod.gleam:4:11: Integer literal `-9223372036854775809`",
    "src/mod.gleam:5:11: Integer literal `0x8000_0000_0000_0000`",
    "src/mod.gleam:6:11: Integer literal `-0x8000_0000_0000_0001`",
    "src/mod.gleam:7:11: Integer literal `0o1000000000000000000000`",
    "src/mod.gleam:8:11: Integer literal `0b1000000000000000000000000000000000000000000000000000000000000000`",
    "src/mod.gleam:9:13: Integer literal `9223372036854775808`",
    "src/mod.gleam:10:20: Integer literal `9223372036854775808`",
    "src/mod.gleam:12:7: Integer literal `9223372036854775808`",
    "src/mod.gleam:13:14: Integer literal `9223372036854775808`",
    "src/mod.gleam:17:5: Integer literal `9223372036854775808`",
  ]
  list.each(expected_fragments, fn(frag) {
    assert string.contains(err, frag)
  })

  let skip_src =
    "@target(javascript)\n"
    <> "pub fn js_only() -> Int {\n"
    <> "  9223372036854775808\n"
    <> "}\n\n"
    <> "/// @external(moonbit, \"mbt_ffi\", \"ffi_fn\")\n"
    <> "pub fn ffi_fallback() -> Int {\n"
    <> "  9223372036854775808\n"
    <> "}\n"
  let assert Ok(#(skip_ast, skip_pre)) =
    prepass.parse_module("skip_mod", skip_src)
  let skip_table =
    symbol_table.index_project(
      "app",
      [#("skip_mod", skip_ast, skip_pre)],
      None,
      dict.new(),
    )
  assert validate.validate_module_int_literals(skip_ast, skip_table, "skip_mod")
    == Ok(Nil)
}

pub fn int_literal_range_diagnostic_e2e_test() {
  let root = "build/test_fixtures/int_lit_range"
  let out_dir = "build/test_fixtures/int_lit_range_mbt"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  assert simplifile.create_directory_all(filepath.join(root, "src")) == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"int_lit_range\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/int_lit_range.gleam"),
      contents: "pub fn huge() -> Int {\n  9_223_372_036_854_775_808\n}\n",
    )
    == Ok(Nil)

  let assert Error(err) = workspace.transpile_project(root, out_dir)
  assert string.contains(err, "src/int_lit_range.gleam:2:3")
  assert string.contains(err, "9_223_372_036_854_775_808")
  assert string.contains(err, "-9223372036854775808..9223372036854775807")
  assert simplifile.is_directory(out_dir) != Ok(True)

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn shorthand_fields_and_prelude_shadowing_test() {
  let dep_src = "pub const shared_name = \"alice\"\n"
  let main_src =
    "import dep.{shared_name}\n"
    <> "pub type User { User(name: String, age: Int) }\n"
    <> "pub type CustomErr { Error(String) Ok(Int) }\n"
    <> "pub fn make_user() -> User {\n"
    <> "  let u = User(name: \"bob\", age: 1)\n"
    <> "  let _ = User(name: shared_name, age: 2)\n"
    <> "  let _ = User(shared_name:, age: 3)\n"
    <> "  User(..u, shared_name:)\n"
    <> "}\n"
    <> "pub fn check_custom(e: CustomErr) -> String {\n"
    <> "  let x = Error(\"custom\")\n"
    <> "  case x, e {\n"
    <> "    Error(msg), Ok(_) -> msg\n"
    <> "    _, Error(msg) -> msg\n"
    <> "    _, _ -> \"\"\n"
    <> "  }\n"
    <> "}\n"

  let assert Ok(#(dep_ast, dep_pre)) = prepass.parse_module("dep", dep_src)
  let assert Ok(#(main_ast, main_pre)) = prepass.parse_module("main", main_src)
  let table =
    symbol_table.index_project(
      "app",
      [#("dep", dep_ast, dep_pre), #("main", main_ast, main_pre)],
      None,
      dict.new(),
    )
  let ir_mod = desugar.desugar_module(main_ast, table, "main")
  let #(mbt, _) = moonbit.emit_module_with_table(ir_mod, table)

  assert string.contains(mbt, "@dep.shared_name")
  assert string.contains(mbt, "Error((\"custom\" : StringView))")
  assert !string.contains(mbt, "Err((\"custom\" : StringView))")
}

pub fn tco_non_tail_let_and_synthetic_pattern_root_test() {
  let src =
    "pub fn sum_with_let(xs: List(Int), acc: Int) -> Int {\n"
    <> "  case xs {\n"
    <> "    [] -> {\n"
    <> "      let out = acc + 1\n"
    <> "    }\n"
    <> "    [x, ..rest] -> sum_with_let(rest, acc + x)\n"
    <> "  }\n"
    <> "}\n"

  let assert Ok(#(ast_mod, pre)) = prepass.parse_module("app", src)
  let table =
    symbol_table.index_project(
      "app",
      [#("app", ast_mod, pre)],
      None,
      dict.new(),
    )
  let ir_mod =
    desugar.desugar_module(ast_mod, table, "app")
    |> tco.optimize_module
  let #(mbt, _) = moonbit.emit_module_with_table(ir_mod, table)
  assert string.contains(mbt, "break out")

  let pat_ast =
    glance.PatternAssignment(
      location: glance.Span(0, 0),
      pattern: glance.PatternVariable(
        location: glance.Span(0, 0),
        name: "__user_var",
      ),
      name: "user_alias",
    )
  let lp = pattern.lower_pattern(pat_ast, table, "app", 0)
  assert lp.is_synthetic_root == False
  assert lp.prefix_bindings == []
  assert lp.pattern == ir.IrPatAs(ir.IrPatVar("__user_var"), "user_alias")
}

pub fn shadowed_private_external_fn_not_reachable_test() {
  let src =
    "@external(erlang, \"m\", \"dead\")\n"
    <> "fn dead() -> Int\n\n"
    <> "pub fn main_fn() -> Int {\n"
    <> "  let dead = 42\n"
    <> "  dead + 1\n"
    <> "}\n"
  let assert Ok(#(ast_mod, pre)) = prepass.parse_module("app", src)
  let table =
    symbol_table.index_project(
      "app",
      [#("app", ast_mod, pre)],
      None,
      dict.new(),
    )
  let assert Ok(ms) = dict.get(table.modules, "app")
  let reachable =
    symbol_table.reachable_private_functions(ast_mod, ms.functions)
  assert !set.contains(reachable, "dead")
  assert set.contains(reachable, "main_fn")
  assert validate.validate_module_int_literals(ast_mod, table, "app") == Ok(Nil)
}

pub fn type_alias_function_field_disables_derive_test() {
  let src =
    "pub type Handler = fn(Int) -> Int\n"
    <> "pub type Box {\n"
    <> "  Box(cb: Handler)\n"
    <> "}\n"
  let assert Ok(#(ast_mod, pre)) = prepass.parse_module("app", src)
  let table =
    symbol_table.index_project(
      "app",
      [#("app", ast_mod, pre)],
      None,
      dict.new(),
    )
  let assert Ok(ms) = dict.get(table.modules, "app")
  let assert Ok(box_info) = dict.get(ms.types, "Box")
  assert box_info.has_function_field == True
  let ir_mod = desugar.desugar_module(ast_mod, table, "app")
  let assert [td] = ir_mod.types
  assert td.derive_eq_debug_hash == False
}

pub fn pipe_into_local_closure_and_curried_closure_test() {
  let src =
    "pub fn test_pipes() -> Int {\n"
    <> "  let add = fn(a: Int, b: Int) -> Int { a + b }\n"
    <> "  let curried = fn(a: Int) { fn(b: Int) { a + b } }\n"
    <> "  let r1 = 10 |> add(5)\n"
    <> "  let r2 = 10 |> curried(5)\n"
    <> "  r1 + r2\n"
    <> "}\n"
  let assert Ok(#(ast_mod, pre)) = prepass.parse_module("app", src)
  let table =
    symbol_table.index_project(
      "app",
      [#("app", ast_mod, pre)],
      None,
      dict.new(),
    )
  let ir_mod = desugar.desugar_module(ast_mod, table, "app")
  let #(mbt, _) = moonbit.emit_module_with_table(ir_mod, table)
  assert string.contains(mbt, "add(10L, 5L)")
  assert string.contains(mbt, "curried(5L)(10L)")
}

pub fn workspace_module_pkg_dir_collision_test() {
  let root = "build/test_fixtures/pkg_dir_collision"
  let out_dir = "build/test_fixtures/pkg_dir_collision_mbt"
  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)

  assert simplifile.create_directory_all(filepath.join(root, "src/foo"))
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "gleam.toml"),
      contents: "name = \"pkg_dir_collision\"\nversion = \"0.1.0\"\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/foo/bar.gleam"),
      contents: "pub fn a() -> Int { 1 }\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/foo_bar.gleam"),
      contents: "pub fn b() -> Int { 2 }\n",
    )
    == Ok(Nil)
  assert simplifile.write(
      to: filepath.join(root, "src/pkg_dir_collision.gleam"),
      contents: "import foo/bar\nimport foo_bar\npub fn total() -> Int { bar.a() + foo_bar.b() }\n",
    )
    == Ok(Nil)

  let assert Ok(summary) = workspace.transpile_project(root, out_dir)
  let assert Ok(dir_nested) = dict.get(summary.module_pkg_dirs, "foo/bar")
  let assert Ok(dir_flat) = dict.get(summary.module_pkg_dirs, "foo_bar")
  assert dir_flat == "foo_bar"
  assert dir_nested != dir_flat
  let check_res =
    cmd.run(command: "moon", args: ["check", "--target", "wasm"], cwd: out_dir)
  assert check_res.exit_code == 0

  let _ = simplifile.delete(file_or_dir_at: root)
  let _ = simplifile.delete(file_or_dir_at: out_dir)
  Nil
}

pub fn ir_util_traversal_combinators_test() {
  let ty =
    ir.IrTypeFn(
      [ir.IrTypeList(ir.IrTypeVar("a"))],
      ir.IrTypeResult(ir.IrTypeTuple([ir.IrTypeVar("b")]), ir.IrTypeString),
    )
  let collected_vars =
    ir_util.fold_type(ty, [], fn(acc, t) {
      case t {
        ir.IrTypeVar(v) -> [v, ..acc]
        _ -> acc
      }
    })
  assert collected_vars == ["b", "a"]

  let mapped_ty =
    ir_util.map_type_children(
      ir.IrTypeNamed(
        module_alias: None,
        package: "p",
        module: "m",
        name: "Box",
        args: [ir.IrTypeVar("a")],
      ),
      fn(t) {
        case t {
          ir.IrTypeVar("a") -> ir.IrTypeInt64
          _ -> t
        }
      },
    )
  assert mapped_ty
    == ir.IrTypeNamed(
      module_alias: None,
      package: "p",
      module: "m",
      name: "Box",
      args: [ir.IrTypeInt64],
    )

  let sample_stmt =
    ir.IrStmtLet(
      pattern: ir.IrPatBitString([
        #(ir.IrPatVar("x"), [
          glance.SizeValueOption(ir.IrBitSizeVar("sz_var")),
        ]),
      ]),
      annotation: Some(ir.IrTypeList(ir.IrTypeVar("elem"))),
      value: ir.IrFn(
        params: [ir.IrFnParam("p", Some(ir.IrTypeVar("p_ty")))],
        return_type: Some(ir.IrTypeBool),
        body: [
          ir.IrStmtExpr(
            ir.IrMatch(subjects: [ir.IrVar("p")], clauses: [
              ir.IrClause(
                patterns: [[ir.IrPatAs(ir.IrPatVar("y"), "alias_y")]],
                guard: Some(ir.IrBool(True)),
                prefix_bindings: [#("pre", ir.IrInt("1"))],
                body: ir.IrBitString([
                  #(ir.IrVar("y"), [glance.SizeValueOption(ir.IrVar("sz_expr"))]),
                ]),
              ),
            ]),
          ),
        ],
      ),
    )

  let visitor =
    ir_util.IrVisitor(
      ..ir_util.default_visitor(),
      on_expr: fn(acc, e) {
        case e {
          ir.IrVar(v) -> Ok(["expr:" <> v, ..acc])
          _ -> Ok(acc)
        }
      },
      on_pattern: fn(acc, p) {
        case p {
          ir.IrPatVar(v) -> Ok(["pat:" <> v, ..acc])
          _ -> Ok(acc)
        }
      },
      on_type: fn(acc, t) {
        case t {
          ir.IrTypeVar(v) -> Ok(["ty:" <> v, ..acc])
          _ -> Ok(acc)
        }
      },
      on_bit_size: fn(acc, sz) {
        case sz {
          ir.IrBitSizeVar(v) -> Ok(["sz:" <> v, ..acc])
          _ -> Ok(acc)
        }
      },
    )
  let visited = ir_util.fold_stmts([sample_stmt], [], visitor)
  assert list.contains(visited, "pat:x")
  assert list.contains(visited, "sz:sz_var")
  assert list.contains(visited, "ty:elem")
  assert list.contains(visited, "ty:p_ty")
  assert list.contains(visited, "expr:p")
  assert list.contains(visited, "pat:y")
  assert list.contains(visited, "expr:y")
  assert list.contains(visited, "expr:sz_expr")

  let short_circuit =
    ir_util.try_fold_stmts(
      [sample_stmt],
      Nil,
      ir_util.IrVisitor(..ir_util.default_visitor(), on_expr: fn(_, e) {
        case e {
          ir.IrVar("sz_expr") -> Error("found")
          _ -> Ok(Nil)
        }
      }),
    )
  assert short_circuit == Error("found")

  let direct =
    ir_util.fold_expr_direct_children(
      ir.IrBinOp(op: ir.IrAddInt, left: ir.IrInt("1"), right: ir.IrInt("2")),
      0,
      fn(acc, _) { acc + 1 },
    )
  assert direct == 2
}
