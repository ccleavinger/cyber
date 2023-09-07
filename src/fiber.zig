// Copyright (c) 2023 Cyber (See LICENSE)

/// Fibers.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const stdx = @import("stdx");
const t = stdx.testing;
const cy = @import("cyber.zig");
const vmc = @import("vm_c.zig");
const rt = cy.rt;
const log = cy.log.scoped(.fiber);
const Value = cy.Value;

pub const PanicPayload = u64;

pub const PanicType = enum(u8) {
    uncaughtError = vmc.PANIC_UNCAUGHT_ERROR,
    staticMsg = vmc.PANIC_STATIC_MSG,
    msg = vmc.PANIC_MSG,
    nativeThrow = vmc.PANIC_NATIVE_THROW,
    inflightOom = vmc.PANIC_INFLIGHT_OOM,
    none = vmc.PANIC_NONE,
};

test "fiber internals." {
    if (cy.is32Bit) {
        try t.eq(@sizeOf(vmc.Fiber), 72);
        try t.eq(@sizeOf(vmc.TryFrame), 12);
    } else {
        try t.eq(@sizeOf(vmc.Fiber), 88);
        try t.eq(@sizeOf(vmc.TryFrame), 16);
    }
}

pub fn allocFiber(vm: *cy.VM, pc: usize, args: []const cy.Value, initialStackSize: u32) linksection(cy.HotSection) !cy.Value {
    // Args are copied over to the new stack.
    var stack = try vm.alloc.alloc(Value, initialStackSize);
    // Assumes initial stack size generated by compiler is enough to hold captured args.
    // Assumes call start local is at 1.
    std.mem.copy(Value, stack[5..5+args.len], args);

    const obj: *vmc.Fiber = @ptrCast(try cy.heap.allocExternalObject(vm, @sizeOf(vmc.Fiber)));
    const parentDstLocal = cy.NullU8;
    obj.* = .{
        .typeId = rt.FiberT,
        .rc = 1,
        .stackPtr = @ptrCast(stack.ptr),
        .stackLen = @intCast(stack.len),
        .pcOffset = @intCast(pc),
        .stackOffset = 0,
        .parentDstLocal = parentDstLocal,
        .tryStackCap = 0,
        .tryStackPtr = undefined,
        .tryStackLen = 0,
        .throwTracePtr = undefined,
        .throwTraceCap = 0,
        .throwTraceLen = 0,
        .initialPcOffset = @intCast(pc),
        .panicPayload = undefined,
        .panicType = vmc.PANIC_NONE,
        .prevFiber = undefined,
    };

    return Value.initPtr(obj);
}

/// Since this is called from a coresume expression, the fiber should already be retained.
pub fn pushFiber(vm: *cy.VM, curFiberEndPc: usize, curFramePtr: [*]Value, fiber: *cy.Fiber, parentDstLocal: u8) PcSp {
    // Save current fiber.
    vm.curFiber.stackPtr = @ptrCast(vm.stack.ptr);
    vm.curFiber.stackLen = @intCast(vm.stack.len);
    vm.curFiber.pcOffset = @intCast(curFiberEndPc);
    vm.curFiber.stackOffset = @intCast(getStackOffset(vm.stack.ptr, curFramePtr));

    // Push new fiber.
    fiber.prevFiber = vm.curFiber;
    fiber.parentDstLocal = parentDstLocal;
    vm.curFiber = fiber;
    vm.stack = @as([*]Value, @ptrCast(fiber.stackPtr))[0..fiber.stackLen];
    vm.stackEndPtr = vm.stack.ptr + fiber.stackLen;
    // Check if fiber was previously yielded.
    if (vm.ops[fiber.pcOffset].opcode() == .coyield) {
        log.debug("fiber set to {} {*}", .{fiber.pcOffset + 3, vm.framePtr});
        return .{
            .pc = toVmPc(vm, fiber.pcOffset + 3),
            .sp = @ptrCast(fiber.stackPtr + fiber.stackOffset),
        };
    } else {
        log.debug("fiber set to {} {*}", .{fiber.pcOffset, vm.framePtr});
        return .{
            .pc = toVmPc(vm, fiber.pcOffset),
            .sp = @ptrCast(fiber.stackPtr + fiber.stackOffset),
        };
    }
}

