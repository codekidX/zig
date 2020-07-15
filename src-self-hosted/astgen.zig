const std = @import("std");
const mem = std.mem;
const Value = @import("value.zig").Value;
const Type = @import("type.zig").Type;
const TypedValue = @import("TypedValue.zig");
const assert = std.debug.assert;
const zir = @import("zir.zig");
const Module = @import("Module.zig");
const ast = std.zig.ast;
const trace = @import("tracy.zig").trace;
const Scope = Module.Scope;
const InnerError = Module.InnerError;

pub fn expr(mod: *Module, scope: *Scope, ast_node: *ast.Node) InnerError!*zir.Inst {
    switch (ast_node.id) {
        .Identifier => return identifier(mod, scope, @fieldParentPtr(ast.Node.Identifier, "base", ast_node)),
        .Asm => return assembly(mod, scope, @fieldParentPtr(ast.Node.Asm, "base", ast_node)),
        .StringLiteral => return stringLiteral(mod, scope, @fieldParentPtr(ast.Node.StringLiteral, "base", ast_node)),
        .IntegerLiteral => return integerLiteral(mod, scope, @fieldParentPtr(ast.Node.IntegerLiteral, "base", ast_node)),
        .BuiltinCall => return builtinCall(mod, scope, @fieldParentPtr(ast.Node.BuiltinCall, "base", ast_node)),
        .Call => return callExpr(mod, scope, @fieldParentPtr(ast.Node.Call, "base", ast_node)),
        .Unreachable => return unreach(mod, scope, @fieldParentPtr(ast.Node.Unreachable, "base", ast_node)),
        .ControlFlowExpression => return controlFlowExpr(mod, scope, @fieldParentPtr(ast.Node.ControlFlowExpression, "base", ast_node)),
        .If => return ifExpr(mod, scope, @fieldParentPtr(ast.Node.If, "base", ast_node)),
        .InfixOp => return infixOp(mod, scope, @fieldParentPtr(ast.Node.InfixOp, "base", ast_node)),
        .BoolNot => return boolNot(mod, scope, @fieldParentPtr(ast.Node.BoolNot, "base", ast_node)),
        .VarDecl => return varDecl(mod, scope, @fieldParentPtr(ast.Node.VarDecl, "base", ast_node)),
        else => return mod.failNode(scope, ast_node, "TODO implement astgen.Expr for {}", .{@tagName(ast_node.id)}),
    }
}

pub fn blockExpr(mod: *Module, scope: *Scope, block_node: *ast.Node.Block) !void {
    const tracy = trace(@src());
    defer tracy.end();

    if (block_node.label) |label| {
        return mod.failTok(scope, label, "TODO implement labeled blocks", .{});
    }
    for (block_node.statements()) |statement| {
        _ = try expr(mod, scope, statement);
    }
}

fn varDecl(mod: *Module, scope: *Scope, node: *ast.Node.VarDecl) InnerError!*zir.Inst {
    return mod.failNode(scope, &node.base, "TODO implement var decls", .{});
}

fn boolNot(mod: *Module, scope: *Scope, node: *ast.Node.BoolNot) InnerError!*zir.Inst {
    const operand = try expr(mod, scope, node.rhs);
    const tree = scope.tree();
    const src = tree.token_locs[node.op_token].start;
    return mod.addZIRInst(scope, src, zir.Inst.BoolNot, .{ .operand = operand }, .{});
}

