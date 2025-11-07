#!/usr/bin/env bash

set -e
set -o pipefail

check-cmd() {
  [[ -z "$*" ]] && exit 2
  error=false
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null; then
      echo "Need $cmd installed"
      error=true
    fi
  done

  [[ "$error" == false ]]
}

check-cmd gh jq sendmail

# Defaults
ORG=NLnetLabs
REPOS=()

OLDEST="7 days ago"
NEWEST="2 days ago"

TO=""
FROM="$USER@$HOSTNAME"
SUBJECT_PRE="Reminder about unanswered issues in"
SUBJECT="$SUBJECT_PRE <repository>"
SENDMAIL_ACCOUNT=default

###
# Argument parsing and help
###

SCRIPTNAME=$0

usage() {
  cat <<EOF
Usage: $SCRIPTNAME [OPTIONS] -t <recipient> <repository...>

Notify the recipient via e-mail about unanswered GitHub issues, if they are older than '--until' and have no labels or assignees.

Requires jq, gh, and sendmail.

Options:
  -t, --to            Specify the email address to send the reminder mail to
  -f, --from          Specify the email address to send the reminder mail from [default: $FROM]
      --subject       Specify the email subject for the reminder mail [default: $SUBJECT]
  -o, --org           Specify the GitHub organization to fetch the members list [default: $ORG]
  -s, --since         Specify how old issues should maximally be to be fetched and checked for comments [default: $OLDEST]
  -u, --until         Specify how old issues should be at least to be considered unanswered [default: $NEWEST]
  -a, --account       Specify the sendmail account to use [default: $SENDMAIL_ACCOUNT]
      --cat           Print the resulting e-mail to the terminal instead of sending it out
  -h, --help          Print this help text
EOF
}

check-empty() {
  if [[ -z "$2" ]]; then
    echo "Missing $1 '$3' $4"
    usage
    exit 1
  fi
}

check-empty-opt() { check-empty option "$@"; }
check-empty-arg() { check-empty argument "$@"; }

# Assigning to a variable first to exit on getopt failure (through set -e)
PARSED_ARGS=$(getopt -n "$0" -o "ht:f:o:s:u:a:" -l "help,cat,to:,from:,org:,since:,until:,subject:,account:" -- "$@")
eval set -- "$PARSED_ARGS"

while [[ -n "$1" ]]; do
  case "$1" in
    -h|--help)
      usage && exit
      ;;
    --cat)
      CAT_ONLY=true
      shift 1
      ;;
    -t|--to)
      TO=$2
      shift 2
      ;;
    -f|--from)
      FROM=$2
      shift 2
      ;;
    -o|--org)
      ORG=$2
      shift 2
      ;;
    -s|--since)
      OLDEST=$2
      shift 2
      ;;
    -u|--until)
      NEWEST=$2
      shift 2
      ;;
    --subject)
      SUBJECT=$2
      shift 2
      ;;
    -a|--account)
      SENDMAIL_ACCOUNT=$2
      shift 2
      ;;
    --)
      shift 1
      break
      ;;
    *) echo "Unknown option: $1" && usage && exit 1
  esac
done

REPOS=("$@")

check-empty-opt "$TO" "-t" "(recipient)"
check-empty-arg "${REPOS[*]}" "repository"

##
## Functions ##
##

function prettify-issues() {
  [[ -z "$1" ]] && return 1
  <<<"$1" jq -r 'sort_by(.number) | .[] |
    "- "
    + .title
    + " (#"
    + (.number | tostring)
    + ")\n    by @"
    + .login
    + " at "
    + .created_at
    + "\n    at "
    + .html_url
    '
}

