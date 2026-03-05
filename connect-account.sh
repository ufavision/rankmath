#!/bin/bash
# =============================================================
#  rankmath-connect-bulk.sh
#  Bulk Connect Account — Rank Math SEO (Free Plan)
# =============================================================

VERSION="1.1.5"

MAX_JOBS=10
WP_TIMEOUT=25
DEACT_TIMEOUT=8

# ─── โหลด credentials ────────────────────────────────────────
# รองรับ 3 วิธี:
#   1. ส่ง config file path เป็น argument:  bash script.sh /path/to/conf
#   2. ใช้ env var:  RANKMATH_CONF=/path/to/conf bash script.sh
#   3. ใช้ default:  /root/.rankmath-connect.conf

CONFIG_FILE="${1:-${RANKMATH_CONF:-/root/.rankmath-connect.conf}}"

# รองรับกรณีส่งเข้ามาเป็น /dev/fd/xx (pipe จาก bash <(...))
if [[ "$CONFIG_FILE" == /dev/fd/* || "$CONFIG_FILE" == /proc/self/fd/* ]]; then
    _TMP_CONF=$(mktemp /tmp/rankmath-conf-XXXXXX)
    cat "$CONFIG_FILE" > "$_TMP_CONF"
    CONFIG_FILE="$_TMP_CONF"
    trap 'rm -f "$_TMP_CONF"' EXIT
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌ ERROR: ไม่พบ config file: $CONFIG_FILE"
    echo "วิธีใช้:"
    echo "  bash script.sh /path/to/rankmath-connect.conf"
    echo "  RANKMATH_CONF=/path/to/conf bash script.sh"
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

for _var in RM_USERNAME RM_EMAIL RM_API_KEY RM_PLAN RM_OLD_USERNAME RM_OLD_API_KEY; do
    if [[ -z "${!_var}" ]]; then
        echo "❌ ERROR: config ขาด $_var"
        exit 1
    fi
done
# ─────────────────────────────────────────────────────────────

LOG_DIR="/var/log"
LOG_FILE="$LOG_DIR/rankmath-connect.log"
LOG_PASS="$LOG_DIR/rankmath-connect-pass.log"
LOG_FAIL="$LOG_DIR/rankmath-connect-fail.log"
LOG_ALREADY="$LOG_DIR/rankmath-connect-already.log"
LOG_OVERWRITE="$LOG_DIR/rankmath-connect-overwrite.log"
LOG_NOPLUGIN="$LOG_DIR/rankmath-connect-noplugin.log"

RESULT_DIR="/tmp/rankmath-$$"
mkdir -p "$RESULT_DIR"

# ─── ตรวจ WP-CLI ─────────────────────────────────────────────
WP_BIN=$(command -v wp 2>/dev/null)
if [[ -z "$WP_BIN" ]]; then
    echo "❌ ERROR: ไม่พบ WP-CLI — https://wp-cli.org"
    exit 1
fi

# ─── Logging (atomic write) ──────────────────────────────────
_write_log() {
    local file="$1" msg="$2" lock="${1}.lck"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    (
        flock -x 9
        echo "[$ts] $msg" >> "$file"
    ) 9>"$lock"
}

log_main()      { echo "$1"; _write_log "$LOG_FILE"      "$1"; }
log_pass()      { _write_log "$LOG_PASS"      "$1"; }
log_fail()      { _write_log "$LOG_FAIL"      "$1"; }
log_already()   { _write_log "$LOG_ALREADY"   "$1"; }
log_overwrite() { _write_log "$LOG_OVERWRITE" "$1"; }
log_noplugin()  { _write_log "$LOG_NOPLUGIN"  "$1"; }

# ─── Cleanup ─────────────────────────────────────────────────
cleanup() {
    wait 2>/dev/null
    rm -rf "$RESULT_DIR"
    find "$LOG_DIR" -name "rankmath-connect*.lck" -delete 2>/dev/null
}
trap cleanup EXIT INT TERM

# ─── ล้าง log ────────────────────────────────────────────────
> "$LOG_FILE"; > "$LOG_PASS"; > "$LOG_FAIL"
> "$LOG_ALREADY"; > "$LOG_OVERWRITE"; > "$LOG_NOPLUGIN"

START_TIME=$(date +%s)
log_main "======================================"
log_main " BULK RANK MATH CONNECT (FREE PLAN)"
log_main " Version  : v$VERSION"
log_main " เริ่มเวลา : $(date '+%Y-%m-%d %H:%M:%S')"
log_main " Account  : $RM_EMAIL | plan=$RM_PLAN"
log_main " Jobs     : $MAX_JOBS"
log_main "======================================"

# ─── ค้นหา WordPress ทุกเว็บ ─────────────────────────────────
declare -A _SEEN
DIRS=()

_add_dir() {
    local d; d="$(dirname "$1")/"
    [[ -z "${_SEEN[$d]+_}" ]] && { _SEEN[$d]=1; DIRS+=("$d"); }
}

if [[ -f /etc/trueuserdomains ]]; then
    while IFS=' ' read -r _dom _usr _rest; do
        _usr="${_usr%:}"
        [[ -z "$_usr" ]] && continue
        _uhome=$(getent passwd "$_usr" 2>/dev/null | cut -d: -f6)
        [[ -d "$_uhome" ]] || continue
        while IFS= read -r -d '' f; do _add_dir "$f"; done \
            < <(find "$_uhome" -maxdepth 6 -name "wp-config.php" -print0 2>/dev/null)
    done < /etc/trueuserdomains
fi

for _base in /home /home2 /home3 /home4 /home5 /usr/home; do
    [[ -d "$_base" ]] || continue
    while IFS= read -r -d '' f; do _add_dir "$f"; done \
        < <(find "$_base" -maxdepth 6 -name "wp-config.php" -print0 2>/dev/null)
done

TOTAL=${#DIRS[@]}
log_main "พบ WordPress : $TOTAL เว็บ"
log_main "======================================"

# ─── deactivateSite แบบ background (non-blocking) ────────────
deactivate_bg() {
    local u="$1" k="$2" site="$3"
    curl -s -m "$DEACT_TIMEOUT" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$u\",\"api_key\":\"$k\",\"site_url\":\"$site\"}" \
        "https://rankmath.com/wp-json/rankmath/v1/deactivateSite" \
        &>/dev/null &
    disown
}

# ─── process แต่ละเว็บ ───────────────────────────────────────
process_site() {
    local dir="$1" idx="$2" total="$3"
    local SITE LABEL UNIQ STATUS EVAL_OUT

    SITE=$(echo "$dir" | sed 's|/home[0-9]*/\?||;s|/$||')
    LABEL="[$idx/$total] $SITE"
    UNIQ="${BASHPID}_${idx}"

    [[ -f "${dir}wp-config.php" ]] || return

    EVAL_OUT=$(timeout "$WP_TIMEOUT" \
        "$WP_BIN" --path="$dir" \
            --skip-themes \
            eval '
        // 1. ตรวจ Plugin
        $slug = null;
        foreach (["seo-by-rank-math/rank-math.php","rank-math-seo/rank-math.php"] as $f) {
            if (is_plugin_active($f)) { $slug = $f; break; }
        }
        if (!$slug) { echo "STATUS:NOPLUGIN"; return; }

        // 2. ตรวจ account ปัจจุบัน
        $reg = RankMath\Admin\Admin_Helper::get_registration_data();
        if ($reg && !empty($reg["api_key"])) {
            $cur = $reg["username"] ?? "";
            if ($cur === "'"$RM_USERNAME"'") {
                printf("STATUS:ALREADY\tUSER:%s\tPLAN:%s", $cur, $reg["plan"] ?? "?");
                return;
            }
            $old_key = ($cur === "'"$RM_OLD_USERNAME"'") ? "'"$RM_OLD_API_KEY"'" : ($reg["api_key"] ?? "");
            printf("STATUS:OVERWRITE\tOLD_USER:%s\tOLD_KEY:%s\t", $cur, $old_key);
            RankMath\Admin\Admin_Helper::get_registration_data(false);
            wp_cache_flush();
        }

        // 3. Inject
        $site_url = get_option("siteurl");
        RankMath\Admin\Admin_Helper::get_registration_data([
            "username"  => "'"$RM_USERNAME"'",
            "email"     => "'"$RM_EMAIL"'",
            "api_key"   => "'"$RM_API_KEY"'",
            "plan"      => "'"$RM_PLAN"'",
            "connected" => true,
            "site_url"  => $site_url,
        ]);

        // 4. Flush cache
        wp_cache_flush();
        wp_cache_delete("rank_math_connect_data", "options");
        if (class_exists("LiteSpeed\Purge"))            { LiteSpeed\Purge::purge_all(); }
        elseif (function_exists("litespeed_purge_all")) { litespeed_purge_all(); }

        // 5. Verify
        $v = RankMath\Admin\Admin_Helper::get_registration_data();
        $ok = ($v && ($v["api_key"] ?? "") === "'"$RM_API_KEY"'") ? "1" : "0";
        printf("STATUS:DONE\tSITE:%s\tSAVED:%s", $site_url, $ok);
    ' --allow-root 2>/dev/null)

    STATUS=$(echo "$EVAL_OUT" | grep -oP '(?<=STATUS:)\w+' | head -1)

    case "$STATUS" in
        ALREADY)
            local AU AP
            AU=$(echo "$EVAL_OUT" | grep -oP '(?<=USER:)[^\t]*')
            AP=$(echo "$EVAL_OUT" | grep -oP '(?<=PLAN:)[^\t]*')
            log_main "✔️  ALREADY: $LABEL | user=$AU"
            log_already "$SITE | user=$AU | plan=$AP"
            touch "${RESULT_DIR}/already_${UNIQ}"
            ;;

        OVERWRITE)
            local OLD_U OLD_K DU
            OLD_U=$(echo "$EVAL_OUT" | grep -oP '(?<=OLD_USER:)[^\t ]*')
            OLD_K=$(echo "$EVAL_OUT" | grep -oP '(?<=OLD_KEY:)[^\t ]*')
            DU=$(echo "$EVAL_OUT"    | grep -oP '(?<=SITE:)[^\t ]*')
            [[ -n "$OLD_U" && -n "$OLD_K" && -n "$DU" ]] && deactivate_bg "$OLD_U" "$OLD_K" "$DU"
            if echo "$EVAL_OUT" | grep -q "SAVED:1"; then
                timeout 15 "$WP_BIN" --path="$dir" cache flush --allow-root &>/dev/null &
                timeout 15 "$WP_BIN" --path="$dir" litespeed-purge all --allow-root &>/dev/null &
                log_main "🔄 OVERWRITE: $LABEL | $OLD_U → $RM_USERNAME | $DU"
                log_overwrite "$SITE | old=$OLD_U → new=$RM_USERNAME | site=$DU"
                touch "${RESULT_DIR}/pass_${UNIQ}"
            else
                log_main "❌ FAIL (overwrite): $LABEL | old=$OLD_U"
                log_fail "$SITE | overwrite fail | old=$OLD_U"
                touch "${RESULT_DIR}/fail_${UNIQ}"
            fi
            ;;

        DONE)
            local DU DS
            DU=$(echo "$EVAL_OUT" | grep -oP '(?<=SITE:)[^\t]*')
            DS=$(echo "$EVAL_OUT" | grep -oP '(?<=SAVED:)\d+')
            if [[ "$DS" == "1" ]]; then
                timeout 15 "$WP_BIN" --path="$dir" cache flush --allow-root &>/dev/null &
                timeout 15 "$WP_BIN" --path="$dir" litespeed-purge all --allow-root &>/dev/null &
                log_main "✅ PASS: $LABEL | $DU"
                log_pass "$SITE | site=$DU"
                touch "${RESULT_DIR}/pass_${UNIQ}"
            else
                log_main "❌ FAIL (verify): $LABEL"
                log_fail "$SITE | verify fail"
                touch "${RESULT_DIR}/fail_${UNIQ}"
            fi
            ;;

        NOPLUGIN)
            log_main "⏭  SKIP: $LABEL"
            log_noplugin "$SITE"
            touch "${RESULT_DIR}/noplugin_${UNIQ}"
            ;;

        *)
            local SHORT="${EVAL_OUT:0:120}"
            log_main "❌ FAIL (error): $LABEL | $SHORT"
            log_fail "$SITE | $SHORT"
            touch "${RESULT_DIR}/fail_${UNIQ}"
            ;;
    esac
}

