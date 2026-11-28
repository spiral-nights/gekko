import glance
import gleam/option.{type Option}
import project/prepass.{type ExternalType, type FfiKind}

/// Lowered MoonBit-ready representation of a single Gleam module.
pub type IrModule {
  IrModule(
    module_name: String,
    package_name: String,
    imports: List(IrImport),
    types: List(IrTypeDef),
    type_aliases: List(IrTypeAlias),
    getters: List(IrGetter),
    constants: List(IrConstant),
    functions: List(IrFunction),
  )
}

/// Module dependency imported by this module.
pub type IrImport {
  IrImport(module: String, alias: Option(String))
}

/// Lowered custom type emitted uniformly as a MoonBit `pub(all) enum`.
pub type IrTypeDef {
  IrTypeDef(
    name: String,
    unmangled_name: String,
    publicity: glance.Publicity,
    opaque_: Bool,
    type_params: List(String),
    variants: List(IrVariant),
    external_type: Option(ExternalType),
    derive_eq_debug_hash: Bool,
  )
}

/// A variant of an `IrTypeDef` enum.
pub type IrVariant {
  IrVariant(name: String, fields: List(IrVariantField))
}

/// A field of an `IrVariant`.
pub type IrVariantField {
  IrVariantField(
    label: Option(String),
    unmangled_label: Option(String),
    field_type: IrType,
  )
}

/// Lowered type alias.
pub type IrTypeAlias {
  IrTypeAlias(
    name: String,
    publicity: glance.Publicity,
    type_params: List(String),
    aliased: IrType,
  )
}

