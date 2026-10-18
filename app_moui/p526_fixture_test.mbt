// app_moui/p526_fixture_test.mbt — a self-contained on-disk dataset for
// the disk-layer tests.
//
// ── Why this exists ──────────────────────────────────────────────────────
//
// Sixteen tests in disk_io_test.mbt / image_decode_test.mbt /
// image_header_test.mbt used to read the shipped `data/` sample. Those
// directories are gitignored per-deployment data, so on a clean checkout
// all 16 failed with `0 != 6` and `moon test` could not gate CI at all.
//
// The original reason for not synthesising them was sound, and is worth
// keeping:
//
//   "A synthetic JPEG written by this file could not tell 'decoded the
//    file' from 'decoded the bytes I just handed it'; the read is the
//    part under test, so the file has to already exist."
//
// That argument requires the file to be **on disk**, not to be the
// shipped dataset. This module writes real files under `_build/` and the
// tests read them back through the same `@xfs` path, so the property
// under test is preserved. What is gone is only the dependency on files
// that do not travel with the repository.
//
// ── The six images are deliberately different sizes ──────────────────────
//
// The shipped sample's six JPEGs are six different *filenames* over one
// set of dimensions (517x371), so "the registered dimensions are the
// file's real ones" was satisfied by a hardcoded 517x371 just as well
// as by reading the header. These six have six different sizes
// (8x6 ... 14x11), so no constant can satisfy all of them: each image
// must report its own, and the decode tests assert the value per index.
//
// ── The PNGs are complete files, not header stubs ────────────────────────
//
// `png_header(w, h)` in image_header_test.mbt builds 33 bytes — enough
// for `png_dimensions`, useless for decoding. These are whole files:
// signature, IHDR, zlib-compressed IDAT, IEND, correct CRC-32s,
// produced once with Python's `zlib.compress` and embedded as hex.
//
// Same approach, and the same reason, as the 5.23 fixtures: a
// hand-rolled builder emitting *stored* deflate blocks with a
// hand-written CRC-32 fails to decode, because MoonBit's `Int` is
// 32-bit *signed* — `0xFFFFFFFF` is -1 and `>>` is an arithmetic
// shift, so a CRC state of -1 shifts to -1 forever and returns a wrong
// negative number with no error anywhere.
//
// The bytes are written with `@xfs.write_bytes_to_file`, not
// `write_string_to_file`: these files are binary, and routing them
// through String would re-encode every byte >= 0x80 as UTF-8 and
// corrupt the file.

// ── fixture images, in the order scan_folder must return them ─────────────