pub fn popFiber(vm: *cy.VM, curFiberEndPc: usize, curFp: [*]Value, retValue: Value) PcSp {
    vm.curFiber.stackPtr = @ptrCast(vm.stack.ptr);
    vm.curFiber.stackLen = @intCast(vm.stack.len);
    vm.curFiber.pcOffset = @intCast(curFiberEndPc);
    vm.curFiber.stackOffset = @intCast(getStackOffset(vm.stack.ptr, curFp));
    const dstLocal = vm.curFiber.parentDstLocal;

    // Release current fiber.
    const nextFiber = vm.curFiber.prevFiber.?;
    cy.arc.releaseObject(vm, cy.ptrAlignCast(*cy.HeapObject, vm.curFiber));

    // Set to next fiber.
    vm.curFiber = nextFiber;

    // Copy return value to parent local.
    if (dstLocal != cy.NullU8) {
        vm.curFiber.stackPtr[vm.curFiber.stackOffset + dstLocal] = @bitCast(retValue);
    } else {
        cy.arc.release(vm, retValue);
    }

    vm.stack = @as([*]Value, @ptrCast(vm.curFiber.stackPtr))[0..vm.curFiber.stackLen];
    vm.stackEndPtr = vm.stack.ptr + vm.curFiber.stackLen;
    log.debug("fiber set to {} {*}", .{vm.curFiber.pcOffset, vm.framePtr});
    return PcSp{
        .pc = toVmPc(vm, vm.curFiber.pcOffset),
        .sp = @ptrCast(vm.curFiber.stackPtr + vm.curFiber.stackOffset),
    };
}

/// Unwinds the stack and releases the locals.
/// This also releases the initial captured vars since it's on the stack.
pub fn releaseFiberStack(vm: *cy.VM, fiber: *cy.Fiber) !void {
    log.debug("release fiber stack", .{});
    var stack = @as([*]Value, @ptrCast(fiber.stackPtr))[0..fiber.stackLen];
    var framePtr = fiber.stackOffset;
    var pc = fiber.pcOffset;

    if (pc != cy.NullId) {

        // Check if fiber is still in init state.
        switch (vm.ops[pc].opcode()) {
            .callFuncIC,
            .callSym => {
                if (pc >= 6 and vm.ops[pc - 6].opcode() == .coinit) {
                    const numArgs = vm.ops[pc - 4].val;
                    for (stack[fiber.stackOffset + 5..fiber.stackOffset + 5 + numArgs]) |arg| {
                        cy.arc.release(vm, arg);
                    }
                }
            },
            else => {},
        }

        // Check if fiber was previously on a yield op.
        if (vm.ops[pc].opcode() == .coyield) {
            const jump = @as(*const align(1) u16, @ptrCast(&vm.ops[pc+1])).*;
            log.debug("release on frame {} {} {}", .{framePtr, pc, pc + jump});
            // The yield statement already contains the end locals pc.
            cy.arc.runBlockEndReleaseOps(vm, stack, framePtr, pc + jump);

            // Prev frame.
            pc = @intCast(getInstOffset(vm.ops.ptr, stack[framePtr + 2].retPcPtr) - stack[framePtr + 1].retInfoCallInstOffset());
            framePtr = @intCast(getStackOffset(stack.ptr, stack[framePtr + 3].retFramePtr));

            // Unwind stack and release all locals.
            while (framePtr > 0) {
                const sym = cy.debug.getDebugSym(vm, pc) orelse return error.NoDebugSym;
                const endLocalsPc = cy.debug.debugSymToEndLocalsPc(vm, sym);
                log.debug("release on frame {} {} {}", .{framePtr, pc, endLocalsPc});
                if (endLocalsPc != cy.NullId) {
                    cy.arc.runBlockEndReleaseOps(vm, stack, framePtr, endLocalsPc);
                }

                // Prev frame.
                pc = @intCast(getInstOffset(vm.ops.ptr, stack[framePtr + 2].retPcPtr) - stack[framePtr + 1].retInfoCallInstOffset());
                framePtr = @intCast(getStackOffset(stack.ptr, stack[framePtr + 3].retFramePtr));
            }
        }

        // Check to run extra release ops (eg. For call1 inst.)
        if (vm.ops[pc].opcode() != .coreturn) {
            switch (vm.ops[fiber.initialPcOffset].opcode()) {
                .call => {
                    const endLocalsPc = fiber.initialPcOffset + cy.bytecode.CallInstLen;
                    if (vm.ops[endLocalsPc].opcode() == .release) {
                        const local = vm.ops[endLocalsPc+1].val;
                        cy.arc.release(vm, stack[framePtr + local]);
                    }
                },
                else => {},
            }
        }
    }
    // Finally free stack.
    vm.alloc.free(stack);
}

