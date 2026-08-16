const std = @import("std");
const model = @import("model.zig");
const options = @import("options.zig");
const types = @import("types.zig");

pub fn embed(
    alloc: std.mem.Allocator,
    io: std.Io,
    m: model.EmbeddingModel,
    value: []const u8,
    opts: options.EmbedOptions,
) !types.EmbedResult {
    const values = [_][]const u8{value};
    const result = try embedManyInner(alloc, io, m, &values, opts, true);
    return result;
}

pub fn embedMany(
    alloc: std.mem.Allocator,
    io: std.Io,
    m: model.EmbeddingModel,
    values: []const []const u8,
    opts: options.EmbedOptions,
) !types.EmbedResult {
    return embedManyInner(alloc, io, m, values, opts, false);
}

fn embedManyInner(
    alloc: std.mem.Allocator,
    io: std.Io,
    m: model.EmbeddingModel,
    values: []const []const u8,
    opts: options.EmbedOptions,
    single: bool,
) !types.EmbedResult {
    _ = single;
    if (values.len == 0) return .{};

    var all: std.ArrayList([]const f64) = .empty;
    errdefer {
        for (all.items) |e| alloc.free(e);
        all.deinit(alloc);
    }
    var total_usage = types.Usage{};

    const chunk_size = 128;
    const parallelism = @max(opts.max_parallel_calls, 1);
    var i: usize = 0;
    while (i < values.len) {
        const remaining_chunks = (values.len - i + chunk_size - 1) / chunk_size;
        const job_count = @min(parallelism, remaining_chunks);
        const Job = struct {
            embedding_model: model.EmbeddingModel,
            alloc: std.mem.Allocator,
            io: std.Io,
            params: model.EmbedParams,
            client: ?*std.http.Client,
            max_retries: u32,
            result: ?*types.EmbedResult = null,
            err: ?anyerror = null,

            fn run(job: *@This()) void {
                job.result = job.embedding_model.embed(
                    job.alloc,
                    job.io,
                    job.params,
                    job.client,
                    job.max_retries,
                ) catch |err| {
                    job.err = err;
                    return;
                };
            }
        };
        const jobs = try alloc.alloc(Job, job_count);
        defer alloc.free(jobs);
        const threads = try alloc.alloc(std.Thread, job_count);
        defer alloc.free(threads);
        var spawned: usize = 0;
        for (jobs, 0..) |*job, index| {
            const start = i + index * chunk_size;
            const end = @min(start + chunk_size, values.len);
            job.* = .{
                .embedding_model = m,
                .alloc = alloc,
                .io = io,
                .params = .{
                    .values = values[start..end],
                    .provider_options = opts.provider_options,
                    .headers = opts.headers,
                    .timeout_ms = opts.timeout_ms,
                    .cancellation = opts.cancellation,
                },
                .client = opts.client,
                .max_retries = opts.max_retries,
            };
            if (job_count == 1) {
                job.run();
            } else {
                threads[spawned] = std.Thread.spawn(.{}, Job.run, .{job}) catch {
                    job.run();
                    continue;
                };
                spawned += 1;
            }
        }
        for (threads[0..spawned]) |*thread| thread.join();

        var consumed: usize = 0;
        errdefer {
            for (jobs[consumed..]) |job| {
                if (job.result) |result| {
                    result.deinit(alloc);
                    alloc.destroy(result);
                }
            }
        }
        for (jobs, 0..) |job, index| {
            if (job.err) |err| return err;
            const result = job.result.?;
            for (result.embeddings) |embedding| try all.append(alloc, try alloc.dupe(f64, embedding));
            total_usage.add(result.usage);
            result.deinit(alloc);
            alloc.destroy(result);
            consumed = index + 1;
        }
        i += job_count * chunk_size;
    }

    return .{
        .embeddings = try all.toOwnedSlice(alloc),
        .usage = total_usage,
    };
}
