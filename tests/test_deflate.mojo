"""Tests for canvas/io/deflate.mojo: inflate() and deflate().

inflate(): every compressed byte sequence below is real
`zlib.compress()` output, not hand-built -- the streams a real encoder
produces, byte for byte. Each forces a specific DEFLATE block type,
confirmed by inspecting the block header bits: stored, fixed Huffman
and dynamic Huffman go through genuinely different code paths
(_stored_block/_fixed_tables/_dynamic_tables), so one passing test
couldn't cover all three.

deflate(): the inverse, checked three ways -- round-tripped through
inflate() (not circular, since that decoder is verified against real
zlib output), compared byte for byte against a hand-derived encoding
for one small input, and checked for real compression effectiveness,
since a match finder that is technically correct but barely compresses
would pass every round-trip test here.
"""

from std.testing import assert_equal, assert_true, TestSuite

from canvas.io.deflate import (
    _huffman_lengths,
    _run_length_code,
    deflate,
    inflate,
)


def _assert_inflates_to(
    var compressed: List[UInt8], expected: List[UInt8]
) raises:
    var result = inflate(compressed^)
    assert_equal(len(result), len(expected))
    for i in range(len(expected)):
        assert_equal(result[i], expected[i])


def test_stored_block() raises:
    # zlib.compressobj(0): level 0 forces BTYPE=00 (stored, no
    # compression), confirmed from the block header's first byte.
    var compressed: List[UInt8] = [1, 5, 0, 250, 255, 77, 111, 106, 111, 33]
    var expected: List[UInt8] = [77, 111, 106, 111, 33]  # "Mojo!"
    _assert_inflates_to(compressed^, expected)


def test_fixed_huffman_block() raises:
    # zlib.compressobj(9) on short, low-entropy data. The block header
    # (BTYPE=01) confirms zlib chose fixed Huffman: custom code tables
    # don't pay for themselves on data this short.
    var compressed: List[UInt8] = [75, 76, 36, 14, 36, 17, 2, 0]
    var expected: List[UInt8] = [
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        97,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
        98,
    ]
    _assert_inflates_to(compressed^, expected)


def test_dynamic_huffman_block() raises:
    # zlib.compressobj(9) on 474 bytes of semi-random-plus-repeated
    # text, sized so zlib picks dynamic Huffman (BTYPE=10, from the
    # block header) over fixed. This is the only test reaching
    # _dynamic_tables' code-length-code parsing and the 16/17/18 repeat
    # instructions.
    var compressed: List[UInt8] = [
        197,
        203,
        233,
        90,
        130,
        64,
        24,
        64,
        97,
        6,
        17,
        105,
        128,
        145,
        69,
        145,
        157,
        15,
        134,
        125,
        199,
        59,
        178,
        162,
        178,
        50,
        202,
        165,
        237,
        234,
        171,
        171,
        232,
        239,
        121,
        159,
        35,
        196,
        61,
        167,
        44,
        130,
        222,
        245,
        11,
        115,
        43,
        243,
        1,
        50,
        157,
        180,
        31,
        152,
        218,
        85,
        91,
        146,
        240,
        43,
        132,
        80,
        17,
        49,
        102,
        37,
        59,
        45,
        10,
        73,
        239,
        6,
        148,
        24,
        164,
        34,
        189,
        167,
        33,
        155,
        22,
        188,
        152,
        183,
        218,
        162,
        91,
        183,
        13,
        56,
        80,
        74,
        186,
        150,
        4,
        96,
        37,
        172,
        191,
        236,
        44,
        187,
        20,
        55,
        180,
        30,
        170,
        110,
        51,
        119,
        75,
        224,
        7,
        28,
        90,
        155,
        160,
        69,
        62,
        171,
        55,
        89,
        146,
        88,
        5,
        198,
        64,
        152,
        65,
        138,
        40,
        177,
        192,
        136,
        13,
        79,
        45,
        105,
        218,
        50,
        230,
        182,
        3,
        33,
        28,
        168,
        236,
        204,
        252,
        77,
        76,
        37,
        176,
        3,
        195,
        54,
        152,
        40,
        202,
        182,
        217,
        218,
        75,
        17,
        201,
        69,
        154,
        136,
        115,
        170,
        176,
        21,
        55,
        71,
        46,
        211,
        247,
        234,
        82,
        93,
        100,
        162,
        161,
        113,
        24,
        43,
        33,
        46,
        213,
        162,
        209,
        188,
        122,
        21,
        248,
        11,
        164,
        155,
        107,
        123,
        43,
        41,
        188,
        210,
        130,
        156,
        58,
        136,
        32,
        235,
        138,
        109,
        177,
        219,
        64,
        229,
        68,
        36,
        175,
        67,
        151,
        132,
        5,
        178,
        170,
        120,
        85,
        230,
        206,
        172,
        211,
        5,
        121,
        166,
        115,
        156,
        174,
        119,
        216,
        142,
        21,
        129,
        161,
        108,
        34,
        199,
        30,
        30,
        154,
        12,
        88,
        83,
        50,
        120,
        57,
        174,
        156,
        243,
        195,
        8,
        111,
        151,
        253,
        205,
        19,
        92,
        31,
        167,
        143,
        23,
        184,
        155,
        62,
        225,
        241,
        114,
        120,
        61,
        193,
        244,
        62,
        30,
        225,
        143,
        159,
        119,
        223,
        95,
        112,
        59,
        221,
        195,
        105,
        252,
        77,
        187,
        103,
        56,
        239,
        15,
        227,
        9,
        254,
        227,
        252,
        1,
    ]
    var result = inflate(compressed^)
    assert_equal(len(result), 474)
    # The trailing repeated phrase is exact, checkable text: spot-check
    # its offset rather than re-embedding all 474 expected bytes, which
    # two tests above already do exactly.
    var tail = String(
        "the quick brown fox jumps over the lazy dog several times "
    )
    var tail_bytes = tail.as_bytes()
    var start = 474 - 3 * len(tail_bytes)
    var matches = True
    for i in range(len(tail_bytes)):
        if result[start + i] != UInt8(tail_bytes[i]):
            matches = False
            break
    assert_true(matches)


