// Resizable byte runs use offsets between invocations; descriptors retain no stale slice views.
namespace continuation_pool_test;

import silly from "..";

import std;

struct Run {
    start: i64,
    length: i64,
    generation: u64,
}

fn read_run(bytes: u8[:], run: Run, expected: u64) -> const u8[:] {
    assert(run.generation == expected);
    assert(run.start >= 0);
    assert(run.start <= bytes.len);
    assert(run.length >= 0);
    assert(run.length <= bytes.len - run.start);
    return bytes[run.start..run.start + run.length];
}

fn slice_pool_growth() {
    reusable[] var bytes: u8[>..] = [];
    var run = Run {
        start: 0,
        length: 3,
        generation: 1
    };
    {
        let initial = bytes.alloc_slice(run.length);
        run.start = bytes.index_of(initial[0]);
        initial[0] = 'o';
        initial[1] = 'l';
        initial[2] = 'd';
    }
    let blocker = bytes.alloc_slice(3);
    blocker[0] = 'x';
    let old_start = run.start;
    {
        let grown = bytes.realloc_slice(bytes[run.start..run.start + run.length], 12);
        run.start = bytes.index_of(grown[0]);
        run.length = grown.len;
        assert(run.start != old_start);
        assert(grown[..3] == "old");
        grown[3] = '!';
    }
    assert(read_run(bytes, run, 1)[..4] == "old!");
    bytes.free_slice(bytes[run.start..run.start + run.length]);
    run.generation += 1;
    {
        let replacement = bytes.alloc_slice(12);
        run.start = bytes.index_of(replacement[0]);
        run.length = replacement.len;
        for byte in replacement {
            assert(byte == 0);
        }
        replacement[0] = 'n';
    }
    assert(read_run(bytes, run, 2)[0] == 'n');
    assert(blocker[0] == 'x');
    bytes.free_slice(bytes[run.start..run.start + run.length]);
    bytes.free_slice(blocker);
}

fn::main() {
    continuation_pool_test::slice_pool_growth();
    print("continuation slice pool contracts passed");
}