/// Unwind given stack starting at a pc, framePtr and release all locals.
/// TODO: See if releaseFiberStack can resuse the same code.
pub fn unwindReleaseStack(vm: *cy.VM, stack: []const Value, startFramePtr: [*]const Value, startPc: [*]const cy.Inst) !void {
    var pcOffset = getInstOffset(vm.ops.ptr, startPc);
    var fpOffset = getStackOffset(vm.stack.ptr, startFramePtr);

    while (true) {
        log.debug("release frame at {}", .{pcOffset});

        // Release temporaries in the current frame.
        cy.arc.runTempReleaseOps(vm, vm.stack, fpOffset, pcOffset);

        const sym = cy.debug.getDebugSym(vm, pcOffset) orelse return error.NoDebugSym;
        const endLocalsPc = cy.debug.debugSymToEndLocalsPc(vm, sym);
        if (endLocalsPc != cy.NullId) {
            cy.arc.runBlockEndReleaseOps(vm, stack, fpOffset, endLocalsPc);
        }
        if (fpOffset == 0) {
            // Done, at main block.
            return;
        } else {
            // Unwind.
            pcOffset = getInstOffset(vm.ops.ptr, stack[fpOffset + 2].retPcPtr) - stack[fpOffset + 1].retInfoCallInstOffset();
            fpOffset = getStackOffset(stack.ptr, stack[fpOffset + 3].retFramePtr);
        }
    }
}

/// Performs ARC deinit for each frame starting at `start` but not including the target framePtr.
/// Records minimal trace to reconstruct later.
pub fn unwindThrowUntilFramePtr(vm: *cy.VM, startFp: [*]const Value, pc: [*]const cy.Inst, targetFp: [*]const Value) !void {
    var pcOffset = getInstOffset(vm.ops.ptr, pc);
    var fpOffset = getStackOffset(vm.stack.ptr, startFp);
    const tFpOffset = getStackOffset(vm.stack.ptr, targetFp);

    while (fpOffset > tFpOffset) {
        log.debug("release frame: {} {}", .{pcOffset, vm.ops[pcOffset].opcode()});
        // Perform cleanup for this frame.

        // Release temporaries in the current frame.
        const instLen = cy.getInstLenAt(vm.ops.ptr + pcOffset);
        cy.arc.runTempReleaseOps(vm, vm.stack, fpOffset, pcOffset + instLen);

        const sym = cy.debug.getDebugSym(vm, pcOffset) orelse return error.NoDebugSym;
        const endLocalsPc = cy.debug.debugSymToEndLocalsPc(vm, sym);
        if (endLocalsPc != cy.NullId) {
            cy.arc.runBlockEndReleaseOps(vm, vm.stack, fpOffset, endLocalsPc);
        }

        // Record frame.
        try vm.throwTrace.append(vm.alloc, .{
            .pcOffset = sym.pc,
            .fpOffset = fpOffset,
        });

        // Unwind frame.
        pcOffset = getInstOffset(vm.ops.ptr, vm.stack[fpOffset + 2].retPcPtr) - vm.stack[fpOffset + 1].retInfoCallInstOffset();
        fpOffset = getStackOffset(vm.stack.ptr, vm.stack[fpOffset + 3].retFramePtr);
    }

    // Release temporaries in the current frame.
    log.debug("release temps: {} {}", .{pcOffset, vm.ops[pcOffset].opcode()});
    const instLen = cy.getInstLenAt(vm.ops.ptr + pcOffset);
    cy.arc.runTempReleaseOps(vm, vm.stack, fpOffset, pcOffset + instLen);
}

pub fn throw(vm: *cy.VM, startFp: [*]Value, pc: [*]const cy.Inst, err: Value) !?PcSp {
    if (vm.tryStack.len > 0) {
        const tframe = vm.tryStack.buf[vm.tryStack.len-1];

        // Pop try frame.
        vm.tryStack.len -= 1;

        vm.throwTrace.clearRetainingCapacity();
        if (@as([*]Value, @ptrCast(tframe.fp)) == startFp) {
            // Copy error to catch dst.
            if (tframe.catchErrDst != cy.NullU8) {
                startFp[tframe.catchErrDst] = err;
            }

            // Record one frame.
            const pcOffset = getInstOffset(vm.ops.ptr, pc);
            const fpOffset = getStackOffset(vm.stack.ptr, startFp);
            try vm.throwTrace.append(vm.alloc, .{
                .pcOffset = pcOffset,
                .fpOffset = fpOffset,
            });

            // Release temporaries in the current frame.
            log.debug("release temps: {} {}", .{pcOffset, vm.ops[pcOffset].opcode()});
            cy.arc.runTempReleaseOps(vm, vm.stack, fpOffset, pcOffset);

            // Goto catch block in current frame.
            return PcSp{
                .pc = toVmPc(vm, tframe.catchPc),
                .sp = startFp,
            };
        } else {
            // Unwind to next try frame.
            try cy.fiber.unwindThrowUntilFramePtr(vm, startFp, pc, @ptrCast(tframe.fp));

            // Copy error to catch dst.
            if (tframe.catchErrDst != cy.NullU8) {
                tframe.fp[tframe.catchErrDst] = @bitCast(err);
            }

            return PcSp{
                .pc = toVmPc(vm, tframe.catchPc),
                .sp = @ptrCast(tframe.fp),
            };
        }
    } else {
        // No try frames.
        return null;
    }
}

