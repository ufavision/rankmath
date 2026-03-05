#!/bin/bash
# =============================================================
#  rankmath-connect-bulk.sh
#  Bulk "Connect Account" — Rank Math SEO Plugin
#
#  สิ่งที่ script นี้ทำ:
#    ค้นหา WordPress ทุกเว็บบนเซิร์ฟเวอร์
#    → ตรวจว่า Rank Math ติดตั้งและ active อยู่หรือไม่
#    → ตรวจสถานะการเชื่อมต่อ rankmath.com account
#    → ถ้ายังไม่เชื่อมต่อ → พยายาม activate license key (ถ้ามี)
#    → บันทึก log แยกตาม status
# =============================================================

# ─── ตั้งค่า ─────────────────────────────────────────────────
MAX_JOBS=5       # parallel jobs
WP_TIMEOUT=30    # timeout ต่อเว็บ (วินาที)
MAX_RETRY=3      # retry สูงสุดต่อเว็บ
RETRY_DELAY=5    # รอ (วินาที) ก่อน retry

# ใส่ Rank Math License Key ถ้ามี (ถ้าไม่มีให้เว้นว่าง)
RM_LICENSE_KEY=""
# ─────────────────────────────────────────────────────────────

LOG_FILE="/var/log/rankmath-connect.log"
LOG_PASS="/var/log/rankmath-connect-pass.log"
LOG_FAIL="/var/log/rankmath-connect-fail.log"
LOG_SKIP="/var/log/rankmath-connect-skip.log"
LOG_ALREADY="/var/log/rankmath-connect-already.log"
LOG_NOPLUGIN="/var/log/rankmath-connect-noplugin.log"
LOG_NOKEY="/var/log/rankmath-connect-nokey.log"
LOCK_FILE="${LOG_FILE}.lock"
RESULT_DIR="/tmp/rankmath-connect-$$"
mkdir -p "$RESULT_DIR"

log() {
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$1"
    ( flock 200; echo "[$ts] $1" >> "$LOG_FILE" ) 200>"$LOCK_FILE"
}

log_result() {
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    case "$1" in
        pass)     ( flock 201; echo "[$ts] $2" >> "$LOG_PASS"     ) 201>"${LOG_FILE}.pass.lock" ;;
        fail)     ( flock 202; echo "[$ts] $2" >> "$LOG_FAIL"     ) 202>"${LOG_FILE}.fail.lock" ;;
        skip)     ( flock 203; echo "[$ts] $2" >> "$LOG_SKIP"     ) 203>"${LOG_FILE}.skip.lock" ;;
        already)  ( flock 204; echo "[$ts] $2" >> "$LOG_ALREADY"  ) 204>"${LOG_FILE}.already.lock" ;;
        noplugin) ( flock 205; echo "[$ts] $2" >> "$LOG_NOPLUGIN" ) 205>"${LOG_FILE}.noplugin.lock" ;;
        nokey)    ( flock 206; echo "[$ts] $2" >> "$LOG_NOKEY"    ) 206>"${LOG_FILE}.nokey.lock" ;;
    esac
}

cleanup() {
    wait
    rm -rf "$RESULT_DIR"
    rm -f "$LOCK_FILE" \
        "${LOG_FILE}.pass.lock" "${LOG_FILE}.fail.lock" "${LOG_FILE}.skip.lock" \
        "${LOG_FILE}.already.lock" "${LOG_FILE}.noplugin.lock" "${LOG_FILE}.nokey.lock"
}
trap cleanup EXIT

# ─── ตรวจ WP-CLI ─────────────────────────────────────────────
if ! command -v wp &>/dev/null; then
    log "❌ ERROR: ไม่พบ WP-CLI — https://wp-cli.org"
    exit 1
fi

# ─── ล้าง log ก่อนรัน ────────────────────────────────────────
> "$LOG_FILE"
> "$LOG_PASS"
> "$LOG_FAIL"
> "$LOG_SKIP"
> "$LOG_ALREADY"
> "$LOG_NOPLUGIN"
> "$LOG_NOKEY"

START_TIME=$(date +%s)
log "======================================"
log " BULK RANK MATH CONNECT ACCOUNT"
log " เริ่มเวลา   : $(date '+%Y-%m-%d %H:%M:%S')"
log " Jobs        : $MAX_JOBS | Retry: ${MAX_RETRY}x | RetryDelay: ${RETRY_DELAY}s"
log " License Key : ${RM_LICENSE_KEY:-(ไม่ได้ตั้งค่า)}"
log "======================================"