///|
/// (filename, hex, width, height).
fn p526_images() -> Array[(String, String, Int, Int)] {
  [
    (
      "BIOMEDICA_P0_JCAS-2-72-g003.jpg",
      "89504e470d0a1a0a0000000d4948445200000008000000060802000000716748ac0000008f4944415478da05c1310f81311000d04b9a8b2e954b439ab82e25392cb8048bfb062c18b060c0828589c9e6b77b0fc061f0d80ad88d384e38cfb82d7816849aa386a712681069966895e950e8260475c7ecb917781279917897f952f8290c4d276d2fc32016659de498e55ee42d02d969dfeb34e832ea3ee935ebabe857143ace46deaa609b68a7648f6c9f623fb13f3a9915c1f16d363d0000000049454e44ae426082",
      8,
      6,
    ),
    (
      "BIOMEDICA_P0_JCAS-2-72-g007.jpg",
      "89504e470d0a1a0a0000000d494844520000000900000007080200000055f9f037000000c04944415478da05c13d4b03301000d04038cc12398225e0654985531b500fac0e3d87dac2a983b643ebe0c7a00e7e0cd5455deca4939bbfd8f79cf31003ac47d84cb09f6158e0bcc215c36303b7e2712d608db8937090f1a4e0ace21de3a2a15bf54481b622f5131d67ba28745de989e9bd91eb78ee06de8dac894f33cf0bdf577e65fe6aec8a97ed200751464926596e8a3c57f960f96ee236bcee053d8a7a96f432eb43d1b7aa4bd6dfa6aee7ed30d838da34d96db697629fd57ed8fe9afd0360f320fb8a4b5e3d0000000049454e44ae426082",
      9,
      7,
    ),
    (
      "BIOMEDICA_P0_JCAS-3-170-g001.jpg",
      "89504e470d0a1a0a0000000d494844520000000b000000080802000000a05a92df000001014944415478da05c1b74a00301000d04008668984a004bc2c51384b4013303a780a1688052c010b58060b58060b58060b5806cba02eeaa2934e6efea0ef31c68592a2458976237aad187662da8b6514db411c47719d056be0ba496aaf74b7d103568f3b3deff53aeafda0cfa3becf9a357200091d0ab281110b330e563cec209c04b889f09c8135736c95d8a3900c4e585c70b8e1f100f122e043c4b78cccf1d429539f4aa326cddab4ead2ae4fa7986e437a89e93327d6c6294a1a54346968d1d2a6a3434f97488f81de237d67625dbcf4cb32a6ca9c296bb6ecb972e6cb1d96d750be62f9cd85255e87649d5275c9d42d5b8f5cbdf2f509eb47a83fb1fee5fa0f6ef0375988c77d750000000049454e44ae426082",
      11,
      8,
    ),
    (
      "BIOMEDICA_P0_JCAS-3-93-g004.jpg",
      "89504e470d0a1a0a0000000d494844520000000c00000009080200000089da5a030000013e4944415478da05c1cb4b10301c00e0c118ee3219a318b85da6f0331be8064d634ec117d382d2810fa825a4422ff001bec007f88252b007f438a81dd28b76c9939dbcf56ff57d0861c2286962a455900792f469f2c49067405e59b2ecc84e20c791a006ccef506e186f17bc5bf261cdc70d7f097cdef20dc7df07fe3572d48895a2ea1e5341a87ea99e6af5dca8d7a056acda75ea63502751a1bb189a297430480246244c689831b000b069e183836f017e45401afb36ea3b991f107e54faaafd1be357c1ef59ffc9f9d3e02fa3472d38399a7a587a24d2a44cb33a2d9ab405e9d0a6ef2e9d87f42726741fe72e9a07591e13f985cc6f755e33791ff2679bcf5cbe0af92666e471e9a5e5312b53a2ccc9b2a4cbb62947507ed872e1ca7528b7b1a087b80ed15a589d16f59dacebba1e98fa05ea4f5b7fbbfa37d47fb1fe07d5b34b857645f74e0000000049454e44ae426082",
      12,
      9,
    ),
    (
      "BIOMEDICA_P0_JCAS-4-2-g001.jpg",
      "89504e470d0a1a0a0000000d494844520000000d0000000a0802000000e08c43930000017a4944415478da05c1d98b08401c00e0a969322fa3695a4d997919eab79862a60c1ac3c4d2b8724cb1c450aec6518e6dd92d965ce5ca55ae5c65518e07c7035ef0c2134fdefc33be0f214c1825d319191464be24cb34596fc87620dd925147ce057223924799a029980f506e189f2bf862c95769bed9f0ddc08f587ecaf1cb81df8dfc79e6682a568aaa594c05a1964bb541ab1d461d0075c2aaf34edd0cea7154afb342d330cca0308f4112b05ac2160d7b0c1c05386de18a837b012623bccf8034f6b3a95fc0fc90f01ba56fda1f34fe24f80bd6df72fe49f06fa2ff9c3d9a8993a369094b6b441a9669af4ec74c9a8074d5a6fb2ebd08e9434cdf724273705948cb0a563689b2539643ba8c997211ca6d5b9ebaf236942fb1fccc05795c97d2ba96d5ada2ee93f5b8ae674cbd06f581ad2f5dfd18eaf7587fe78a16e1b692b6cada2ed10ecb36aedb25d3ee407b66db3bd7be86f62bb6bfb9a18cfb3adab7b1be5ff411d9cfea7eddf487d05fd9fec9f51fa1ff89fd5feeff0100cd640bfae24fbd0000000049454e44ae426082",
      13,
      10,
    ),
    (
      "BIOMEDICA_P0_JCAS-4-51-g001.jpg",
      "89504e470d0a1a0a0000000d494844520000000e0000000b0802000000c0e72b35000001be4944415478da05c1b7ab10311c00e0c011bc25120ee5c064890f7e96034dc0a89c7906351a1b96880d8d8a8dd8b0042b366c0f1b566c58b13cacd8c00696c132a88bbae8a4939bff82df8750814989fb10dcafc2436a3c8ae32902cf039c1abc51e23d1a1f6bf1458b6f3b8c7a14b4574905a1832a3aa2a6e3399d29e862a06b1bba5dd2839a9e69e9754b1f3a8a7a168c95ac3f61ba62a36b3695b3f982ad00b6a9617b253baed9a596ddb1ec9963a877017d4b184cc05430a186591c96085807b0a3814312ce6ab8d1c2230baf1d205ea801a51a4ad4984a4dab55e46aa5509b41ed6bd409a92e6b75b755cfad7aef14ea288c2c4d2731132b33bb364bb9592fcc4e30871b734e9a9bda3c6ecd1b6b3e3b8306167e58e91df1d32bbfa0f6abb8df22fc7ef0271b7f45fa7bdabf68fd07ebbf398f5411469661120973aab0ac0e1b78d825c21108e79b704b86273abc6dc3171b7eba808617716c1903890babb8ba8e5b793c20e22988579b785fc6973a7e6ce3771b7fbb886c912697692e49cbab94ebb49ba7a3225d80d4dda4a732bdd3e96b9b7ed9f4d72534aec833cabc88e43555de56e72e9e4f8b7c0df28326bf92f993ce3fdafcc7e67f2eff07676d81570cab412a0000000049454e44ae426082",
      14,
      11,
    ),
  ]
}

