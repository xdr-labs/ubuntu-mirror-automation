# 실제 DP 6.6.0 E2E — 현장 실행 체크리스트

이 문서는 현재 `xdr-labs/ubuntu-mirror-automation` **main**을 실제
Mirror Server에 반영한 뒤, 운영자가 **승인된 테스트 DP**에서 검증할
절차입니다. 전체 근거와 세부 검증 기준은 [영문 계약](DP_FIELD_E2E_6_6_0.md)에
있습니다. **정상 업그레이드가 완료된 Master는 다시 bringup하지 않습니다.**

## 1. 모드 결정

| 현재 DP | Mirror Manager 모드 | 실행 |
|---|---|---|
| Ubuntu 16.04, DP 6.2.x~6.5.x | **FULL** | Menu 7의 OS 4-hop + Phase 2 |
| Ubuntu 24.04, DP 6.2.x~6.5.x | **PHASE2_ONLY** | Menu 7의 Phase 2만, **OS 업그레이드 없음** |
| Ubuntu 24.04, 정상 DP 6.6.0 | 업그레이드 불필요 | 기존 상태·증거 보존, 재실행하지 않음 |
| 중간 실패/버전 불명 | 먼저 진단 | 강제 실행, 상태 삭제, 임의 복구 금지 |

시작 전 테스트 대상 DL/DA Master 및 Worker IP, 현재 OS/DP 버전,
유지보수 시간, VM 전원 OFF 상태의 하이퍼바이저 스냅샷 및 복원
담당자를 확인합니다. 제품에서 자체 OS/DP 롤백 명령을 제공하지 않습니다.

## 2. 실제 미러 서버 업데이트

DP에서 HTTP 다운로드가 진행 중이지 않을 때 **미러 서버**의 기존
Repository에서 다음을 실행합니다. 개발서버 `dev-drlink`는 실제
미러 서버가 아닙니다.

```bash
cd ~/ubuntu-mirror-automation
git switch main
git pull --ff-only origin main
git rev-parse HEAD
sudo ./install.sh
```

이후 또는 재접속 시:

```bash
sudo ubuntu-offline-mirror mirror-manager
```

1. **Menu 1 — Configuration:** 실제 FULL/PHASE2_ONLY 모드, 미러 IP,
   DL/DA Worker 목록을 저장합니다.
2. **Menu 2 — Download and Prepare:** 수정된 `.sh.in` 소스를 기준으로
   **서명된 OS 클라이언트를 아직 재생성하지 않은 경우** 반드시
   최신 클라이언트 generation을 생성·서명합니다. 기존의 검증된 대용량
   아티팩트는 삭제하지 않습니다. 이전 generation과 현재 소스가
   이미 일치하면 Mirror Manager의 정상 재사용 판정을 따릅니다.
   PHASE2_ONLY에서는 OS-hop 파일이 `NOT REQUIRED`인 것이 정상입니다.
3. **Menu 3 — Enable HTTP Distribution:** HTTP/nginx 실제 검사 PASS.
4. **Menu 4 — Verify Upgrade Readiness:** **명시적 PASS 필수**.
   과거 PASS 화면이나 `PREPARED` 상태만으로 DP 작업을 시작하지 않습니다.
5. **Menu 7 — Show DP Client Upgrade Commands:** 실제 AIO 또는 Cluster
   토폴로지로 다시 출력합니다. 미러 주소/서명 generation에 묶인
   **새 명령만 사용**합니다. 저장 위치:
   `/var/log/ubuntu-mirror-automation/dp-client-upgrade-commands.txt`.

미러 IP만 변경되었고 나머지 검증된 준비물은 변하지 않았다면
일반적으로 **Menu 3 → 4 → 7**로 endpoint만 다시 게시합니다.
대용량 파일을 이유 없이 재다운로드하지 않습니다. DP에서 미러
TCP/80 접근을 확인합니다. DP의 R2/ACPS 직접 연결은 필요하지 않습니다.

## 3. 테스트 DP 실행 순서

**Menu 7의 명령을 그대로 복사**합니다. 문서만 보고 URL, SHA-256,
Worker 옵션을 수동 조립하지 않습니다.

