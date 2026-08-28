const std = @import("std");
const types = @import("types.zig");
const model = @import("model.zig");
const options = @import("options.zig");
const schema = @import("schema.zig");
const log = std.log.scoped(.sdk_generate);

const Message = types.Message;
const GenerateOptions = options.GenerateOptions;

fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}

pub fn complete(
    alloc: std.mem.Allocator,
    io: std.Io,
    chat: model.LanguageModel,
    opts: GenerateOptions,
) !types.TextResult {
    return run(alloc, io, chat, opts, null);
}

pub fn streamText(
    alloc: std.mem.Allocator,
    io: std.Io,
    chat: model.LanguageModel,
    opts: GenerateOptions,
) !types.TextResult {
    var sctx = model.StreamContext{
        .emit = streamEmit,
        .emit_ctx = @ptrCast(@constCast(&opts)),
    };
    const result = try run(alloc, io, chat, opts, &sctx);
    if (opts.stream.on_finish) |f| f(opts.stream.on_finish_ctx, &result);
    return result;
}

fn streamEmit(ctx: ?*anyopaque, chunk: types.StreamChunk) void {
    const opts: *const GenerateOptions = @ptrCast(@alignCast(ctx.?));
    const cb = &opts.stream;
    switch (chunk.type) {
        .text => if (cb.on_text) |f| f(cb.on_text_ctx, chunk.text),
        .reasoning => if (cb.on_reasoning) |f| f(cb.on_reasoning_ctx, chunk.text),
        .tool_call, .tool_call_delta, .tool_call_streaming_start, .tool_result => if (cb.on_tool_call) |f| f(cb.on_tool_call_ctx, chunk),
        .step_finish => if (cb.on_step_finish) |f| {
            const step = options.StepInfo{
                .number = chunk.number,
                .text = chunk.text,
                .finish_reason = chunk.finish_reason orelse .other,
                .usage = chunk.usage orelse .{},
            };
            f(cb.on_step_finish_ctx, step);
        },
        .err => if (cb.on_error) |f| f(cb.on_error_ctx, chunk.err orelse error.Unknown),
        .finish => {},
    }
}

