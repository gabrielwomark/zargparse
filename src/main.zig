//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.
const std = @import("std");
const StructField = std.builtin.Type.StructField;

const SampleArgs = struct {
    example: u8,
    optional_example: ?[]const u8 = null,
    foo: u8,

    pub fn init() SampleArgs {
        return SampleArgs{ .example = undefined, .foo = undefined };
    }
};

const CliError = error{
    ConfigNoInit,
    ConfigInitHasArgs,
    ConfigInitNoReturnConfig,
    RequiredArgMissingValue,
    ConfigTypeUnsupported,
};

const ParsedArg = struct { arg_name: []const u8, arg_value: ?[]const u8 };

fn str_eql(this: []const u8, other: []const u8) bool {
    return std.mem.eql(u8, this, other);
}

fn parse_arg(args: *std.process.ArgIterator) ?ParsedArg {
    var parsed_arg = ParsedArg{ .arg_name = undefined, .arg_value = undefined };
    const maybe_arg = args.next();
    if (maybe_arg == null) {
        return null;
    }
    const arg = maybe_arg.?;
    if (!str_eql(arg[0..2], "--")) {
        return null;
    }

    var split = std.mem.splitSequence(u8, arg, "=");
    parsed_arg.arg_name = split.next().?[2..];

    const after_equal_sign = split.next();
    if (after_equal_sign != null) {
        parsed_arg.arg_value = after_equal_sign;
        return parsed_arg;
    }

    parsed_arg.arg_value = args.next();
    return parsed_arg;
}

inline fn ArgParser(comptime T: type) !type {
    if (!@hasDecl(T, "init")) {
        return CliError.ConfigNoInit;
    }

    const func_info = @typeInfo(@TypeOf(@field(T, "init"))).@"fn";
    if (func_info.params.len > 0) {
        return CliError.ConfigInitHasArgs;
    }

    if (func_info.return_type != T) {
        return CliError.ConfigInitNoReturnConfig;
    }
    return struct {
        config: T = T.init(),

        pub inline fn fields(self: @This()) []const StructField {
            return @typeInfo(@TypeOf(self.config)).@"struct".fields;
        }

        fn assign_int_value(self: *@This(), field: StructField, field_type: type, arg_value: []const u8) !void {
            const signedness = @typeInfo(field_type).int.signedness;
            const parsed_value = switch (signedness) {
                .signed => try std.fmt.parseInt(field_type, arg_value, 10),
                .unsigned => try std.fmt.parseUnsigned(field_type, arg_value, 10),
            };
            @field(self.config, field.name) = parsed_value;
        }

        fn assign_float_value(self: *@This(), field: StructField, field_type: type, arg_value: []const u8) !void {
            const parsed_value = try std.fmt.parseFloat(field_type, arg_value);
            @field(self.config, field.name) = parsed_value;
        }

        fn assign_string_value(self: *@This(), field: StructField, field_type: type, arg_value: []const u8) !void {
            const field_info = @typeInfo(field_type);
            const child_type = field_info.pointer.child;

            if (!(child_type == u8) or !field_info.pointer.is_const) {
                return CliError.ConfigTypeUnsupported;
            }
            @field(self.config, field.name) = arg_value;
        }

        fn assign_field_value(self: *@This(), field: StructField, parsed_arg: ParsedArg) !void {
            // we found the arg for this field but no value
            // since the field is optional we can just leave the loop
            comptime var field_info = @typeInfo(field.type);
            comptime var field_type = field.type;

            if (field_info == .optional) {
                if (parsed_arg.arg_value == null) {
                    return;
                }

                // stupid shit to make sure we can use a single
                // switch statement even for optional types
                field_type = field_info.optional.child;
                field_info = @typeInfo(field_info.optional.child);
            }

            if (parsed_arg.arg_value == null) {
                return CliError.RequiredArgMissingValue;
            }

            const arg_value = parsed_arg.arg_value.?;
            switch (field_info) {
                .int => {
                    try self.assign_int_value(field, field_type, arg_value);
                },
                .bool => {
                    @field(self.config, field.name) = true;
                },
                .float => {
                    try self.assign_float_value(field, field_type, arg_value);
                },
                .pointer => {
                    try self.assign_string_value(field, field_type, arg_value);
                },
                else => {
                    return CliError.ConfigTypeUnsupported;
                },
            }
        }

        fn process_parsed_args(self: *@This(), parsed_arg: ParsedArg) !void {
            inline for (self.fields()) |field| {
                // hate how deep we're nesting here but for some reason
                // the compiler won't let me early-continue on the complement
                // of this condition
                if (str_eql(field.name, parsed_arg.arg_name)) {
                    try self.assign_field_value(field, parsed_arg);
                    break;
                }
            }
        }

        pub fn parse_args(self: *@This(), allocator: std.mem.Allocator) !T {
            var args = try std.process.argsWithAllocator(allocator);
            defer args.deinit();

            // skip first arg
            _ = args.next();

            while (true) {
                const maybe_parsed_arg = parse_arg(&args);
                if (maybe_parsed_arg == null) {
                    break;
                }
                const parsed_arg = maybe_parsed_arg.?;
                try self.process_parsed_args(parsed_arg);
            }
            return self.config;
        }
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const parser = try ArgParser(SampleArgs);
    var ps = parser{};
    const config = try ps.parse_args(allocator);
    std.debug.print("{?}\n", .{config});
    std.debug.print("{s}\n", .{config.optional_example.?});
}