- **FULL:** Menu 7 **STEP 0~10**. DP Precheck → `aella_cli`에서 Pause
  → 전원 OFF/스냅샷/ON → 16.04→18.04→20.04→22.04→24.04
  → Phase 2 staging → Bringup → 필요 시 Resume → 최종 검증.
- **PHASE2_ONLY:** Menu 7 **STEP 0~7**. Precheck → Pause → 전원 OFF/
  스냅샷/ON → Ubuntu 24.04 선행 조건 검사 → Phase 2 staging → Bringup
  → 필요 시 Resume → 검증. OS-hop을 실행하지 않습니다.
- **AIO:** 해당 DP 하나에서 staging/bringup을 수행합니다.
- **Cluster:** 업그레이드 대상 **모든 노드**에서 staging을 먼저 끝낸 뒤,
  DL Master와 DA Master가 존재하는 경우 **각 Master에서만**
  해당 역할의 Menu 7 bringup을 실행합니다. `--worker-ips`는
  Menu 7이 생성하며, Master가 Worker 실행을 조정합니다.
  Worker에서 Master bringup을 수동으로 실행하지 않습니다.
  Worker SSH 암호는 Master의 마스킹 프롬프트에서 입력합니다.
  완료된 정상 Master는 다시 실행하지 않습니다.

## 4. E2E 합격 조건

Bringup이 PASS로 종료돼도 서비스가 Pause 상태라면 완료가 아닙니다.
Master 또는 AIO에서 다음을 실행합니다.

```bash
sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --validate-cluster
```

Pause 상태면 **Linux Bash가 아닌 `aella_cli` 내부에서** Resume한 뒤
다시 `--validate-cluster`를 실행합니다. 노드·서비스 준비 상태,
DL/AIO License 또는 DA/DR System Ready, Worker 상태,
index/model/provision의 명시적 실패 여부를 확인합니다.

DP 6.2/6.3/6.4에서 업그레이드한 경우 Menu 7이 안내하는 schema
migration을 **실제로 수행·확인한 뒤에만** migration PASS를 기록합니다.
최종 Cluster Validation PASS도 실제 건강 상태 확인 후 기록합니다.
잘못된 PASS를 만들기 위해 `--record-*`를 실행하지 않습니다.

최종 출력의 의미:

- `BRINGUP_RESULT=PASS`: bringup 프로세스 성공. 전체 업그레이드
  완료 판정과 다릅니다.
- `DP_UPGRADE_COMPLETE=YES`: 해당 실행의 완료 조건을 충족.
- `DP_WORKER_READINESS=PASS` 및
  `DP_CLUSTER_UPGRADE_COMPLETE=YES`: 설정된 Worker 토폴로지의
  실행 증거와 검증 조건이 충족된 경우에만 해당.
- `DP_UPGRADE_SCOPE=LOCAL_ONLY`: 로컬/AIO 또는 Master-only 범위.
  `DP_CLUSTER_UPGRADE_COMPLETE=NO`가 단독 DP의 실패를 의미하지는
  않지만 다른 Worker가 정상이라고 증명하는 것도 아닙니다.

## 5. ChatGPT에 전달할 E2E 결과

비밀번호/토큰/개인정보를 제거하고 아래 정보를 그대로 전달합니다.

- 미러 `git rev-parse HEAD`, 준비 모드, Menu 2 재생성/재사용 판정,
  Menu 3·Menu 4 결과 및 Menu 7 출력
- DP의 이전·이후 `/etc/os-release` 및 DP 버전과 노드 역할
- 스냅샷 완료 사실, Pause/Resume 상태, 실제 실행 STEP과 오류/종료 코드
- Phase 2 staging/bringup run ID, Worker별 결과,
  `--validate-cluster` 출력, migration 및 완료 출력
- DP UI/CLI에서 최종 확인한 서비스·클러스터 정상 상태

실패하면 **해당 노드에서 즉시 멈추고 증거를 보존**합니다.
Ubuntu/Stellar Cyber 원본 소프트웨어의 문제는 우리 코드 버그와
구분합니다. 자동화 코드 전수 회귀 PASS가 실제 DP E2E PASS를
대체하지는 않습니다.
