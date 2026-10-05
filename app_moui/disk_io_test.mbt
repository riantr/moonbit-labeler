// app_moui/disk_io_test.mbt — Phase 5.22.
//
// Two kinds of test here, and the split is deliberate:
//
//   - **Pure** (extension / path / folder-name derivation): no disk,
//     exact-value assertions.
//   - **Disk** (scan / read / write): real files in `_build` and in
//     the repo's real `data/` dataset. These are the ones that
//     actually pin the Phase 5.22 claim, because the claim is "the
//     filesystem is reachable from a sync `update`" and only a real
//     read can establish that.
//
// The last test scans the shipped `data/Image@skin` folder. That is
// intentional: a synthetic fixture would have been written by the
// same code under test and would agree with it by construction.

///|
/// `extension_of` reports the last dot's suffix, lowercased, and
/// reports nothing for names that have no usable extension.
test "extension_of — handles case, dotfiles, and double extensions (5.22)" {
  assert_eq(extension_of("a.png"), "png")
  assert_eq(extension_of("a.PNG"), "png")
  assert_eq(extension_of("a.JpEg"), "jpeg")
  assert_eq(extension_of("archive.tar.gz"), "gz")
  // No dot at all.
  assert_eq(extension_of("README"), "")
  // Leading dot is not an extension: `.gitkeep` is a whole name.
  assert_eq(extension_of(".gitkeep"), "")
  // Trailing dot has nothing after it.
  assert_eq(extension_of("weird."), "")
}

///|
/// `media_kind` classifies by extension and folds case, so a
/// `.JPG` from a camera still lands in the image list. `None` (not a
/// third variant) is the "not media" answer.
test "media_kind — images, videos, and the ignored rest (5.22)" {
  assert_eq(media_kind("a.png"), Some(Image))
  assert_eq(media_kind("a.JPG"), Some(Image))
  assert_eq(media_kind("a.mp4"), Some(Video))
  assert_eq(media_kind("a.MOV"), Some(Video))
  // The real dataset dir has a .gitkeep in it; siblings like this are
  // ignored rather than failing the scan.
  assert_eq(media_kind(".gitkeep"), None)
  assert_eq(media_kind("classes.txt"), None)
}

///|
/// `join_path` never doubles the separator, which matters because
/// the caller passes user-typed folder paths that may or may not
/// already end in one.
test "join_path — exactly one separator, empty dir means bare name (5.22)" {
  assert_eq(join_path("a", "b.txt"), "a/b.txt")
  assert_eq(join_path("a/", "b.txt"), "a/b.txt")
  assert_eq(join_path("a\\", "b.txt"), "a\\b.txt")
  assert_eq(join_path("", "b.txt"), "b.txt")
}

///|
/// `strip_extension` keeps dotfiles whole — stripping `.gitkeep`
/// would turn it into the empty string.
test "strip_extension — drops the last extension only (5.22)" {
  assert_eq(strip_extension("a.jpg"), "a")
  assert_eq(strip_extension("archive.tar.gz"), "archive.tar")
  assert_eq(strip_extension("README"), "README")
  assert_eq(strip_extension(".gitkeep"), ".gitkeep")
}

///|
/// The label path convention, asserted against the **actual**
/// filenames in `data/`. `BIOMEDICA_P0_JCAS-4-2-g001.jpg` pairs
/// with `BIOMEDICA_P0_JCAS-4-2-g001.json` — extension stripped, not
/// `.jpg.json` appended. This test is the reason the convention is
/// known rather than guessed.
test "label_path_for — matches the real dataset convention (5.22)" {
  assert_eq(
    label_path_for("data/Image@skin/BIOMEDICA_P0_JCAS-4-2-g001.jpg", ""),
    "data/Image@skin/BIOMEDICA_P0_JCAS-4-2-g001.json",
  )
  assert_eq(
    label_path_for(
      "data/Image@skin/BIOMEDICA_P0_JCAS-4-2-g001.jpg", "data/Label@skin",
    ),
    "data/Label@skin/BIOMEDICA_P0_JCAS-4-2-g001.json",
  )
  // An explicit label folder wins over the image's own directory.
  assert_eq(
    label_path_for("C:/x/img/a.png", "C:/y/Label@x"),
    "C:/y/Label@x/a.json",
  )
}