///|
/// The one labelled image, mirroring the shipped file's shape: a `rect`
/// then eight `keypoints`, all of class `object`, no bindings. The tests
/// assert on that exact count and on `annotations[0]` / `annotations[1]`
/// being different shapes, so this JSON's shape is part of what they
/// check -- it is not free to change.
fn p526_label_text() -> String {
  "{\"img_name\":\"BIOMEDICA_P0_JCAS-4-2-g001.json\",\"infos\":[" +
  "{\"id\":\"obj_fixture01\",\"shape\":\"rect\",\"type\":\"object\",\"points\":[[1,2],[3,4]]}," +
  "{\"id\":\"kp_fixture01\",\"shape\":\"keypoint\",\"type\":\"object\",\"points\":[[5,6]]}," +
  "{\"id\":\"kp_fixture02\",\"shape\":\"keypoint\",\"type\":\"object\",\"points\":[[7,8]]}," +
  "{\"id\":\"kp_fixture03\",\"shape\":\"keypoint\",\"type\":\"object\",\"points\":[[9,10]]}," +
  "{\"id\":\"kp_fixture04\",\"shape\":\"keypoint\",\"type\":\"object\",\"points\":[[11,12]]}," +
  "{\"id\":\"kp_fixture05\",\"shape\":\"keypoint\",\"type\":\"object\",\"points\":[[13,14]]}," +
  "{\"id\":\"kp_fixture06\",\"shape\":\"keypoint\",\"type\":\"object\",\"points\":[[15,16]]}," +
  "{\"id\":\"kp_fixture07\",\"shape\":\"keypoint\",\"type\":\"object\",\"points\":[[17,18]]}," +
  "{\"id\":\"kp_fixture08\",\"shape\":\"keypoint\",\"type\":\"object\",\"points\":[[19,20]]}" +
  "],\"bindings\":[]}"
}

///|
/// Root of the generated dataset. `_build/` is gitignored and already
/// used for scratch by disk_io_test (`p522_empty_folder`,
/// `p522_saved.json`), so this claims no new territory.
fn p526_root() -> String {
  "../_build/p526_fixture"
}

fn p526_image_folder() -> String {
  p526_root() + "/Image@skin"
}

fn p526_label_folder() -> String {
  p526_root() + "/Label@skin"
}

///|
/// Read a file as bytes, `None` when it cannot be read. Mirrors
/// `read_label_text` in disk_io.mbt: the `catch` arm returns, so both
/// paths agree on the type.
fn p526_read_bytes(path : String) -> Bytes? {
  let data = @xfs.read_file_to_bytes(path) catch { _ => return None }
  Some(data)
}

///|
/// Write `path` unless it already holds `expected`.
///
/// Compares by length rather than content, which is enough here: the
/// fixture is byte-identical on every run, so a length match means the
/// write already happened. Read as bytes rather than as a String --
/// these are binary files, and a String read of a PNG can fail on
/// invalid UTF-8 and make the caller rewrite forever.
fn p526_write_if_absent(path : String, expected : Bytes) -> Unit {
  match p526_read_bytes(path) {
    Some(actual) => if (actual.length() == expected.length()) { return }
    None => ()
  }
  ignore(@xfs.write_bytes_to_file(path, expected) catch { _ => () })
}

