"""Tests for canvas/io/view.mojo: the two views are the pointer
operations they wrap, in either build. The checked build's abort
cannot be asserted from inside a test suite, since an abort ends the
process; `scripts/fuzz.sh` is what runs that build, and these tests
pass under `-D CANVAS_CHECKED_READS` too, which is the check that
every access here is in bounds.
"""

from std.testing import assert_equal, TestSuite

from canvas.io.view import _ReadView, _WriteView


def test_read_view_indexes_offsets_and_loads() raises:
    var xs = List[UInt8]()
    for i in range(40):
        xs.append(UInt8(i))
    var r = _ReadView(xs)
    assert_equal(r[0], 0)
    assert_equal(r[39], 39)
    var tail = r.offset(30)
    assert_equal(tail[0], 30)
    assert_equal(tail.offset(5)[4], 39)
    var v = r.load[DType.uint8, 16](4)
    assert_equal(v[0], 4)
    assert_equal(v[15], 19)
    var ints: List[Int] = [7, 8, 9]
    assert_equal(_ReadView(ints).offset(1)[1], 9)


def test_write_view_stores_where_the_list_reads() raises:
    var ys = List[UInt8](length=40, fill=0)
    var w = _WriteView(ys)
    w[3] = 7
    w.offset(10)[0] = 8
    w.store[DType.uint8, 16](20, SIMD[DType.uint8, 16](5))
    assert_equal(ys[3], 7)
    assert_equal(ys[10], 8)
    assert_equal(ys[20], 5)
    assert_equal(ys[35], 5)
    assert_equal(ys[36], 0)
    assert_equal(w[35], 5)
    assert_equal(w.load[DType.uint8, 4](33)[2], 5)
    var floats = List[Float32](length=8, fill=0.0)
    var wf = _WriteView(floats)
    wf.store[DType.float32, 8](0, SIMD[DType.float32, 8](1.5))
    assert_equal(floats[7], 1.5)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