# ─── ค้นหา WordPress ทุกเว็บ ─────────────────────────────────
declare -A _SEEN
DIRS=()

# แหล่งที่ 1: WHM — /etc/trueuserdomains
if [[ -f /etc/trueuserdomains ]]; then
    while IFS=' ' read -r _dom _usr _rest; do
        _usr="${_usr%:}"
        [[ -z "$_usr" ]] && continue
        _uhome=$(getent passwd "$_usr" 2>/dev/null | cut -d: -f6)
        [[ -d "$_uhome" ]] || continue
        while IFS= read -r -d '' _wpc; do
            _d="$(dirname "$_wpc")/"
            [[ -z "${_SEEN[$_d]+_}" ]] && { _SEEN[$_d]=1; DIRS+=("$_d"); }
        done < <(find "$_uhome" -maxdepth 5 -name "wp-config.php" -print0 2>/dev/null)
    done < /etc/trueuserdomains
fi

# แหล่งที่ 2: Scan /home /home2 /home3 /home4 /home5 /usr/home
for _base in /home /home2 /home3 /home4 /home5 /usr/home; do
    [[ -d "$_base" ]] || continue
    while IFS= read -r -d '' _wpc; do
        _d="$(dirname "$_wpc")/"
        [[ -z "${_SEEN[$_d]+_}" ]] && { _SEEN[$_d]=1; DIRS+=("$_d"); }
    done < <(find "$_base" -maxdepth 5 -name "wp-config.php" -print0 2>/dev/null)
done

