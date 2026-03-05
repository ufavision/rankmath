#!/bin/bash

# ============================================================
# WordPress Rank Math Plugin - Login & Connect Script
# Site: whanjeab.co
# ============================================================

WP_URL="https://whanjeab.co"
WP_USER="ufavisionseoteam@gmail.com"
WP_PASS="Areeif300533@"
COOKIE_FILE="/tmp/wp_cookies_whanjeab.txt"
LOG_FILE="/tmp/rankmath_log.txt"

# สีสำหรับ output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  WordPress Rank Math Connect Script${NC}"
echo -e "${BLUE}  Site: ${WP_URL}${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# ---- STEP 1: ตรวจสอบว่าเว็บเข้าถึงได้ ----
echo -e "${YELLOW}[1/4] ตรวจสอบการเข้าถึงเว็บไซต์...${NC}"
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$WP_URL")

if [ "$HTTP_STATUS" -eq 200 ] || [ "$HTTP_STATUS" -eq 301 ] || [ "$HTTP_STATUS" -eq 302 ]; then
    echo -e "${GREEN}    ✅ เว็บไซต์ตอบสนอง (HTTP $HTTP_STATUS)${NC}"
else
    echo -e "${RED}    ❌ ไม่สามารถเข้าถึงเว็บไซต์ได้ (HTTP $HTTP_STATUS)${NC}"
    exit 1
fi

# ---- STEP 2: ดึง Login Nonce ----
echo -e "${YELLOW}[2/4] กำลัง Login เข้า WordPress Admin...${NC}"

LOGIN_PAGE=$(curl -s -c "$COOKIE_FILE" "$WP_URL/wp-login.php")
LOGIN_NONCE=$(echo "$LOGIN_PAGE" | grep -oP '(?<=name="testcookie" value=")[^"]*' || echo "")

# Login
LOGIN_RESPONSE=$(curl -s -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
    -X POST "$WP_URL/wp-login.php" \
    --data-urlencode "log=$WP_USER" \
    --data-urlencode "pwd=$WP_PASS" \
    --data-urlencode "wp-submit=Log In" \
    --data-urlencode "redirect_to=/wp-admin/" \
    --data-urlencode "testcookie=1" \
    -L \
    -w "\n%{http_code}" \
    -o /tmp/login_response_body.html)

LOGIN_STATUS=$(tail -n1 <<< "$LOGIN_RESPONSE")
LOGIN_BODY=$(cat /tmp/login_response_body.html)

# ตรวจสอบว่า Login สำเร็จ
if echo "$LOGIN_BODY" | grep -q "Dashboard\|wp-admin\|ยินดีต้อนรับ\|Welcome"; then
    echo -e "${GREEN}    ✅ Login สำเร็จ!${NC}"
elif echo "$LOGIN_BODY" | grep -q "login_error\|ERROR\|incorrect"; then
    echo -e "${RED}    ❌ Login ล้มเหลว - Username หรือ Password ไม่ถูกต้อง${NC}"
    exit 1
else
    # ลองตรวจสอบจาก cookie
    if grep -q "wordpress_logged_in" "$COOKIE_FILE" 2>/dev/null; then
        echo -e "${GREEN}    ✅ Login สำเร็จ (ยืนยันจาก cookie)${NC}"
    else
        echo -e "${YELLOW}    ⚠️  ไม่สามารถยืนยัน Login ได้แน่ชัด (HTTP $LOGIN_STATUS)${NC}"
    fi
fi

# ---- STEP 3: เข้าถึง Rank Math Dashboard ----
echo -e "${YELLOW}[3/4] กำลังเข้าถึง Rank Math Plugin...${NC}"

RANKMATH_URL="$WP_URL/wp-admin/admin.php?page=rank-math"

RANKMATH_RESPONSE=$(curl -s -b "$COOKIE_FILE" \
    "$RANKMATH_URL" \
    -w "\n%{http_code}" \
    -o /tmp/rankmath_response_body.html)

RANKMATH_STATUS=$(tail -n1 <<< "$RANKMATH_RESPONSE")
RANKMATH_BODY=$(cat /tmp/rankmath_response_body.html)

if echo "$RANKMATH_BODY" | grep -qi "rank.math\|rank-math\|rankmath"; then
    echo -e "${GREEN}    ✅ พบ Rank Math Plugin! (HTTP $RANKMATH_STATUS)${NC}"
    
    # ดึงข้อมูล Version
    RM_VERSION=$(echo "$RANKMATH_BODY" | grep -oP '(?<=Rank Math SEO )[0-9.]+' | head -1)
    if [ -n "$RM_VERSION" ]; then
        echo -e "${GREEN}    📦 Rank Math Version: $RM_VERSION${NC}"
    fi
else
    echo -e "${RED}    ❌ ไม่พบ Rank Math Plugin หรือ Plugin ไม่ได้ติดตั้ง (HTTP $RANKMATH_STATUS)${NC}"
fi

# ---- STEP 4: ตรวจสอบ Rank Math Connect Status ----
echo -e "${YELLOW}[4/4] ตรวจสอบ Rank Math Account Connection...${NC}"

CONNECT_URL="$WP_URL/wp-admin/admin.php?page=rank-math-registration"

CONNECT_RESPONSE=$(curl -s -b "$COOKIE_FILE" \
    "$CONNECT_URL" \
    -w "\n%{http_code}" \
    -o /tmp/connect_response_body.html)

CONNECT_BODY=$(cat /tmp/connect_response_body.html)

if echo "$CONNECT_BODY" | grep -qi "connected\|activate\|registered"; then
    echo -e "${GREEN}    ✅ Rank Math Account เชื่อมต่อแล้ว${NC}"
elif echo "$CONNECT_BODY" | grep -qi "connect\|register\|login"; then
    echo -e "${YELLOW}    ⚠️  Rank Math ยังไม่ได้เชื่อมต่อ Account${NC}"
fi

# ---- สรุปผล ----
echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  สรุปผลการทดสอบ${NC}"
echo -e "${BLUE}============================================${NC}"
echo -e "  🌐 Site URL   : $WP_URL"
echo -e "  👤 User       : $WP_USER"
echo -e "  🍪 Cookie     : $COOKIE_FILE"
echo -e "  📄 Log        : $LOG_FILE"
echo ""

# บันทึก log
{
    echo "=== Rank Math Connect Log ==="
    echo "Date     : $(date)"
    echo "Site     : $WP_URL"
    echo "User     : $WP_USER"
    echo "Status   : Done"
} > "$LOG_FILE"

echo -e "${GREEN}✅ ทดสอบเสร็จสิ้น! ดู log ได้ที่: $LOG_FILE${NC}"

# ---- Cleanup ----
rm -f /tmp/login_response_body.html /tmp/rankmath_response_body.html /tmp/connect_response_body.html