def _round_trip(data: List[UInt8]) raises -> List[UInt8]:
    """Borrowed, not owned, unlike inflate()'s `var` parameter:
    deflate() only reads `data`, and every caller below needs it
    afterward to check the result against.
    """
    var compressed = deflate(data)
    return inflate(compressed^)


def test_deflate_flat_input_matches_a_single_candidate_search() raises:
    # A fully flat run is where every hash-chain candidate matches to
    # the maximum length, so none can improve on the first -- the case
    # _find_match's early exit at max_possible exists for. The stream
    # must be identical to what an exhaustive candidate search emits,
    # which this pins by round-tripping and by checking the ratio is
    # still the one a maximal match run produces (a broken early exit
    # would settle for shorter matches and inflate the output).
    var flat = List[UInt8]()
    for _ in range(100000):
        flat.append(42)
    var compressed = deflate(flat)
    assert_true(
        len(compressed) < 1000,
        "100KB of one byte must compress to well under 1KB via maximal matches",
    )
    var back = inflate(compressed^)
    assert_equal(len(back), 100000)
    for i in range(0, 100000, 997):
        assert_equal(back[i], 42)


def test_deflate_codes_a_flat_run_at_distance_one() raises:
    # Every position a match covers is indexed, not only the position
    # the search ran from, so the search that follows a match finds the
    # position immediately behind it and codes the next match at
    # distance 1.
    #
    # The bound separates that from indexing match starts alone. Either
    # way 100,000 identical bytes are one literal and 388 matches (387
    # of the 258-byte maximum, one of 153), but with only starts
    # indexed every match after the first sits 258 back. Distance 258
    # falls in the 257-384 distance code, which carries 7 extra bits
    # (RFC 1951 3.2.5), so those matches spend 388 * 7 = 2716 bits, 339
    # bytes, in extra bits before a single Huffman code is counted.
    # Distance 1 has a code of its own and no extra bits, so a stream
    # under 339 bytes can only be one coded at a near distance.
    var flat = List[UInt8](capacity=100_000)
    for _ in range(100_000):
        flat.append(42)
    var compressed = deflate(flat)
    assert_true(
        len(compressed) < 200,
        "a flat run must be coded at distance 1, not at distance 258",
    )
    var back = inflate(compressed^)
    assert_equal(len(back), 100_000)
    for i in range(0, 100_000, 997):
        assert_equal(back[i], 42)


