QOI fixtures are produced by running the moon encoder against
the PNG fixtures under ../png/. See testdata/qoi/_generate.mbt
(TODO: add a generator test that decodes each PNG, then calls
encode(image, ImageFormat::QOI), then writes the bytes here).
