// app_moui/image_cache_test.mbt — Phase 13 image cache tests.
//
// Tests the cache's key behavior: load-bytes injection, hit/miss
// lookup, malformed-input rejection, and clear(). Disk-based
// loading is Phase 14 — these tests work entirely on
// pre-decoded RGBA bytes.

///|
/// Build a tiny RGBA image as raw bytes (no codec involved).
/// 2 pixels wide × 1 pixel tall, R=255 G=0 B=0 A=255 then
/// R=0 G=255 B=0 A=255 — a hand-crafted red/green stripe.
fn tiny_rgba() -> Bytes {
  let bytes : Array[Byte] = []
  // Pixel 0: red opaque.
  bytes.push(b'\xFF') // R
  bytes.push(b'\x00') // G
  bytes.push(b'\x00') // B
  bytes.push(b'\xFF') // A
  // Pixel 1: green opaque.
  bytes.push(b'\x00') // R
  bytes.push(b'\xFF') // G
  bytes.push(b'\x00') // B
  bytes.push(b'\xFF') // A
  Bytes::from_array(bytes)
}

///|
/// Empty cache returns None for any key.
test "image_cache_empty_returns_none" {
  let cache : ImageCache = ImageCache::new()
  assert_eq(cache.get("any"), None)
}

///|
/// load_bytes stores the image and get retrieves it.
test "image_cache_load_bytes_then_get" {
  let cache : ImageCache = ImageCache::new()
  let data : Bytes = tiny_rgba()
  let result : DecodedImage? = cache.load_bytes("icon.png", 2, 1, data)
  // load_bytes succeeded.
  match result {
    Some(_) => ()
    None => fail("expected Some from load_bytes")
  }
  // get retrieves the same image.
  let hit : DecodedImage? = cache.get("icon.png")
  guard hit is Some(d) else { fail("expected Some from get") }
  assert_eq(d.width, 2)
  assert_eq(d.height, 1)
  // Data is byte-equal (Bytes equality is value-based).
  assert_eq(d.data == data, true)
}

///|
/// get_or_inject returns cached entry on hit, injects on miss.
test "image_cache_get_or_inject_hit_then_miss" {
  let cache : ImageCache = ImageCache::new()
  let data : Bytes = tiny_rgba()
  // First call: miss → inject.
  let first : DecodedImage? = cache.get_or_inject("foo.bmp", 2, 1, data)
  match first {
    Some(_) => ()
    None => fail("expected Some from get_or_inject (miss)")
  }
  // Second call: hit, returns same data without re-injecting.
  let second : DecodedImage? = cache.get_or_inject("foo.bmp", 99, 99, tiny_rgba())
  guard second is Some(d) else { fail("expected Some from get_or_inject (hit)") }
  // Hit returns the original (2, 1) not the requested (99, 99).
  assert_eq(d.width, 2)
  assert_eq(d.height, 1)
}

///|
/// load_bytes rejects width<=0, height<=0, and mismatched length.
test "image_cache_load_bytes_validates_input" {
  let cache : ImageCache = ImageCache::new()
  // Zero width.
  assert_eq(
    cache.load_bytes("bad.png", 0, 1, Bytes::new(0)) is None,
    true,
  )
  // Zero height.
  assert_eq(
    cache.load_bytes("bad.png", 1, 0, Bytes::new(0)) is None,
    true,
  )
  // Length mismatch: 2x1 needs 8 bytes, provide 4.
  assert_eq(
    cache.load_bytes("bad.png", 2, 1, Bytes::new(4)) is None,
    true,
  )
  // Negative width.
  assert_eq(
    cache.load_bytes("bad.png", -1, 1, Bytes::new(0)) is None,
    true,
  )
  // None of these failed loads should appear in the cache.
  assert_eq(cache.get("bad.png"), None)
}

///|
/// clear() empties the cache.
test "image_cache_clear_drops_entries" {
  let cache : ImageCache = ImageCache::new()
  let data : Bytes = tiny_rgba()
  let _ = cache.load_bytes("foo.png", 2, 1, data)
  match cache.get("foo.png") {
    Some(_) => ()
    None => fail("expected Some after load_bytes")
  }
  cache.clear()
  assert_eq(cache.get("foo.png"), None)
}
