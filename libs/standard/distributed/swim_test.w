# wbuild: x64
import lib.testing
import libs.standard.distributed.swim


# Drains every pending piggyback update so a test can observe only the
# updates it creates afterward.
void swim_test_drain(swim* s):
	int* out = malloc(16 * __word_size__)
	int got = swim_next_piggyback(s, 16, out)
	while (got > 0):
		got = swim_next_piggyback(s, 16, out)
	free(out)


void test_new_instance_self_alive():
	swim* s = swim_new(1, 500, 3)
	assert_equal(1, swim_member_count(s))
	assert_equal(swim_alive(), swim_state(s, 1))
	assert_equal(0, swim_incarnation(s, 1))
	assert_equal(0, swim_self_incarnation(s))
	assert_equal(1, swim_alive_count(s))
	assert_equal(0 - 1, swim_probe_target(s))
	assert_equal(0 - 1, swim_state(s, 42))
	assert_equal(0 - 1, swim_incarnation(s, 42))
	swim_free(s)


void test_join_adds_unknown_only():
	swim* s = swim_new(1, 500, 3)
	assert_equal(1, swim_join(s, 2, 100))
	assert_equal(1, swim_join(s, 3, 100))
	assert_equal(0, swim_join(s, 2, 150))
	assert_equal(0, swim_join(s, 1, 150))
	assert_equal(3, swim_member_count(s))
	assert_equal(swim_alive(), swim_state(s, 2))
	assert_equal(0, swim_incarnation(s, 3))
	swim_free(s)


void test_probe_round_robin_never_self():
	swim* s = swim_new(1, 500, 3)
	swim_join(s, 2, 0)
	swim_join(s, 3, 0)
	swim_join(s, 4, 0)
	assert_equal(2, swim_probe_target(s))
	assert_equal(3, swim_probe_target(s))
	assert_equal(4, swim_probe_target(s))
	assert_equal(2, swim_probe_target(s))
	assert_equal(3, swim_probe_target(s))
	assert_equal(4, swim_probe_target(s))
	swim_free(s)


void test_probe_skips_dead_members():
	swim* s = swim_new(1, 500, 3)
	swim_join(s, 2, 0)
	swim_join(s, 3, 0)
	swim_join(s, 4, 0)
	swim_on_dead_msg(s, 3, 10)
	assert_equal(2, swim_probe_target(s))
	assert_equal(4, swim_probe_target(s))
	assert_equal(2, swim_probe_target(s))
	assert_equal(4, swim_probe_target(s))
	swim_on_dead_msg(s, 2, 20)
	swim_on_dead_msg(s, 4, 20)
	assert_equal(0 - 1, swim_probe_target(s))
	swim_free(s)


void test_probe_timeout_suspects_target():
	swim* s = swim_new(1, 500, 3)
	swim_join(s, 2, 0)
	swim_on_probe_timeout(s, 2, 1000)
	assert_equal(swim_suspect(), swim_state(s, 2))
	assert_equal(0, swim_incarnation(s, 2))
	# a timeout for an unknown target is ignored
	swim_on_probe_timeout(s, 99, 1000)
	assert_equal(0 - 1, swim_state(s, 99))
	swim_free(s)


void test_suspect_expires_to_dead_after_timeout():
	swim* s = swim_new(1, 500, 3)
	swim_join(s, 2, 0)
	swim_test_drain(s)
	swim_on_probe_timeout(s, 2, 1000)
	swim_test_drain(s)
	swim_tick(s, 1499)
	assert_equal(swim_suspect(), swim_state(s, 2))
	swim_tick(s, 1500)
	assert_equal(swim_dead(), swim_state(s, 2))
	# the death is a fresh pending update
	int* out = malloc(4 * __word_size__)
	assert_equal(1, swim_next_piggyback(s, 4, out))
	assert_equal(2, out[0])
	free(out)
	swim_free(s)


void test_alive_refutation_needs_higher_incarnation():
	swim* s = swim_new(1, 500, 3)
	swim_join(s, 2, 0)
	swim_on_probe_timeout(s, 2, 1000)
	assert_equal(swim_suspect(), swim_state(s, 2))
	# alive at the same incarnation is not a refutation
	swim_on_alive_msg(s, 2, 0, 1100)
	assert_equal(swim_suspect(), swim_state(s, 2))
	# the suspect bumping its incarnation is
	swim_on_alive_msg(s, 2, 1, 1200)
	assert_equal(swim_alive(), swim_state(s, 2))
	assert_equal(1, swim_incarnation(s, 2))
	swim_free(s)


