import gleam/dict
import gleam/string
import kirari/hashpin
import kirari/types.{Hex, Npm}

pub fn parse_roundtrip_test() {
  let pins =
    hashpin.HashPins(
      hex: dict.from_list([#("gleam_stdlib", ["abc123", "def456"])]),
      npm: dict.from_list([#("react", ["sha256hex1"])]),
    )
  let encoded = hashpin.encode(pins)
  let assert Ok(parsed) = hashpin.parse(encoded)
  assert dict.get(parsed.hex, "gleam_stdlib") == Ok(["abc123", "def456"])
  assert dict.get(parsed.npm, "react") == Ok(["sha256hex1"])
}

pub fn parse_empty_test() {
  let assert Ok(pins) = hashpin.parse("")
  assert pins.hex == dict.new()
  assert pins.npm == dict.new()
}

pub fn check_pin_matched_test() {
  let pins =
    hashpin.HashPins(
      hex: dict.from_list([#("gleam_stdlib", ["abc123"])]),
      npm: dict.new(),
    )
  case hashpin.check(pins, "gleam_stdlib", Hex, "abc123") {
    hashpin.PinMatched(name, _) -> {
      assert name == "gleam_stdlib"
    }
    _ -> panic as "expected PinMatched"
  }
}

pub fn check_pin_mismatch_test() {
  let pins =
    hashpin.HashPins(
      hex: dict.from_list([#("gleam_stdlib", ["abc123"])]),
      npm: dict.new(),
    )
  case hashpin.check(pins, "gleam_stdlib", Hex, "wrong_hash") {
    hashpin.PinMismatch(name, _, actual, _allowed) -> {
      assert name == "gleam_stdlib"
      assert actual == "wrong_hash"
    }
    _ -> panic as "expected PinMismatch"
  }
}

pub fn check_no_entry_test() {
  let pins = hashpin.empty()
  assert hashpin.check(pins, "unknown", Hex, "abc") == hashpin.NoPinEntry
}

pub fn check_case_insensitive_test() {
  let pins =
    hashpin.HashPins(
      hex: dict.from_list([#("pkg", ["abcdef"])]),
      npm: dict.new(),
    )
  case hashpin.check(pins, "pkg", Hex, "ABCDEF") {
    hashpin.PinMatched(_, _) -> Nil
    _ -> panic as "expected case-insensitive match"
  }
}

pub fn add_hash_dedup_test() {
  let pins = hashpin.empty()
  let pins = hashpin.add_hash(pins, "pkg", Hex, "abc123")
  let pins = hashpin.add_hash(pins, "pkg", Hex, "abc123")
  let assert Ok(hashes) = dict.get(pins.hex, "pkg")
  assert hashes == ["abc123"]
}

pub fn add_hash_multiple_test() {
  let pins = hashpin.empty()
  let pins = hashpin.add_hash(pins, "pkg", Npm, "hash1")
  let pins = hashpin.add_hash(pins, "pkg", Npm, "hash2")
  let assert Ok(hashes) = dict.get(pins.npm, "pkg")
  assert hashes == ["hash1", "hash2"]
}

pub fn check_multiple_allowed_test() {
  let pins =
    hashpin.HashPins(
      hex: dict.new(),
      npm: dict.from_list([#("react", ["old_hash", "new_hash"])]),
    )
  case hashpin.check(pins, "react", Npm, "new_hash") {
    hashpin.PinMatched(_, _) -> Nil
    _ -> panic as "expected PinMatched with multiple allowed"
  }
}

pub fn encode_empty_test() {
  let pins = hashpin.empty()
  assert hashpin.encode(pins) == ""
}

pub fn encode_sorted_test() {
  let pins =
    hashpin.HashPins(
      hex: dict.from_list([#("beta", ["b"]), #("alpha", ["a"])]),
      npm: dict.new(),
    )
  let encoded = hashpin.encode(pins)
  // alpha가 beta보다 먼저 나와야 함
  let assert Ok(alpha_pos) = string.crop(encoded, "alpha") |> Ok
  let assert Ok(beta_pos) = string.crop(encoded, "beta") |> Ok
  assert string.length(alpha_pos) > string.length(beta_pos)
}