fn run(
    alloc: std.mem.Allocator,
    io: std.Io,
    chat: model.LanguageModel,
    opts_in: GenerateOptions,
    sctx: ?*model.StreamContext,
) !types.TextResult {
    var opts = opts_in;
    var history: std.ArrayList(Message) = .empty;
    errdefer {
        for (history.items) |msg| types.freeMessage(alloc, msg);
        history.deinit(alloc);
    }

    try appendOwnedMessages(alloc, &history, opts.messages);
    if (opts.prompt.len > 0) {
        try history.append(alloc, .{
            .role = .user,
            .single = types.Part.textPart(try alloc.dupe(u8, opts.prompt)),
        });
    }

    var steps: std.ArrayList(types.StepResult) = .empty;
    errdefer {
        for (steps.items) |step| step.deinit(alloc);
        steps.deinit(alloc);
    }

    var total_usage = types.Usage{};
    var finish: types.FinishReason = .stop;
    var exhausted = false;
    var step_no: usize = 0;

    while (step_no < opts.max_steps) {
        step_no += 1;

        if (opts.cancellation) |token| try token.check();

        if (opts.hooks.on_prepare_step) |f| {
            const prepared = try f(opts.hooks.on_prepare_step_ctx, .{
                .number = step_no,
                .messages = history.items,
            });
            if (prepared.replace) {
                var replacement: std.ArrayList(Message) = .empty;
                errdefer {
                    for (replacement.items) |msg| types.freeMessage(alloc, msg);
                    replacement.deinit(alloc);
                }
                try appendOwnedMessages(alloc, &replacement, prepared.messages);
                for (history.items) |msg| types.freeMessage(alloc, msg);
                history.deinit(alloc);
                history = replacement;
            } else {
                try appendOwnedMessages(alloc, &history, prepared.messages);
            }
            if (prepared.tools) |fresh| opts.tools = fresh;
        }

        if (opts.hooks.on_reminder) |f| {
            if (f(opts.hooks.on_reminder_ctx, .{ .step = step_no, .message_count = history.items.len })) |text| {
                const owned = try alloc.dupe(u8, text);
                errdefer alloc.free(owned);
                try history.append(alloc, .{
                    .role = .user,
                    .single = types.Part.textPart(owned),
                });
            }
        }

        if (opts.hooks.on_checkpoint) |f| f(opts.hooks.on_checkpoint_ctx, history.items);

        if (opts.hooks.on_request) |f| {
            f(opts.hooks.on_request_ctx, .{
                .model = chat.modelId(),
                .message_count = history.items.len,
                .tool_count = opts.tools.len,
                .messages = history.items,
            });
        }

        const params = model.GenerateParams{
            .messages = history.items,
            .system = opts.system,
            .tools = opts.tools,
            .max_output_tokens = opts.max_output_tokens,
            .temperature = opts.temperature,
            .top_p = opts.top_p,
            .top_k = opts.top_k,
            .frequency_penalty = opts.frequency_penalty,
            .presence_penalty = opts.presence_penalty,
            .seed = opts.seed,
            .stop_sequences = opts.stop_sequences,
            .headers = opts.headers,
            .provider_options = opts.provider_options,
            .prompt_caching = opts.prompt_caching,
            .cache_ttl = opts.cache_ttl,
            .tool_choice = opts.tool_choice,
            .response_format = if (opts.explicit_schema) |value| .{
                .name = opts.schema_name,
                .schema = value,
            } else null,
            .timeout_ms = opts.timeout_ms,
            .cancellation = opts.cancellation,
            .on_provider_error = opts.hooks.on_provider_error,
            .on_provider_error_ctx = opts.hooks.on_provider_error_ctx,
        };

        const started = nowMs(io);
        const gen_result = if (sctx) |sc|
            chat.stream(alloc, io, params, opts.client, opts.max_retries, sc)
        else
            chat.generate(alloc, io, params, opts.client, opts.max_retries);
        var result = gen_result catch |err| {
            if (opts.hooks.on_response) |f| {
                f(opts.hooks.on_response_ctx, .{ .latency_ms = @intCast(nowMs(io) - started), .err = err });
            }
            if (opts.stream.on_error) |f| f(opts.stream.on_error_ctx, err);
            return err;
        };
        errdefer {
            result.deinit(alloc);
            alloc.destroy(result);
        }

        if (opts.hooks.on_response) |f| {
            f(opts.hooks.on_response_ctx, .{
                .latency_ms = @intCast(nowMs(io) - started),
                .usage = result.usage,
                .finish_reason = result.finish_reason,
            });
        }

        total_usage.add(result.usage);
        finish = result.finish_reason;

        {
            const assistant_message = Message{
                .role = .assistant,
                .content = try assistantParts(alloc, result),
            };
            errdefer types.freeMessage(alloc, assistant_message);
            try history.append(alloc, assistant_message);
        }
        const assistant_msg = history.items[history.items.len - 1];

        const has_tools = result.tool_calls.len > 0;
        if (!has_tools and result.finish_reason == .tool_calls) {
            log.err("provider finished with tool_calls but returned no valid tool calls at step {d}; ending agent loop", .{step_no});
        }
        const execute_tools = has_tools and step_no < opts.max_steps;
        if (has_tools and !execute_tools) exhausted = true;
        const tool_results: []types.ToolResult = if (execute_tools)
            try executeTools(alloc, io, opts, result.tool_calls, step_no)
        else
            &.{};
        defer if (execute_tools) {
            freeToolResults(alloc, tool_results);
            alloc.free(tool_results);
        };
        if (execute_tools) {
            try appendToolMessages(alloc, &history, tool_results);
        }

        var should_stop = false;
        for (tool_results) |tool_result| {
            if (tool_result.exit_loop) should_stop = true;
        }
        if (!should_stop) should_stop = if (opts.hooks.stop_when) |f|
            f(opts.hooks.stop_when_ctx, .{
                .step = step_no,
                .messages = history.items,
                .tool_results = tool_results,
            })
        else
            false;

        if (opts.hooks.on_step_finish) |f| {
            f(opts.hooks.on_step_finish_ctx, .{
                .number = step_no,
                .text = result.text,
                .tool_calls = result.tool_calls,
                .tool_results = tool_results,
                .finish_reason = result.finish_reason,
                .usage = result.usage,
            });
        }

        if (sctx) |sc| {
            sc.send(.{
                .type = .step_finish,
                .number = step_no,
                .text = result.text,
                .finish_reason = result.finish_reason,
                .usage = result.usage,
            });
        }

        try steps.append(alloc, try makeStepResult(
            alloc,
            step_no,
            assistant_msg,
            tool_results,
            result,
        ));

        result.deinit(alloc);
        alloc.destroy(result);
        if (!execute_tools or should_stop) break;
    }

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    var reasoning: std.ArrayList(u8) = .empty;
    errdefer reasoning.deinit(alloc);

    for (steps.items) |*step| {
        try text.appendSlice(alloc, step.text);
        if (step.reasoning.len > 0) try reasoning.appendSlice(alloc, step.reasoning);
    }

    const last_step_calls = if (steps.items.len > 0)
        steps.items[steps.items.len - 1].tool_calls
    else
        &.{};
    const final_tool_calls = try alloc.alloc(types.ToolCall, last_step_calls.len);
    errdefer alloc.free(final_tool_calls);
    @memcpy(final_tool_calls, last_step_calls);

    const final_text = try text.toOwnedSlice(alloc);
    errdefer alloc.free(final_text);
    const final_reasoning = try reasoning.toOwnedSlice(alloc);
    errdefer alloc.free(final_reasoning);
    const final_steps_slice = try steps.toOwnedSlice(alloc);
    errdefer {
        for (final_steps_slice) |step| step.deinit(alloc);
        alloc.free(final_steps_slice);
    }

    const last_response = if (final_steps_slice.len > 0)
        final_steps_slice[final_steps_slice.len - 1].response
    else
        types.ResponseMetadata{};
    const resp_id = try alloc.dupe(u8, last_response.id);
    errdefer alloc.free(resp_id);
    const resp_model = try alloc.dupe(u8, last_response.model);

    const messages = try history.toOwnedSlice(alloc);
    errdefer {
        for (messages) |msg| types.freeMessage(alloc, msg);
        alloc.free(messages);
    }

    return .{
        .text = final_text,
        .reasoning = final_reasoning,
        .tool_calls = final_tool_calls,
        .steps = final_steps_slice,
        .total_usage = total_usage,
        .finish_reason = finish,
        .response = .{ .id = resp_id, .model = resp_model },
        .steps_exhausted = exhausted,
        .messages = messages,
    };
}