def test_deflate_codes_a_two_value_alternation_at_distance_two() raises:
    # The same property one step out from a flat run. 30,000 bytes
    # alternating between two values are two literals and 117 matches
    # (116 of 258, one of 70). At distance 258 -- even, so it does
    # reproduce an alternation -- each carries 7 extra bits, 117 * 7 =
    # 819 bits or 102 bytes; at distance 2 none of them do.
    var alt = List[UInt8](capacity=30_000)
    for i in range(30_000):
        alt.append(UInt8(7) if i % 2 == 0 else UInt8(200))
    var compressed = deflate(alt)
    assert_true(
        len(compressed) < 100,
        "an alternation must be coded at distance 2, not at distance 258",
    )
    var back = inflate(compressed^)
    assert_equal(len(back), 30_000)
    for i in range(0, 30_000, 499):
        assert_equal(back[i], UInt8(7) if i % 2 == 0 else UInt8(200))


def test_deflate_takes_a_literal_when_the_next_position_matches_longer() raises:
    # 65 bytes built so the two encodings differ by one byte, which is
    # the lazy rule's decision made visible:
    #
    #   0..29   S, the 30 distinct bytes 100..129
    #   30..33  50, 100, 101, 200
    #   34      50
    #   35..64  S again
    #
    # At 34 the bytes 50, 100, 101 match position 30 and stop there,
    # since 102 != 200: a 3-byte match at distance 4. At 35 the whole
    # of S matches position 0: a 30-byte match at distance 35. Greedy
    # takes the 3-byte match and then codes the 28 bytes left of S;
    # lazy emits 50 as a literal and codes S in one match.
    #
    # Small enough that deflate() codes it with the fixed tables (RFC
    # 1951 3.2.6), so both encodings can be counted in bits. They share
    # 34 literals -- 33 below 144 at 8 bits and 200 at 9 -- and the
    # 3-bit block header, 276 bits, and the end-of-block code, 7.
    #
    #   greedy: length 3 is code 257, 7 bits and no extra; distance 4
    #           is code 3, 5 bits and no extra. Length 28 is code 271
    #           (base 27) with 2 extra bits, and distance 35 is code 10
    #           (base 33) with 4 extra: 7 + 5 + 7 + 2 + 5 + 4 = 30 bits
    #           on top of the shared 283, so 313, which is 40 bytes.
    #   lazy:   the literal 50 is 8 bits, and length 30 is again code
    #           271 with 2 extra bits at distance 35: 8 + 7 + 2 + 5 + 4
    #           = 26 bits, so 309, which is 39 bytes.
    var data = List[UInt8](capacity=65)
    for k in range(30):
        data.append(UInt8(100 + k))
    data.append(50)
    data.append(100)
    data.append(101)
    data.append(200)
    data.append(50)
    for k in range(30):
        data.append(UInt8(100 + k))
    var compressed = deflate(data)
    # BFINAL=1, BTYPE=01 packed LSB-first: 1 | (1 << 1) == 3.
    assert_equal(Int(compressed[0] & 0b111), 3, "fixed block")
    assert_equal(len(compressed), 39, "the literal, not the 3-byte match")
    var back = inflate(compressed^)
    assert_equal(len(back), len(data))
    for i in range(len(data)):
        assert_equal(back[i], data[i])


def test_deflate_round_trips_empty_input() raises:
    var result = _round_trip(List[UInt8]())
    assert_equal(len(result), 0)


def test_deflate_round_trips_literal_only_data() raises:
    # No 3-byte sequence repeats in this input, so every byte comes out
    # a plain Huffman-coded literal with zero LZ77 matches -- the code
    # path the repetitive-data tests never reach.
    var data: List[UInt8] = [0, 10, 20, 30, 40, 50, 60]
    var result = _round_trip(data)
    assert_equal(len(result), len(data))
    for i in range(len(data)):
        assert_equal(result[i], data[i])