///|
/// The `Image@<name>` / `Label@<name>` sibling convention. A folder
/// that is not named `Image@...` gets no guessed label folder — the
/// alternative is writing annotations into an unrelated directory.
test "sibling_label_folder — Image@ swaps to Label@, others opt out (5.22)" {
  assert_eq(sibling_label_folder("data/Image@skin"), "data/Label@skin")
  assert_eq(
    sibling_label_folder("data/Image@CARS.Part.01"),
    "data/Label@CARS.Part.01",
  )
  // Bare name, no separator.
  assert_eq(sibling_label_folder("Image@skin"), "Label@skin")
  // Not an Image@ folder -> no guess.
  assert_eq(sibling_label_folder("data/photos"), "")
  // A folder that merely contains "Image" is not a match.
  assert_eq(sibling_label_folder("data/MyImages"), "")
  // "Image@" with nothing after it has no name to carry over.
  assert_eq(sibling_label_folder("data/Image@"), "")
}

// ── disk-backed ────────────────────────────────────────────────────

///|
/// A missing label file is `None`, and that is the *normal* case for
/// an un-annotated image rather than an error.
test "read_label_text — missing file is None, not empty text (5.22)" {
  assert_eq(read_label_text("../_build/p522_absent_label.json"), None)
}

///|
/// write -> read round-trips exactly, including the JSON's braces
/// and quotes surviving byte-for-byte.
test "write_label_text then read_label_text — round-trips (5.22)" {
  let path = "../_build/p522_roundtrip.json"
  let text = "{\"img_name\":\"a.jpg\",\"infos\":[],\"bindings\":[]}"
  assert_eq(write_label_text(path, text), true)
  assert_eq(read_label_text(path), Some(text))
}

///|
/// Writing into a directory that does not exist fails cleanly
/// instead of raising. The caller surfaces this on the status bar;
/// auto-creating `Label@...` folders would hide a wrong layout.
test "write_label_text — missing directory reports failure (5.22)" {
  assert_eq(write_label_text("../_build/p522_no_such_dir/a.json", "{}"), false)
}

///|
/// The full read+parse path against a real file: one rect and one
/// keypoint come back as real `Annotation` values, with the class
/// name resolved through the class table.
test "load_label — reads and parses a real file into annotations (5.22)" {
  let path = "../_build/p522_load.json"
  let text =
    #|{"img_name":"a.jpg","infos":[
    #|{"id":"r1","shape":"rect","type":"knife","points":[[10,20],[30,40]]},
    #|{"id":"k1","shape":"keypoint","type":"knife","points":[[15,25]]}
    #|],"bindings":[]}
  ignore(write_label_text(path, text))
  let classes : Array[ClassEntry] = [
    { id: "c-knife", name: "knife", is_default: true, },
  ]
  let loaded = load_label(path, classes)
  match loaded {
    None => assert_true(false)
    Some((label, annotations, bindings)) => {
      assert_eq(annotations.length(), 2)
      assert_eq(bindings.length(), 0)
      assert_eq(annotations[0].id, "r1")
      assert_eq(annotations[0].shape, Rect)
      // The class name in the file resolved to an id, which is what
      // makes rename (Phase 5.19/5.21) work on a loaded label.
      assert_eq(annotations[0].class_id, "c-knife")
      assert_eq(annotations[1].shape, Keypoint)
      // The raw text is kept so a re-save cannot destroy a label
      // this build failed to fully understand.
      assert_eq(label.raw_json, text)
      assert_eq(label.dirty, false)
    }
  }
}