TOTAL=${#DIRS[@]}
log "พบ WordPress : $TOTAL เว็บ"
log "======================================"

# ─── ฟังก์ชัน process แต่ละเว็บ (รัน parallel) ───────────────
process_site() {
    local dir="$1"
    local COUNT="$2"
    local TOTAL="$3"
    local SITE UNIQ
    SITE=$(echo "$dir" | sed 's|/home[0-9]*/||;s|/$||')
    UNIQ="${BASHPID}_$(date +%s%N)"
    local LABEL="[$COUNT/$TOTAL] $SITE"

    # ── Skip /public_html/ root ───────────────────────────────
    if [[ "$dir" =~ /public_html/$ ]]; then
        return
    fi

    _log() {
        local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$1"
        ( flock 200; echo "[$ts] $1" >> "$LOG_FILE" ) 200>"$LOCK_FILE"
    }
    _log_r() {
        local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
        case "$1" in
            pass)     ( flock 201; echo "[$ts] $2" >> "$LOG_PASS"     ) 201>"${LOG_FILE}.pass.lock" ;;
            fail)     ( flock 202; echo "[$ts] $2" >> "$LOG_FAIL"     ) 202>"${LOG_FILE}.fail.lock" ;;
            skip)     ( flock 203; echo "[$ts] $2" >> "$LOG_SKIP"     ) 203>"${LOG_FILE}.skip.lock" ;;
            already)  ( flock 204; echo "[$ts] $2" >> "$LOG_ALREADY"  ) 204>"${LOG_FILE}.already.lock" ;;
            noplugin) ( flock 205; echo "[$ts] $2" >> "$LOG_NOPLUGIN" ) 205>"${LOG_FILE}.noplugin.lock" ;;
            nokey)    ( flock 206; echo "[$ts] $2" >> "$LOG_NOKEY"    ) 206>"${LOG_FILE}.nokey.lock" ;;
        esac
    }

    local MR="$MAX_RETRY"
    local RD="$RETRY_DELAY"
    local LICENSE="$RM_LICENSE_KEY"

    EVAL_OUT=$(timeout "$WP_TIMEOUT" wp --path="$dir" eval '
        // ── 1. Plugin active? ────────────────────────────────
        $plugin_file = "seo-by-rank-math/rank-math.php";
        if (!is_plugin_active($plugin_file)) {
            $alt = "rank-math-seo/rank-math.php";
            if (!is_plugin_active($alt)) {
                echo "STATUS:NOPLUGIN"; return;
            }
        }

        // ── 2. ตรวจสถานะ Connected อยู่แล้วหรือไม่ ──────────
        $connect_data = get_option("rank_math_connect_data", []);
        $is_connected = !empty($connect_data) && !empty($connect_data["access_token"]);

        if ($is_connected) {
            $email = $connect_data["user_email"] ?? $connect_data["email"] ?? "unknown";
            $plan  = $connect_data["plan"]       ?? "unknown";
            printf("STATUS:ALREADY\tEMAIL:%s\tPLAN:%s", $email, $plan);
            return;
        }

        // ── 3. ตรวจ License Key ───────────────────────────────
        $license_key = trim("'"$LICENSE"'");

        if (!$license_key) {
            $stored = get_option("rank_math_license_key", "");
            $license_key = trim((string) $stored);
        }

        if (!$license_key) {
            echo "STATUS:NOKEY"; return;
        }

        // ── 4. เรียก Rank Math API เพื่อ Activate License ────
        $site_url    = get_site_url();
        $max_retry   = '"$MR"';
        $retry_delay = '"$RD"';
        $attempt     = 0;
        $api_error   = "";
        $result_data = [];

        while ($attempt < $max_retry) {
            $attempt++;

            $response = wp_remote_post("https://rankmath.com/wp-json/rankmath/v1/activate", [
                "timeout" => 15,
                "body"    => [
                    "license" => $license_key,
                    "site"    => $site_url,
                ],
            ]);

            if (is_wp_error($response)) {
                $api_error = $response->get_error_message();
                if ($attempt < $max_retry) { sleep($retry_delay); continue; }
                break;
            }

            $http_code = wp_remote_retrieve_response_code($response);
            $body      = json_decode(wp_remote_retrieve_body($response), true);

            if ($http_code !== 200) {
                $api_error = "http:" . $http_code;
                if ($attempt < $max_retry) { sleep($retry_delay); continue; }
                break;
            }

            if (!empty($body["success"]) || !empty($body["activated"])) {
                $result_data = $body;
                break;
            }

            $api_error = $body["message"] ?? json_encode($body);
            if ($attempt < $max_retry) sleep($retry_delay);
        }

        // ── 5. บันทึก connect data ลง DB ─────────────────────
        if (!empty($result_data)) {
            $connect = [
                "access_token" => $result_data["token"]   ?? $license_key,
                "user_email"   => $result_data["email"]   ?? "",
                "plan"         => $result_data["plan"]    ?? "free",
                "expires"      => $result_data["expires"] ?? "",
                "connected_at" => current_time("mysql"),
            ];
            update_option("rank_math_connect_data", $connect);
            update_option("rank_math_license_key",  $license_key);

            $verify = get_option("rank_math_connect_data", []);
            $saved  = !empty($verify["access_token"]) ? "1" : "0";

            printf("STATUS:DONE\tEMAIL:%s\tPLAN:%s\tATTEMPT:%d\tSAVED:%s\tERROR:",
                $connect["user_email"], $connect["plan"], $attempt, $saved
            );
        } else {
            printf("STATUS:FAIL\tATTEMPT:%d\tERROR:%s", $attempt, $api_error);
        }
    ' --allow-root 2>/dev/null)

    local STATUS
    STATUS=$(echo "$EVAL_OUT" | grep -oP '(?<=STATUS:)\w+')

    case "$STATUS" in
        ALREADY)
            local AE AP
            AE=$(echo "$EVAL_OUT" | grep -oP '(?<=EMAIL:)[^\t]*')
            AP=$(echo "$EVAL_OUT" | grep -oP '(?<=PLAN:)[^\t]*')
            _log  "✔️  ALREADY: $LABEL | email=$AE | plan=$AP"
            _log_r already "$SITE | email=$AE | plan=$AP"
            touch "${RESULT_DIR}/already_${UNIQ}"
            ;;
        NOPLUGIN)
            _log  "⏭  SKIP (ไม่มี Rank Math Plugin): $LABEL"
            _log_r noplugin "$SITE | Rank Math ไม่ได้ติดตั้งหรือไม่ active"
            touch "${RESULT_DIR}/noplugin_${UNIQ}"
            ;;
        NOKEY)
            _log  "🔑 NOKEY: $LABEL | ไม่มี License Key"
            _log_r nokey "$SITE | ต้องกำหนด RM_LICENSE_KEY ใน script"
            touch "${RESULT_DIR}/nokey_${UNIQ}"
            ;;
        DONE)
            local DE DP DA DS
            DE=$(echo "$EVAL_OUT" | grep -oP '(?<=EMAIL:)[^\t]*')
            DP=$(echo "$EVAL_OUT" | grep -oP '(?<=PLAN:)[^\t]*')
            DA=$(echo "$EVAL_OUT" | grep -oP '(?<=ATTEMPT:)\d+')
            DS=$(echo "$EVAL_OUT" | grep -oP '(?<=SAVED:)\d+')
            if [[ "$DS" == "1" ]]; then
                _log  "✅ PASS: $LABEL | email=$DE | plan=$DP | attempt=${DA}/${MAX_RETRY}"
                _log_r pass "$SITE | email=$DE | plan=$DP | attempt=${DA}/${MAX_RETRY}"
                touch "${RESULT_DIR}/pass_${UNIQ}"
            else
                _log  "❌ FAIL (บันทึก DB ล้มเหลว): $LABEL | email=$DE"
                _log_r fail "$SITE | API สำเร็จแต่บันทึก DB ล้มเหลว | email=$DE"
                touch "${RESULT_DIR}/fail_${UNIQ}"
            fi
            ;;
        FAIL)
            local FA FE
            FA=$(echo "$EVAL_OUT" | grep -oP '(?<=ATTEMPT:)\d+')
            FE=$(echo "$EVAL_OUT" | grep -oP '(?<=ERROR:).*')
            _log  "❌ FAIL: $LABEL | attempt=${FA}/${MAX_RETRY} | error=$FE"
            _log_r fail "$SITE | attempt=${FA}/${MAX_RETRY} | error=$FE"
            touch "${RESULT_DIR}/fail_${UNIQ}"
            ;;
        *)
            _log  "❌ FAIL (wp error/timeout): $LABEL | ${EVAL_OUT:0:120}"
            _log_r fail "$SITE | wp eval ล้มเหลว | ${EVAL_OUT:0:120}"
            touch "${RESULT_DIR}/fail_${UNIQ}"
            ;;
    esac
}