fn clonePart(alloc: std.mem.Allocator, value: types.Part) !types.Part {
    return switch (value) {
        .text => |text| types.Part.textPart(try alloc.dupe(u8, text)),
        .reasoning => |reasoning| blk: {
            const text = try alloc.dupe(u8, reasoning.text);
            errdefer alloc.free(text);
            break :blk types.Part.reasoningPart(text, try alloc.dupe(u8, reasoning.signature));
        },
        .image => |image| blk: {
            const url = try alloc.dupe(u8, image.url);
            errdefer alloc.free(url);
            const media_type = try alloc.dupe(u8, image.media_type);
            errdefer alloc.free(media_type);
            break :blk .{ .image = .{
                .url = url,
                .media_type = media_type,
                .detail = try alloc.dupe(u8, image.detail),
            } };
        },
        .tool_call => |call| blk: {
            const id = try alloc.dupe(u8, call.id);
            errdefer alloc.free(id);
            const name = try alloc.dupe(u8, call.name);
            errdefer alloc.free(name);
            break :blk types.Part.toolCallPart(id, name, try alloc.dupe(u8, call.input));
        },
        .tool_result => |result| blk: {
            const id = try alloc.dupe(u8, result.id);
            errdefer alloc.free(id);
            const name = try alloc.dupe(u8, result.name);
            errdefer alloc.free(name);
            break :blk .{ .tool_result = .{
                .id = id,
                .name = name,
                .output = try alloc.dupe(u8, result.output),
                .is_error = result.is_error,
                .exit_loop = result.exit_loop,
            } };
        },
        .file => |file| blk: {
            const url = try alloc.dupe(u8, file.url);
            errdefer alloc.free(url);
            const media_type = try alloc.dupe(u8, file.media_type);
            errdefer alloc.free(media_type);
            break :blk types.Part.filePart(url, media_type, try alloc.dupe(u8, file.filename));
        },
        .provider_data => |data| blk: {
            const provider = try alloc.dupe(u8, data.provider);
            errdefer alloc.free(provider);
            break :blk types.Part.providerDataPart(provider, try alloc.dupe(u8, data.data));
        },
    };
}