///|
/// A label file that exists but does not parse still comes back with
/// its **text intact**. This is the asymmetry that matters: the
/// canvas is blank either way, but only this branch can be re-saved
/// without destroying data.
test "load_label — corrupt JSON keeps raw text, yields no annotations (5.22)" {
  let path = "../_build/p522_corrupt.json"
  ignore(write_label_text(path, "{not json at all"))
  let loaded = load_label(path, [])
  match loaded {
    None => assert_true(false)
    Some((label, annotations, bindings)) => {
      assert_eq(annotations.length(), 0)
      assert_eq(bindings.length(), 0)
      assert_eq(label.raw_json, "{not json at all")
    }
  }
}

///|
/// `scan_folder` on a missing directory is `None` — the caller shows
/// "folder load failed", which is different from "folder is empty".
test "scan_folder — unreadable folder is None (5.22)" {
  match scan_folder("../_build/p522_no_such_folder") {
    None => ()
    Some(_) => assert_true(false)
  }
}

///|
/// A readable folder with no media in it is `Some` with two empty
/// lists, not `None`. Collapsing the two would make "empty project"
/// indistinguishable from "broken path".
///
/// This creates its **own** directory rather than reusing `_build`.
/// The first draft scanned `_build` on the assumption that a build
/// directory holds no images; it holds 173 of them (smoke captures),
/// and the assertion failed on the very first run. A shared build
/// directory is not a fixture — its contents move with whatever else
/// is running.
test "scan_folder — readable but empty folder is Some (5.22)" {
  let dir = "../_build/p522_empty_dir"
  // Fails harmlessly when the directory is already there from a
  // previous run; that is still a readable, empty directory.
  ignore(@xfs.create_dir(dir) catch { _ => () })
  match scan_folder(dir) {
    None => assert_true(false)
    Some(scan) => {
      assert_eq(scan.images.length(), 0)
      assert_eq(scan.videos.length(), 0)
      // An un-named folder has no Image@ sibling to derive from.
      assert_eq(scan.label_folder, "")
    }
  }
}

///|
/// **The end-to-end claim, against the shipped dataset.** Scans the
/// real `data/Image@skin` folder: six JPEGs are found, sorted, and the
/// label folder is derived as `data/Label@skin`.
test "scan_folder — the real data/Image@skin yields sorted images + Label@skin (5.22)" {
  match scan_folder("../data/Image@skin") {
    None => assert_true(false)
    Some(scan) => {
      assert_eq(scan.images.length(), 6)
      assert_eq(scan.videos.length(), 0)
      assert_eq(scan.label_folder, "../data/Label@skin")
      // Sorted, not filesystem order: the sidebar indexes this list
      // directly, so an unstable order would shuffle the UI. Uses
      // `name_less`, not `<` — see `name_less` for why.
      let mut previous : String = ""
      let mut first = true
      for img in scan.images {
        if !first {
          assert_true(name_less(previous, img.name))
        }
        previous = img.name
        first = false
        // Full path is usable as-is by label_path_for.
        assert_eq(
          label_path_for(img.path, scan.label_folder),
          "../data/Label@skin/" + strip_extension(img.name) + ".json",
        )
      }
    }
  }
}

///|
/// The real label file parses: the shipped
/// `BIOMEDICA_P0_JCAS-4-2-g001.json` has one rect and eight
/// keypoints, all of class `object`. This is the check that the
/// parser and the on-disk format actually agree — a synthetic
/// fixture written by this same code would agree by construction.
test "load_label — the real data/Label@skin JSON parses (5.22)" {
  let classes : Array[ClassEntry] = [
    { id: "c-object", name: "object", is_default: true, },
  ]
  let path = "../data/Label@skin/BIOMEDICA_P0_JCAS-4-2-g001.json"
  let loaded = load_label(path, classes)
  match loaded {
    None => assert_true(false)
    Some((_label, annotations, bindings)) => {
      assert_eq(annotations.length(), 9)
      assert_eq(bindings.length(), 0)
      assert_eq(annotations[0].shape, Rect)
      assert_eq(annotations[0].points.length(), 2)
      assert_eq(annotations[1].shape, Keypoint)
      assert_eq(annotations[1].points.length(), 1)
      assert_eq(annotations[0].class_id, "c-object")
    }
  }
}