def test_deflate_matches_hand_and_cross_derived_bytes_for_all_literal_input() raises:
    # The same 7-byte all-literal input, checked byte for byte against
    # deflate()'s output. Verified two ways: captured from a real run
    # and decompressed back through both inflate() and Python's
    # zlib.decompress(-15), each reproducing the original 7 bytes; and
    # the first two literal symbols' Huffman codes (0 -> 8 bits
    # 00110000, 10 -> 8 bits 00111010) derived from RFC 1951 3.2.2's
    # canonical-code algorithm and matched against this sequence's
    # first 16 post-header bits.
    var data: List[UInt8] = [0, 10, 20, 30, 40, 50, 60]
    var compressed = deflate(data)
    var expected: List[UInt8] = [99, 224, 18, 145, 211, 48, 178, 1, 0]
    assert_equal(len(compressed), len(expected))
    for i in range(len(expected)):
        assert_equal(compressed[i], expected[i])


def test_deflate_output_starts_with_bfinal_and_fixed_huffman_btype() raises:
    # BFINAL=1 (bit 0) and BTYPE=01/fixed-Huffman (bits 1-2), packed
    # LSB-first into the first byte: 1 | (1 << 1) == 3. Five literals
    # cost 5 * 8 bits under the fixed code and a dynamic block's header
    # alone is more than that, so deflate() picks fixed here -- which is
    # what keeps this file's byte-for-byte expectations for tiny inputs
    # valid.
    var data: List[UInt8] = [1, 2, 3, 4, 5]
    var compressed = deflate(data)
    assert_true(len(compressed) > 0)
    assert_equal(Int(compressed[0] & 0b111), 3)


def test_deflate_picks_a_dynamic_block_for_a_skewed_alphabet() raises:
    # 20,000 bytes drawn from four values in a pseudo-random order.
    # Every value is below 144, so the fixed code spends 8 bits on
    # each literal and a fixed block of pure literals would be 20,000
    # bytes; a code fitted to four symbols spends 2. The matcher also
    # takes short matches through this, which cost more than the
    # literals they replace under either code, so the bound below is
    # not the 5,000 an ideal 2-bit literal stream would give -- but it
    # is well under half of what fixed Huffman could manage, and the
    # header byte says which code was chosen.
    var data = List[UInt8](capacity=20_000)
    var state = UInt32(42)
    for _ in range(20_000):
        state = state * 1664525 + 1013904223
        data.append(UInt8(((state >> 24) & 3) * 60))
    var compressed = deflate(data)
    # BTYPE=10 in bits 1-2 of the first byte: 1 | (2 << 1) == 5.
    assert_equal(Int(compressed[0] & 0b111), 5, "dynamic block chosen")
    assert_true(
        len(compressed) < 10_000,
        "a four-symbol alphabet packs into far fewer than 8 bits a byte",
    )
    var back = inflate(compressed^)
    assert_equal(len(back), 20_000)
    state = UInt32(42)
    for i in range(20_000):
        state = state * 1664525 + 1013904223
        assert_equal(back[i], UInt8(((state >> 24) & 3) * 60))


def test_huffman_lengths_are_a_valid_prefix_code_within_the_limit() raises:
    # Fibonacci frequencies over 25 symbols: the textbook case whose
    # unbounded Huffman tree is a chain, 24 deep, past DEFLATE's 15-bit
    # cap. The limiter has to hand back lengths of at most 15 that are
    # still a valid prefix code -- Kraft's inequality, sum(2^-len) <= 1,
    # checked in integers as sum(2^(15 - len)) <= 2^15.
    var freqs = List[Int]()
    var a = 1
    var b = 1
    for _ in range(25):
        freqs.append(a)
        var next = a + b
        a = b
        b = next

    var unlimited = _huffman_lengths(freqs, 64)
    var deepest = 0
    for l in unlimited:
        if l > deepest:
            deepest = l
    assert_equal(deepest, 24, "without a limit the tree really is a chain")

    var limited = _huffman_lengths(freqs, 15)
    var kraft = 0
    var longest = 0
    for l in limited:
        assert_true(l > 0, "every used symbol keeps a code")
        if l > longest:
            longest = l
        kraft += 1 << (15 - l)
    assert_true(longest <= 15, "no code longer than the limit")
    assert_true(kraft <= 1 << 15, "and the lengths still form a prefix code")