fn appendOwnedMessages(alloc: std.mem.Allocator, history: *std.ArrayList(Message), messages: []const Message) !void {
    for (messages) |msg| {
        if (msg.role == .system) continue;
        const parts = msg.parts();
        const owned = try alloc.alloc(types.Part, parts.len);
        errdefer alloc.free(owned);
        var cloned: usize = 0;
        errdefer for (owned[0..cloned]) |part| types.freePart(alloc, part);
        for (parts, 0..) |part, i| {
            owned[i] = try clonePart(alloc, part);
            cloned = i + 1;
        }
        try history.append(alloc, .{ .role = msg.role, .content = owned });
    }
}

fn assistantParts(alloc: std.mem.Allocator, result: *const model.GenerateResult) ![]const types.Part {
    var parts: std.ArrayList(types.Part) = .empty;
    errdefer {
        for (parts.items) |part| types.freePart(alloc, part);
        parts.deinit(alloc);
    }
    if (result.text.len > 0) {
        const text = try alloc.dupe(u8, result.text);
        errdefer alloc.free(text);
        try parts.append(alloc, types.Part.textPart(text));
    }
    if (result.reasoning.len > 0) {
        const text = try alloc.dupe(u8, result.reasoning);
        errdefer alloc.free(text);
        const signature = try alloc.dupe(u8, result.reasoning_signature);
        errdefer alloc.free(signature);
        try parts.append(alloc, types.Part.reasoningPart(text, signature));
    }
    for (result.tool_calls) |tc| {
        const id = try alloc.dupe(u8, tc.id);
        errdefer alloc.free(id);
        const name = try alloc.dupe(u8, tc.name);
        errdefer alloc.free(name);
        const input = try alloc.dupe(u8, tc.input);
        errdefer alloc.free(input);
        try parts.append(alloc, types.Part.toolCallPart(id, name, input));
    }
    for (result.provider_parts) |part| try parts.append(alloc, try clonePart(alloc, part));
    return parts.toOwnedSlice(alloc);
}

fn assistantReasoning(msg: Message) []const u8 {
    for (msg.parts()) |part| {
        switch (part) {
            .reasoning => |reasoning| return reasoning.text,
            else => {},
        }
    }
    return "";
}

fn makeStepResult(
    alloc: std.mem.Allocator,
    number: usize,
    assistant_msg: Message,
    tool_results: []const types.ToolResult,
    result: *const model.GenerateResult,
) !types.StepResult {
    var step = types.StepResult{
        .number = number,
        .finish_reason = result.finish_reason,
        .usage = result.usage,
    };
    errdefer step.deinit(alloc);
    step.text = try alloc.dupe(u8, assistant_msg.text());
    step.reasoning = try alloc.dupe(u8, assistantReasoning(assistant_msg));
    step.tool_calls = try cloneStepToolCalls(alloc, assistant_msg);
    step.tool_results = try cloneStepToolResults(alloc, tool_results);
    step.response.id = try alloc.dupe(u8, result.response.id);
    step.response.model = try alloc.dupe(u8, result.response.model);
    return step;
}

