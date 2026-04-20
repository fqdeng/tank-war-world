extends GutTest

const NameSanitizer = preload("res://server/util/name_sanitizer.gd")

func test_passthrough_normal_name() -> void:
	assert_eq(NameSanitizer.sanitize("Wolf", 7), "Wolf")

func test_strips_leading_and_trailing_whitespace() -> void:
	assert_eq(NameSanitizer.sanitize("  Wolf  ", 7), "Wolf")

func test_truncates_to_12_characters() -> void:
	assert_eq(NameSanitizer.sanitize("VeryLongNameOver12", 7), "VeryLongName")

func test_preserves_internal_space() -> void:
	assert_eq(NameSanitizer.sanitize("hello world", 7), "hello world")

func test_strips_cjk_then_falls_back() -> void:
	# 狼王 has no printable-ASCII chars → empty after filter → fallback to P<pid>
	assert_eq(NameSanitizer.sanitize("狼王", 42), "P42")

func test_strips_control_chars() -> void:
	assert_eq(NameSanitizer.sanitize("AB\u0001CD", 7), "ABCD")

func test_empty_input_falls_back() -> void:
	assert_eq(NameSanitizer.sanitize("", 9), "P9")

func test_whitespace_only_falls_back() -> void:
	assert_eq(NameSanitizer.sanitize("   ", 9), "P9")

func test_mixed_cjk_and_ascii_keeps_only_ascii() -> void:
	assert_eq(NameSanitizer.sanitize("Wolf王", 7), "Wolf")