///|
/// **MoonBit's `String.<` is length-first, not lexicographic.**
/// This is measured, not documented anywhere obvious, and it was
/// found by a failing index assertion: sorting the shipped dataset
/// put `BIOMEDICA_P0_JCAS-4-2-g001.jpg` (30 chars) first because it
/// is the shortest name, ahead of the `2-` series.
///
/// Pinned here so the next person does not re-derive it from a wrong
/// index. If a future toolchain makes `<` lexicographic this test
/// fails loudly, which is when `name_less` can be deleted.
test "MoonBit String.< compares length before content (5.22)" {
  // Shorter string is "less" even though 'c' > 'b' at position 1.
  assert_true("bb" < "ccc")
  // Equal length falls through to content, as one would expect.
  assert_true("bb" < "bc")
  assert_true("bc" > "bb")
}

///|
/// `name_less` is the lexicographic order a file list wants, and it
/// disagrees with `<` exactly where it matters.
///
/// **Neither order is universally right**, and this test records the
/// trade rather than pretending otherwise. MoonBit's length-first `<`
/// happens to give numbered scans the order people want
/// (`img1, img2, img10, img100`), while lexicographic gives
/// `img1, img10, img100, img2`. This dataset is not numbered — it is
/// series-named (`BIOMEDICA_P0_JCAS-4-2-g001.jpg`), where only
/// lexicographic reads correctly — so `scan_folder` uses
/// `name_less`. If the app ever points at numbered filenames, this is
/// the line to revisit.
test "name_less — lexicographic, unlike String.< (5.22)" {
  // Lexicographic: '1' (0x31) sorts before '2' (0x32), so img10
  // precedes img2. `<` says the opposite, because "img2.jpg" is one
  // character shorter — that single pair is the disagreement.
  assert_true(name_less("img10.jpg", "img2.jpg"))
  assert_true(!name_less("img2.jpg", "img10.jpg"))
  assert_true("img2.jpg" < "img10.jpg")
  assert_true(name_less("aa", "ab"))
  assert_true(!name_less("ab", "aa"))
  // The real disagreement that motivates the whole helper.
  assert_true(
    name_less(
      "BIOMEDICA_P0_JCAS-2-72-g003.jpg", "BIOMEDICA_P0_JCAS-4-2-g001.jpg",
    ),
  )
  assert_true(
    !name_less(
      "BIOMEDICA_P0_JCAS-4-2-g001.jpg", "BIOMEDICA_P0_JCAS-2-72-g003.jpg",
    ),
  )
  // A prefix sorts before the longer string that extends it.
  assert_true(name_less("abc", "abcd"))
  assert_true(!name_less("abc", "abc"))
}

///|
/// The sorted scan puts the labelled image at index 4, which is where
/// the handler tests below look for it. This asserts the order
/// explicitly so an ordering change fails with the order visible.
test "scan_folder — alphabetical order, labelled image at index 4 (5.22)" {
  match scan_folder("../data/Image@skin") {
    None => assert_true(false)
    Some(scan) => {
      assert_eq(scan.images[0].name, "BIOMEDICA_P0_JCAS-2-72-g003.jpg")
      assert_eq(scan.images[1].name, "BIOMEDICA_P0_JCAS-2-72-g007.jpg")
      assert_eq(scan.images[2].name, "BIOMEDICA_P0_JCAS-3-170-g001.jpg")
      assert_eq(scan.images[3].name, "BIOMEDICA_P0_JCAS-3-93-g004.jpg")
      assert_eq(scan.images[4].name, "BIOMEDICA_P0_JCAS-4-2-g001.jpg")
      assert_eq(scan.images[5].name, "BIOMEDICA_P0_JCAS-4-51-g001.jpg")
    }
  }
}