fn cloneStepToolCalls(alloc: std.mem.Allocator, msg: Message) ![]const types.ToolCall {
    var calls: std.ArrayList(types.ToolCall) = .empty;
    errdefer {
        for (calls.items) |call| {
            alloc.free(call.id);
            alloc.free(call.name);
            alloc.free(call.input);
        }
        calls.deinit(alloc);
    }
    for (msg.parts()) |part| {
        switch (part) {
            .tool_call => |call| {
                const id = try alloc.dupe(u8, call.id);
                errdefer alloc.free(id);
                const name = try alloc.dupe(u8, call.name);
                errdefer alloc.free(name);
                const input = try alloc.dupe(u8, call.input);
                errdefer alloc.free(input);
                try calls.append(alloc, .{ .id = id, .name = name, .input = input });
            },
            else => {},
        }
    }
    return calls.toOwnedSlice(alloc);
}

fn cloneStepToolResults(alloc: std.mem.Allocator, values: []const types.ToolResult) ![]const types.ToolResult {
    var results: std.ArrayList(types.ToolResult) = .empty;
    errdefer {
        freeToolResults(alloc, results.items);
        results.deinit(alloc);
    }
    for (values) |value| {
        const tool_call_id = try alloc.dupe(u8, value.tool_call_id);
        errdefer alloc.free(tool_call_id);
        const tool_name = try alloc.dupe(u8, value.tool_name);
        errdefer alloc.free(tool_name);
        const output = try alloc.dupe(u8, value.output);
        errdefer alloc.free(output);
        var image: ?types.ToolImage = null;
        if (value.image) |source| {
            const url = try alloc.dupe(u8, source.url);
            errdefer alloc.free(url);
            const media_type = try alloc.dupe(u8, source.media_type);
            errdefer alloc.free(media_type);
            image = .{
                .url = url,
                .media_type = media_type,
            };
        }
        try results.append(alloc, .{
            .tool_call_id = tool_call_id,
            .tool_name = tool_name,
            .output = output,
            .is_error = value.is_error,
            .exit_loop = value.exit_loop,
            .image = image,
        });
    }
    return results.toOwnedSlice(alloc);
}

fn appendToolMessages(alloc: std.mem.Allocator, history: *std.ArrayList(Message), results: []const types.ToolResult) !void {
    for (results) |tr| {
        const id = try alloc.dupe(u8, tr.tool_call_id);
        errdefer alloc.free(id);
        const name = try alloc.dupe(u8, tr.tool_name);
        errdefer alloc.free(name);
        const output = try alloc.dupe(u8, tr.output);
        errdefer alloc.free(output);
        const part_count: usize = if (tr.image != null) 2 else 1;
        const parts = try alloc.alloc(types.Part, part_count);
        parts[0] = .{ .tool_result = .{
            .id = id,
            .name = name,
            .output = output,
            .is_error = tr.is_error,
            .exit_loop = tr.exit_loop,
        } };
        if (tr.image) |image| parts[1] = .{ .image = .{
            .url = try alloc.dupe(u8, image.url),
            .media_type = try alloc.dupe(u8, image.media_type),
        } };
        try history.append(alloc, .{ .role = .tool, .content = parts });
    }
}

fn freeToolResults(alloc: std.mem.Allocator, results: []const types.ToolResult) void {
    for (results) |tr| {
        alloc.free(tr.tool_call_id);
        alloc.free(tr.tool_name);
        alloc.free(tr.output);
        if (tr.image) |image| {
            alloc.free(image.url);
            alloc.free(image.media_type);
        }
    }
}