fn infixOp(mod: *Module, scope: *Scope, infix_node: *ast.Node.InfixOp) InnerError!*zir.Inst {
    switch (infix_node.op) {
        .Assign => {
            if (infix_node.lhs.id == .Identifier) {
                const ident = @fieldParentPtr(ast.Node.Identifier, "base", infix_node.lhs);
                const tree = scope.tree();
                const ident_name = tree.tokenSlice(ident.token);
                if (std.mem.eql(u8, ident_name, "_")) {
                    return expr(mod, scope, infix_node.rhs);
                } else {
                    return mod.failNode(scope, &infix_node.base, "TODO implement infix operator assign", .{});
                }
            } else {
                return mod.failNode(scope, &infix_node.base, "TODO implement infix operator assign", .{});
            }
        },
        .Add => {
            const lhs = try expr(mod, scope, infix_node.lhs);
            const rhs = try expr(mod, scope, infix_node.rhs);

            const tree = scope.tree();
            const src = tree.token_locs[infix_node.op_token].start;

            return mod.addZIRInst(scope, src, zir.Inst.Add, .{ .lhs = lhs, .rhs = rhs }, .{});
        },
        .BangEqual,
        .EqualEqual,
        .GreaterThan,
        .GreaterOrEqual,
        .LessThan,
        .LessOrEqual,
        => {
            const lhs = try expr(mod, scope, infix_node.lhs);
            const rhs = try expr(mod, scope, infix_node.rhs);

            const tree = scope.tree();
            const src = tree.token_locs[infix_node.op_token].start;

            const op: std.math.CompareOperator = switch (infix_node.op) {
                .BangEqual => .neq,
                .EqualEqual => .eq,
                .GreaterThan => .gt,
                .GreaterOrEqual => .gte,
                .LessThan => .lt,
                .LessOrEqual => .lte,
                else => unreachable,
            };

            return mod.addZIRInst(scope, src, zir.Inst.Cmp, .{
                .lhs = lhs,
                .op = op,
                .rhs = rhs,
            }, .{});
        },
        else => |op| {
            return mod.failNode(scope, &infix_node.base, "TODO implement infix operator {}", .{op});
        },
    }
}

fn ifExpr(mod: *Module, scope: *Scope, if_node: *ast.Node.If) InnerError!*zir.Inst {
    if (if_node.payload) |payload| {
        return mod.failNode(scope, payload, "TODO implement astgen.IfExpr for optionals", .{});
    }
    if (if_node.@"else") |else_node| {
        if (else_node.payload) |payload| {
            return mod.failNode(scope, payload, "TODO implement astgen.IfExpr for error unions", .{});
        }
    }
    var block_scope: Scope.GenZIR = .{
        .decl = scope.decl().?,
        .arena = scope.arena(),
        .instructions = .{},
    };
    defer block_scope.instructions.deinit(mod.gpa);

    const cond = try expr(mod, &block_scope.base, if_node.condition);

    const tree = scope.tree();
    const if_src = tree.token_locs[if_node.if_token].start;
    const condbr = try mod.addZIRInstSpecial(&block_scope.base, if_src, zir.Inst.CondBr, .{
        .condition = cond,
        .true_body = undefined, // populated below
        .false_body = undefined, // populated below
    }, .{});

    const block = try mod.addZIRInstBlock(scope, if_src, .{
        .instructions = try block_scope.arena.dupe(*zir.Inst, block_scope.instructions.items),
    });
    var then_scope: Scope.GenZIR = .{
        .decl = block_scope.decl,
        .arena = block_scope.arena,
        .instructions = .{},
    };
    defer then_scope.instructions.deinit(mod.gpa);

    const then_result = try expr(mod, &then_scope.base, if_node.body);
    if (!then_result.tag.isNoReturn()) {
        const then_src = tree.token_locs[if_node.body.lastToken()].start;
        _ = try mod.addZIRInst(&then_scope.base, then_src, zir.Inst.Break, .{
            .block = block,
            .operand = then_result,
        }, .{});
    }
    condbr.positionals.true_body = .{
        .instructions = try then_scope.arena.dupe(*zir.Inst, then_scope.instructions.items),
    };

    var else_scope: Scope.GenZIR = .{
        .decl = block_scope.decl,
        .arena = block_scope.arena,
        .instructions = .{},
    };
    defer else_scope.instructions.deinit(mod.gpa);

    if (if_node.@"else") |else_node| {
        const else_result = try expr(mod, &else_scope.base, else_node.body);
        if (!else_result.tag.isNoReturn()) {
            const else_src = tree.token_locs[else_node.body.lastToken()].start;
            _ = try mod.addZIRInst(&else_scope.base, else_src, zir.Inst.Break, .{
                .block = block,
                .operand = else_result,
            }, .{});
        }
    } else {
        // TODO Optimization opportunity: we can avoid an allocation and a memcpy here
        // by directly allocating the body for this one instruction.
        const else_src = tree.token_locs[if_node.lastToken()].start;
        _ = try mod.addZIRInst(&else_scope.base, else_src, zir.Inst.BreakVoid, .{
            .block = block,
        }, .{});
    }
    condbr.positionals.false_body = .{
        .instructions = try else_scope.arena.dupe(*zir.Inst, else_scope.instructions.items),
    };

    return &block.base;
}