// ── handler wiring (5.22) ──────────────────────────────────────────
//
// The tests above prove the disk layer. These prove the app actually
// calls it — a correct `load_label` that nothing dispatches is the
// exact "dead control" shape that Phases 5.9 and 5.17 spent two
// phases removing from the UI.

///|
/// `LoadFolder` really scans: the shipped folder yields 6 images, the
/// derived label folder, and `currentIndex` 0 (not -1 — the folder is
/// not empty).
test "LoadFolder — scanning the real folder populates the model (5.22)" {
  let (model, _) = update(Model::new(), LoadFolder("../data/Image@skin"))
  assert_eq(model.images.length(), 6)
  assert_eq(model.videos.length(), 0)
  assert_eq(model.labelFolder, "../data/Label@skin")
  assert_eq(model.folder, "../data/Image@skin")
  assert_eq(model.currentIndex, 0)
}

///|
/// An unreadable folder reports the failure instead of leaving a
/// half-populated model: images stay empty and the toast carries the
/// reason.
test "LoadFolder — a bad path reports, does not half-load (5.22)" {
  let base = Model::new()
  let (model, _) = update(base, LoadFolder("../_build/p522_no_such_folder"))
  assert_eq(model.images.length(), 0)
  assert_eq(model.toastKind, Error)
  match model.toastMessage {
    Some(m) => assert_true(m.contains("p522_no_such_folder"))
    None => assert_true(false)
  }
}

///|
/// An empty-but-readable folder leaves `currentIndex` at -1, the
/// "no image" sentinel. Landing on 0 would highlight a row that does
/// not exist.
test "LoadFolder — an empty folder selects no image (5.22)" {
  let dir = "../_build/p522_empty_folder"
  ignore(@xfs.create_dir(dir) catch { _ => () })
  let (model, _) = update(Model::new(), LoadFolder(dir))
  assert_eq(model.images.length(), 0)
  assert_eq(model.currentIndex, -1)
}

///|
/// **The reachable feature.** Clicking the 5th row of the real folder
/// loads its real label: 9 annotations, and `loadedFromDisk` true.
/// This is the end-to-end claim of the whole phase — sidebar row ->
/// `SelectIndex` -> read -> parse -> model.
test "SelectIndex — picking a row loads that image's real label (5.22)" {
  let (loaded, _) = update(Model::new(), LoadFolder("../data/Image@skin"))
  // Sorted order puts BIOMEDICA_P0_JCAS-4-2-g001.jpg at index 4, and
  // that is the one image in the dataset that has a label file.
  assert_eq(loaded.images.length(), 6)
  assert_eq(loaded.images[4].name, "BIOMEDICA_P0_JCAS-4-2-g001.jpg")
  let (model, _) = update(loaded, SelectIndex(4))
  assert_eq(model.loadedFromDisk, true)
  assert_eq(model.annotations.length(), 9)
  assert_eq(model.bindings.length(), 0)
  assert_eq(
    model.labelPath,
    "../data/Label@skin/BIOMEDICA_P0_JCAS-4-2-g001.json",
  )
  assert_eq(model.currentIndex, 4)
}

///|
/// A row whose image has **no** label file is not an error: the canvas
/// is empty, `loadedFromDisk` is false, and the status says so rather
/// than raising a red toast for an unlabelled scan.
test "SelectIndex — a row with no label file loads empty, not broken (5.22)" {
  let (loaded, _) = update(Model::new(), LoadFolder("../data/Image@skin"))
  let (model, _) = update(loaded, SelectIndex(0))
  assert_eq(model.loadedFromDisk, false)
  assert_eq(model.annotations.length(), 0)
  assert_eq(model.currentIndex, 0)
  // The path is still recorded, so Save knows where to write.
  assert_eq(
    model.labelPath,
    "../data/Label@skin/BIOMEDICA_P0_JCAS-2-72-g003.json",
  )
  assert_true(model.statusMessage.contains("no label"))
}