void test_suspect_overrides_alive_at_same_incarnation():
	swim* s = swim_new(1, 500, 3)
	swim_join(s, 2, 0)
	assert_equal(0, swim_on_suspect_msg(s, 2, 0, 100))
	assert_equal(swim_suspect(), swim_state(s, 2))
	# a higher-incarnation suspect lands too, at that incarnation
	swim_join(s, 3, 0)
	assert_equal(4, swim_on_suspect_msg(s, 3, 4, 100))
	assert_equal(swim_suspect(), swim_state(s, 3))
	assert_equal(4, swim_incarnation(s, 3))
	swim_free(s)


void test_repeat_suspect_same_incarnation_keeps_deadline():
	swim* s = swim_new(1, 500, 3)
	swim_join(s, 2, 0)
	swim_on_suspect_msg(s, 2, 0, 1000)   # deadline 1500
	swim_on_suspect_msg(s, 2, 0, 1400)   # same incarnation: no refresh
	swim_tick(s, 1500)
	assert_equal(swim_dead(), swim_state(s, 2))
	# a higher-incarnation suspect does re-arm the deadline
	swim_join(s, 3, 0)
	swim_on_suspect_msg(s, 3, 0, 1000)   # deadline 1500
	swim_on_suspect_msg(s, 3, 1, 1400)   # fresh deadline 1900
	swim_tick(s, 1500)
	assert_equal(swim_suspect(), swim_state(s, 3))
	swim_tick(s, 1900)
	assert_equal(swim_dead(), swim_state(s, 3))
	swim_free(s)


void test_self_refutation_bumps_incarnation():
	swim* s = swim_new(1, 500, 3)
	assert_equal(1, swim_on_suspect_msg(s, 1, 0, 100))
	assert_equal(1, swim_self_incarnation(s))
	assert_equal(swim_alive(), swim_state(s, 1))
	assert_equal(1, swim_incarnation(s, 1))
	assert_equal(6, swim_on_suspect_msg(s, 1, 5, 200))
	assert_equal(6, swim_self_incarnation(s))
	assert_equal(6, swim_incarnation(s, 1))
	# a stale suspicion below the current incarnation bumps nothing
	assert_equal(6, swim_on_suspect_msg(s, 1, 2, 300))
	assert_equal(6, swim_self_incarnation(s))
	# the refutation pends as an alive update about self
	int* out = malloc(4 * __word_size__)
	assert_equal(1, swim_next_piggyback(s, 4, out))
	assert_equal(1, out[0])
	free(out)
	swim_free(s)


void test_dead_is_terminal():
	swim* s = swim_new(1, 500, 3)
	swim_join(s, 2, 0)
	swim_on_dead_msg(s, 2, 100)
	assert_equal(swim_dead(), swim_state(s, 2))
	# v1: no resurrection, even at a higher incarnation (see swim.w)
	swim_on_alive_msg(s, 2, 99, 200)
	assert_equal(swim_dead(), swim_state(s, 2))
	swim_on_suspect_msg(s, 2, 99, 200)
	assert_equal(swim_dead(), swim_state(s, 2))
	assert_equal(0, swim_incarnation(s, 2))
	# repeating dead changes nothing and pends nothing new
	swim_test_drain(s)
	swim_on_dead_msg(s, 2, 300)
	int* out = malloc(2 * __word_size__)
	assert_equal(0, swim_next_piggyback(s, 2, out))
	free(out)
	swim_free(s)


void test_unknown_member_joins_via_alive_gossip():
	swim* s = swim_new(1, 500, 3)
	swim_on_alive_msg(s, 7, 3, 100)
	assert_equal(2, swim_member_count(s))
	assert_equal(swim_alive(), swim_state(s, 7))
	assert_equal(3, swim_incarnation(s, 7))
	# and the newcomer itself pends for dissemination
	int* out = malloc(2 * __word_size__)
	assert_equal(1, swim_next_piggyback(s, 2, out))
	assert_equal(7, out[0])
	free(out)
	swim_free(s)


void test_unknown_member_joins_via_suspect_gossip():
	swim* s = swim_new(1, 500, 3)
	assert_equal(2, swim_on_suspect_msg(s, 9, 2, 1000))
	assert_equal(swim_suspect(), swim_state(s, 9))
	assert_equal(2, swim_incarnation(s, 9))
	swim_tick(s, 1500)
	assert_equal(swim_dead(), swim_state(s, 9))
	swim_free(s)


void test_ack_does_not_clear_suspicion():
	swim* s = swim_new(1, 500, 3)
	swim_join(s, 2, 0)
	swim_test_drain(s)
	# an ack from an alive member changes nothing and pends nothing
	swim_on_ack(s, 2, 50)
	assert_equal(swim_alive(), swim_state(s, 2))
	int* out = malloc(2 * __word_size__)
	assert_equal(0, swim_next_piggyback(s, 2, out))
	# an ack at the same incarnation leaves a suspect suspect: only the
	# suspect bumping its own incarnation refutes (see swim.w header)
	swim_on_probe_timeout(s, 2, 1000)
	swim_on_ack(s, 2, 1100)
	assert_equal(swim_suspect(), swim_state(s, 2))
	free(out)
	swim_free(s)