fn controlFlowExpr(
    mod: *Module,
    scope: *Scope,
    cfe: *ast.Node.ControlFlowExpression,
) InnerError!*zir.Inst {
    switch (cfe.kind) {
        .Break => return mod.failNode(scope, &cfe.base, "TODO implement astgen.Expr for Break", .{}),
        .Continue => return mod.failNode(scope, &cfe.base, "TODO implement astgen.Expr for Continue", .{}),
        .Return => {},
    }
    const tree = scope.tree();
    const src = tree.token_locs[cfe.ltoken].start;
    if (cfe.rhs) |rhs_node| {
        const operand = try expr(mod, scope, rhs_node);
        return mod.addZIRInst(scope, src, zir.Inst.Return, .{ .operand = operand }, .{});
    } else {
        return mod.addZIRInst(scope, src, zir.Inst.ReturnVoid, .{}, .{});
    }
}

fn identifier(mod: *Module, scope: *Scope, ident: *ast.Node.Identifier) InnerError!*zir.Inst {
    const tree = scope.tree();
    const ident_name = tree.tokenSlice(ident.token);
    const src = tree.token_locs[ident.token].start;
    if (mem.eql(u8, ident_name, "_")) {
        return mod.failNode(scope, &ident.base, "TODO implement '_' identifier", .{});
    }

    if (getSimplePrimitiveValue(ident_name)) |typed_value| {
        return mod.addZIRInstConst(scope, src, typed_value);
    }

    if (ident_name.len >= 2) integer: {
        const first_c = ident_name[0];
        if (first_c == 'i' or first_c == 'u') {
            const is_signed = first_c == 'i';
            const bit_count = std.fmt.parseInt(u16, ident_name[1..], 10) catch |err| switch (err) {
                error.Overflow => return mod.failNode(
                    scope,
                    &ident.base,
                    "primitive integer type '{}' exceeds maximum bit width of 65535",
                    .{ident_name},
                ),
                error.InvalidCharacter => break :integer,
            };
            const val = switch (bit_count) {
                8 => if (is_signed) Value.initTag(.i8_type) else Value.initTag(.u8_type),
                16 => if (is_signed) Value.initTag(.i16_type) else Value.initTag(.u16_type),
                32 => if (is_signed) Value.initTag(.i32_type) else Value.initTag(.u32_type),
                64 => if (is_signed) Value.initTag(.i64_type) else Value.initTag(.u64_type),
                else => return mod.failNode(scope, &ident.base, "TODO implement arbitrary integer bitwidth types", .{}),
            };
            return mod.addZIRInstConst(scope, src, .{
                .ty = Type.initTag(.type),
                .val = val,
            });
        }
    }

    if (mod.lookupDeclName(scope, ident_name)) |decl| {
        return try mod.addZIRInst(scope, src, zir.Inst.DeclValInModule, .{ .decl = decl }, .{});
    }

    // Function parameter
    if (scope.decl()) |decl| {
        if (tree.root_node.decls()[decl.src_index].cast(ast.Node.FnProto)) |fn_proto| {
            for (fn_proto.params()) |param, i| {
                const param_name = tree.tokenSlice(param.name_token.?);
                if (mem.eql(u8, param_name, ident_name)) {
                    return try mod.addZIRInst(scope, src, zir.Inst.Arg, .{ .index = i }, .{});
                }
            }
        }
    }

    return mod.failNode(scope, &ident.base, "TODO implement local variable identifier lookup", .{});
}