///|
/// 5.18's invariant survives the load: the loaded label replaces
/// whatever was there, and switching to an unlabelled image clears it
/// again rather than leaving the previous image's annotations on
/// screen under the new name.
test "SelectIndex — switching does not carry the previous label (5.22)" {
  let (loaded, _) = update(Model::new(), LoadFolder("../data/Image@skin"))
  let (with_label, _) = update(loaded, SelectIndex(4))
  assert_eq(with_label.annotations.length(), 9)
  let (next, _) = update(with_label, SelectIndex(0))
  assert_eq(next.annotations.length(), 0)
  assert_eq(next.loadedFromDisk, false)
}

///|
/// The class name in a loaded label resolves through `model.classes`
/// when the class is present. `Model::new` seeds knife/gun/..., and
/// the real label says "object", which is deliberately *not* in that
/// list — so this asserts both halves: an unknown class leaves the id
/// empty (the canvas falls back to the annotation id) instead of
/// inventing one, and a known class resolves.
test "SelectIndex — loaded class names resolve through model.classes (5.22)" {
  let (loaded, _) = update(Model::new(), LoadFolder("../data/Image@skin"))
  // Every index below is length-guarded. An unguarded `annotations[0]`
  // panics, and a panic kills the whole blackbox executable — which
  // silently discards the results of every test that ran before it.
  assert_eq(loaded.images.length(), 6)
  let (model, _) = update(loaded, SelectIndex(4))
  assert_eq(model.loadedFromDisk, true)
  assert_eq(model.annotations.length(), 9)
  // "object" is not a demo class, so nothing resolved.
  assert_eq(model.annotations[0].class_id, "")
  // Same file, same parser, but now the class exists.
  let seeded = {
    ..loaded,
    classes: [{ id: "c-obj", name: "object", is_default: false, }],
  }
  let (resolved, _) = update(seeded, SelectIndex(4))
  assert_eq(resolved.annotations.length(), 9)
  assert_eq(resolved.annotations[0].class_id, "c-obj")
}

///|
/// `SaveLabel` writes the annotations to the path it read from, and
/// the file on disk is then readable back with the same content.
test "SaveLabel — writes to the path the label was read from (5.22)" {
  let (loaded, _) = update(Model::new(), LoadFolder("../data/Image@skin"))
  let (model, _) = update(loaded, SelectIndex(4))
  // Redirect at a scratch copy so the shipped dataset is not touched.
  let scratch = "../_build/p522_saved.json"
  let staged = { ..model, labelPath: scratch, }
  let (saved, _) = update(staged, SaveLabel)
  assert_true(saved.statusMessage.contains("Saved"))
  assert_eq(saved.label.dirty, false)
  let text = read_label_text(scratch)
  match text {
    None => assert_true(false)
    Some(t) => {
      // Re-reading what we wrote must round-trip to the same set.
      let (annotations, bindings) = parse_label_text(t, saved.classes)
      assert_eq(annotations.length(), 9)
      assert_eq(bindings.length(), 0)
    }
  }
}

///|
/// Saving before any image has been read is refused rather than
/// guessed at. `labelPath` is the only thing that says where to write,
/// so an empty one means "we do not know" — inventing a filename here
/// would drop a stray JSON into the working directory.
test "SaveLabel — refuses when no label path is known (5.22)" {
  let (model, _) = update(Model::new(), SaveLabel)
  assert_eq(model.label.dirty, false)
  assert_eq(model.statusMessage, "Save failed")
}

///|
/// A write into a directory that does not exist fails cleanly and
/// says so, instead of raising out of `update`.
test "SaveLabel — unwritable target reports failure (5.22)" {
  let base = Model::new()
  let staged = {
    ..base,
    labelPath: "../_build/p522_absent_dir/a.json",
    imageSource: "../_build/p522_absent_dir/a.jpg",
  }
  let (model, _) = update(staged, SaveLabel)
  assert_eq(model.statusMessage, "Save failed")
}