export -f process_site
export LOG_FILE LOCK_FILE LOG_PASS LOG_FAIL LOG_SKIP LOG_ALREADY LOG_NOPLUGIN LOG_NOKEY
export RESULT_DIR WP_TIMEOUT MAX_RETRY RETRY_DELAY RM_LICENSE_KEY

# ─── รัน parallel ────────────────────────────────────────────
declare -a PIDS=()
COUNT=0
for dir in "${DIRS[@]}"; do
    COUNT=$(( COUNT + 1 ))
    process_site "$dir" "$COUNT" "$TOTAL" &
    PIDS+=($!)
    if (( ${#PIDS[@]} >= MAX_JOBS )); then
        wait "${PIDS[0]}"
        PIDS=("${PIDS[@]:1}")
    fi
done
for pid in "${PIDS[@]}"; do wait "$pid"; done

# ─── สรุป ────────────────────────────────────────────────────
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
SUCCESS=$(  find "$RESULT_DIR" -name "pass_*"     2>/dev/null | wc -l)
FAILED=$(   find "$RESULT_DIR" -name "fail_*"     2>/dev/null | wc -l)
ALREADY=$(  find "$RESULT_DIR" -name "already_*"  2>/dev/null | wc -l)
NOPLUGIN=$( find "$RESULT_DIR" -name "noplugin_*" 2>/dev/null | wc -l)
NOKEY=$(    find "$RESULT_DIR" -name "nokey_*"    2>/dev/null | wc -l)

log "======================================"
log " สรุปผลรวม"
log " รวมทั้งหมด              : $TOTAL เว็บ"
log " ✅ Pass (connected ใหม่) : $SUCCESS เว็บ"
log " ✔️  Already connected    : $ALREADY เว็บ  (เชื่อมต่ออยู่แล้ว)"
log " ❌ Fail                  : $FAILED เว็บ   (API error/timeout)"
log " 🔑 No License Key        : $NOKEY เว็บ   (ต้องตั้ง RM_LICENSE_KEY)"
log " ⏭  No Plugin             : $NOPLUGIN เว็บ (ไม่มี Rank Math)"
log " เวลาที่ใช้               : $(( ELAPSED / 60 )) นาที $(( ELAPSED % 60 )) วินาที"
log "======================================"
log " Log รวม     : $LOG_FILE"
log " ✅ Pass      : $LOG_PASS"
log " ✔️  Already   : $LOG_ALREADY"
log " ❌ Fail      : $LOG_FAIL"
log " 🔑 No Key    : $LOG_NOKEY"
log " ⏭  No Plugin : $LOG_NOPLUGIN"
log "======================================"

exit 0