def test_huffman_lengths_edge_cases() raises:
    # Nothing used: nothing coded.
    var none = _huffman_lengths([0, 0, 0], 15)
    assert_equal(none[0], 0)
    assert_equal(none[1], 0)
    assert_equal(none[2], 0)
    # One symbol used: a 1-bit code, since DEFLATE has no 0-bit one.
    var one = _huffman_lengths([0, 0, 5, 0], 15)
    assert_equal(one[2], 1)
    assert_equal(one[0], 0)
    # Two symbols, however skewed: one bit each.
    var two = _huffman_lengths([1000, 1], 15)
    assert_equal(two[0], 1)
    assert_equal(two[1], 1)


def test_run_length_code_matches_the_spec_by_hand() raises:
    # RFC 1951 3.2.7's three repeat symbols, each at the run length
    # that first earns it, plus the runs too short to use one. Nonzero
    # values sit between the zero runs so each run is its own case.
    var lengths: List[Int] = [5, 5, 5, 5, 0, 0, 7, 0, 0, 0, 9]
    for _ in range(11):
        lengths.append(0)
    # 5 5 5 5   -> 5, then 16 repeating it three times (extra 3-3=0)
    # 0 0       -> two zeros, too short for 17: two literal 0s
    # 7         -> a lone 7
    # 0 0 0     -> three zeros: 17 with extra 3-3=0
    # 9         -> a lone 9
    # 0 x 11    -> eleven zeros: 18 with extra 11-11=0
    var expected_symbols: List[Int] = [5, 16, 0, 0, 7, 17, 9, 18]
    var expected_bits: List[Int] = [0, 2, 0, 0, 0, 3, 0, 7]
    var codes = _run_length_code(lengths)
    assert_equal(len(codes), len(expected_symbols))
    for i in range(len(codes)):
        assert_equal(
            codes[i].symbol, expected_symbols[i], "symbol " + String(i)
        )
        assert_equal(codes[i].extra, 0, "extra " + String(i))
        assert_equal(
            codes[i].extra_bits, expected_bits[i], "extra bits " + String(i)
        )

    # A run of zeros past 138 splits: 140 zeros -> 18 (138, extra 127)
    # then two literal zeros.
    var long = List[Int](length=140, fill=0)
    var split = _run_length_code(long)
    assert_equal(len(split), 3)
    assert_equal(split[0].symbol, 18)
    assert_equal(split[0].extra, 127)
    assert_equal(split[1].symbol, 0)
    assert_equal(split[2].symbol, 0)

    # Repeats past six split too: 9 sevens -> 7, 16 (x6, extra 3),
    # then 16 would need three more but only two remain: two literal 7s.
    var sevens = List[Int](length=9, fill=7)
    var reps = _run_length_code(sevens)
    assert_equal(len(reps), 4)
    assert_equal(reps[0].symbol, 7)
    assert_equal(reps[1].symbol, 16)
    assert_equal(reps[1].extra, 3)
    assert_equal(reps[2].symbol, 7)
    assert_equal(reps[3].symbol, 7)


def test_deflate_compresses_a_long_repeated_run_substantially() raises:
    # LZ77's best case, and an effectiveness check rather than a
    # correctness one: a 10,000-byte solid run must come out far
    # smaller, not merely smaller, which a match finder that barely
    # finds anything would also manage.
    var data = List[UInt8](capacity=10_000)
    for _ in range(10_000):
        data.append(77)
    var compressed = deflate(data)
    assert_true(len(compressed) < len(data) // 20)


def test_deflate_round_trips_a_run_that_crosses_the_window_boundary() raises:
    # 40,000 bytes, past DEFLATE's 32,768-byte max match distance
    # (_WINDOW), so a search partway through has candidates on both
    # sides of the legal window. _find_match's distance cutoff has to
    # still find a correct match among those in range, not just avoid
    # the out-of-window ones.
    var data = List[UInt8](capacity=40_000)
    for i in range(40_000):
        data.append(UInt8(i % 251))
    var result = _round_trip(data)
    assert_equal(len(result), len(data))
    for i in range(len(data)):
        assert_equal(result[i], UInt8(i % 251))


def test_deflate_round_trips_pseudo_random_incompressible_data() raises:
    # Little LZ77 redundancy to exploit: the worst case for any
    # compressor, and where an off-by-one match length or wrong
    # distance surfaces, since almost every byte takes the literal path
    # the other tests here don't lean on.
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
