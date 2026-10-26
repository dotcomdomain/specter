plan "scheduler state — malformed intervals, 32-bit limits and clock changes"
bootstrap
source_libs
. "$REPO_ROOT/src/lib/scheduler_state.sh"
assert_eq "interval: invalid uses default" 86400 "$(scheduler_interval NaN 86400)"
assert_eq "interval: negative uses default" 300 "$(scheduler_interval -1 300)"
assert_eq "interval: too large uses default" 300 "$(scheduler_interval 99999999999999999999 300)"
assert_eq "interval: over signed limit uses default" 300 "$(scheduler_interval 2147483648 300)"
assert_eq "interval: zero clamps to minimum" 10 "$(scheduler_interval 0 300)"
assert_eq "interval: leading zeros normalized" 80 "$(scheduler_interval 00080 300)"
assert_eq "last-run: malformed cleared" 0 "$(scheduler_last_run bad 1790000000)"
assert_eq "last-run: future timestamp cleared" 0 "$(scheduler_last_run 1800000000 1790000000)"
assert_eq "last-run: valid timestamp kept" 1789999999 "$(scheduler_last_run 1789999999 1790000000)"
assert_eq "last-run: leading zeros normalized" 80 "$(scheduler_last_run 00080 1790000000)"
done_testing
