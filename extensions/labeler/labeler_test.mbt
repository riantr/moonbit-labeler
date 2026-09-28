// White-box tests for the labeler extension's pure parsers and
// helpers. The async drivers (`import_voc_internal` etc.) are
// exercised end-to-end by the black-box harness in qa/.
//
// Coverage in this file:
//   - xml_find_element / xml_element_text (handles attrs, self-close,
//     missing tag, nested elements)
//   - parse_voc_xml (single object, multi-object, difficult flag,
//     invalid box, missing name)
//   - parse_yolo_lines (basic 5-tuple, 6-tuple with confidence,
//     out-of-range class id, normalised bbox denormalisation)
//   - import_split_lines / import_split_whitespace (handles CRLF,
//     trailing empty line, multiple separators)

///|
test "xml_find_element returns body offset pair for simple tag" {
  let s = "<root><name>cat</name><tail/></root>"
  let (bs, be) = xml_find_element(s, 0, "name")
  assert_eq(bs, 12)
  assert_eq(be, 15)
}

///|
test "xml_find_element handles element with attributes" {
  let s = "<root><bndbox x1=\"1\"><xmin>5</xmin></bndbox></root>"
  let (bs, be) = xml_find_element(s, 0, "xmin")
  // Body of `<xmin>` (between `>` and `<`) starts at offset 27, ends
  // at offset 28 (just before the `</xmin>` closing tag).
  assert_eq(bs, 27)
  assert_eq(be, 28)
}

///|
test "xml_find_element returns -1 for self-closing tag" {
  let s = "<root><note/></root>"
  let (bs, be) = xml_find_element(s, 0, "note")
  assert_eq(bs, -1)
  assert_eq(be, -1)
}

///|
test "xml_find_element returns -1 for missing tag" {
  let s = "<root><other>x</other></root>"
  let (bs, be) = xml_find_element(s, 0, "missing")
  assert_eq(bs, -1)
  assert_eq(be, -1)
}

///|
test "xml_element_text returns trimmed body" {
  let s = "<root><name>  cat  </name></root>"
  assert_eq(xml_element_text(s, "name"), "cat")
}

///|
test "parse_voc_xml single object basic" {
  let xml =
    #|<annotation>
    #|  000001.jpg</filename>
    #|  <object>
    #|    <name>cat</name>
    #|    <bndbox>
    #|      <xmin>1</xmin><ymin>2</ymin>
    #|      <xmax>100</xmax><ymax>200</ymax>
    #|    </bndbox>
    #|  </object>
    #|</annotation>
  let anns = parse_voc_xml(xml)
  assert_eq(anns.length(), 1)
  assert_eq(anns[0].type_, "cat")
  assert_eq(anns[0].shape, "rect")
  assert_eq(anns[0].points.length(), 2)
  assert_eq(anns[0].points[0].0, 1.0)
  assert_eq(anns[0].points[0].1, 2.0)
  assert_eq(anns[0].points[1].0, 100.0)
  assert_eq(anns[0].points[1].1, 200.0)
}

///|
test "parse_voc_xml multi-object with difficult flag" {
  let xml =
    #|<annotation>
    #|  <object>
    #|    <name>person</name>
    #|    <difficult>1</difficult>
    #|    <bndbox>
    #|      <xmin>10</xmin><ymin>20</ymin>
    #|      <xmax>110</xmax><ymax>220</ymax>
    #|    </bndbox>
    #|  </object>
    #|  <object>
    #|    <name>dog</name>
    #|    <bndbox>
    #|      <xmin>300</xmin><ymin>400</ymin>
    #|      <xmax>350</xmax><ymax>450</ymax>
    #|    </bndbox>
    #|  </object>
    #|</annotation>
  let anns = parse_voc_xml(xml)
  assert_eq(anns.length(), 2)
  assert_eq(anns[0].type_, "person")
  assert_eq(anns[1].type_, "dog")
}

///|
test "parse_voc_xml drops invalid boxes (xmin>=xmax)" {
  let xml =
    #|<annotation>
    #|  <object>
    #|    <name>cat</name>
    #|    <bndbox><xmin>100</xmin><ymin>0</ymin><xmax>100</xmax><ymax>200</ymax></bndbox>
    #|  </object>
    #|  <object>
    #|    <name>cat</name>
    #|    <bndbox><xmin>0</xmin><ymin>0</ymin><xmax>50</xmax><ymax>50</ymax></bndbox>
    #|  </object>
    #|</annotation>
  let anns = parse_voc_xml(xml)
  assert_eq(anns.length(), 1)
  assert_eq(anns[0].points[1].0, 50.0)
}

///|
test "parse_yolo_lines basic 5-tuple" {
  let lines = ["0 0.5 0.5 0.4 0.3"]
  let classes = ["cat"]
  let anns = parse_yolo_lines(lines, classes, 1000, 800)
  assert_eq(anns.length(), 1)
  assert_eq(anns[0].type_, "cat")
  assert_eq(anns[0].points.length(), 2)
  // cx=0.5*1000=500, cy=0.5*800=400, w=0.4*1000=400, h=0.3*800=240
  // xmin = 500-200 = 300, ymin = 400-120 = 280
  // xmax = 500+200 = 700, ymax = 400+120 = 520
  assert_eq(anns[0].points[0].0, 300.0)
  assert_eq(anns[0].points[0].1, 280.0)
  assert_eq(anns[0].points[1].0, 700.0)
  assert_eq(anns[0].points[1].1, 520.0)
}

///|
test "parse_yolo_lines 6-tuple with confidence ignored" {
  let lines = ["1 0.25 0.25 0.5 0.5 0.95"]
  let classes = ["a", "dog"]
  let anns = parse_yolo_lines(lines, classes, 200, 200)
  assert_eq(anns.length(), 1)
  assert_eq(anns[0].type_, "dog")
}

///|
test "parse_yolo_lines drops out-of-range class id" {
  let lines = ["5 0.5 0.5 0.4 0.3"]
  let classes = ["a", "b"]
  let anns = parse_yolo_lines(lines, classes, 100, 100)
  assert_eq(anns.length(), 0)
}

///|
test "parse_yolo_lines skips blank lines and comments" {
  let lines = ["", "# this is a comment", "0 0.5 0.5 0.4 0.3"]
  let classes = ["cat"]
  let anns = parse_yolo_lines(lines, classes, 100, 100)
  assert_eq(anns.length(), 1)
}

///|
test "parse_yolo_lines returns empty on zero image dims" {
  let lines = ["0 0.5 0.5 0.4 0.3"]
  let classes = ["cat"]
  let anns = parse_yolo_lines(lines, classes, 0, 0)
  assert_eq(anns.length(), 0)
}

///|
test "import_split_lines handles CRLF and trailing line" {
  let s = "a\r\nb\r\nc"
  let lines = import_split_lines(s)
  assert_eq(lines.length(), 3)
  assert_eq(lines[0], "a")
  assert_eq(lines[2], "c")
}

///|
test "import_split_whitespace collapses multiple separators" {
  let parts = import_split_whitespace("a  b\t\tc")
  assert_eq(parts.length(), 3)
  assert_eq(parts[0], "a")
  assert_eq(parts[1], "b")
  assert_eq(parts[2], "c")
}

///|
test "import_split_whitespace trims leading/trailing whitespace" {
  let parts = import_split_whitespace("  a b c  ")
  assert_eq(parts.length(), 3)
}
