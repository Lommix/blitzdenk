const std = @import("std");
const types = @import("types.zig");
const model = @import("model.zig");
const options = @import("options.zig");
const schema = @import("schema.zig");

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

const StepScratch = struct {
    number: usize,
    finish_reason: types.FinishReason,
    usage: types.Usage,
    response_id: []const u8 = "",
    response_model: []const u8 = "",
    assistant_index: usize,
    tool_count: usize = 0,
};

fn run(
    alloc: std.mem.Allocator,
    io: std.Io,
    chat: model.LanguageModel,
    opts: GenerateOptions,
    sctx: ?*model.StreamContext,
) !types.TextResult {
    var history: std.ArrayList(Message) = .empty;
    errdefer {
        for (history.items) |msg| types.freeMessage(alloc, msg);
        history.deinit(alloc);
    }

    if (opts.prompt.len > 0) {
        try history.append(alloc, .{
            .role = .user,
            .single = types.Part.textPart(try alloc.dupe(u8, opts.prompt)),
        });
    }
    try appendOwnedMessages(alloc, &history, opts.messages);

    var steps: std.ArrayList(StepScratch) = .empty;
    errdefer {
        for (steps.items) |sc| {
            alloc.free(sc.response_id);
            alloc.free(sc.response_model);
        }
        steps.deinit(alloc);
    }

    var total_usage = types.Usage{};
    var finish: types.FinishReason = .stop;
    var exhausted = false;
    var step_no: usize = 0;

    while (step_no < opts.max_steps) {
        step_no += 1;

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

        {
            const resp_id = try alloc.dupe(u8, result.response.id);
            errdefer alloc.free(resp_id);
            const resp_model = try alloc.dupe(u8, result.response.model);
            errdefer alloc.free(resp_model);
            try steps.append(alloc, .{
                .number = step_no,
                .finish_reason = result.finish_reason,
                .usage = result.usage,
                .response_id = resp_id,
                .response_model = resp_model,
                .assistant_index = history.items.len - 1,
            });
        }

        if (result.tool_calls.len == 0) {
            result.deinit(alloc);
            alloc.destroy(result);
            break;
        }

        if (step_no >= opts.max_steps) {
            exhausted = true;
            result.deinit(alloc);
            alloc.destroy(result);
            break;
        }

        const tool_results = try executeTools(alloc, io, opts, result.tool_calls, step_no);
        defer {
            freeToolResults(alloc, tool_results);
            alloc.free(tool_results);
        }
        try appendToolMessages(alloc, &history, tool_results);
        steps.items[steps.items.len - 1].tool_count = tool_results.len;

        if (opts.hooks.on_step_finish) |f| {
            f(opts.hooks.on_step_finish_ctx, .{
                .number = step_no,
                .text = result.text,
                .tool_calls = result.tool_calls,
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

        result.deinit(alloc);
        alloc.destroy(result);
    }

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    var reasoning: std.ArrayList(u8) = .empty;
    errdefer reasoning.deinit(alloc);

    var final_steps: std.ArrayList(types.StepResult) = .empty;
    errdefer {
        for (final_steps.items) |step| {
            alloc.free(step.tool_calls);
            alloc.free(step.tool_results);
            alloc.free(step.response.id);
            alloc.free(step.response.model);
        }
        final_steps.deinit(alloc);
    }

    for (steps.items) |*sc| {
        const assistant_msg = history.items[sc.assistant_index];
        const tool_msgs = history.items[sc.assistant_index + 1 .. sc.assistant_index + 1 + sc.tool_count];
        try final_steps.append(alloc, .{
            .number = sc.number,
            .text = assistant_msg.text(),
            .reasoning = assistantReasoning(assistant_msg),
            .tool_calls = try stepToolCalls(alloc, assistant_msg),
            .tool_results = try stepToolResults(alloc, tool_msgs),
            .finish_reason = sc.finish_reason,
            .usage = sc.usage,
            .response = .{ .id = sc.response_id, .model = sc.response_model },
        });
        sc.response_id = "";
        sc.response_model = "";
        const step = &final_steps.items[final_steps.items.len - 1];
        try text.appendSlice(alloc, step.text);
        if (step.reasoning.len > 0) try reasoning.appendSlice(alloc, step.reasoning);
    }
    steps.deinit(alloc);

    const last_step_calls = if (final_steps.items.len > 0)
        final_steps.items[final_steps.items.len - 1].tool_calls
    else
        &.{};
    const final_tool_calls = try alloc.alloc(types.ToolCall, last_step_calls.len);
    errdefer alloc.free(final_tool_calls);
    @memcpy(final_tool_calls, last_step_calls);

    const final_text = try text.toOwnedSlice(alloc);
    errdefer alloc.free(final_text);
    const final_reasoning = try reasoning.toOwnedSlice(alloc);
    errdefer alloc.free(final_reasoning);
    const final_steps_slice = try final_steps.toOwnedSlice(alloc);
    errdefer {
        for (final_steps_slice) |step| {
            alloc.free(step.tool_calls);
            alloc.free(step.tool_results);
            alloc.free(step.response.id);
            alloc.free(step.response.model);
        }
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
    var result = value;
    result.text = try alloc.dupe(u8, value.text);
    errdefer alloc.free(result.text);
    result.url = try alloc.dupe(u8, value.url);
    errdefer alloc.free(result.url);
    result.media_type = try alloc.dupe(u8, value.media_type);
    errdefer alloc.free(result.media_type);
    result.filename = try alloc.dupe(u8, value.filename);
    errdefer alloc.free(result.filename);
    result.detail = try alloc.dupe(u8, value.detail);
    errdefer alloc.free(result.detail);
    result.tool_call_id = try alloc.dupe(u8, value.tool_call_id);
    errdefer alloc.free(result.tool_call_id);
    result.tool_name = try alloc.dupe(u8, value.tool_name);
    errdefer alloc.free(result.tool_name);
    result.tool_input = try alloc.dupe(u8, value.tool_input);
    errdefer alloc.free(result.tool_input);
    result.tool_output = try alloc.dupe(u8, value.tool_output);
    errdefer alloc.free(result.tool_output);
    result.signature = try alloc.dupe(u8, value.signature);
    errdefer alloc.free(result.signature);
    result.cache_control = try alloc.dupe(u8, value.cache_control);
    return result;
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
        try parts.append(alloc, .{ .type = .text, .text = text });
    }
    if (result.reasoning.len > 0) {
        const text = try alloc.dupe(u8, result.reasoning);
        errdefer alloc.free(text);
        try parts.append(alloc, .{ .type = .reasoning, .text = text });
    }
    for (result.tool_calls) |tc| {
        const id = try alloc.dupe(u8, tc.id);
        errdefer alloc.free(id);
        const name = try alloc.dupe(u8, tc.name);
        errdefer alloc.free(name);
        const input = try alloc.dupe(u8, tc.input);
        errdefer alloc.free(input);
        try parts.append(alloc, .{
            .type = .tool_call,
            .tool_call_id = id,
            .tool_name = name,
            .tool_input = input,
        });
    }
    return parts.toOwnedSlice(alloc);
}

fn assistantReasoning(msg: Message) []const u8 {
    for (msg.parts()) |part| {
        if (part.type == .reasoning) return part.text;
    }
    return "";
}

fn stepToolCalls(alloc: std.mem.Allocator, msg: Message) ![]const types.ToolCall {
    var calls: std.ArrayList(types.ToolCall) = .empty;
    for (msg.parts()) |part| {
        if (part.type != .tool_call) continue;
        try calls.append(alloc, .{ .id = part.tool_call_id, .name = part.tool_name, .input = part.tool_input });
    }
    return calls.toOwnedSlice(alloc);
}

fn stepToolResults(alloc: std.mem.Allocator, tool_msgs: []const Message) ![]const types.ToolResult {
    var results: std.ArrayList(types.ToolResult) = .empty;
    for (tool_msgs) |msg| {
        for (msg.parts()) |part| {
            if (part.type != .tool_result) continue;
            try results.append(alloc, .{
                .tool_call_id = part.tool_call_id,
                .tool_name = part.tool_name,
                .output = part.tool_output,
                .is_error = part.is_error,
            });
        }
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
        try history.append(alloc, .{
            .role = .tool,
            .single = .{
                .type = .tool_result,
                .tool_call_id = id,
                .tool_name = name,
                .tool_output = output,
                .is_error = tr.is_error,
            },
        });
    }
}

fn freeToolResults(alloc: std.mem.Allocator, results: []const types.ToolResult) void {
    for (results) |tr| {
        alloc.free(tr.tool_call_id);
        alloc.free(tr.tool_name);
        alloc.free(tr.output);
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
            alloc: std.mem.Allocator,
            io: std.Io,
            opts: GenerateOptions,
            call: types.ToolCall,
            step: usize,
            result: *types.ToolResult,

            fn run(job: *@This()) void {
                const result = executeOne(job.alloc, job.io, job.opts, job.call, job.step) catch |err| types.ToolResult{
                    .tool_call_id = job.alloc.dupe(u8, job.call.id) catch "",
                    .tool_name = job.alloc.dupe(u8, job.call.name) catch "",
                    .output = std.fmt.allocPrint(job.alloc, "error: tool execution failed: {s}", .{@errorName(err)}) catch "",
                    .is_error = true,
                };
                job.result.* = result;
            }
        };
        const jobs = try alloc.alloc(Job, calls.len);
        errdefer alloc.free(jobs);
        const threads = try alloc.alloc(std.Thread, calls.len);
        errdefer alloc.free(threads);
        var spawned: usize = 0;
        for (calls, 0..) |tc, i| {
            jobs[i] = .{ .alloc = alloc, .io = io, .opts = opts, .call = tc, .step = step, .result = &results[i] };
            threads[spawned] = std.Thread.spawn(.{}, Job.run, .{&jobs[i]}) catch {
                jobs[i].run();
                continue;
            };
            spawned += 1;
        }
        for (threads[0..spawned]) |*t| t.join();
        completed = calls.len;
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
    var exec_err: ?anyerror = error.UnknownTool;
    var err_buf: []u8 = &.{};

    for (opts.tools) |tool| {
        if (!std.mem.eql(u8, tool.name, call.name)) continue;
        if (tool.execute) |exec| {
            if (exec(tool.execute_ctx, call.input)) |out| {
                output = out;
                is_err = false;
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
    defer a.free(err_buf);

    const id = try a.dupe(u8, call.id);
    errdefer a.free(id);
    const name = try a.dupe(u8, call.name);
    errdefer a.free(name);
    const out = try a.dupe(u8, output);
    errdefer a.free(out);

    const duration: u64 = @intCast(nowMs(io) - started);
    if (opts.hooks.on_tool_call) |f| {
        f(opts.hooks.on_tool_call_ctx, .{
            .tool_call_id = call.id,
            .tool_name = call.name,
            .step = step,
            .input = call.input,
            .output = output,
            .duration_ms = duration,
            .err = exec_err,
        });
    }

    return .{
        .tool_call_id = id,
        .tool_name = name,
        .output = out,
        .is_error = is_err,
    };
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
