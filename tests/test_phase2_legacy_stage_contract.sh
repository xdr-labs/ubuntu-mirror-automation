#!/usr/bin/env bash
# Exercise actual staging bridges and static vendor compatibility without
# importing stage_main, downloading bundles, or running package operations.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/phase2-legacy-stage-test.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
export ROOT TEST_ROOT

python3 - <<'PY'
import os
from pathlib import Path

root, work = Path(os.environ['ROOT']), Path(os.environ['TEST_ROOT'])
stage = (root / 'client/stage-dp-phase2.sh').read_text()
functions = []
for name in ('require_dpkg_apt_clean', 'verify_installed_bringup_vendor_compat'):
    anchor = '\n' + name + '() {\n'
    assert stage.count(anchor) == 1, name
    body = stage.split(anchor, 1)[1].split('\n}\n', 1)[0]
    functions.append(name + '() {\n' + body + '\n}\n')
(work / 'stage-functions.sh').write_text('\n'.join(functions))

# Trust order is structural here; the artifact validator has its own execution
# fixtures. A deferred stage must verify the sealed files before inspecting
# replacement metadata, and finish that inspection before controller publish.
main = stage.split('\nstage_main() {\n', 1)[1]
anchors = [
    '\n  ensure_verified_bundle\n',
    '  verify_sha1_pair "${NEW_ART}/aelladeb_py3_common.tar.gz"',
    '    "${NEW_ART}/aella-uvp-2404_${TARGET_DP_VERSION}ubuntu1_amd64.deb.sha1"',
    '  verify_sha1_pair "${NEW_ART}/bringup_py3_dp_after_os_upgrade.sh"',
    '    "${NEW_ART}/images-${TARGET_DP_VERSION}.tar.sha256"',
    '    dp2_validate_product_replacement_artifact ',
    '\n  install_bringup_lifecycle_wrapper\n',
]
positions = [main.index(anchor) for anchor in anchors]
assert positions == sorted(positions), 'replacement verification escaped sealed artifact order'
assert 'if [[ "$LEGACY_PRODUCT_REPLACEMENT_REQUIRED" == "YES" ]]; then' in main[:positions[-2]]
print('PASS stage_target_verification_order')
PY

cat >"$TEST_ROOT/check-stage.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$1"
scenario="$2"
LEGACY_PRODUCT_REPLACEMENT_REQUIRED=YES
trap 'rc=$?; printf "RESULT_FLAG=%s\n" "$LEGACY_PRODUCT_REPLACEMENT_REQUIRED"; exit "$rc"' EXIT
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
dpkg() {
  [[ "$*" == --audit ]] || { echo 'unexpected dpkg call' >&2; exit 90; }
  case "$scenario" in
    dirty_audit) printf 'unconfigured product package\n'; return 0 ;;
    failed_audit) return 2 ;;
    *) return 0 ;;
  esac
}
apt-get() {
  printf 'APT_CALLED\n' >&2
  [[ "$*" == check ]] || { echo 'unexpected APT call' >&2; exit 90; }
  case "$scenario" in
    healthy) return 0 ;;
    invocation_error) printf 'package cache unavailable\n'; return 2 ;;
    *) printf 'legacy dependency details\n'; printf 'APT failure summary\n' >&2; return 100 ;;
  esac
}
dp2_try_legacy_product_transition() {
  printf 'CLASSIFIER_CALLED=%s\n' "$1"
  [[ "$1" == staging && "$scenario" == supported ]]
}
require_dpkg_apt_clean
printf 'STAGE_CONTINUED\n'
SH

count=0
for scenario in healthy supported unsupported invocation_error dirty_audit failed_audit; do
  rc=0
  if out="$(bash "$TEST_ROOT/check-stage.sh" "$TEST_ROOT/stage-functions.sh" "$scenario" 2>&1)"; then rc=0; else rc=$?; fi
  case "$scenario" in
    healthy)
      [[ "$rc" == 0 && "$out" == *RESULT_FLAG=NO* && "$out" == *STAGE_CONTINUED* && "$out" != *CLASSIFIER_CALLED* ]]
      ;;
    supported)
      [[ "$rc" == 0 && "$out" == *RESULT_FLAG=YES* && "$out" == *STAGE_CONTINUED* && "$out" == *CLASSIFIER_CALLED=staging* ]]
      ;;
    unsupported)
      [[ "$rc" != 0 && "$out" == *RESULT_FLAG=NO* && "$out" != *STAGE_CONTINUED* && "$out" == *CLASSIFIER_CALLED=staging* && "$out" == *'legacy dependency details'* ]]
      ;;
    invocation_error)
      [[ "$rc" != 0 && "$out" == *RESULT_FLAG=NO* && "$out" != *STAGE_CONTINUED* && "$out" != *CLASSIFIER_CALLED* && "$out" == *'exit=2'* ]]
      ;;
    dirty_audit|failed_audit)
      [[ "$rc" != 0 && "$out" == *RESULT_FLAG=NO* && "$out" != *STAGE_CONTINUED* && "$out" != *CLASSIFIER_CALLED* && "$out" != *APT_CALLED* ]]
      ;;
  esac || { printf 'FAIL stage_%s rc=%s\n%s\n' "$scenario" "$rc" "$out" >&2; exit 1; }
  count=$((count + 1))
  printf 'PASS stage_%s\n' "$scenario"
