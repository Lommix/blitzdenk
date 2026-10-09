
pub const EMPTY_PROMPT_LABEL = "<no prompt saved>";

pub const Row = struct {
    id: []const u8,
    date: []const u8,
    prompt: []const u8,
};

pub const new_session = Row{ .id = "", .date = "", .prompt = "New session" };

pub fn isNewSession(row: Row) bool {
    return row.id.len == 0;
}

pub const Picker = struct {
    rows: []const Row = &.{},
    selected: usize = 0,
    scroll: usize = 0,

    pub fn move(self: *Picker, delta: i8) void {
        if (self.rows.len == 0) return;
        const moved = @as(i64, @intCast(self.selected)) + delta;
        self.selected = @intCast(@min(@max(moved, 0), @as(i64, @intCast(self.rows.len - 1))));
    }

    pub fn syncScroll(self: *Picker, visible: usize) void {
        if (visible == 0 or self.rows.len <= visible) {
            self.scroll = 0;
            return;
        }
        if (self.selected < self.scroll) self.scroll = self.selected;
        if (self.selected >= self.scroll + visible) self.scroll = self.selected + 1 - visible;
    }

    pub fn pick(self: Picker) ?Row {
        if (self.rows.len == 0) return null;
        return self.rows[self.selected];
    }
};
