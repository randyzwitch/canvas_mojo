"""Tests for canvas_mojo/io/deflate.mojo: inflate() (decompression)
and deflate() (compression).

inflate(): every compressed byte sequence below is real
`zlib.compress()` output (Python's stdlib zlib, itself wrapping the
same C zlib every other tool uses), not hand-built -- these are the
actual streams a real encoder produces, byte for byte, not a synthetic
approximation of one. Each was chosen to force a specific DEFLATE
block type (confirmed by inspecting the block header bits before
trusting it as "the fixed-Huffman case" or "the dynamic-Huffman
case"): stored, fixed Huffman, and dynamic Huffman are all exercised
separately, since they're decoded by genuinely different code paths
(_stored_block/_fixed_tables/_dynamic_tables) that a single passing
test couldn't confirm all three of. See canvas_mojo/io/deflate.mojo's
own docstring for how the decoder itself was verified (round-tripping
real zlib output, not just these three vectors -- large multi-block
and larger dynamic-Huffman streams were also checked via probe before
this file was written).

deflate(): the inverse direction, checked the same rigorous way in
reverse -- round-tripped back through inflate() above (real, since
that decoder is independently verified against real zlib output, not
circular), an exact hand-and-cross-derived byte comparison for one
small input (see that test's own docstring for exactly how those bytes
were confirmed), and a real compression-effectiveness check (not just
"round-trips correctly" -- a match finder that's technically correct
but barely compresses anything would still pass every round-trip test
here).
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas_mojo.io.deflate import deflate, inflate


def _assert_inflates_to(var compressed: List[UInt8], expected: List[UInt8]) raises:
    var result = inflate(compressed^)
    assert_equal(len(result), len(expected))
    for i in range(len(expected)):
        assert_equal(result[i], expected[i])


def test_stored_block() raises:
    # zlib.compressobj(0) -- level 0 forces BTYPE=00 (stored, no
    # compression). Confirmed via the block header's own first byte
    # before trusting this as "the stored-block test".
    var compressed: List[UInt8] = [1, 5, 0, 250, 255, 77, 111, 106, 111, 33]
    var expected: List[UInt8] = [77, 111, 106, 111, 33]  # "Mojo!"
    _assert_inflates_to(compressed^, expected)


def test_fixed_huffman_block() raises:
    # zlib.compressobj(9) on short, low-entropy data -- confirmed via
    # the block header (BTYPE=01) that zlib chose fixed Huffman here
    # rather than dynamic (custom code tables aren't worth their own
    # overhead for data this short and simple).
    var compressed: List[UInt8] = [75, 76, 36, 14, 36, 17, 2, 0]
    var expected: List[UInt8] = [
        97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97,
        97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97,
        98, 98, 98, 98, 98, 98, 98, 98, 98, 98, 98, 98, 98, 98, 98, 98, 98, 98, 98, 98,
        98, 98, 98, 98, 98, 98, 98, 98, 98, 98, 98, 98, 98,
    ]
    _assert_inflates_to(compressed^, expected)


def test_dynamic_huffman_block() raises:
    # zlib.compressobj(9) on 474 bytes of semi-random-plus-repeated-text
    # data, specifically chosen for enough size/complexity that zlib's
    # own encoder picks dynamic Huffman (BTYPE=10, confirmed via the
    # block header) over fixed -- this exercises _dynamic_tables'
    # own code-length-code parsing and the 16/17/18 repeat instructions,
    # which neither the stored nor fixed-Huffman test above touches at
    # all.
    var compressed: List[UInt8] = [
        197, 203, 233, 90, 130, 64, 24, 64, 97, 6, 17, 105, 128, 145, 69, 145, 157,
        15, 134, 125, 199, 59, 178, 162, 178, 50, 202, 165, 237, 234, 171, 171, 232, 239,
        121, 159, 35, 196, 61, 167, 44, 130, 222, 245, 11, 115, 43, 243, 1, 50, 157,
        180, 31, 152, 218, 85, 91, 146, 240, 43, 132, 80, 17, 49, 102, 37, 59, 45,
        10, 73, 239, 6, 148, 24, 164, 34, 189, 167, 33, 155, 22, 188, 152, 183, 218,
        162, 91, 183, 13, 56, 80, 74, 186, 150, 4, 96, 37, 172, 191, 236, 44, 187,
        20, 55, 180, 30, 170, 110, 51, 119, 75, 224, 7, 28, 90, 155, 160, 69, 62,
        171, 55, 89, 146, 88, 5, 198, 64, 152, 65, 138, 40, 177, 192, 136, 13, 79,
        45, 105, 218, 50, 230, 182, 3, 33, 28, 168, 236, 204, 252, 77, 76, 37, 176,
        3, 195, 54, 152, 40, 202, 182, 217, 218, 75, 17, 201, 69, 154, 136, 115, 170,
        176, 21, 55, 71, 46, 211, 247, 234, 82, 93, 100, 162, 161, 113, 24, 43, 33,
        46, 213, 162, 209, 188, 122, 21, 248, 11, 164, 155, 107, 123, 43, 41, 188, 210,
        130, 156, 58, 136, 32, 235, 138, 109, 177, 219, 64, 229, 68, 36, 175, 67, 151,
        132, 5, 178, 170, 120, 85, 230, 206, 172, 211, 5, 121, 166, 115, 156, 174, 119,
        216, 142, 21, 129, 161, 108, 34, 199, 30, 30, 154, 12, 88, 83, 50, 120, 57,
        174, 156, 243, 195, 8, 111, 151, 253, 205, 19, 92, 31, 167, 143, 23, 184, 155,
        62, 225, 241, 114, 120, 61, 193, 244, 62, 30, 225, 143, 159, 119, 223, 95, 112,
        59, 221, 195, 105, 252, 77, 187, 103, 56, 239, 15, 227, 9, 254, 227, 252, 1,
    ]
    var result = inflate(compressed^)
    assert_equal(len(result), 474)
    # The trailing repeated phrase is exact, hand-checkable text --
    # spot-check it landed at the right offset rather than re-embedding
    # all 474 expected bytes for a test this file already has two
    # exact-match versions of above.
    var tail = String("the quick brown fox jumps over the lazy dog several times ")
    var tail_bytes = tail.as_bytes()
    var start = 474 - 3 * len(tail_bytes)
    var matches = True
    for i in range(len(tail_bytes)):
        if result[start + i] != UInt8(tail_bytes[i]):
            matches = False
            break
    assert_true(matches)


def _round_trip(data: List[UInt8]) raises -> List[UInt8]:
    """Borrowed, not owned, unlike inflate()'s own `var` parameter --
    deflate() itself only reads `data` (see its own signature), so
    there's nothing to transfer, and every caller below still needs
    its own `data` afterward to check the result against.
    """
    var compressed = deflate(data)
    return inflate(compressed^)


def test_deflate_round_trips_empty_input() raises:
    var result = _round_trip(List[UInt8]())
    assert_equal(len(result), 0)


def test_deflate_round_trips_literal_only_data() raises:
    # No 3-byte sequence repeats anywhere in this input, so every byte
    # must come out the other end as a plain Huffman-coded literal --
    # zero LZ77 matches, a real code path (not just the repetitive-data
    # one) this test exists specifically to exercise.
    var data: List[UInt8] = [0, 10, 20, 30, 40, 50, 60]
    var result = _round_trip(data)
    assert_equal(len(result), len(data))
    for i in range(len(data)):
        assert_equal(result[i], data[i])


def test_deflate_matches_hand_and_cross_derived_bytes_for_all_literal_input() raises:
    # The same 7-byte all-literal input as the test above, but checked
    # byte-for-byte against deflate()'s own actual output -- verified
    # two independent ways before being locked in here (see this
    # file's own module docstring for the general standard, and
    # canvas_mojo/io/deflate.mojo's own module docstring for how
    # deflate() itself is verified): (1) captured from a real run,
    # decompressed back through both inflate() and Python's separate
    # zlib.decompress(-15), both reproducing the original 7 bytes
    # exactly; (2) the first two literal symbols' own Huffman codes
    # (0 -> 8 bits 00110000, 10 -> 8 bits 00111010) hand-derived from
    # RFC 1951 3.2.2's own canonical-code algorithm and confirmed to
    # match this exact byte sequence's own first 16 post-header bits,
    # bit for bit.
    var data: List[UInt8] = [0, 10, 20, 30, 40, 50, 60]
    var compressed = deflate(data)
    var expected: List[UInt8] = [99, 224, 18, 145, 211, 48, 178, 1, 0]
    assert_equal(len(compressed), len(expected))
    for i in range(len(expected)):
        assert_equal(compressed[i], expected[i])


def test_deflate_output_starts_with_bfinal_and_fixed_huffman_btype() raises:
    # BFINAL=1 (bit 0) and BTYPE=01/fixed-Huffman (bits 1-2), packed
    # LSB-first into the very first byte -- deflate()'s own docstring
    # promise that it always emits exactly one fixed-Huffman block.
    # 1 | (1 << 1) == 3.
    var data: List[UInt8] = [1, 2, 3, 4, 5]
    var compressed = deflate(data)
    assert_true(len(compressed) > 0)
    assert_equal(Int(compressed[0] & 0b111), 3)


def test_deflate_compresses_a_long_repeated_run_substantially() raises:
    # LZ77's own best case -- a real compression-effectiveness check,
    # not just a round-trip correctness one: a 10,000-byte solid run
    # must come out far smaller than the input, not merely "some
    # smaller size" (that alone wouldn't catch a match finder that's
    # technically correct but barely finds anything).
    var data = List[UInt8](capacity=10_000)
    for _ in range(10_000):
        data.append(77)
    var compressed = deflate(data)
    assert_true(len(compressed) < len(data) // 20)


def test_deflate_round_trips_a_run_that_crosses_the_window_boundary() raises:
    # 40,000 bytes -- past DEFLATE's own 32,768-byte max match distance
    # (_WINDOW), so a match search partway through this input has
    # candidates both inside and outside the legal window; confirms
    # _find_match's own distance cutoff doesn't just avoid crashing on
    # an out-of-window candidate but still finds a *correct* match
    # among the ones that remain in range.
    var data = List[UInt8](capacity=40_000)
    for i in range(40_000):
        data.append(UInt8(i % 251))
    var result = _round_trip(data)
    assert_equal(len(result), len(data))
    for i in range(len(data)):
        assert_equal(result[i], UInt8(i % 251))


def test_deflate_round_trips_pseudo_random_incompressible_data() raises:
    # Little to no LZ77 redundancy to exploit -- the worst case for any
    # compressor, and specifically where a match-finder bug (an
    # off-by-one in a match length, a wrong distance) would be likeliest
    # to surface, since almost every byte takes the literal path instead
    # of the match path this file's other tests already lean on.
    var data = List[UInt8](capacity=20_000)
    var state = UInt32(42)
    for _ in range(20_000):
        state = state * 1664525 + 1013904223
        data.append(UInt8((state >> 24) & 0xFF))
    var result = _round_trip(data)
    assert_equal(len(result), len(data))
    var i = 0
    state = UInt32(42)
    while i < len(data):
        state = state * 1664525 + 1013904223
        assert_equal(result[i], UInt8((state >> 24) & 0xFF))
        i += 1


def test_invalid_block_type_raises() raises:
    # BFINAL=1, BTYPE=11 (reserved/invalid) packed into the first byte's
    # low 3 bits: 1 | (3 << 1) = 0b111 = 7.
    var compressed: List[UInt8] = [7]
    var raised = False
    try:
        var result = inflate(compressed^)
        _ = result
    except:
        raised = True
    assert_true(raised)


def test_truncated_stream_raises() raises:
    # A stored-block header claiming a length far beyond the bytes
    # actually available.
    var compressed: List[UInt8] = [1, 255, 255, 0, 0]
    var raised = False
    try:
        var result = inflate(compressed^)
        _ = result
    except:
        raised = True
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