fn executeTools(
    alloc: std.mem.Allocator,
    io: std.Io,
    opts: GenerateOptions,
    calls: []const types.ToolCall,
    step: usize,
) ![]types.ToolResult {
    const results = try alloc.alloc(types.ToolResult, calls.len);
    var completed: usize = 0;
    errdefer {
        freeToolResults(alloc, results[0..completed]);
        alloc.free(results);
    }

    if (opts.sequential_tool_execution or calls.len == 1) {
        for (calls, 0..) |tc, i| {
            results[i] = try executeOne(alloc, io, opts, tc, step);
            completed = i + 1;
        }
    } else {
        const Job = struct {
            result: types.ToolResult,

            fn run(a: std.mem.Allocator, io_: std.Io, options_: GenerateOptions, call_: types.ToolCall, step_: usize) anyerror!@This() {
                const result_ = executeOne(a, io_, options_, call_, step_) catch |err| {
                    if (err == error.Canceled) return err;
                    return .{ .result = .{
                        .tool_call_id = try a.dupe(u8, call_.id),
                        .tool_name = try a.dupe(u8, call_.name),
                        .output = try std.fmt.allocPrint(a, "error: tool execution failed: {s}", .{@errorName(err)}),
                        .is_error = true,
                    } };
                };
                return .{ .result = result_ };
            }
        };
        const futures = try alloc.alloc(std.Io.Future(anyerror!Job), calls.len);
        defer alloc.free(futures);
        for (calls, 0..) |tc, i| {
            futures[i] = std.Io.async(io, Job.run, .{ alloc, io, opts, tc, step });
        }
        var awaited: usize = 0;
        errdefer for (futures[awaited..]) |*future| {
            if (future.cancel(io)) |job| freeToolResults(alloc, &.{job.result}) else |_| {}
        };
        for (futures) |*future| {
            const job = try future.await(io);
            results[awaited] = job.result;
            awaited += 1;
            completed = awaited;
        }
    }

    return results;
}

fn executeOne(
    a: std.mem.Allocator,
    io: std.Io,
    opts: GenerateOptions,
    call: types.ToolCall,
    step: usize,
) !types.ToolResult {
    if (opts.cancellation) |token| try token.check();
    const started = nowMs(io);
    if (opts.hooks.on_tool_call_start) |f| {
        f(opts.hooks.on_tool_call_start_ctx, .{
            .tool_call_id = call.id,
            .tool_name = call.name,
            .step = step,
            .input = call.input,
        });
    }

    var output: []const u8 = "error: unknown tool";
    var is_err = true;
    var exit_loop = false;
    var image: ?types.ToolImage = null;
    var exec_err: ?anyerror = error.UnknownTool;
    var err_buf: []u8 = &.{};
    defer a.free(err_buf);

    for (opts.tools) |tool| {
        if (!std.mem.eql(u8, tool.name, call.name)) continue;
        if (tool.execute) |exec| {
            if (executeTool(a, io, opts.cancellation, exec, tool.execute_ctx, call)) |out| {
                output = out.content;
                is_err = out.is_error;
                exit_loop = out.exit_loop;
                image = out.image;
                exec_err = null;
            } else |err| {
                err_buf = std.fmt.allocPrint(a, "error: {s}", .{@errorName(err)}) catch "";
                output = if (err_buf.len > 0) err_buf else "error: tool failed";
                is_err = true;
                exec_err = err;
            }
        } else {
            output = "error: tool has no execute function";
            exec_err = error.ToolHasNoExecute;
        }
        break;
    }
    if (opts.cancellation) |token| try token.check();

    const id = try a.dupe(u8, call.id);
    errdefer a.free(id);
    const name = try a.dupe(u8, call.name);
    errdefer a.free(name);
    const out = try a.dupe(u8, output);
    errdefer a.free(out);
    const owned_image: ?types.ToolImage = if (image) |value| .{
        .url = try a.dupe(u8, value.url),
        .media_type = try a.dupe(u8, value.media_type),
    } else null;

    const duration: u64 = @intCast(nowMs(io) - started);
    if (opts.hooks.on_tool_call) |f| {
        f(opts.hooks.on_tool_call_ctx, .{
            .tool_call_id = call.id,
            .tool_name = call.name,
            .step = step,
            .input = call.input,
            .output = output,
            .is_error = is_err,
            .duration_ms = duration,
            .err = exec_err,
        });
    }

    return .{
        .tool_call_id = id,
        .tool_name = name,
        .output = out,
        .is_error = is_err,
        .exit_loop = exit_loop,
        .image = owned_image,
    };
}