fn stringLiteral(mod: *Module, scope: *Scope, str_lit: *ast.Node.StringLiteral) InnerError!*zir.Inst {
    const tree = scope.tree();
    const unparsed_bytes = tree.tokenSlice(str_lit.token);
    const arena = scope.arena();

    var bad_index: usize = undefined;
    const bytes = std.zig.parseStringLiteral(arena, unparsed_bytes, &bad_index) catch |err| switch (err) {
        error.InvalidCharacter => {
            const bad_byte = unparsed_bytes[bad_index];
            const src = tree.token_locs[str_lit.token].start;
            return mod.fail(scope, src + bad_index, "invalid string literal character: '{c}'\n", .{bad_byte});
        },
        else => |e| return e,
    };

    const src = tree.token_locs[str_lit.token].start;
    return mod.addZIRInst(scope, src, zir.Inst.Str, .{ .bytes = bytes }, .{});
}

fn integerLiteral(mod: *Module, scope: *Scope, int_lit: *ast.Node.IntegerLiteral) InnerError!*zir.Inst {
    const arena = scope.arena();
    const tree = scope.tree();
    const prefixed_bytes = tree.tokenSlice(int_lit.token);
    const base = if (mem.startsWith(u8, prefixed_bytes, "0x"))
        16
    else if (mem.startsWith(u8, prefixed_bytes, "0o"))
        8
    else if (mem.startsWith(u8, prefixed_bytes, "0b"))
        2
    else
        @as(u8, 10);

    const bytes = if (base == 10)
        prefixed_bytes
    else
        prefixed_bytes[2..];

    if (std.fmt.parseInt(u64, bytes, base)) |small_int| {
        const int_payload = try arena.create(Value.Payload.Int_u64);
        int_payload.* = .{ .int = small_int };
        const src = tree.token_locs[int_lit.token].start;
        return mod.addZIRInstConst(scope, src, .{
            .ty = Type.initTag(.comptime_int),
            .val = Value.initPayload(&int_payload.base),
        });
    } else |err| {
        return mod.failTok(scope, int_lit.token, "TODO implement int literals that don't fit in a u64", .{});
    }
}

fn assembly(mod: *Module, scope: *Scope, asm_node: *ast.Node.Asm) InnerError!*zir.Inst {
    if (asm_node.outputs.len != 0) {
        return mod.failNode(scope, &asm_node.base, "TODO implement asm with an output", .{});
    }
    const arena = scope.arena();
    const tree = scope.tree();

    const inputs = try arena.alloc(*zir.Inst, asm_node.inputs.len);
    const args = try arena.alloc(*zir.Inst, asm_node.inputs.len);

    for (asm_node.inputs) |input, i| {
        // TODO semantically analyze constraints
        inputs[i] = try expr(mod, scope, input.constraint);
        args[i] = try expr(mod, scope, input.expr);
    }

    const src = tree.token_locs[asm_node.asm_token].start;
    const return_type = try mod.addZIRInstConst(scope, src, .{
        .ty = Type.initTag(.type),
        .val = Value.initTag(.void_type),
    });
    const asm_inst = try mod.addZIRInst(scope, src, zir.Inst.Asm, .{
        .asm_source = try expr(mod, scope, asm_node.template),
        .return_type = return_type,
    }, .{
        .@"volatile" = asm_node.volatile_token != null,
        //.clobbers =  TODO handle clobbers
        .inputs = inputs,
        .args = args,
    });
    return asm_inst;
}