pub inline fn getInstOffset(from: [*]const cy.Inst, to: [*]const cy.Inst) u32 {
    return @intCast(@intFromPtr(to) - @intFromPtr(from));
}

pub inline fn getStackOffset(from: [*]const Value, to: [*]const Value) u32 {
    // Divide by eight.
    return @intCast((@intFromPtr(to) - @intFromPtr(from)) >> 3);
}

pub inline fn stackEnsureUnusedCapacity(self: *cy.VM, unused: u32) !void {
    if (@intFromPtr(self.framePtr) + 8 * unused >= @intFromPtr(self.stack.ptr + self.stack.len)) {
        try self.stackGrowTotalCapacity((@intFromPtr(self.framePtr) + 8 * unused) / 8);
    }
}

pub inline fn stackEnsureTotalCapacity(self: *cy.VM, newCap: usize) !void {
    if (newCap > self.stack.len) {
        try stackGrowTotalCapacity(self, newCap);
    }
}

pub fn stackEnsureTotalCapacityPrecise(self: *cy.VM, newCap: usize) !void {
    if (newCap > self.stack.len) {
        try stackGrowTotalCapacityPrecise(self, newCap);
    }
}

pub fn stackGrowTotalCapacity(self: *cy.VM, newCap: usize) !void {
    var betterCap = self.stack.len;
    while (true) {
        betterCap +|= betterCap / 2 + 8;
        if (betterCap >= newCap) {
            break;
        }
    }
    if (self.alloc.resize(self.stack, betterCap)) {
        self.stack.len = betterCap;
        self.stackEndPtr = self.stack.ptr + betterCap;
    } else {
        self.stack = try self.alloc.realloc(self.stack, betterCap);
        self.stackEndPtr = self.stack.ptr + betterCap;
    }
}

pub fn stackGrowTotalCapacityPrecise(self: *cy.VM, newCap: usize) !void {
    if (self.alloc.resize(self.stack, newCap)) {
        self.stack.len = newCap;
        self.stackEndPtr = self.stack.ptr + newCap;
    } else {
        self.stack = try self.alloc.realloc(self.stack, newCap);
        self.stackEndPtr = self.stack.ptr + newCap;
    }
}

pub inline fn toVmPc(self: *const cy.VM, offset: usize) [*]cy.Inst {
    return self.ops.ptr + offset;
}

// Performs stackGrowTotalCapacityPrecise in addition to patching the frame pointers.
pub fn growStackAuto(vm: *cy.VM) !void {
    @setCold(true);
    // Grow by 50% with minimum of 16.
    var growSize = vm.stack.len / 2;
    if (growSize < 16) {
        growSize = 16;
    }
    try growStackPrecise(vm, vm.stack.len + growSize);
}

pub fn ensureTotalStackCapacity(vm: *cy.VM, newCap: usize) !void {
    if (newCap > vm.stack.len) {
        var betterCap = vm.stack.len;
        while (true) {
            betterCap +|= betterCap / 2 + 8;
            if (betterCap >= newCap) {
                break;
            }
        }
        try growStackPrecise(vm, betterCap);
    }
}

fn growStackPrecise(vm: *cy.VM, newCap: usize) !void {
    if (vm.alloc.resize(vm.stack, newCap)) {
        vm.stack.len = newCap;
        vm.stackEndPtr = vm.stack.ptr + newCap;
    } else {
        const newStack = try vm.alloc.alloc(Value, newCap);

        // Copy to new stack.
        std.mem.copy(Value, newStack[0..vm.stack.len], vm.stack);

        // Patch frame ptrs. 
        var curFpOffset = getStackOffset(vm.stack.ptr, vm.framePtr);
        while (curFpOffset != 0) {
            const prevFpOffset = getStackOffset(vm.stack.ptr, newStack[curFpOffset + 3].retFramePtr);
            newStack[curFpOffset + 3].retFramePtr = newStack.ptr + prevFpOffset;
            curFpOffset = prevFpOffset;
        }

        // Free old stack.
        vm.alloc.free(vm.stack);

        // Update to new frame ptr.
        vm.framePtr = newStack.ptr + getStackOffset(vm.stack.ptr, vm.framePtr);
        vm.stack = newStack;
        vm.stackEndPtr = vm.stack.ptr + newCap;
    }
}

pub const PcSp = struct {
    pc: [*]cy.Inst,
    sp: [*]Value,
};