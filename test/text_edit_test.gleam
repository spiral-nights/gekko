import project/text_edit

pub fn strip_visibility_prefix_test() {
  assert text_edit.strip_visibility_prefix("pub fn greet()") == "fn greet()"
  assert text_edit.strip_visibility_prefix("pub(all) enum Color {")
    == "enum Color {"
  assert text_edit.strip_visibility_prefix("pub(open) type T") == "type T"
  assert text_edit.strip_visibility_prefix("pub(readonly) type T") == "type T"
  assert text_edit.strip_visibility_prefix("priv fn helper()") == "fn helper()"
  assert text_edit.strip_visibility_prefix("fn local()") == "fn local()"
  assert text_edit.strip_visibility_prefix("publication") == "publication"
}