export -f process_site deactivate_bg _write_log log_main log_pass log_fail log_already log_overwrite log_noplugin
export LOG_FILE LOG_PASS LOG_FAIL LOG_ALREADY LOG_OVERWRITE LOG_NOPLUGIN LOG_DIR
export RESULT_DIR WP_TIMEOUT DEACT_TIMEOUT WP_BIN
export RM_USERNAME RM_EMAIL RM_API_KEY RM_PLAN RM_OLD_USERNAME RM_OLD_API_KEY

# ─── Parallel runner ─────────────────────────────────────────
declare -a PIDS=()
COUNT=0
for dir in "${DIRS[@]}"; do
    COUNT=$(( COUNT + 1 ))
    process_site "$dir" "$COUNT" "$TOTAL" &
    PIDS+=($!)
    while (( ${#PIDS[@]} >= MAX_JOBS )); do
        for i in "${!PIDS[@]}"; do
            if ! kill -0 "${PIDS[$i]}" 2>/dev/null; then
                unset "PIDS[$i]"
            fi
        done
        PIDS=("${PIDS[@]}")
        (( ${#PIDS[@]} >= MAX_JOBS )) && sleep 0.2
    done
done
wait

# ─── สรุป ────────────────────────────────────────────────────
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
C_PASS=$(     find "$RESULT_DIR" -name "pass_*"     2>/dev/null | wc -l)
C_FAIL=$(     find "$RESULT_DIR" -name "fail_*"     2>/dev/null | wc -l)
C_ALREADY=$(  find "$RESULT_DIR" -name "already_*"  2>/dev/null | wc -l)
C_NOPLUGIN=$( find "$RESULT_DIR" -name "noplugin_*" 2>/dev/null | wc -l)
C_OVERWRITE=$(grep -c "" "$LOG_OVERWRITE" 2>/dev/null || echo 0)

log_main "======================================"
log_main " สรุปผลรวม"
log_main " รวมทั้งหมด              : $TOTAL เว็บ"
log_main " ✅ Pass/Overwrite       : $C_PASS เว็บ (รวม overwrite $C_OVERWRITE เว็บ)"
log_main " ✔️  Already              : $C_ALREADY เว็บ (ข้ามแล้ว)"
log_main " ❌ Fail                  : $C_FAIL เว็บ"
log_main " ⏭  No Plugin             : $C_NOPLUGIN เว็บ"
log_main " เวลาที่ใช้               : $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"
log_main "======================================"
log_main " ✅ Pass      : $LOG_PASS"
log_main " ✔️  Already   : $LOG_ALREADY"
log_main " 🔄 Overwrite : $LOG_OVERWRITE"
log_main " ❌ Fail      : $LOG_FAIL"
log_main " ⏭  Skip      : $LOG_NOPLUGIN"
log_main "======================================"