///|
/// Same, for the label file, which is plain JSON and therefore goes
/// through the String API.
///
/// The images and the label deliberately take **different** paths: the
/// images are binary and would be corrupted by a String round trip
/// (every byte >= 0x80 becomes two UTF-8 bytes), while the label is
/// ASCII text that a String write carries faithfully. An earlier
/// version pushed the label through the image hex decoder, which wrote
/// garbage and made every label-parsing test fail with `0 != 9`.
///
/// This compares content rather than mere presence, which is what lets
/// it repair that garbage: a binary file read as a String still comes
/// back as Some, so a presence check would skip the rewrite forever.
fn p526_write_label_if_absent(path : String, text : String) -> Unit {
  match read_label_text(path) {
    Some(existing) => if (existing == text) { return }
    None => ()
  }
  ignore(@xfs.write_string_to_file(path, text) catch { _ => () })
}

///|
/// Write the dataset to disk if it is not already there, and return the
/// image folder.
///
/// `create_dir` is **not** recursive, so each level is created in turn;
/// the first version of this function created only the leaves and every
/// write silently failed with "error code 3", leaving the fixture absent
/// and the decode tests failing on `None`.
fn p526_materialise() -> String {
  let root = p526_root()
  let images = p526_image_folder()
  let labels = p526_label_folder()
  ignore(@xfs.create_dir(root) catch { _ => () })
  ignore(@xfs.create_dir(images) catch { _ => () })
  ignore(@xfs.create_dir(labels) catch { _ => () })
  for (name, hex, _w, _h) in p526_images() {
    p526_write_if_absent(images + "/" + name, p526_hex(hex))
  }
  p526_write_label_if_absent(
    labels + "/BIOMEDICA_P0_JCAS-4-2-g001.json",
    p526_label_text(),
  )
  images
}

///|
/// Hex to `Bytes`. A straight conversion: no decoding, so the fixture
/// cannot depend on the code under test.
fn p526_hex(hex : String) -> Bytes {
  let chars : Array[Char] = hex.to_array()
  let out : Array[Byte] = []
  let mut i : Int = 0
  while i + 1 < chars.length() {
    out.push((p526_hexval(chars[i]) * 16 + p526_hexval(chars[i + 1])).to_byte())
    i = i + 2
  }
  Bytes::from_array(out)
}

///|
fn p526_hexval(c : Char) -> Int {
  if c >= '0' && c <= '9' {
    c.to_int() - '0'.to_int()
  } else if c >= 'a' && c <= 'f' {
    c.to_int() - 'a'.to_int() + 10
  } else {
    c.to_int() - 'A'.to_int() + 10
  }
}

///|
/// The generated files are real images. Without this, the fixture could
/// silently decay into something `scan_folder` lists but nothing decodes,
/// and the decode tests would then pass for the wrong reason.
test "p526 fixture — the generated images really decode (5.26)" {
  let folder = p526_materialise()
  for (name, _hex, w, h) in p526_images() {
    match load_image_into_cache(folder + "/" + name) {
      None => assert_true(false)
      Some((gw, gh)) => {
        assert_eq(gw, w)
        assert_eq(gh, h)
      }
    }
  }
}

///|
/// Every image has a distinct size, which is the whole point: a
/// hardcoded dimension cannot satisfy all six.
test "p526 fixture — the six images have six distinct sizes (5.26)" {
  let folder = p526_materialise()
  let seen : Array[(Int, Int)] = []
  for (name, _hex, _w, _h) in p526_images() {
    match load_image_into_cache(folder + "/" + name) {
      None => assert_true(false)
      Some((w, h)) => {
        assert_true(!seen.contains((w, h)))
        seen.push((w, h))
      }
    }
  }
  assert_eq(seen.length(), 6)
}

///|
/// The fixture lives where the sort and sibling-folder tests expect, and
/// is not the shipped dataset.
test "p526 fixture — lives under _build, not data (5.26)" {
  assert_true(p526_image_folder().contains("_build"))
  assert_true(!p526_image_folder().contains("/data/"))
  assert_eq(sibling_label_folder(p526_image_folder()), p526_label_folder())
}