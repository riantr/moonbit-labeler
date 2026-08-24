# Gherkin spec for the image codec stack
#
# These are plain Gherkin (.feature) files; the matching step definitions
# live in tests/gherkin/steps.mbt and run under `moon test --target
# native`. Each scenario is one `test "..."` in MoonBit and the step
# phrases are matched by string prefix.

Feature: Detect image format from magic bytes
  As a consumer of `detect_format`
  I want every recognised format to be picked out from its magic
  So that I can branch on the result before allocating a decoder

  Scenario: PNG signature is detected
    Given a PNG signature b"\x89PNG\r\n\x1a\n"
    When I call detect_format
    Then the result is Some(PNG)

  Scenario: QOI signature is detected
    Given a QOI signature b"qoif\x00\x00\x00\x01"
    When I call detect_format
    Then the result is Some(QOI)

  Scenario: BMP signature is detected
    Given a BMP signature b"BM\x36\x00\x00\x00\x00\x00\x00"
    When I call detect_format
    Then the result is Some(BMP)

  Scenario: JPEG signature is detected
    Given a JPEG SOI b"\xFF\xD8\xFF\xE0\x00\x10JFIF"
    When I call detect_format
    Then the result is Some(JPEG)

  Scenario: ICO signature is detected
    Given an ICO signature b"\x00\x00\x01\x00\x01\x00\x10\x10\x00\x00\x00\x00"
    When I call detect_format
    Then the result is Some(ICO)

  Scenario: TIFF little-endian signature is detected
    Given a TIFF II signature b"II\x2A\x00\x00\x00\x00\x00"
    When I call detect_format
    Then the result is Some(TIFF)

  Scenario: Garbage input is rejected
    Given the input b"not a header"
    When I call detect_format
    Then the result is None

Feature: Decode errors are categorised
  As an error-handling layer
  I want every failure to carry a typed DecodeError variant
  So that I can map them to user-facing messages

  Scenario: Unknown format raises UnsupportedFormat
    Given the input b"definitely not an image"
    When I call decode
    Then it raises DecodeError::UnsupportedFormat

  Scenario: Corrupt BMP raises InvalidHeader
    Given the input b"BM\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    When I call decode
    Then it raises DecodeError::InvalidHeader

  Scenario: Encode of PNG raises EncodeNotImplemented
    Given a 1x1 red RGB8 image
    When I call encode with PNG
    Then it raises DecodeError::EncodeNotImplemented

Feature: Image round-trip
  As a caller who wants predictable output
  I want encode(decode(x)) to produce the same image as decode(x)
  So that the codec is stable across a save / load cycle

  Scenario: BMP round-trip preserves dimensions and pixel data
    Given a 1x1 red RGB8 image
    When I encode to BMP and decode back
    Then the decoded image equals the original

  Scenario: QOI round-trip preserves dimensions and pixel data
    Given a 1x1 red RGB8 image
    When I encode to QOI and decode back
    Then the decoded image equals the original