fn executeTool(
    alloc: std.mem.Allocator,
    io: std.Io,
    cancellation: ?*options.CancellationToken,
    exec: types.ToolExecuteFn,
    ctx: ?*anyopaque,
    call: types.ToolCall,
) !types.ToolOutput {
    const token = cancellation orelse return exec(ctx, alloc, io, call);
    const Selection = union(enum) { output: anyerror!types.ToolOutput, canceled: void };
    var buffer: [2]Selection = undefined;
    var select = std.Io.Select(Selection).init(io, &buffer);
    try select.concurrent(.output, runToolCallback, .{ exec, ctx, alloc, io, call });
    select.async(.canceled, options.CancellationToken.waitUntilCanceled, .{ token, io });
    switch (try select.await()) {
        .output => |output| {
            select.cancelDiscard();
            return output;
        },
        .canceled => {
            select.cancelDiscard();
            return error.Canceled;
        },
    }
}

fn runToolCallback(exec: types.ToolExecuteFn, ctx: ?*anyopaque, alloc: std.mem.Allocator, io: std.Io, call: types.ToolCall) !types.ToolOutput {
    return exec(ctx, alloc, io, call);
}

pub fn generateObject(
    comptime T: type,
    alloc: std.mem.Allocator,
    io: std.Io,
    chat: model.LanguageModel,
    opts: GenerateOptions,
) !types.ObjectResult(T) {
    var object_opts = opts;
    object_opts.explicit_schema = opts.explicit_schema orelse schema.schemaFrom(T);
    const result = try run(alloc, io, chat, object_opts, null);
    defer result.deinit(alloc);

    var object_arena = std.heap.ArenaAllocator.init(alloc);
    errdefer object_arena.deinit();
    const object = std.json.parseFromSliceLeaky(T, object_arena.allocator(), result.text, .{}) catch {
        return error.InvalidObjectResponse;
    };

    return .{
        .object = object,
        .usage = result.total_usage,
        .finish_reason = result.finish_reason,
        .response = .{
            .id = try alloc.dupe(u8, result.response.id),
            .model = try alloc.dupe(u8, result.response.model),
        },
        .arena = object_arena,
    };
}

pub fn streamObject(
    comptime T: type,
    alloc: std.mem.Allocator,
    io: std.Io,
    chat: model.LanguageModel,
    opts: GenerateOptions,
) !types.ObjectResult(T) {
    var object_opts = opts;
    object_opts.explicit_schema = opts.explicit_schema orelse schema.schemaFrom(T);
    var sctx = model.StreamContext{
        .emit = streamEmit,
        .emit_ctx = @ptrCast(&object_opts),
    };
    const result = try run(alloc, io, chat, object_opts, &sctx);
    defer result.deinit(alloc);

    var object_arena = std.heap.ArenaAllocator.init(alloc);
    errdefer object_arena.deinit();
    const object = std.json.parseFromSliceLeaky(T, object_arena.allocator(), result.text, .{}) catch {
        return error.InvalidObjectResponse;
    };

    return .{
        .object = object,
        .usage = result.total_usage,
        .finish_reason = result.finish_reason,
        .response = .{
            .id = try alloc.dupe(u8, result.response.id),
            .model = try alloc.dupe(u8, result.response.model),
        },
        .arena = object_arena,
    };
}
