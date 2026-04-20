extends GutTest

const NamePool = preload("res://client/menu/name_pool.gd")

func test_random_name_returns_value_from_pool() -> void:
    var name: String = NamePool.random_name()
    assert_true(NamePool.NAMES.has(name), "random_name() returned %s which is not in NAMES" % name)

func test_random_name_distribution_has_variety() -> void:
    # 100 calls should produce >= 5 distinct names — sanity check that the RNG
    # isn't stuck on a single value. With a 60-name pool the probability of
    # fewer than 5 distinct names in 100 draws is astronomically small.
    var seen: Dictionary = {}
    for i in 100:
        seen[NamePool.random_name()] = true
    assert_true(seen.size() >= 5, "Only %d distinct names in 100 draws" % seen.size())

func test_pool_is_non_empty() -> void:
    assert_true(NamePool.NAMES.size() > 0)