/// Synthesized uniform field getter method: `pub fn Type::field(self : Type) -> T`.
pub type IrGetter {
  IrGetter(
    type_name: String,
    type_params: List(String),
    publicity: glance.Publicity,
    field_name: String,
    return_type: IrType,
    /// Variant name and number of leading unlabelled fields (each needs a
    /// `_` placeholder in the MoonBit pattern).
    variants: List(#(String, Int)),
  )
}

/// Lowered module constant.
pub type IrConstant {
  IrConstant(
    name: String,
    unmangled_name: String,
    publicity: glance.Publicity,
    value_type: IrType,
    value: IrExpr,
  )
}

/// Lowered top-level function.
pub type IrFunction {
  IrFunction(
    name: String,
    unmangled_name: String,
    publicity: glance.Publicity,
    type_params: List(String),
    params: List(IrParam),
    return_type: IrType,
    ffi: Option(FfiKind),
    external: Bool,
    body: List(IrStmt),
  )
}

/// Function parameter in `IrFunction`.
pub type IrParam {
  IrParam(label: Option(String), name: String, param_type: IrType)
}

/// Anonymous function parameter in `IrFn`.
pub type IrFnParam {
  IrFnParam(name: String, param_type: Option(IrType))
}

/// Call argument with optional MoonBit label.
pub type IrCallArg {
  IrCallArg(label: Option(String), value: IrExpr)
}

/// Pattern argument inside a variant pattern.
pub type IrPatArg {
  IrPatArg(label: Option(String), pattern: IrPattern)
}

/// Reason for a runtime abort.
pub type IrAbortKind {
  LetAssertAbort
  AssertAbort
  PanicAbort
  TodoAbort
}

/// Lowered statement inside a block or function body.
pub type IrStmt {
  IrStmtLet(pattern: IrPattern, annotation: Option(IrType), value: IrExpr)
  IrStmtGuard(
    value: IrExpr,
    pattern: IrPattern,
    guard_condition: Option(IrExpr),
    abort_message: Option(IrExpr),
    post_bindings: List(#(String, IrExpr)),
  )
  IrStmtAssert(condition: IrExpr, abort_message: Option(IrExpr))
  IrStmtExpr(IrExpr)
}

/// Lowered expression (with `use`, `|>`, captures, and record updates lowered).
pub type IrExpr {
  IrInt(String)
  IrFloat(String)
  IrString(String)
  IrBool(Bool)
  IrUnit
  IrVar(String)
  IrModuleRef(
    module_alias: Option(String),
    target_module: String,
    symbol: String,
  )
  IrConstructor(
    module_alias: Option(String),
    target_module: Option(String),
    name: String,
  )
  IrTuple(List(IrExpr))
  IrTupleIndex(tuple: IrExpr, index: Int)
  IrList(elements: List(IrExpr), tail: Option(IrExpr))
  IrBitString(
    segments: List(#(IrExpr, List(glance.BitStringSegmentOption(IrExpr)))),
  )
  IrNegateInt(IrExpr)
  IrNegateBool(IrExpr)
  IrBinOp(op: IrBinOp, left: IrExpr, right: IrExpr)
  IrCall(function: IrExpr, args: List(IrCallArg))
  IrGetterCall(receiver: IrExpr, field: String)
  IrBlock(List(IrStmt))
  IrFn(params: List(IrFnParam), return_type: Option(IrType), body: List(IrStmt))
  IrMatch(subjects: List(IrExpr), clauses: List(IrClause))
  IrForLoop(bindings: List(#(String, IrExpr)), body: List(IrStmt))
  IrContinue(List(IrExpr))
  IrBreak(IrExpr)
  IrAbort(kind: IrAbortKind, message: Option(IrExpr))
  IrEcho(expr: IrExpr, message: Option(IrExpr), file_path: String, line: Int)
}

/// Lowered match arm.
pub type IrClause {
  IrClause(
    patterns: List(List(IrPattern)),
    guard: Option(IrExpr),
    prefix_bindings: List(#(String, IrExpr)),
    body: IrExpr,
  )
}

/// Lowered binary operators (`Pipe` is eliminated during desugaring).
pub type IrBinOp {
  IrAnd
  IrOr
  IrEq
  IrNotEq
  IrLtInt
  IrLtEqInt
  IrGtInt
  IrGtEqInt
  IrLtFloat
  IrLtEqFloat
  IrGtFloat
  IrGtEqFloat
  IrAddInt
  IrSubInt
  IrMultInt
  IrDivInt
  IrRemInt
  IrAddFloat
  IrSubFloat
  IrMultFloat
  IrDivFloat
  IrStringConcat
}

/// Lowered pattern inside `IrMatch`, `IrStmtLet`, and `IrStmtGuard`.
pub type IrPattern {
  IrPatInt(String)
  IrPatFloat(String)
  IrPatString(String)
  IrPatStringPrefix(prefix: String, rest: Option(String))
  IrPatBool(Bool)
  IrPatUnit
  IrPatDiscard
  IrPatVar(String)
  IrPatTuple(List(IrPattern))
  IrPatVariant(
    module_alias: Option(String),
    target_module: Option(String),
    constructor: String,
    args: List(IrPatArg),
    with_spread: Bool,
  )
  IrPatAs(pattern: IrPattern, alias: String)
  IrPatBitString(
    segments: List(#(IrPattern, List(glance.BitStringSegmentOption(IrBitSize)))),
  )
}

/// Lowered size expression inside a `BitArray` pattern segment.
pub type IrBitSize {
  IrBitSizeInt(String)
  IrBitSizeVar(String)
  IrBitSizeBinOp(
    op: glance.BitArraySizeOperator,
    left: IrBitSize,
    right: IrBitSize,
  )
}

/// Lowered MoonBit type expression.
pub type IrType {
  IrTypeInt64
  IrTypeDouble
  IrTypeString
  IrTypeBool
  IrTypeUnit
  IrTypeBitArray
  IrTypeList(IrType)
  IrTypeResult(ok: IrType, err: IrType)
  IrTypeTuple(List(IrType))
  IrTypeFn(params: List(IrType), return: IrType)
  IrTypeVar(String)
  IrTypeNamed(
    module_alias: Option(String),
    package: String,
    module: String,
    name: String,
    args: List(IrType),
  )
}