fn builtinCall(mod: *Module, scope: *Scope, call: *ast.Node.BuiltinCall) InnerError!*zir.Inst {
    const tree = scope.tree();
    const builtin_name = tree.tokenSlice(call.builtin_token);
    const src = tree.token_locs[call.builtin_token].start;

    inline for (std.meta.declarations(zir.Inst)) |inst| {
        if (inst.data != .Type) continue;
        const T = inst.data.Type;
        if (!@hasDecl(T, "builtin_name")) continue;
        if (std.mem.eql(u8, builtin_name, T.builtin_name)) {
            var value: T = undefined;
            const positionals = @typeInfo(std.meta.fieldInfo(T, "positionals").field_type).Struct;
            if (positionals.fields.len == 0) {
                return mod.addZIRInst(scope, src, T, value.positionals, value.kw_args);
            }
            const arg_count: ?usize = if (positionals.fields[0].field_type == []*zir.Inst) null else positionals.fields.len;
            if (arg_count) |some| {
                if (call.params_len != some) {
                    return mod.failTok(
                        scope,
                        call.builtin_token,
                        "expected {} parameter{}, found {}",
                        .{ some, if (some == 1) "" else "s", call.params_len },
                    );
                }
                const params = call.params();
                inline for (positionals.fields) |p, i| {
                    @field(value.positionals, p.name) = try expr(mod, scope, params[i]);
                }
            } else {
                return mod.failTok(scope, call.builtin_token, "TODO var args builtin '{}'", .{builtin_name});
            }

            return mod.addZIRInst(scope, src, T, value.positionals, .{});
        }
    }
    return mod.failTok(scope, call.builtin_token, "TODO implement builtin call for '{}'", .{builtin_name});
}

fn callExpr(mod: *Module, scope: *Scope, node: *ast.Node.Call) InnerError!*zir.Inst {
    const tree = scope.tree();
    const lhs = try expr(mod, scope, node.lhs);

    const param_nodes = node.params();
    const args = try scope.cast(Scope.GenZIR).?.arena.alloc(*zir.Inst, param_nodes.len);
    for (param_nodes) |param_node, i| {
        args[i] = try expr(mod, scope, param_node);
    }

    const src = tree.token_locs[node.lhs.firstToken()].start;
    return mod.addZIRInst(scope, src, zir.Inst.Call, .{
        .func = lhs,
        .args = args,
    }, .{});
}

fn unreach(mod: *Module, scope: *Scope, unreach_node: *ast.Node.Unreachable) InnerError!*zir.Inst {
    const tree = scope.tree();
    const src = tree.token_locs[unreach_node.token].start;
    return mod.addZIRInst(scope, src, zir.Inst.Unreachable, .{}, .{});
}

fn getSimplePrimitiveValue(name: []const u8) ?TypedValue {
    const simple_types = std.ComptimeStringMap(Value.Tag, .{
        .{ "u8", .u8_type },
        .{ "i8", .i8_type },
        .{ "isize", .isize_type },
        .{ "usize", .usize_type },
        .{ "c_short", .c_short_type },
        .{ "c_ushort", .c_ushort_type },
        .{ "c_int", .c_int_type },
        .{ "c_uint", .c_uint_type },
        .{ "c_long", .c_long_type },
        .{ "c_ulong", .c_ulong_type },
        .{ "c_longlong", .c_longlong_type },
        .{ "c_ulonglong", .c_ulonglong_type },
        .{ "c_longdouble", .c_longdouble_type },
        .{ "f16", .f16_type },
        .{ "f32", .f32_type },
        .{ "f64", .f64_type },
        .{ "f128", .f128_type },
        .{ "c_void", .c_void_type },
        .{ "bool", .bool_type },
        .{ "void", .void_type },
        .{ "type", .type_type },
        .{ "anyerror", .anyerror_type },
        .{ "comptime_int", .comptime_int_type },
        .{ "comptime_float", .comptime_float_type },
        .{ "noreturn", .noreturn_type },
    });
    if (simple_types.get(name)) |tag| {
        return TypedValue{
            .ty = Type.initTag(.type),
            .val = Value.initTag(tag),
        };
    }
    if (mem.eql(u8, name, "null")) {
        return TypedValue{
            .ty = Type.initTag(.@"null"),
            .val = Value.initTag(.null_value),
        };
    }
    if (mem.eql(u8, name, "undefined")) {
        return TypedValue{
            .ty = Type.initTag(.@"undefined"),
            .val = Value.initTag(.undef),
        };
    }
    if (mem.eql(u8, name, "true")) {
        return TypedValue{
            .ty = Type.initTag(.bool),
            .val = Value.initTag(.bool_true),
        };
    }
    if (mem.eql(u8, name, "false")) {
        return TypedValue{
            .ty = Type.initTag(.bool),
            .val = Value.initTag(.bool_false),
        };
    }
    return null;
}