void test_piggyback_budget_exhausts():
	swim* s = swim_new(1, 500, 3)
	swim_join(s, 2, 0)
	int* out = malloc(4 * __word_size__)
	assert_equal(1, swim_next_piggyback(s, 4, out))
	assert_equal(2, out[0])
	assert_equal(1, swim_next_piggyback(s, 4, out))
	assert_equal(2, out[0])
	assert_equal(1, swim_next_piggyback(s, 4, out))
	assert_equal(2, out[0])
	assert_equal(0, swim_next_piggyback(s, 4, out))
	free(out)
	swim_free(s)


void test_piggyback_prefers_freshest_update():
	swim* s = swim_new(1, 500, 3)
	swim_join(s, 2, 0)
	swim_join(s, 3, 0)
	int* out = malloc(4 * __word_size__)
	# both pend at full budget 3; table order breaks the tie
	assert_equal(2, swim_next_piggyback(s, 4, out))
	assert_equal(2, out[0])
	assert_equal(3, out[1])
	# suspecting 3 grants it a fresh budget: 3 transmits vs 2 remaining
	swim_on_probe_timeout(s, 3, 1000)
	assert_equal(1, swim_next_piggyback(s, 1, out))
	assert_equal(3, out[0])
	# back to a tie at 2 transmits each: table order again
	assert_equal(2, swim_next_piggyback(s, 4, out))
	assert_equal(2, out[0])
	assert_equal(3, out[1])
	assert_equal(2, swim_next_piggyback(s, 4, out))
	assert_equal(0, swim_next_piggyback(s, 4, out))
	free(out)
	swim_free(s)


void test_piggyback_respects_max_cap():
	swim* s = swim_new(1, 500, 3)
	swim_join(s, 2, 0)
	swim_join(s, 3, 0)
	swim_join(s, 4, 0)
	int* out = malloc(8 * __word_size__)
	assert_equal(2, swim_next_piggyback(s, 2, out))
	assert_equal(2, out[0])
	assert_equal(3, out[1])
	# member 4 kept its full budget, so it now goes first
	assert_equal(3, swim_next_piggyback(s, 8, out))
	assert_equal(4, out[0])
	assert_equal(2, out[1])
	assert_equal(3, out[2])
	assert_equal(0, swim_next_piggyback(s, 0, out))
	free(out)
	swim_free(s)


void test_indirect_candidates_exclude_self_target_dead():
	swim* s = swim_new(1, 500, 3)
	swim_join(s, 2, 0)
	swim_join(s, 3, 0)
	swim_join(s, 4, 0)
	swim_join(s, 5, 0)
	swim_on_dead_msg(s, 4, 10)
	int* out = malloc(8 * __word_size__)
	# helpers for target 2 exclude self(1), target(2), dead(4)
	assert_equal(2, swim_indirect_candidates(s, 2, 8, out))
	assert_equal(3, out[0])
	assert_equal(5, out[1])
	# k caps the count
	assert_equal(1, swim_indirect_candidates(s, 2, 1, out))
	assert_equal(3, out[0])
	assert_equal(0, swim_indirect_candidates(s, 2, 0, out))
	# availability caps the count below k
	swim_on_dead_msg(s, 5, 20)
	assert_equal(1, swim_indirect_candidates(s, 2, 8, out))
	assert_equal(3, out[0])
	free(out)
	swim_free(s)


void test_suspect_deadline_across_32bit_wrap():
	swim* s = swim_new(1, 500, 3)
	swim_join(s, 2, 0)
	# timestamp just below the 32-bit wrap, built at runtime with no
	# bit-31 literals (monotime_test.w style); the deadline lands past
	# the wrap on x86 and the same asserts hold unwrapped on x64
	int q = 1 << 30
	int now = q + q - 100
	swim_on_probe_timeout(s, 2, now)
	assert_equal(swim_suspect(), swim_state(s, 2))
	swim_tick(s, now + 499)
	assert_equal(swim_suspect(), swim_state(s, 2))
	swim_tick(s, now + 500)
	assert_equal(swim_dead(), swim_state(s, 2))
	swim_free(s)


void test_alive_count_tracks_state_changes():
	swim* s = swim_new(1, 500, 3)
	swim_join(s, 2, 0)
	swim_join(s, 3, 0)
	assert_equal(3, swim_alive_count(s))
	swim_on_suspect_msg(s, 2, 0, 100)
	assert_equal(2, swim_alive_count(s))
	swim_on_dead_msg(s, 3, 100)
	assert_equal(1, swim_alive_count(s))
	# dead and suspect members stay in the table
	assert_equal(3, swim_member_count(s))
	swim_free(s)