done

source "$TEST_ROOT/stage-functions.sh"
log() { printf '%s\n' "$*"; }
BRINGUP_SCRIPT="$TEST_ROOT/controller.sh"
printf '# --worker-password\n' >"$BRINGUP_SCRIPT"
LEGACY_PRODUCT_REPLACEMENT_REQUIRED=YES
check_vendor() {
  local name="$1" file="$2" expected="$3" before after out rc=0
  VENDOR_BRINGUP_INSTALLED="$file"
  before="$(sha256sum "$file")"
  if out="$(verify_installed_bringup_vendor_compat 2>&1)"; then rc=0; else rc=$?; fi
  after="$(sha256sum "$file")"
  if [[ "$before" != "$after" ]] ||
     [[ "$expected" == pass && ( "$rc" != 0 || "$out" != *BRINGUP_VENDOR_COMPAT=PASS* ) ]] ||
     [[ "$expected" == fail && ( "$rc" == 0 || "$out" != *BRINGUP_VENDOR_COMPAT=FAIL* ) ]]; then
    printf 'FAIL vendor_%s expected=%s rc=%s\n%s\n' "$name" "$expected" "$rc" "$out" >&2
    exit 1
  fi
  count=$((count + 1))
  printf 'PASS vendor_%s unchanged=YES\n' "$name"
}

check_vendor current_golden "$ROOT/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh" pass
for generation in production-3af369 production-f1a73; do
  upstream="$ROOT/tests/fixtures/dp-phase2/$generation/bringup_py3_dp_after_os_upgrade.sh"
  before="$(sha256sum "$upstream")"
  python3 "$ROOT/scripts/lib/patch_dp_phase2_bringup.py" \
    --upstream "$upstream" --output "$TEST_ROOT/${generation}.sh" >"$TEST_ROOT/${generation}.patch.log"
  [[ "$before" == "$(sha256sum "$upstream")" ]] || { echo 'FAIL upstream fixture was rewritten' >&2; exit 1; }
  check_vendor "$generation" "$TEST_ROOT/${generation}.sh" pass
done

python3 - <<'PY'
import os
from pathlib import Path

root, work = Path(os.environ['ROOT']), Path(os.environ['TEST_ROOT'])
golden = (root / 'vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh').read_text()
hook = '    install_phase2_ubuntu_prerequisites || \\\n        die "PHASE2_PREREQ_INSTALL=FAIL critical Ubuntu prerequisites missing"'
assert golden.count(hook) == 1
assert golden.count('\n    install_uvp\n') == 1
variants = {
    'early_hook_missing': golden.replace(hook, '    : # missing prerequisite hook'),
    'helper_missing': golden.replace('\ninstall_phase2_ubuntu_prerequisites() {\n', '\nobsolete_prerequisite_helper() {\n'),
    'subshell_helper': golden.replace('        dp2_install_phase2_ubuntu_prerequisites\n        return $?\n', '        ( dp2_install_phase2_ubuntu_prerequisites )\n        return $?\n'),
    # Indentation is deliberately unchanged: counting literal call lines alone
    # must not accept a condition which can skip the armed replacement guard.
    'conditional_uvp': golden.replace('\n    install_uvp\n', '\n    if false; then\n    install_uvp\n    fi\n'),
    'wrong_order': golden.replace('\n    install_python3\n', '\n    TEMP_SWAP\n').replace('\n    install_uvp\n', '\n    install_python3\n').replace('\n    TEMP_SWAP\n', '\n    install_uvp\n'),
    'late_hook': golden.replace(hook, '    unexpected_mutation\n' + hook),
}
for name, text in variants.items():
    assert text != golden, name
    (work / (name + '.sh')).write_text(text)
PY

for variant in early_hook_missing helper_missing subshell_helper conditional_uvp wrong_order late_hook; do
  check_vendor "$variant" "$TEST_ROOT/${variant}.sh" fail
done
printf 'PASS phase2 legacy staging contract (%s behavior cases plus trust order)\n' "$count"
