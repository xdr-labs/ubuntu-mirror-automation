# shellcheck shell=bash
# Shared hermetic fixture-escape policy for offline OS upgrade clients.
# Injected into single-file clients at build / stub-render time.
# Compatible with Bash 4.3+ and safe under `set -Eeuo pipefail`.
#
# Contract:
# - Production must never honor test/fixture controls from the environment alone.
# - Fixture behavior requires MM_HERMETIC_TEST_MODE=1 AND the specific control.
# - Call dp_offline_enforce_production_fixture_policy early in main() before
#   TEST_ROOT / SYSTEMCTL_BIN fixture paths take effect.

dp_offline_hermetic_test_mode() {
  [[ "${MM_HERMETIC_TEST_MODE:-0}" == "1" ]]
}

# True when hermetic fixtures are permitted (companion flag checked by caller).
dp_offline_hermetic_fixtures_enabled() {
  dp_offline_hermetic_test_mode
}

# Category-C fixture controls: alter trust, identity, topology, confirmation,
# package mutation, systemctl behavior, or upgrade success/failure semantics.
# Keep this list the single inventory shared by all four hop clients.
dp_offline_category_c_fixture_vars() {
  printf '%s\n' \
    DP_OFFLINE_TEST_ROOT \
    STELLAR_OFFLINE_TEST_ROOT \
    DP_OFFLINE_TEST_HANDOFF \
    DP_OFFLINE_FAKE_DP_VERSION \
    DP_OFFLINE_FAKE_ROLE \
    DP_OFFLINE_FAKE_MIRROR_TRUST \
    DP_OFFLINE_FAKE_CONFIRM \
    DP_OFFLINE_FAKE_KERNEL \
    DP_OFFLINE_FAKE_UNHOLD_FAIL \
    DP_OFFLINE_FAKE_UNHOLD_STILL_HELD \
    DP_OFFLINE_FAKE_HOLD_FAIL \
    DP_OFFLINE_FAKE_SHELL_CHANGE_FAIL \
    DP_OFFLINE_FAKE_SHELL_CHANGE_FAIL_USER \
    DP_OFFLINE_FAKE_SHELL_CHSH_FAIL \
    DP_OFFLINE_FAKE_SHELL_NOOP_SUCCESS \
    DP_OFFLINE_FAKE_FAIL_AFTER_UNHOLD \
    DP_OFFLINE_FORCE_NONINTERACTIVE \
    DP_OFFLINE_FORCE_MONITOR \
    DP_OFFLINE_UPGRADE_MODE \
    STELLAR_OFFLINE_FORCE_SEMANTIC_GATE_FAIL \
    STELLAR_OFFLINE_FORCE_DRO_PRE_TRANSITION_FAIL \
    STELLAR_OFFLINE_SMOKE_STOP_BEFORE_DRO \
    DP_OFFLINE_FAKE_PYTHON2_CLASS \
    DP_OFFLINE_FAKE_PYTHON2_PACKAGES \
    DP_OFFLINE_FAKE_PYTHON2_RDEPENDS \
    DP_OFFLINE_FAKE_PYTHON2_NO_CANDIDATE \
    DP_OFFLINE_FAKE_PYTHON2_PRODUCT_REMOVE \
    DP_OFFLINE_FAKE_PYTHON2_SIM_PLAN \
    DP_OFFLINE_FAKE_LXD_CLASS \
    DP_OFFLINE_FAKE_LXD_CONTAINERS \
    DP_OFFLINE_FAKE_LXD_IMAGES \
    DP_OFFLINE_FAKE_LXD_STORAGE \
    DP_OFFLINE_FAKE_LXD_WAITREADY \
    DP_OFFLINE_FAKE_LXD_TIMEOUT \
    DP_OFFLINE_FAKE_LXD_JSON_PARSE \
    DP_OFFLINE_FAKE_LXD_REMOVAL_SIM \
    DP_OFFLINE_FAKE_LXD_NETWORK_RISK \
    DP_OFFLINE_FAKE_LXD_TARGET_SELECTED \
    DP_OFFLINE_FAKE_LXD_DO_REMOVE \
    STELLAR_OFFLINE_FAKE_NTP_UID_PROCS \
    STELLAR_OFFLINE_FAKE_NTP_UID_PROCS_AFTER_STOP \
    STELLAR_OFFLINE_FAKE_LEGACY_NTP_PACKAGE \
    STELLAR_OFFLINE_FAKE_NTPSEC_PACKAGE \
    STELLAR_OFFLINE_FAKE_LEGACY_NTP_UNIT_FRAGMENT \
    STELLAR_OFFLINE_FAKE_LEGACY_NTP_UNIT_OWNED \
    STELLAR_OFFLINE_FAKE_LEGACY_NTP_ACTIVE \
    STELLAR_OFFLINE_FAKE_DEFAULT_ROUTE \
    STELLAR_OFFLINE_FAKE_SYSTEMCTL_STOP \
    DP_OFFLINE_FAKE_LXD_WAITREADY_DELAY_SECS \
    DP_OFFLINE_FAKE_LXD_TIMEOUT_ONCE \
    DP_OFFLINE_FAKE_LXD_JSON_PARSE_FAIL
}

# Resolve TEST_ROOT only under hermetic fixtures.
dp_offline_resolve_test_root() {
  if dp_offline_hermetic_fixtures_enabled; then
    printf '%s' "${DP_OFFLINE_TEST_ROOT:-}"
  else
    printf '%s' ""
  fi
}

# Resolve SYSTEMCTL_BIN: production always uses systemctl; fixture override
# requires hermetic mode.
dp_offline_resolve_systemctl_bin() {
  if dp_offline_hermetic_fixtures_enabled; then
    printf '%s' "${SYSTEMCTL_BIN:-systemctl}"
  else
    printf '%s' "systemctl"
  fi
}

# Fail closed in production when any Category-C fixture control is present, or
# when SYSTEMCTL_BIN is overridden away from the default binary name.
dp_offline_enforce_production_fixture_policy() {
  if dp_offline_hermetic_test_mode; then
    return 0
  fi

  local var val bad=""
  while IFS= read -r var; do
    [[ -n "$var" ]] || continue
    # Bash 4.3-safe indirect expansion.
    eval "val=\${${var}-}"
    if [[ -n "$val" ]]; then
      bad="${bad}${bad:+ }${var}"
    fi
  done < <(dp_offline_category_c_fixture_vars)

  if [[ -n "${SYSTEMCTL_BIN:-}" && "${SYSTEMCTL_BIN}" != "systemctl" ]]; then
    bad="${bad}${bad:+ }SYSTEMCTL_BIN"
  fi

  if [[ -n "$bad" ]]; then
    printf 'ERROR: FIXTURE_ESCAPE_PRODUCTION_FORBIDDEN vars=%s (require MM_HERMETIC_TEST_MODE=1)\n' "$bad" >&2
    return 1
  fi

  SYSTEMCTL_BIN="systemctl"
  return 0
}
