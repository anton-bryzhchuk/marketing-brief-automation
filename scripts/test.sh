#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
base_url=${BASE_URL:-http://127.0.0.1:5678}
if [ -z "${WEBHOOK_API_KEY:-}" ]; then
    WEBHOOK_API_KEY=$(sed -n 's/^WEBHOOK_API_KEY=//p' .env | head -n 1)
fi
: "${WEBHOOK_API_KEY:?Set WEBHOOK_API_KEY or put it in .env}"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
body=$scratch/response.json
failures=0
valid='{"topic":"Plan a spring campaign","audience":"Small business owners"}'

request() {
    endpoint=$1
    payload=$2
    shift 2
    if ! http_status=$(curl --silent --show-error --max-time 120 -o "$body" -w '%{http_code}' \
        "$base_url/webhook/$endpoint" -H 'Content-Type: application/json' \
        "$@" --data "$payload"); then
        http_status=000
        printf '{}\n' > "$body"
    fi
}

assert_response() {
    label=$1
    expected=$2
    condition=$3
    if [ "$http_status" = "$expected" ] && jq -e "$condition" "$body" >/dev/null; then
        printf 'PASS %s (HTTP %s)\n' "$label" "$http_status"
    else
        printf 'FAIL %s (expected HTTP %s, received %s)\n' "$label" "$expected" "$http_status"
        cat "$body"
        printf '\n'
        failures=$((failures + 1))
    fi
}

run_id() {
    jq -r '.run_id // ""' "$body"
}

key="X-API-KEY: $WEBHOOK_API_KEY"
request marketing-brief "$valid" -H "$key"
assert_response '1 Valid brief and package' 200 '
    def text_limit($max): type == "string" and test("\\S") and length <= $max;
    def text_list($min; $max):
        type == "array" and length >= $min and length <= $max and all(.[]; type == "string" and test("\\S"));
    .status == "approved" and (.run_id | type == "string") and
    any(.checks[]; .stage == "output" and .passed and .attempt == 1) and
    (.package |
        keys == ["keywords", "linkedin_post", "meta_description", "outline", "seo_title"] and
        (.seo_title | text_limit(60)) and (.meta_description | text_limit(155)) and
        (.linkedin_post | text_limit(600)) and (.outline | text_list(5; 7)) and
        (.keywords | text_list(5; 8)))
'
approved=$(run_id)
cp "$body" "$scratch/approved.json"

request marketing-brief "$valid"
assert_response '2 Missing API key' 401 '.status == "rejected" and .package == null and (.message | contains("X-API-KEY"))'
unauthorized=$(run_id)

request marketing-brief '{"topic":"Plan a spring campaign"}' -H "$key"
assert_response '3 Missing audience' 400 '.status == "rejected" and .package == null and (.message | contains("audience"))'
rejected=$(run_id)

request marketing-brief '{"topic":"Campaign FORCE_INVALID","audience":"Editors"}' -H "$key"
assert_response '4 Corrective retry and needs_review' 200 '
    .status == "needs_review" and .package == null and
    ([.checks[] | select(.stage == "output" and .passed == false) | .attempt] == [1, 2])
'
review_required=$(run_id)

request marketing-brief '{"topic":"Campaign FORCE_ERROR","audience":"Editors"}' -H "$key"
assert_response '5 Provider outage' 502 '
    .status == "error" and .package == null and
    (.message | contains("provider is unavailable")) and any(.checks[]; .stage == "provider" and (.passed | not))
'
errored=$(run_id)

request marketing-brief '{"topic":"Frühlingskampagne","audience":"Redaktion","language":"de"}' -H "$key"
assert_response 'German brief after outage' 200 '.status == "approved" and (.package.seo_title | contains("Leitfaden"))'
german=$(run_id)

request marketing-brief-review "$(jq -nc --arg id "$approved" '{run_id:$id, decision:"approve", note:"Editorially checked."}')" -H "$key"
assert_response 'Human approval recorded' 200 '.decision == "approve" and .note == "Editorially checked." and (.reviewed_at | type == "string")'
request marketing-brief-review "$(jq -nc --arg id "$approved" '{run_id:$id, decision:"approve"}')" -H "$key"
assert_response 'Duplicate approval rejected' 409 '.message | contains("already been recorded")'
request marketing-brief-review "$(jq -nc --arg id "$review_required" '{run_id:$id, decision:"request_changes"}')" -H "$key"
assert_response 'Failed draft sent back for changes' 200 '.decision == "request_changes"'

check_log() {
    jq -es --arg a "$approved" --arg u "$unauthorized" --arg r "$rejected" \
        --arg n "$review_required" --arg e "$errored" --arg g "$german" '
        def entry($id; $status; $attempts):
            [.[] | select(.run_id == $id)] | length == 1 and
            all(.[]; .status == $status and .generation_attempts == $attempts and
                (.duration_ms >= 0) and (.checks | length > 0) and (.timestamp | type == "string"));
        entry($a; "approved"; 1) and entry($u; "rejected"; 0) and entry($r; "rejected"; 0) and
        entry($n; "needs_review"; 2) and entry($e; "error"; 1) and entry($g; "approved"; 1)
    ' data/runs.jsonl >/dev/null
}

# The Error Trigger runs asynchronously after the client receives its 502.
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if [ -f data/errors.jsonl ] && jq -es --arg id "$errored" '
        any(.[]; .run_id == $id and .error_code == "provider_unavailable")
    ' data/errors.jsonl >/dev/null; then
        touch "$scratch/error-logged"
        break
    fi
    sleep 1
done

if check_log &&
    jq -e --slurpfile approved "$scratch/approved.json" '
        .editorial_review == "pending" and .package == $approved[0].package
    ' "data/packages/$approved.json" >/dev/null &&
    jq -e '.status == "needs_review" and .editorial_review == "pending" and (.candidate | length > 0)' \
        "data/packages/$review_required.json" >/dev/null &&
    jq -e '.decision == "approve"' "data/reviews/$approved.json" >/dev/null &&
    jq -e '.decision == "request_changes"' "data/reviews/$review_required.json" >/dev/null &&
    [ -f "$scratch/error-logged" ]; then
    printf 'PASS 6 Audit rows, packages, editorial decisions, and error workflow log\n'
else
    printf 'FAIL 6 Audit rows, packages, editorial decisions, or error workflow log\n'
    failures=$((failures + 1))
fi

if docker compose logs --no-log-prefix mock > "$scratch/mock.log" &&
    jq -esR --arg invalid "$review_required" --arg error "$errored" '
        def events($id): split("\n") | map(fromjson? | select(.run_id == $id));
        ((events($invalid) | map([.status, .correction])) == [[200,false],[200,true]]) and
        ((events($error) | map(.status)) == [500,500,500])
    ' "$scratch/mock.log" >/dev/null; then
    printf 'PASS 7 Mock observed one corrective call and three outage attempts\n'
else
    printf 'FAIL 7 Mock call counts\n'
    failures=$((failures + 1))
fi

[ "$failures" -eq 0 ] || exit 1
printf 'All mock acceptance tests passed.\n'
