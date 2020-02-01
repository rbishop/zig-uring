const std = @import("std");
const builtin = std.builtin;
const os = std.os;
const sys = os.system;
const io = std.io;
const kernel = @import("kernel.zig");

pub const MAX_SUBS = 4096;

pub const RingSetupError = error{
    RingSizeTooLarge,
    RingSizeTooSmall,
    RingSizeMustBeBaseTwo,
    NotEnoughFilesProcess,
    NotEnoughFilesSystem,
    NotEnoughMemory,
    PermissionsError,
    PollRequiresRoot,
    ParamsOutOfBounds,
    ReservedDataNotZeroed,
    InvalidFlags,
    EntriesOutOfBounds,
    AffinityRequiresPollMode,
    InvalidCompletionQueueSize,
};

pub const Ring = struct {
    fd: i32,
    size: u32,
    subs: SubQueue,
    comps: CompQueue,

    pub fn init(size: u32, params: *kernel.RingParams) RingSetupError!Ring {
        var ring: Ring = undefined;

        if (size > MAX_SUBS) {
            return RingSetupError.RingSizeTooLarge;
        }

        if (size < 1) {
            return RingSetupError.RingSizeTooSmall;
        }

        if (size & (size - 1) != 0) {
            return RingSetupError.RingSizeMustBeBaseTwo;
        }

        const rc = sys.io_uring_setup(size, @ptrCast(*os.io_uring_params, params));

        switch (os.errno(rc)) {
            os.EFAULT => return RingSetupError.ParamsOutOfBounds,
            os.EINVAL => return RingSetupError.InvalidFlags,
            os.EMFILE => return RingSetupError.NotEnoughFilesProcess,
            os.ENFILE => return RingSetupError.NotEnoughFilesSystem,
            os.ENOMEM => return RingSetupError.NotEnoughMemory,
            os.EPERM => return RingSetupError.PollRequiresRoot,
            else => ring.fd = @intCast(i32, rc),
        }

        ring.size = size;
        ring.subs = SubQueue.init(params.sq_capacity, ring.fd, params.sq_off);
        ring.comps = CompQueue.init(params.cq_capacity, ring.fd, params.cq_off);
        //var stdout = &io.getStdOut().outStream().stream;

        return ring;
    }
};

pub const SubQueue = struct {
    head: *u32,
    tail: *u32,
    mask: *u32,
    entries: *u32,
    flags: *u32,
    dropped: *u32,
    array: [*]u32,

    mmap_ptr: usize,
    size: u32,
    sqes: [*]kernel.SubmissionEntry,

    const Self = @This();

    pub fn init(capacity: u32, ring_fd: i32, offsets: kernel.SubmissionRingOffsets) @This() {
        var subs: SubQueue = undefined;
        subs.size = offsets.array + (capacity * @sizeOf(u32));
        subs.mmap_ptr = sys.mmap(null, subs.size, os.PROT_READ | os.PROT_WRITE, os.MAP_SHARED | os.MAP_POPULATE, @intCast(i32, ring_fd), os.IORING_OFF_SQ_RING);

        subs.head = @intToPtr(*u32, subs.mmap_ptr + offsets.head);
        subs.tail = @intToPtr(*u32, subs.mmap_ptr + offsets.tail);
        subs.mask = @intToPtr(*u32, subs.mmap_ptr + offsets.mask);
        subs.entries = @intToPtr(*u32, subs.mmap_ptr + offsets.entries);
        subs.flags = @intToPtr(*u32, subs.mmap_ptr + offsets.flags);
        subs.dropped = @intToPtr(*u32, subs.mmap_ptr + offsets.dropped);
        subs.array = @intToPtr([*]u32, subs.mmap_ptr + offsets.array);

        var sqe_size = capacity + @sizeOf(os.io_uring_sqe);
        var sqe_ptr = sys.mmap(null, sqe_size, os.PROT_READ | os.PROT_WRITE, os.MAP_SHARED | os.MAP_POPULATE, ring_fd, os.IORING_OFF_SQES);
        subs.sqes = @intToPtr([*]kernel.SubmissionEntry, sqe_ptr);

        return subs;
    }

    // This can error, add error type later
    // I should also think of an API that makes this re-entrant
    // consider supporting multi threading, though maybe rings should be owned by threads
    pub fn next(self: *Self) *kernel.SubmissionEntry {
        var index = self.tail.* & self.mask.*;
        return &self.sqes[index];
    }

    // Let's the kernel know we've added submission entries
    // TODO: Make sure num is within the size of the ring
    pub fn signal(self: *Self, num: u16) void {
        @fence(builtin.AtomicOrder.SeqCst);
        self.tail.* += num;
        @fence(builtin.AtomicOrder.SeqCst);
    }

    pub fn print(self: *Self) void {
        var stdout = &io.getStdOut().outStream().stream;
        var idx: u16 = 0;

        while (idx < self.entries.*) {
            _ = stdout.print("sqe #{}: {}\n", .{ idx, &self.sqes[idx] }) catch |err| null;
            idx += 1;
        }
    }
};

pub const CompQueue = struct {
    head: *u32,
    tail: *u32,
    mask: *u32,
    entries: *u32,
    overflow: *u32,

    mmap_ptr: usize,
    size: u32,
    cqes: [*]kernel.CompletionEntry,

    const Self = @This();

    pub fn init(capacity: u32, ring_fd: i32, offsets: kernel.CompletionRingOffsets) @This() {
        var comps: CompQueue = undefined;
        comps.size = offsets.cqes + (capacity * @sizeOf(u32));
        comps.mmap_ptr = sys.mmap(null, comps.size, os.PROT_READ | os.PROT_WRITE, os.MAP_SHARED | os.MAP_POPULATE, ring_fd, os.IORING_OFF_SQ_RING);

        comps.head = @intToPtr(*u32, comps.mmap_ptr + offsets.head);
        comps.tail = @intToPtr(*u32, comps.mmap_ptr + offsets.tail);
        comps.mask = @intToPtr(*u32, comps.mmap_ptr + offsets.mask);
        comps.entries = @intToPtr(*u32, comps.mmap_ptr + offsets.entries);
        comps.overflow = @intToPtr(*u32, comps.mmap_ptr + offsets.overflow);
        comps.cqes = @intToPtr([*]kernel.CompletionEntry, comps.mmap_ptr + offsets.cqes);

        return comps;
    }

    // this can probably error or return an optional
    pub fn get(self: *Self) *kernel.CompletionEntry {
        @fence(builtin.AtomicOrder.SeqCst);
        var idx = self.head.* & self.mask.*;
        var entry = &self.cqes[idx];

        // TODO: Relax this to Acquire/Release later
        @fence(builtin.AtomicOrder.SeqCst);
        self.head.* += 1;
        @fence(builtin.AtomicOrder.SeqCst);

        return entry;
    }

    pub fn print(self: *Self) void {
        var stdout = &io.getStdOut().outStream().stream;
        var idx: u16 = 0;

        while (idx < self.entries.*) {
            _ = stdout.print("cqe #{}: {}\n", .{ idx, &self.cqes[idx] }) catch |err| null;
            idx += 1;
        }
    }
};