function fetch-issues() {
  local repo=$1
  [[ -z "$repo" ]] && echo "Empty repository string" && exit 9
  gh api --paginate --method GET -F per_page=100 "/repos/${repo}/issues?state=open&since=$(date -d "$OLDEST" -Is)" | \
    jq "[
      .[] | select(
        ( # has labels, and assignee
          isempty(.labels | .[]) and
          isempty(.assignees | .[])
        ) and ( # is not authored by one of us
          .user.login | test(\"${MEMBERS}\") | not
        ) and ( # creation time is older than 2 days
          .created_at | fromdateiso8601 < $(date -d "$NEWEST" +%s)
        )
      ) | {
        title,
        html_url,
        number,
        login: .user.login,
        created_at,
        url,
        comments,
        comments_url
      }
    ]"
}

function filter-out-answered-issues() {
  local comment_urls issue_url issues_with_comments issues
  local -a has_comments

  issues="$1"
  comment_urls=$(jq -r '.[] | select(.comments != 0) | .comments_url' <<<"$issues")

  # Fetch comments of issue and check if it has comments by MEMBERS
  while read -r url; do
    [[ -z "$url" ]] && continue
    issue_url=$(gh api --method GET -F per_page=100 "${url}?since=$(date -d "$OLDEST" -Is)" | \
      jq -r "[ .[] | select(
          # is authored by one of us
          .user.login | test(\"${MEMBERS}\")
        ) | .issue_url ] | unique | .[]"
      )
    if [[ -n "$issue_url" ]]; then
      has_comments+=("$issue_url")
    fi
  done <<<"$comment_urls"

  issues_with_comments=$(IFS="|"; echo "${has_comments[*]}")

  # Filter out issues that have comments from MEMBERS
  if [[ -n "$issues_with_comments" ]]; then
    printf "%s" "$issues" | jq "[
        .[] | select(
          # does not have a comment from us
          .url | test(\"${issues_with_comments}\") | not
        )
      ]"
  else
    printf "%s" "$issues"
  fi

}

function is-empty() {
  [[ -z "$1" ]] || [[ "$(jq '. == []' <<<"$1")" == true ]]
}

function join_by() {
  local delim=$1 first=$2
  if shift 2; then
    printf %s "$first" "${@/#/$delim}"
  fi
}

function summarize-repos() {
  [[ -z "$*" ]] && exit 9
  count=$#

  if [[ "$count" -gt 3 ]]; then
    echo "multiple repositories"
  else
    join_by ", " "$@"
  fi
}

function generate-email() {
  SUBJECT="$SUBJECT_PRE $(summarize-repos "${!PRETTY_ISSUES[@]}")"
  cat <<MAIL
To: ${TO}
From: ${FROM}
Subject: ${SUBJECT}

There are issues without answers from members of the specified org.

Org: $ORG
Checked repos: ${REPOS[*]}
Filtered by oldest="$OLDEST" and newest="$NEWEST"

MAIL

for repo in "${!PRETTY_ISSUES[@]}"; do
  cat <<ISSUES
Repository: ${repo}

${PRETTY_ISSUES["$repo"]}

ISSUES
done
}

function send-notify() {
  if [[ "$CAT_ONLY" == true ]]; then
    cat
  else
    if [[ "$SENDMAIL_ACCOUNT" != default ]]; then
      sendmail -a "$SENDMAIL_ACCOUNT" -i -t
    else
      sendmail -i -t
    fi
  fi
}

### MAIN ###

# Fetch current members of $ORG
MEMBERS=$(
  gh api --method GET -F per_page=100 "/orgs/${ORG}/members" | \
    jq -r '[ .[] | .login ] | join("|")'
)

# Create an associative array
declare -A collected_issues

for repo in "${REPOS[@]}"; do
  issues=$(fetch-issues "$repo")
  issues=$(filter-out-answered-issues "$issues")

  if ! is-empty "$issues"; then
    collected_issues["$repo"]="$issues"
  fi
done

if [[ "${#collected_issues[@]}" != 0 ]]; then
  declare -A PRETTY_ISSUES
  for repo in "${!collected_issues[@]}"; do
    PRETTY_ISSUES["$repo"]=$(prettify-issues "${collected_issues["$repo"]}")
  done

  # generate-email uses the PRETTY_ISSUES variable
  generate-email | send-notify
fi
